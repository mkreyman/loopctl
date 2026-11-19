defmodule Loopctl.Delivery.EscalationHandoffs do
  @moduledoc """
  Every escalated story becomes a claimable handoff on its REPO's channel (#1065, #1067).

  Mark, 2026-11-19: *"I don't want any handoffs/issues "parked". The entire point of this
  automation and workflow is to get every issue resolved, one way or another, without
  involving me personally."* An escalated story waits for `:human_resolution`, and the
  escalation inbox and the daily digest only make it FINDABLE. The coordination channel's
  handoffs are what reach a working session: SessionStart puts unclaimed ones in front of the
  next session on the repo, and a claim gives one session exactly-once custody. So this sweep
  turns the one queue into the other.

  ## Which channel (#1067)

  The channel a session on the repo reads and may claim on: the project
  `Projects.resolve_project/2` returns for the repo of the story's ONE active intake source
  (`repo_full_name`), the same answer `resolve_project({repo_url})` gives a session. NOT the
  story's work project: a delivery work project may carry no `repo_url` at all (chg-delivery),
  so the repo resolves to a different project (the `chg` kb scope), and claude-config's
  `gate-channel-claim-scope.sh` refuses a session's claim on another repo's channel. A handoff
  posted on the work project was one no session in the repo could claim or finish.

  Only when the story's project has no single active intake source, or its repo resolves to no
  project (or to two), does the handoff fall back to the work project, with a warning logged.

  ## The sweep (`sweep_tenant/2`, every five minutes)

  For each escalated story of the tenant, the handoff keyed
  `handoff:<repo>:escalation-<story_id>-g<generation>`, where `<repo>` is the basename of the
  intake source's `repo_full_name` (else of the channel project's `repo_url`, else its slug),
  the same anchor the `/handoff` skill derives:

  - **none posted** → post generation 1;
  - **the newest generation sits on another channel, or under another repo name** (it was
    posted before #1067, or the source moved) → it is closed, and generation + 1 is posted on
    the right channel, so a story never has two open handoffs;
  - **its claim is DONE while the story is still escalated** → the session finished the
    handoff without resolving the escalation; logged, and generation + 1 is posted superseding
    the earlier generations' posts, so the story is never left with no open handoff;
  - **a live claim** → nothing; a session owns it;
  - **unclaimed (or the claim's lease expired) and escalated for more than
    `#{24}` hours, with no pointer in the last 24 hours** → a STALLED pointer is re-posted on
    the same key, once per UTC day, so the handoff is surfaced again as the newest pointer.

  And for every open escalation handoff whose story has LEFT `escalated` (resolved), its claim
  is marked done, so neither queue keeps a stale row: a fresh `done` claim when nobody claimed
  it, and `done_at` on a claim a session still holds (the work it claimed is finished, by
  whoever resolved it).

  ## Closing on resolution (#1067)

  The sweep's close runs up to five minutes after the resolve, so `close_story/3` is also
  called by `Loopctl.Delivery.Escalations.resolve/3` right after `:human_resolution` commits:
  a session that resolves the story sees its handoff gone at once. It is best-effort; a
  failure is logged and the next sweep closes the handoff. Before posting a NEW generation the
  sweep re-reads the story's stage, so a resolve that lands while a sweep is running does not
  leave a fresh "still escalated" handoff behind it.

  ## What the body carries, and what it does not

  The story id, its reason class and edge, the age, and the steps. Never
  `escalation_reason`: it is untrusted, often session-authored text, and a handoff's preview is
  injected into every peer session's SessionStart. The body points at `escalation_list` and
  `story_stage`, which return the reason fenced.

  ## Who resolves

  `resolve_escalation` needs a `:user` key no dispatch minted (`LOOPCTL_USER_KEY` in an
  interactive fleet session). That is the intended path: the session that claims the handoff
  resolves the escalation itself, then marks the handoff done. Nothing here involves Mark.

  ## Retries and concurrency

  Each post is a keyed slot (`(tenant, project, agent, session_id, key)` is unique), so a
  retried run, or two nodes running the sweep at once, posts nothing twice: a slot collision
  reads as already posted. Closing writes `done_at` only where it is NULL.

  Runs on `AdminRepo` with an explicit `tenant_id` on every query.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Delivery.EscalationInbox
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source
  alias Loopctl.Projects
  alias Loopctl.Projects.Project

  require Logger

  @agent_name "system:escalation-handoff"
  @session "loopctl:escalation-handoff"
  @stale_hours 24
  @page 100
  @close_limit 500

  @type outcome :: %{
          posted: non_neg_integer(),
          reposted: non_neg_integer(),
          moved: non_neg_integer(),
          refreshed: non_neg_integer(),
          closed: non_neg_integer(),
          errors: [term()]
        }

  @doc "The reserved name of the system agent the handoffs are posted as."
  @spec agent_name() :: String.t()
  def agent_name, do: @agent_name

  @doc "Hours an escalation may sit unclaimed before its handoff is re-posted as stalled."
  @spec stale_hours() :: pos_integer()
  def stale_hours, do: @stale_hours

  @doc "The handoff key of generation `generation` for `story_id` on the repo named `repo`."
  @spec handoff_key(String.t(), Ecto.UUID.t(), pos_integer()) :: String.t()
  def handoff_key(repo, story_id, generation),
    do: "handoff:#{repo}:escalation-#{story_id}-g#{generation}"

  @doc """
  The tenants this sweep has work in: every tenant holding an escalated story, plus every
  tenant holding an open escalation handoff (which may need closing). Tenant ids only.
  """
  @spec tenants(DateTime.t()) :: [Ecto.UUID.t()]
  def tenants(%DateTime{} = now) do
    escalated =
      from(s in StoryStage, where: s.stage == :escalated, distinct: true, select: s.tenant_id)

    open =
      from(p in ChannelPost,
        as: :post,
        where: like(p.key, "handoff:%:escalation-%") and like(p.session_id, ^"#{@session}%"),
        where: p.expires_at > ^now,
        where: not exists(done_claim(:post)),
        distinct: true,
        select: p.tenant_id
      )

    Enum.uniq(AdminRepo.all(escalated) ++ AdminRepo.all(open))
  end

  @doc """
  One tenant's sweep as of `now`. See the moduledoc.

  `:escalated` is the inbox rows the sweep works from, read through `EscalationInbox.list/2`
  when absent. It is an input so a test can hand the sweep a list read BEFORE a resolve
  landed, which is the race `still_escalated?/2` exists for.
  """
  @spec sweep_tenant(Ecto.UUID.t(), DateTime.t(), keyword()) :: outcome()
  def sweep_tenant(tenant_id, %DateTime{} = now, opts \\ []) do
    acc = %{posted: 0, reposted: 0, moved: 0, refreshed: 0, closed: 0, errors: []}

    case Keyword.get_lazy(opts, :escalated, fn -> escalated(tenant_id) end) do
      [] ->
        close_resolved(tenant_id, MapSet.new(), now, acc)

      rows ->
        case EscalationInbox.system_agent(tenant_id, @agent_name) do
          {:ok, agent_id} ->
            channels = channels(tenant_id, rows)
            acc = Enum.reduce(rows, acc, &ensure(tenant_id, agent_id, channels, &1, now, &2))
            close_resolved(tenant_id, MapSet.new(rows, & &1.story_id), now, acc)

          {:error, reason} ->
            %{acc | errors: [reason]}
        end
    end
  end

  # Every escalated row of the tenant, through the inbox's own read and its classification.
  defp escalated(tenant_id), do: escalated(tenant_id, nil, [])

  defp escalated(tenant_id, cursor, acc) do
    {:ok, page} = EscalationInbox.list(tenant_id, limit: @page, cursor: cursor)
    acc = acc ++ page.data

    if page.has_more,
      do: escalated(tenant_id, page.next_cursor, acc),
      else: acc
  end

  # Work project id => %{project_id: the channel to post on, repo: the anchor's repo part}.
  # See "Which channel" in the moduledoc.
  defp channels(tenant_id, rows) do
    ids = rows |> Enum.map(& &1.project_id) |> Enum.uniq()

    projects =
      from(p in Project,
        where: p.tenant_id == ^tenant_id and p.id in ^ids,
        select: {p.id, {p.repo_url, p.slug}}
      )
      |> AdminRepo.all()
      |> Map.new()

    sources =
      from(s in Source,
        where: s.tenant_id == ^tenant_id and s.project_id in ^ids and is_nil(s.revoked_at),
        select: {s.project_id, s.repo_full_name}
      )
      |> AdminRepo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(ids, fn id ->
      {url, slug} = Map.get(projects, id, {nil, nil})
      {id, channel(tenant_id, id, url, slug, Map.get(sources, id, []))}
    end)
  end

  defp channel(tenant_id, project_id, url, slug, [repo]) do
    case Projects.resolve_project(tenant_id, repo_url: repo) do
      {:ok, %Project{id: channel_id}, _matched_by} ->
        %{project_id: channel_id, repo: repo_name(repo, slug)}

      {:error, reason} ->
        work_project(tenant_id, project_id, url, slug, {:repo_unresolved, repo, reason})
    end
  end

  defp channel(tenant_id, project_id, url, slug, sources),
    do: work_project(tenant_id, project_id, url, slug, {:active_intake_sources, length(sources)})

  defp work_project(tenant_id, project_id, url, slug, why) do
    Logger.warning(
      "EscalationHandoffs: no repo channel for project #{project_id} (#{inspect(why)}); " <>
        "posting its escalation handoffs on the work project",
      tenant_id: tenant_id
    )

    %{project_id: project_id, repo: repo_name(url, slug)}
  end

  @doc """
  The repo part of a handoff anchor: the basename of `repo_url` without `.git`, else the
  project slug.
  """
  @spec repo_name(String.t() | nil, String.t() | nil) :: String.t()
  def repo_name(url, slug) when is_binary(url) and url != "" do
    url
    |> String.trim_trailing("/")
    |> String.split(["/", ":"])
    |> List.last()
    |> String.replace_suffix(".git", "")
    |> case do
      "" -> slug || "repo"
      name -> name
    end
  end

  def repo_name(_url, slug), do: slug || "repo"

  defp ensure(tenant_id, agent_id, channels, row, now, acc) do
    target = Map.fetch!(channels, row.project_id)

    case latest(tenant_id, row.story_id) do
      nil ->
        post(tenant_id, agent_id, row, target, 1, @session, :new, now)
        |> tally(:posted, acc)

      %{generation: g} = latest ->
        cond do
          not on_target?(latest, target, row.story_id) ->
            move(tenant_id, agent_id, row, target, latest, now, acc)

          match?(%ChannelClaim{done_at: %DateTime{}}, latest.claim) ->
            replace(tenant_id, agent_id, row, target, g, now, acc)

          live?(latest.claim, now) or not stalled?(row, latest.newest_at, now) ->
            acc

          true ->
            session = "#{@session}:#{Date.to_iso8601(DateTime.to_date(now))}"

            post(tenant_id, agent_id, row, target, g, session, :stalled, now)
            |> tally(:refreshed, acc)
        end
    end
  end

  defp on_target?(latest, target, story_id),
    do:
      latest.project_id == target.project_id and
        latest.key == handoff_key(target.repo, story_id, latest.generation)

  # The newest generation is on another channel (posted before #1067, or the repo's source
  # moved): close it there and post the next generation where the repo's sessions read.
  defp move(tenant_id, agent_id, row, target, latest, now, acc) do
    if still_escalated?(tenant_id, row.story_id) do
      case close(tenant_id, latest.project_id, latest.key, now) do
        :ok ->
          post(tenant_id, agent_id, row, target, latest.generation + 1, @session, :new, now)
          |> tally(:moved, acc)

        {:error, reason} ->
          %{acc | errors: [{latest.key, reason} | acc.errors]}
      end
    else
      acc
    end
  end

  defp replace(tenant_id, agent_id, row, target, g, now, acc) do
    if still_escalated?(tenant_id, row.story_id) do
      Logger.warning(
        "EscalationHandoffs: handoff #{handoff_key(target.repo, row.story_id, g)} was " <>
          "finished while its story is still escalated; posting generation #{g + 1}",
        tenant_id: tenant_id
      )

      post(tenant_id, agent_id, row, target, g + 1, @session, :reposted, now)
      |> tally(:reposted, acc)
    else
      acc
    end
  end

  # Re-read before a NEW generation is posted: the escalated list was read at the start of the
  # sweep, and a resolve landing since then has already closed the handoff (`close_story/3`).
  # Posting "still escalated" on top of it would reopen what the resolve just closed.
  defp still_escalated?(tenant_id, story_id) do
    AdminRepo.exists?(
      from s in StoryStage,
        where: s.tenant_id == ^tenant_id and s.story_id == ^story_id and s.stage == :escalated
    )
  end

  defp live?(%ChannelClaim{lease_expires_at: lease}, now),
    do: DateTime.compare(lease, now) == :gt

  defp live?(nil, _now), do: false

  defp stalled?(row, newest_at, now) do
    bound = DateTime.add(now, -@stale_hours * 3_600, :second)

    DateTime.compare(row.escalated_at, bound) == :lt and
      DateTime.compare(newest_at, bound) == :lt
  end

  # The newest generation this sweep posted for the story, on ANY channel of the tenant: its
  # channel, key, claim and newest pointer.
  defp latest(tenant_id, story_id) do
    from(p in story_handoffs(tenant_id, story_id),
      group_by: [p.project_id, p.key],
      select: {p.project_id, p.key, max(p.inserted_at)}
    )
    |> AdminRepo.all()
    |> Enum.flat_map(fn {project_id, key, at} ->
      case generation(key, story_id) do
        nil -> []
        g -> [%{generation: g, project_id: project_id, key: key, newest_at: at}]
      end
    end)
    |> Enum.max_by(&{&1.generation, &1.newest_at}, fn -> nil end)
    |> case do
      nil -> nil
      latest -> Map.put(latest, :claim, claim(tenant_id, latest.project_id, latest.key))
    end
  end

  # The story id is a UUID, so it holds no LIKE metacharacter to escape.
  defp story_handoffs(tenant_id, story_id) do
    from p in ChannelPost,
      as: :post,
      where: p.tenant_id == ^tenant_id and like(p.session_id, ^"#{@session}%"),
      where: like(p.key, ^"handoff:%:escalation-#{story_id}-g%")
  end

  defp generation(key, story_id) do
    case String.split(key, ":escalation-#{story_id}-g") do
      [_repo, digits] ->
        case Integer.parse(digits) do
          {g, ""} when g > 0 -> g
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp claim(tenant_id, project_id, ref) do
    AdminRepo.one(
      from c in ChannelClaim,
        where: c.tenant_id == ^tenant_id and c.project_id == ^project_id and c.ref == ^ref
    )
  end

  defp post(tenant_id, agent_id, row, target, generation, session, why, now) do
    key = handoff_key(target.repo, row.story_id, generation)

    attrs = %{
      body: body(row, key, why, now),
      key: key,
      session_id: session,
      refs: [%{"type" => "story", "value" => row.story_id}]
    }

    case Coordination.create_post(tenant_id, target.project_id, agent_id, attrs) do
      {:ok, post} ->
        if why == :reposted, do: supersede_earlier(post, row.story_id)
        :posted

      {:error, %Ecto.Changeset{errors: errors}} ->
        if slot_taken?(errors), do: :already, else: {:error, {key, Keyword.keys(errors)}}

      {:error, :unprocessable_entity, message} ->
        {:error, {key, message}}

      {:error, reason} ->
        {:error, {key, reason}}
    end
  end

  # A re-escalation's generation retires the earlier generations' pointers on its channel, so
  # their instructions read as stale and a claim on their refs is refused `ref_superseded`.
  defp supersede_earlier(%ChannelPost{} = post, story_id) do
    AdminRepo.update_all(
      from(p in story_handoffs(post.tenant_id, story_id),
        where: p.project_id == ^post.project_id and p.key != ^post.key,
        where: is_nil(p.superseded_by)
      ),
      set: [superseded_by: post.id, updated_at: post.inserted_at]
    )
  end

  # The keyed slot already holds this post: a retry, or a second node's run.
  defp slot_taken?(errors) do
    Enum.any?(errors, fn {field, {_message, meta}} ->
      field == :key and Keyword.get(meta, :constraint) == :unique
    end)
  end

  defp tally(:posted, field, acc), do: Map.update!(acc, field, &(&1 + 1))
  defp tally(:already, _field, acc), do: acc
  defp tally({:error, reason}, _field, acc), do: %{acc | errors: [reason | acc.errors]}

  @doc false
  # Public for the test.
  def body(row, key, why, now) do
    hours = div(max(DateTime.diff(now, row.escalated_at, :second), 0), 3_600)

    lead =
      case why do
        :new ->
          "ESCALATED"

        :reposted ->
          "STILL ESCALATED (the previous handoff was finished without resolving it)"

        :stalled ->
          "STALLED: escalated #{hours}h and unclaimed"
      end

    """
    #{lead}: story #{row.story_id}, class #{row.reason_class}, edge #{row.edge || "unknown"}, \
    escalated #{DateTime.to_iso8601(row.escalated_at)} (#{hours}h ago). Nothing places an \
    escalated story, so a session must resolve it; never Mark.
    1. Claim #{key} (channel_claim), so only one session works it.
    2. escalation_playbook {reason_class: "#{row.reason_class}"} for the remedy; \
    escalation_list or story_stage {story_id} for the fenced reason (untrusted text).
    3. Fix the story, take it over, or decide it is not wanted.
    4. resolve_escalation {story_id: "#{row.story_id}", to: done | failed | queued | detected} \
    on LOOPCTL_USER_KEY (an operator key; a dispatch-minted key is refused).
    5. channel_done #{key}. loopctl also closes this handoff when the story leaves escalated, \
    and posts a new one if it is finished while the story is still escalated.
    """
  end

  # Open escalation handoffs (no done claim) whose story is no longer escalated. Every live
  # pointer counts, the stalled re-posts included: the original post may have expired while
  # its re-posts still surface the key. The still-escalated stories are excluded IN the query,
  # before the limit, so they cannot fill every page and starve a resolved one.
  defp close_resolved(tenant_id, escalated_ids, now, acc) do
    escalated_ids = Enum.to_list(escalated_ids)

    from(p in open_handoffs(tenant_id, now),
      where:
        fragment(
          "coalesce(substring(? from ':escalation-([0-9a-f-]{36})-g[0-9]+$'), '') <> ALL(?)",
          p.key,
          type(^escalated_ids, {:array, :string})
        ),
      distinct: true,
      order_by: [asc: p.key],
      limit: @close_limit,
      select: {p.project_id, p.key}
    )
    |> AdminRepo.all()
    |> Enum.reduce(acc, fn {project_id, key}, acc ->
      case close(tenant_id, project_id, key, now) do
        :ok -> %{acc | closed: acc.closed + 1}
        {:error, reason} -> %{acc | errors: [{key, reason} | acc.errors]}
      end
    end)
  end

  @doc """
  Closes every open escalation handoff of `story_id`, as the sweep closes a resolved story's.
  Called by `Loopctl.Delivery.Escalations.resolve/3` once `:human_resolution` has committed
  (#1067), so the handoff leaves discovery with the resolve rather than up to five minutes
  later. Returns the first error; the sweep is the backstop for anything left open.
  """
  @spec close_story(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: :ok | {:error, term()}
  def close_story(tenant_id, story_id, %DateTime{} = now) do
    from(p in story_handoffs(tenant_id, story_id),
      where: p.expires_at > ^now,
      where: not exists(done_claim(:post)),
      distinct: true,
      select: {p.project_id, p.key}
    )
    |> AdminRepo.all()
    |> Enum.reduce_while(:ok, fn {project_id, key}, :ok ->
      case close(tenant_id, project_id, key, now) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp open_handoffs(tenant_id, now) do
    from p in ChannelPost,
      as: :post,
      where: p.tenant_id == ^tenant_id and like(p.session_id, ^"#{@session}%"),
      where: like(p.key, "handoff:%:escalation-%"),
      where: p.expires_at > ^now,
      where: not exists(done_claim(:post))
  end

  defp done_claim(binding) do
    from c in ChannelClaim,
      where:
        c.tenant_id == parent_as(^binding).tenant_id and
          c.project_id == parent_as(^binding).project_id and
          c.ref == parent_as(^binding).key and not is_nil(c.done_at)
  end

  # A claim a session holds is marked done in place; an unclaimed ref gets a done claim by the
  # system agent, which is what takes a handoff out of discovery for good.
  defp close(tenant_id, project_id, key, now) do
    {n, _} =
      AdminRepo.update_all(
        from(c in ChannelClaim,
          where:
            c.tenant_id == ^tenant_id and c.project_id == ^project_id and c.ref == ^key and
              is_nil(c.done_at)
        ),
        set: [done_at: now, updated_at: now]
      )

    if n == 1,
      do: log_closed(tenant_id, key, :claimed),
      else: insert_done(tenant_id, project_id, key, now)
  end

  defp insert_done(tenant_id, project_id, key, now) do
    with {:ok, agent_id} <- EscalationInbox.system_agent(tenant_id, @agent_name) do
      AdminRepo.insert_all(
        ChannelClaim,
        [
          %{
            id: Ecto.UUID.generate(),
            tenant_id: tenant_id,
            project_id: project_id,
            claimant_agent_id: agent_id,
            ref: key,
            claimed_at: now,
            lease_expires_at: now,
            done_at: now,
            claimed_by_session: @session,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :project_id, :ref]
      )

      log_closed(tenant_id, key, :unclaimed)
    end
  end

  defp log_closed(tenant_id, key, how) do
    Logger.info("EscalationHandoffs: closed #{key} (#{how}): its story left escalated",
      tenant_id: tenant_id
    )

    :ok
  end
end
