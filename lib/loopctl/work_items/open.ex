defmodule Loopctl.WorkItems.Open do
  @moduledoc """
  Interactive work on a branch becomes a work item (US-52.18).

  An interactive session's MCP server opens the item for the branch its worktree is on,
  with the session's holder credential. The open is the holder recording its own work,
  atomic with its claim: one story in the repo's project, already `implementing`, held by
  the caller, with a stage row at `implementing` that names the branch. It carries no
  acceptance criteria and reaches `verified` only through report, review and verify like
  any story, so the custody gates are untouched; the caller cannot report it
  (`self_report_blocked`).

  ## One item per (project, branch)

  Opens of one `(tenant, project, branch)` take a transaction-scoped advisory lock first
  (`pg_advisory_xact_lock`), ahead of every row lock, a lock nothing else takes. So two
  racing opens yield one item: the second waits, then reads the first's item and answers
  it (the same holder) or `branch_held` (another holder). An item is open while its stage
  row is at any stage but `done` or `failed`.

  ## Repo

  One `AdminRepo` transaction with an explicit `tenant_id` predicate on every query, because
  the claim it makes is a claim: `Loopctl.Progress`' claim, its stage follower
  (`Stages.follow_claim/4`) and the item log (`Stages.record_item_event/4`) all run on
  `AdminRepo`, and one transaction is what makes the story, its claim, its stage row and its
  events commit together or not at all.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Changes.ReviewCustody
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Holders.Holder
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Projects
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story

  @max_branch_bytes 255
  @max_title_chars 500
  # A unique-number collision with a concurrent create in the same project (another branch,
  # or triage) aborts the whole transaction; the next attempt reads a free number.
  @attempts 3
  @closed_stages [:done, :failed]

  @typedoc "The opener, resolved SERVER-SIDE from the authenticating key, never from params."
  @type opener :: %{
          required(:api_key_id) => Ecto.UUID.t(),
          required(:agent_id) => Ecto.UUID.t() | nil,
          required(:holder_id) => Ecto.UUID.t() | nil,
          optional(:dispatch_id) => Ecto.UUID.t() | nil,
          optional(:minting_lineage) => [Ecto.UUID.t()]
        }

  @type outcome :: :created | :existing | :claimed | :branch_recorded

  @type refusal ::
          :holder_credential_required
          | :holder_ended
          | :holder_lease_expired
          | :invalid_branch
          | :invalid_repo_url
          | :project_not_found
          | :ambiguous_project
          | :no_target_epic
          | :epic_not_found
          | :story_held
          | :chg_root_review_only
          | {:branch_held, Ecto.UUID.t(), Ecto.UUID.t() | nil}
          | Ecto.Changeset.t()
          | atom()

  @doc "The longest branch name an open accepts, in bytes."
  @spec max_branch_bytes() :: pos_integer()
  def max_branch_bytes, do: @max_branch_bytes

  @doc """
  Opens the work item for `attrs.branch` in the project `attrs.repo_url` resolves to.

  `attrs`: `repo_url` and `branch` (required), `title` (default: the branch) and `epic_id`
  (default: the target epic of the project's one live intake source).

  Returns `{:ok, outcome, story}` where `outcome` is `:created` (a new item), `:existing`
  (the caller's own item, or an unheld item past the claim), `:claimed` (an unheld item
  taken back by the caller) or `:branch_recorded` (the caller's one unbranched item now
  names the branch); or `{:error, refusal}`.
  """
  @spec open_interactive(Ecto.UUID.t(), opener(), map(), keyword()) ::
          {:ok, outcome(), Story.t()} | {:error, refusal()}
  def open_interactive(tenant_id, opener, attrs, opts \\ []) do
    with :ok <- holder_credential(opener),
         {:ok, branch} <- branch(attr(attrs, :branch)),
         {:ok, project} <- project(tenant_id, attr(attrs, :repo_url)),
         :ok <-
           ReviewCustody.refuse_chg_root(
             tenant_id,
             Map.get(opener, :minting_lineage, []),
             :chg_root_review_only
           ) do
      request = %{
        tenant_id: tenant_id,
        project: project,
        branch: branch,
        title: title(attr(attrs, :title), branch),
        epic_id: attr(attrs, :epic_id),
        opener: opener
      }

      attempt(request, Keyword.get(opts, :attempts, @attempts))
    end
  end

  defp attempt(request, attempts_left) do
    case AdminRepo.transaction(fn -> open_locked(request) end) do
      {:error, %Ecto.Changeset{} = changeset} when attempts_left > 1 ->
        if number_taken?(changeset),
          do: attempt(request, attempts_left - 1),
          else: {:error, changeset}

      {:ok, {outcome, story}} ->
        {:ok, outcome, story}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp number_taken?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {field, _} -> field in [:tenant_id, :project_id, :number] end)

  defp open_locked(request) do
    %{tenant_id: tenant_id, project: project, branch: branch} = request
    lock_branch(tenant_id, project.id, branch)

    result =
      with {:ok, holder} <- live_holder(tenant_id, request.opener.holder_id) do
        case open_item_on_branch(tenant_id, project.id, branch) do
          %Story{} = story -> reopen(request, holder, story)
          nil -> record_or_create(request, holder)
        end
      end

    case result do
      {:ok, outcome, story} -> {outcome, story}
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  # ── the caller ─────────────────────────────────────────────────────────────

  defp holder_credential(%{holder_id: holder_id}) when is_binary(holder_id), do: :ok
  defp holder_credential(_opener), do: {:error, :holder_credential_required}

  defp live_holder(tenant_id, holder_id) do
    from(h in Holder,
      where: h.id == ^holder_id and h.tenant_id == ^tenant_id,
      lock: "FOR SHARE"
    )
    |> AdminRepo.one()
    |> case do
      %Holder{ended_at: nil} = holder -> live_lease(holder)
      %Holder{} -> {:error, :holder_ended}
      nil -> {:error, :holder_credential_required}
    end
  end

  # US-52.19: the item is claimed on the holder's lease, so a lapsed holder opens nothing.
  defp live_lease(%Holder{lease_until: lease_until} = holder) do
    if DateTime.after?(lease_until, DateTime.utc_now()),
      do: {:ok, holder},
      else: {:error, :holder_lease_expired}
  end

  # ── inputs ─────────────────────────────────────────────────────────────────

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  # A branch is one line of printable text with no whitespace (git refuses those in a ref
  # name too), and never `HEAD`: a detached worktree is not on a branch.
  defp branch(branch) when is_binary(branch) do
    cond do
      branch == "" or byte_size(branch) > @max_branch_bytes -> {:error, :invalid_branch}
      branch == "HEAD" -> {:error, :invalid_branch}
      not String.valid?(branch) -> {:error, :invalid_branch}
      String.match?(branch, ~r/[\s\x00-\x1f\x7f]/u) -> {:error, :invalid_branch}
      true -> {:ok, branch}
    end
  end

  defp branch(_branch), do: {:error, :invalid_branch}

  defp title(title, branch) when is_binary(title) do
    case String.trim(title) do
      "" -> title(nil, branch)
      trimmed -> String.slice(trimmed, 0, @max_title_chars)
    end
  end

  defp title(_title, branch), do: String.slice(branch, 0, @max_title_chars)

  # Only the caller's own tenant is searched (`resolve_project/2` takes the tenant id), so a
  # repo another tenant holds is the same `project_not_found` as a repo nobody holds.
  defp project(tenant_id, repo_url) when is_binary(repo_url) and repo_url != "" do
    case Projects.resolve_project(tenant_id, repo_url: repo_url) do
      {:ok, project, _matched_by} -> {:ok, project}
      {:error, :ambiguous} -> {:error, :ambiguous_project}
      {:error, _not_found} -> {:error, :project_not_found}
    end
  end

  defp project(_tenant_id, _repo_url), do: {:error, :invalid_repo_url}

  # ── locks and reads ────────────────────────────────────────────────────────

  defp lock_branch(tenant_id, project_id, branch) do
    AdminRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      lock_key(tenant_id, project_id, branch)
    ])
  end

  @doc false
  # Public for the race test, which holds the same lock to prove an open waits on it.
  @spec lock_key(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: String.t()
  def lock_key(tenant_id, project_id, branch),
    do: "work_item_open:" <> tenant_id <> ":" <> project_id <> ":" <> branch

  # The project's open item on `branch`, locked: the stage row names the branch and is not
  # finished. Oldest first, so a (legacy) pair always answers the same one.
  defp open_item_on_branch(tenant_id, project_id, branch) do
    story_id =
      from(st in StoryStage,
        join: s in Story,
        on: s.id == st.story_id and s.tenant_id == st.tenant_id,
        where: st.tenant_id == ^tenant_id and s.project_id == ^project_id,
        where: st.branch == ^branch and st.stage not in ^@closed_stages,
        order_by: [asc: s.inserted_at, asc: s.id],
        limit: 1,
        select: s.id
      )
      |> AdminRepo.one()

    story_id && lock_story(tenant_id, story_id)
  end

  defp lock_story(tenant_id, story_id) do
    from(s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id, lock: "FOR UPDATE")
    |> AdminRepo.one()
  end

  defp stage_row(tenant_id, story_id) do
    from(st in StoryStage,
      where: st.tenant_id == ^tenant_id and st.story_id == ^story_id,
      lock: "FOR UPDATE"
    )
    |> AdminRepo.one()
  end

  # ── an item already on the branch (AC-52.18.4, AC-52.18.5) ─────────────────

  defp reopen(_request, %Holder{id: holder_id}, %Story{assigned_holder_id: holder_id} = story),
    do: {:ok, :existing, story}

  defp reopen(request, holder, %Story{assigned_holder_id: nil, agent_status: status} = story)
       when status in [:pending, :contracted] do
    if MapSet.member?(Stages.held_story_ids(request.tenant_id, [story.id]), story.id),
      do: {:error, :story_held},
      else: take_back(request, holder, story)
  end

  # Unheld but past the claim (reported, reviewed): the item exists and the open names it,
  # without moving custody state backwards.
  defp reopen(_request, _holder, %Story{assigned_holder_id: nil} = story)
       when story.agent_status not in [:assigned, :implementing],
       do: {:ok, :existing, story}

  defp reopen(_request, _holder, %Story{} = story),
    do: {:error, {:branch_held, story.id, story.assigned_holder_id}}

  # A session that re-registered after its holder lapsed takes its own branch's item back:
  # the claim fields, a new epoch, the stage row rebound to it and moved back to
  # `implementing`, and a `claimed` item event, all in this transaction.
  defp take_back(request, holder, story) do
    %{tenant_id: tenant_id, branch: branch} = request

    with {:ok, claimed} <- claim(request, holder, story) do
      {:ok, row} =
        Stages.follow_claim(
          tenant_id,
          claimed.id,
          claimed.claim_epoch,
          event_opts(request, holder)
        )

      {:ok, _row} =
        case row do
          %StoryStage{} ->
            Stages.start_for_change_in_tenant_transaction(
              row,
              claimed.claim_epoch,
              [repo: AdminRepo, started_by: "interactive_open"] ++ event_opts(request, holder)
            )

          nil ->
            Stages.open_started_in_tenant_transaction(
              tenant_id,
              claimed.id,
              claimed.claim_epoch,
              [repo: AdminRepo, branch: branch] ++ event_opts(request, holder)
            )
        end

      with {:ok, _event} <- item_event(request, holder, claimed),
           {:ok, _entry} <- audit(request, claimed, "work_item_claimed") do
        {:ok, :claimed, claimed}
      end
    end
  end

  # ── no item on the branch (AC-52.18.6, AC-52.18.1) ─────────────────────────

  defp record_or_create(request, holder) do
    case unbranched_items(request.tenant_id, request.project.id, holder.id) do
      [{story, row}] -> record_branch(request, holder, story, row)
      _none_or_several -> create(request, holder)
    end
  end

  # The caller's held items in this project whose open stage row names no branch.
  defp unbranched_items(tenant_id, project_id, holder_id) do
    from(s in Story,
      join: st in StoryStage,
      on: st.story_id == s.id and st.tenant_id == s.tenant_id,
      where: s.tenant_id == ^tenant_id and s.project_id == ^project_id,
      where: s.assigned_holder_id == ^holder_id and s.agent_status in [:assigned, :implementing],
      where: is_nil(st.branch) and st.stage not in ^@closed_stages,
      limit: 2,
      select: {s.id, st.id}
    )
    |> AdminRepo.all()
    |> Enum.map(fn {story_id, _row_id} ->
      {lock_story(tenant_id, story_id), stage_row(tenant_id, story_id)}
    end)
  end

  defp record_branch(request, holder, story, row) do
    {:ok, _row} =
      Stages.put_started_branch_in_admin_transaction(
        row,
        request.branch,
        event_opts(request, holder)
      )

    {:ok, :branch_recorded, story}
  end

  defp create(request, holder) do
    %{tenant_id: tenant_id, branch: branch} = request

    with {:ok, epic_id} <- epic(request),
         {:ok, number} <- Stories.next_number(tenant_id, epic_id),
         {:ok, story} <-
           Stories.create_story(
             tenant_id,
             %{epic_id: epic_id, number: number, title: request.title},
             actor_id: request.opener.api_key_id,
             actor_label: actor_label(holder)
           ),
         {:ok, claimed} <- claim(request, holder, story),
         {:ok, _row} <-
           Stages.open_started_in_tenant_transaction(
             tenant_id,
             claimed.id,
             claimed.claim_epoch,
             [repo: AdminRepo, branch: branch] ++ event_opts(request, holder)
           ),
         {:ok, _event} <- item_event(request, holder, claimed),
         {:ok, _entry} <- audit(request, claimed, "work_item_opened") do
      {:ok, :created, claimed}
    end
  end

  defp epic(%{epic_id: nil, tenant_id: tenant_id, project: project}) do
    from(s in Source,
      where: s.tenant_id == ^tenant_id and s.project_id == ^project.id,
      where: is_nil(s.revoked_at) and not is_nil(s.target_epic_id),
      distinct: true,
      select: s.target_epic_id
    )
    |> AdminRepo.all()
    |> case do
      [epic_id] -> {:ok, epic_id}
      # None, or live sources that disagree: the caller names the epic.
      _ -> {:error, :no_target_epic}
    end
  end

  defp epic(%{epic_id: epic_id, tenant_id: tenant_id, project: project}) do
    with {:ok, id} <- Ecto.UUID.cast(epic_id),
         %Epic{} <- AdminRepo.get_by(Epic, id: id, tenant_id: tenant_id, project_id: project.id) do
      {:ok, id}
    else
      _ -> {:error, :epic_not_found}
    end
  end

  # ── the claim ──────────────────────────────────────────────────────────────

  defp claim(request, holder, story) do
    now = DateTime.utc_now()

    changes =
      %{
        agent_status: :implementing,
        assigned_agent_id: holder.agent_id,
        assigned_holder_id: holder.id,
        assigned_at: now,
        lifecycle_entered_at: Progress.lifecycle_stamp(story)
      }
      |> Map.merge(Progress.claim_lease_change(story, now, {:holder, holder.lease_until}))
      |> put_dispatch(request.opener)

    story
    |> Ecto.Changeset.change(changes)
    |> AdminRepo.update()
  end

  # The implementer's dispatch, when the opener's key was minted by one: the same
  # provenance a claim records, which the L4 gates compare.
  defp put_dispatch(changes, %{dispatch_id: dispatch_id}) when is_binary(dispatch_id),
    do: Map.put(changes, :implementer_dispatch_id, dispatch_id)

  defp put_dispatch(changes, _opener), do: changes

  defp reason(%{branch: branch}), do: "interactive work started on " <> branch

  defp actor_label(%Holder{id: id}), do: "holder:" <> id

  defp event_opts(request, holder),
    do: [actor_label: actor_label(holder), actor_holder_id: holder.id, reason: reason(request)]

  defp item_event(request, holder, story) do
    Stages.record_item_event(request.tenant_id, story.id, "claimed",
      repo: AdminRepo,
      reason: reason(request),
      actor_holder_id: holder.id,
      actor_label: actor_label(holder),
      data: %{"agent_id" => holder.agent_id, "branch" => request.branch}
    )
  end

  defp audit(request, story, action) do
    Audit.create_log_entry(request.tenant_id, %{
      entity_type: "story",
      entity_id: story.id,
      action: action,
      actor_type: "api_key",
      actor_id: request.opener.api_key_id,
      actor_label: "holder:" <> story.assigned_holder_id,
      new_state: %{
        "branch" => request.branch,
        "project_id" => story.project_id,
        "agent_status" => Atom.to_string(story.agent_status),
        "assigned_holder_id" => story.assigned_holder_id,
        "claim_epoch" => story.claim_epoch
      }
    })
  end
end
