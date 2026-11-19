defmodule Loopctl.Intake do
  @moduledoc """
  GitHub webhook intake for the agent delivery loop (issues #803 and #804).

  ## Sources

  An intake source binds one GitHub repository to one work project under a webhook secret
  (`create_source/3`, `list_sources/2`, `revoke_source/3`). The secret is generated here,
  encrypted at rest, and returned once.

  ## Deliveries

  `receive_github_delivery/2` is the whole of the public webhook, in order:

  1. **Authenticate.** Load the ACTIVE source named by the URL (its tenant active too) and
     verify `X-Hub-Signature-256` over the RAW body in constant time. An unknown id, a
     revoked source, a suspended tenant, a missing or wrong signature all return the same
     `{:error, :unauthorized}`, and an unknown id still computes an HMAC, so neither the
     answer nor its timing says which.
  2. **Decode** the JSON from those same raw bytes.
  3. **Bind the repository.** `repository.full_name` must equal the source's repository,
     case-insensitively, or the answer is the same `:unauthorized`: a valid signature for
     the wrong repository is a misrouted or replayed delivery, not a partial success.
  4. **Record the delivery**, keyed by `X-GitHub-Delivery` under a unique index. A replay
     inserts nothing and changes nothing.
  5. **Apply the event.** `ping` is logged. `issues` with `opened`, `edited`, `reopened`,
     `closed`, `labeled` or `unlabeled` updates the issue's intake record. A `pull_request`
     `closed` with `merged: true` queues `PrReviewOutcomeWorker` (US-50.4) and is recorded as
     `recorded`. Everything else is logged as `ignored`.

  Steps 4 and 5 share one transaction, so a delivery is never marked seen without its
  effect.

  ## Retention

  `prune_deliveries/3` is the delivery log's retention pass, called by
  `Loopctl.Workers.DeliveryLoopPruneWorker`. What the log is FOR decides the predicate:

  - A row is the IDEMPOTENCY EVIDENCE of step 4. Deleting one lets the same
    `X-GitHub-Delivery` be applied a second time, so the window must outlast GitHub's own
    delivery history — GitHub keeps ~30 days and its "Redeliver" button reuses the delivery
    id, so the floor on any tenant's setting is
    `Loopctl.Workers.DeliveryLoopPruneWorker.min_intake_retention_days/0` and the default is
    three times it. Past that window nothing upstream can replay the delivery, so the row is
    disk rather than evidence.
  - A row a RECORD still names as `last_delivery_id` is kept whatever its age. That is the
    provenance of content triage may not have consumed yet, and it costs one row per record.

  Neither clause is the audit trail: an escalation appends to the hash-chained audit log,
  which this never touches.

  ## The record is the queue entry, and its text is untrusted

  An intake record holds reporter text ONLY in `untrusted_*` fields (`Loopctl.Intake.Record`).
  Nothing here creates a story. `Loopctl.Delivery.InjectionDetector` and
  `Loopctl.Intake.TicketFacts` run over the uncapped text of every applied delivery; any
  reason escalates the record, is never cleared by a later delivery, and appends an
  `intake_escalated` entry to the audit chain naming the signals — never the text.

  ## Delivery order

  GitHub does not promise delivery order, and `issue.updated_at` is the only ordering key a
  payload carries. The stored content, `last_action` and `last_delivery_id` move together,
  decided by comparing that timestamp with the stored one:

  - **newer**: applied, and `order_ambiguous` is cleared;
  - **older**: nothing is applied (a stale delivery's signals are still scanned, since they
    arrived signed);
  - **the same second, identical content**: nothing is applied — it restates known state;
  - **the same second, different content**: applied, and the record is marked
    `order_ambiguous` at that second. `updated_at` has one-second precision, so a label
    swap or a bot's close-and-reopen can stamp two deliveries identically, and whichever
    arrived last wins with nothing to say it was really the later event. That is not
    guessed around: **triage must re-read the live issue from GitHub whenever
    `order_ambiguous` is set** (a runner has `gh` access; loopctl does not), and treat the
    stored content as possibly one event behind. The flag clears on the next strictly
    newer delivery, which settles the order.

  An issue's deliveries are ordered against its NEWEST generation (below), and only that one.
  A delivery older than the newest generation's content is dropped there like any other
  older delivery. It is not applied to an earlier generation either, because an earlier
  generation is never written again.

  ## Generations

  An issue has one record per generation (`Loopctl.Intake.Record`, `generation`), unique on
  `(tenant_id, source_id, issue_number, generation)`. Every delivery applies to the NEWEST
  generation. chg closes an issue it filed once the failure has been quiet for a while after
  the merge, and reopens it if the failure comes back. A `reopened` delivery whose newest
  record has reached the end of the loop therefore starts generation N+1 and applies its
  content there. The new record sits at `pending_triage`, and the triage drain takes it like
  any new issue. A record has reached the end of the loop (`loop_ended?/1`) when it has an
  issue-closure row, or when its story's stage is one of `generation_end_stages/0`.

  The bump has to be a delivery that WOULD be applied, newer than the record (or the same
  second with different content). A reopen that is older than what the record already holds
  starts nothing, so a late reopen cannot fork the issue after a newer close.

  Nothing else starts a generation. A reopen of a record whose story is still in flight, or
  that has no story yet, is applied to that record as before. The earlier generation's
  record, story and closure are never written again.

  A new generation inherits its predecessor's escalation (status, reasons, `escalated_at`).
  An escalation is never cleared by a later delivery, and a reopen is a later delivery: a
  reopen must not launder a flagged issue back into the triage queue. The inherited reasons
  get their own `intake_escalated` entry on the new record, naming the generation they came
  from.

  **Which record is newest is decided under the lock, not before it.** `SELECT ... ORDER BY
  generation DESC LIMIT 1 FOR UPDATE` picks its row from the statement's snapshot BEFORE it
  waits. A delivery that queues behind a bump therefore gets generation N once the bump
  commits, although N+1 now exists, because the bump never changes N's row. So after the
  lock is taken, a FRESH statement asks whether a newer generation exists, and if one does
  the delivery locks that one instead, until the row it holds is the newest
  (`newest_locked/2`). It holds every row it passed on the way. A bump holds N's lock while
  it inserts N+1, so a delivery that has the lock on N and has seen no N+1 cannot be
  overtaken. That covers every action: an `edited` lands on N+1, and a second reopen finds
  N+1 with no story and starts nothing. The unique index on the generation stays as a
  backstop. A conflict there would mean a bump without the lock, and it raises rather than
  being absorbed. A replayed delivery never gets this far: step 4's delivery index stops it
  first.

  An earlier generation's closure that is still pending when a later generation starts is
  abandoned by `Loopctl.Delivery.IssueCloser` as `superseded_by_generation`, before any
  forge call. Its story may have ended the loop at `merged`, before its verdict wrote the
  closure. Closing the reopened issue with the old fix's message would answer a report
  that is being triaged again.

  ## Isolation

  `AdminRepo` with an explicit `tenant_id` predicate on every query, as `Loopctl.Runners`
  does. The delivery lookup by source id is the one read without a tenant, because the
  tenant is what it resolves.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.AuditChain
  alias Loopctl.Delivery.InjectionDetector
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Intake.Delivery
  alias Loopctl.Intake.GithubPayload
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Signature
  alias Loopctl.Intake.Source
  alias Loopctl.Intake.TicketFacts
  alias Loopctl.LocalGuc
  alias Loopctl.Projects
  alias Loopctl.Projects.Project
  alias Loopctl.Projects.RepoUrl
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.PrReviewOutcomeWorker

  # The largest webhook body the intake route reads. An `issues` payload with a maximal
  # 65,536-character body, escaped, plus its repository and user objects, stays well under
  # it. `LoopctlWeb.Plugs.IntakeRawBody` enforces it and the OpenAPI spec states it.
  @max_body_bytes 1_048_576

  @issue_actions ~w(opened edited reopened closed labeled unlabeled)

  # The stages at which a story's change has LANDED (`Loopctl.Delivery.StageMachine`). From
  # `merged` on the fix is on trunk, so a recurrence is a new problem for a new triage, not
  # more work on this story. Not `escalated` or `failed`. `escalated` is waiting for a human,
  # who may send it back to `queued` (`:human_resolution`), so the issue is still that
  # story's. A `failed` story shipped nothing. When it failed over `:triage_reject`, the
  # verdict wrote a closure and the closure clause covers it. When it failed over
  # `:budget_exceeded`, nothing in `lib/` writes that edge today.
  @generation_end_stages [:merged, :deployed, :verified, :done]

  # Retention (see "Retention" in the moduledoc). DELIBERATELY an order of magnitude below the
  # trace pruner's, because this half runs on `AdminRepo`, whose pool is 3 connections that
  # `ValidateWitnessHeader` and the Postgres rate limiter touch on every authenticated
  # request. A batch is its own short transaction, so the connection goes back to the pool
  # between batches rather than being held for the run — but the batch is also the longest
  # single statement, so 200 rows keeps it short and the 2,000-row budget keeps a first run
  # after deploy to at most ten of them per tenant. Hourly, that budget still reclaims 48,000
  # deliveries a day per tenant, orders of magnitude above any GitHub webhook rate, so the
  # smaller numbers cost nothing in steady state and only lengthen the initial drain.
  @prune_batch_size 200
  @prune_budget 2_000
  @prune_statement_timeout_ms 15_000
  @prune_lock_timeout_ms 5_000

  @delivery_id_format ~r/\A[A-Za-z0-9-]{1,128}\z/
  @event_format ~r/\A[a-z_]{1,64}\z/

  # Used only to spend an HMAC's worth of work on an unknown source id.
  @timing_key :crypto.hash(:sha256, "loopctl-intake-unknown-source")

  @type delivery_input :: %{
          raw_body: binary(),
          signature: String.t() | nil,
          event: String.t() | nil,
          delivery_id: String.t() | nil,
          content_type: String.t() | nil
        }

  @type outcome :: :ping | :recorded | :ignored | :duplicate

  @doc "The largest webhook body, in bytes, the intake route reads."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The story stages at which a reopen starts an issue's next generation (see Generations)."
  @spec generation_end_stages() :: [atom()]
  def generation_end_stages, do: @generation_end_stages

  @doc "The `issues` actions that update an intake record."
  @spec issue_actions() :: [String.t()]
  def issue_actions, do: @issue_actions

  # ---------------------------------------------------------------------------
  # Sources
  # ---------------------------------------------------------------------------

  @doc """
  Creates an intake source binding `repo_full_name` to the tenant's ACTIVE WORK project
  `project_id`, and records it on the audit chain.

  Returns `{:ok, %{source: source, webhook_secret: secret}}`. The secret is returned once.

  `attrs` may also carry `:mode` (`"pr"`, `"chg"` or `"ledger"`, read by PRESENCE and
  defaulting to `"pr"`; a `"chg"` or `"ledger"` source also needs `:change_events_secret` and
  `:chg_root_dispatch_id`, see `Loopctl.Intake.Source` and `chg_root_invalid` below; a `pr`
  source MAY carry both, and then sends its chg ledger and events too). A `"ledger"` source
  binds an ACTIVE `:kb` SCOPE or an ACTIVE work project (issue #1047): a repository whose
  changes should not route through loopctl gets a ledger credential and nothing else,
  `:target_epic_id` (optional, and `nil` means "not answered") and
  `:base_branch` (optional, and read by PRESENCE: omit it for the `master` default, or name
  the branch this repository's dispatches are cut from — `main` for a repository created on
  GitHub since 2020. It is NOT nullable, so an explicit `nil` or `""` is a validation error
  rather than a silent fallback to the default).

  `{:error, :chg_root_invalid}` when the source would be `chg` and `chg_root_dispatch_id`
  does not name a parentless, unrevoked, orchestrator-role dispatch of THIS tenant
  (`Source.chg_root_requirement/0`). Another tenant's dispatch is the same refusal as an id
  that names nothing, so the answer leaks nothing about other tenants.

  `{:error, {:pr_route_in_flight, story_ids}}` when the source would be `chg` and a story of
  the project still holds a merge allow it has not merged on — see `update_source/4`.

  ## Options

  - `:actor_lineage` — the creating caller's dispatch lineage, for the audit entry.
  """
  @spec create_source(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{source: Source.t(), webhook_secret: String.t()}}
          | {:error,
             Ecto.Changeset.t()
             | :chg_root_invalid
             | {:pr_route_in_flight, [Ecto.UUID.t()]}
             | term()}
  def create_source(tenant_id, attrs, opts \\ []) when is_binary(tenant_id) do
    secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")
    repo = Map.get(attrs, :repo_full_name) || Map.get(attrs, "repo_full_name")
    target_epic_id = Map.get(attrs, :target_epic_id) || Map.get(attrs, "target_epic_id")
    {attrs, mint} = take_root_mint(attrs)

    changeset =
      %Source{tenant_id: tenant_id, webhook_secret: secret}
      |> Source.create_changeset(create_attrs(repo, attrs))
      |> put_project(tenant_id, project_id)
      |> put_target_epic(tenant_id, target_epic_id)
      |> refuse_root_and_mint(mint)

    with {:ok, changeset} <- valid(changeset),
         :ok <- repo_belongs_to(tenant_id, repo, Ecto.Changeset.get_field(changeset, :project_id)),
         {:ok, source} <- insert_source(tenant_id, changeset, root_mint_opts(mint, opts)) do
      {:ok, %{source: source, webhook_secret: secret}}
    end
  end

  # A repo has one project (US-52.1): a source for repo R binds only to the project that holds
  # R, or to a project when NO active project holds R. Binding R to a second project is how
  # four repos came to carry a kb scope plus a `-delivery` work project, and two channels.
  # `update_source/4` cannot change a source's repo or project, so this is the one path.
  defp repo_belongs_to(tenant_id, repo, project_id) do
    case Projects.repo_holder(tenant_id, RepoUrl.key(repo)) do
      {:ok, %{id: ^project_id}} -> :ok
      {:ok, holder} -> {:error, {:repo_has_project, holder.id}}
      :error -> :ok
    end
  end

  # PRESENCE, for `:base_branch`, exactly as `update_source/4` reads it. The column is NOT
  # NULL with a default of `master`, so "absent" and "explicitly null" are different requests:
  # absent keeps the default an enrolment has always taken, while a caller that named the
  # field gets its value validated — including the refusal for `nil` or `""`, since there is no
  # cleared state for a branch every dispatch must name. Passing the key through
  # unconditionally would turn every enrolment that omits it into a `can't be blank` 422.
  #
  # Without this the field was unreachable at enrolment: `create_changeset/2` casts it and
  # nothing ever handed it a value, so every source started at `master` whatever the caller
  # asked for — and a repository whose trunk is `main` (GitHub's default since 2020) sent
  # every dispatch to cut from a branch that does not exist.
  defp create_attrs(repo, attrs) do
    base = %{repo_full_name: repo}

    fields = [
      base_branch: "base_branch",
      mode: "mode",
      required_checks: "required_checks",
      triage_requires_ticket: "triage_requires_ticket",
      change_events_secret: "change_events_secret",
      chg_root_dispatch_id: "chg_root_dispatch_id"
    ]

    Enum.reduce(fields, base, fn {key, string_key}, acc ->
      case fetch_either(attrs, key, string_key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_either(attrs, atom_key, string_key) do
    case Map.fetch(attrs, atom_key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, string_key)
    end
  end

  # The project a source binds must be of a kind its mode allows (`Source.project_kinds/1`):
  # only a `:work` project for `pr` and `chg`, either kind for `ledger` (issue #1047). The work
  # half is what keeps a `:kb` scope from ever becoming a dispatch binding or a merge route
  # through a `pr`/`chg` source. `ledger` takes both because it binds nothing: a repository
  # with only a kb scope, and one whose work project has no intake route, each get a ledger
  # credential and nothing else.
  #
  # A `pr`/`chg` source on an active `:kb` scope is accepted here and the scope is PROMOTED to
  # `:work` in the insert's own transaction (`promote_to_work/3`, US-52.3), so the bound
  # project is still a work project when the source exists. A repo has one project (US-52.1),
  # so refusing would leave a kb-scoped repo no way to take delivery except the second project
  # that rule now refuses.
  defp put_project(changeset, tenant_id, project_id) do
    kinds = Source.project_kinds(Ecto.Changeset.get_field(changeset, :mode))

    case active_project(tenant_id, project_id, [:kb, :work]) do
      {:ok, project} ->
        Ecto.Changeset.put_change(changeset, :project_id, project.id)

      {:error, message} ->
        # "project not found" and "can't be blank" stand as they are; an inactive project is
        # refused in the words of the mode's own kinds.
        message =
          if message == project_kind_message([:kb, :work]),
            do: project_kind_message(kinds),
            else: message

        Ecto.Changeset.add_error(changeset, :project_id, message)
    end
  end

  # Runs inside `insert_source/3`'s transaction, BEFORE the insert, so any refusal after it
  # (the insert itself, the audit chain) rolls it back. The project row is locked and re-read.
  #
  # For a `pr`/`chg` source it makes the bound project the repo's one project (US-52.3):
  #   - a project with no `repo_url` takes the source's repo, so `resolve_project({repo_url})`
  #     finds it and no second project can claim the repo (the index refuses a race);
  #   - an active `:kb` scope is promoted to `:work`, keeping its open channel.
  # A project that already holds a DIFFERENT repo is not refused yet: the test corpus binds
  # sources that way throughout, and the refusal is tracked as its own issue.
  # A `ledger` source binds nothing, so it changes nothing here.
  #
  # Returns `{:ok, claim}`: `nil` when nothing changed, else the project as it was and the
  # fields written, which `audit_claim/4` records once the source exists.
  defp prepare_project(tenant_id, changeset) do
    mode = Ecto.Changeset.get_field(changeset, :mode)
    repo = Ecto.Changeset.get_field(changeset, :repo_full_name)
    kinds = Source.project_kinds(mode)

    project =
      from(p in Project,
        where:
          p.tenant_id == ^tenant_id and
            p.id == ^Ecto.Changeset.get_field(changeset, :project_id),
        lock: "FOR UPDATE"
      )
      |> AdminRepo.one()

    cond do
      is_nil(project) or project.status != :active ->
        {:error, Ecto.Changeset.add_error(changeset, :project_id, project_kind_message(kinds))}

      mode == :ledger ->
        {:ok, nil}

      true ->
        claim_repo(tenant_id, project, repo)
    end
  end

  defp claim_repo(tenant_id, project, repo) do
    changes =
      [kind: :work]
      |> then(&if(project.kind == :kb, do: [{:open_channel, true} | &1], else: &1))
      |> then(fn changes ->
        if is_nil(project.repo_url) do
          url = "https://github.com/#{repo}"
          [{:repo_url, url}, {:repo_key, RepoUrl.key(url)} | changes]
        else
          changes
        end
      end)

    update =
      project
      |> Ecto.Changeset.change(changes)
      |> Ecto.Changeset.unique_constraint(:repo_key,
        name: Project.repo_key_index(),
        message: "already has a project in this tenant"
      )

    if update.changes == %{}, do: {:ok, nil}, else: write_claim(tenant_id, project, update)
  end

  defp write_claim(tenant_id, project, update) do
    case AdminRepo.update(update) do
      {:ok, _} -> {:ok, %{project: project, changes: update.changes}}
      # The loser of an enrolment race for one repo gets the same 409 the pre-check gives.
      {:error, failed} -> Projects.changeset_or_refusal(tenant_id, failed)
    end
  end

  # One audit entry for whatever the enrolment wrote on the project: `kind_promoted` when a kb
  # scope became a work project, `repo_claimed` when only the repo was taken. Both states carry
  # every field written, so the log shows when and why the project took the repo.
  defp audit_claim(_tenant_id, _source, nil, _opts), do: :ok

  defp audit_claim(tenant_id, source, %{project: project, changes: changes}, opts) do
    fields = Map.keys(changes)
    old = project |> Map.take(fields) |> stringify()
    new = stringify(changes)
    promoted = Map.has_key?(changes, :kind)

    metadata =
      %{"intake_source_id" => source.id}
      |> then(&if(promoted, do: Map.merge(&1, %{"from" => "kb", "to" => "work"}), else: &1))

    Ecto.Multi.new()
    |> Audit.log_in_multi(:audit, fn _ ->
      %{
        tenant_id: tenant_id,
        entity_type: "project",
        entity_id: project.id,
        action: if(promoted, do: "kind_promoted", else: "repo_claimed"),
        actor_type: Keyword.get(opts, :actor_type, "api_key"),
        actor_id: Keyword.get(opts, :actor_id),
        actor_label: Keyword.get(opts, :actor_label),
        metadata: metadata,
        old_state: old,
        new_state: new
      }
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, {:promotion_audit_failed, reason}}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), audit_value(v)} end)

  defp audit_value(v) when is_boolean(v) or is_nil(v), do: v
  defp audit_value(v) when is_atom(v), do: to_string(v)
  defp audit_value(v), do: v

  # OPTIONAL, and an absent value is not an error: see the schema. What IS an error is naming
  # an epic that is not this tenant's or does not belong to this source's project — a source
  # whose reports would land in another project's backlog is a mistake worth refusing at
  # enrollment rather than discovering on the first webhook.
  # An explicit `nil` CLEARS the target on a repoint, and means "not answered" on a create —
  # the two callers differ and the changeset is what distinguishes them: a create starts from
  # a struct whose field is already nil, so putting nil changes nothing.
  defp put_target_epic(changeset, _tenant_id, nil),
    do: Ecto.Changeset.put_change(changeset, :target_epic_id, nil)

  # A `ledger` source routes nothing (it refuses every GitHub delivery), so no record is ever
  # triaged into its target, and the target's FK would still block deleting that epic. On a
  # kb scope that was unreachable (a kb scope has no epics); a ledger source on a work project
  # made it reachable, so it is refused here, on the one path every writer takes. The mode is
  # read from the changeset: a switch across `ledger` is refused anyway, so the row's
  # ledger-ness never changes under it.
  defp put_target_epic(changeset, tenant_id, epic_id) do
    if binding_mode?(Ecto.Changeset.get_field(changeset, :mode)),
      do: put_binding_target_epic(changeset, tenant_id, epic_id),
      else:
        Ecto.Changeset.add_error(
          changeset,
          :target_epic_id,
          "a ledger source routes nothing and takes no target epic"
        )
  end

  defp put_binding_target_epic(changeset, tenant_id, epic_id) do
    project_id = Ecto.Changeset.get_field(changeset, :project_id)

    case epic_in_project(tenant_id, project_id, epic_id) do
      {:ok, epic} ->
        changeset
        |> Ecto.Changeset.put_change(:target_epic_id, epic.id)
        # The read above is the READABLE error; this is the one that actually holds. An epic
        # deleted between that read and this insert would otherwise raise out of the
        # controller as a 500 instead of a 422 naming the field.
        # NAMED, because the derived default is wrong here. `foreign_key_constraint/2` builds
        # `intake_sources_target_epic_id_fkey` from the field name; the migration calls the
        # constraint `intake_sources_target_epic_fkey` — no `_id` — because it is a COMPOSITE
        # `(tenant_id, target_epic_id)` reference written by hand. Unnamed it matched nothing,
        # so the race this line exists for still raised a 500. `Epics.epic_delete_changeset/1`
        # passes the same name and is what made the mismatch visible.
        |> Ecto.Changeset.foreign_key_constraint(:target_epic_id,
          name: :intake_sources_target_epic_fkey
        )

      # The project was already rejected, so there is nothing to check an epic against and
      # the project's own error is the one worth showing. Attaching it to :target_epic_id
      # told the caller an epic was wrong when a project was.
      :project_invalid ->
        changeset

      {:error, message} ->
        Ecto.Changeset.add_error(changeset, :target_epic_id, message)
    end
  end

  defp epic_in_project(tenant_id, project_id, epic_id) when is_binary(project_id) do
    with {:ok, id} <- Ecto.UUID.cast(epic_id),
         %Epic{} = epic <- AdminRepo.get_by(Epic, id: id, tenant_id: tenant_id) do
      if epic.project_id == project_id,
        do: {:ok, epic},
        else: {:error, "must belong to this source's project"}
    else
      _ -> {:error, "epic not found"}
    end
  end

  defp epic_in_project(_tenant_id, _project_id, _epic_id), do: :project_invalid

  defp active_project(tenant_id, project_id, kinds) when is_binary(project_id) do
    with {:ok, id} <- Ecto.UUID.cast(project_id),
         %Project{} = project <- AdminRepo.get_by(Project, id: id, tenant_id: tenant_id) do
      if project.kind in kinds and project.status == :active,
        do: {:ok, project},
        else: {:error, project_kind_message(kinds)}
    else
      _ -> {:error, "project not found"}
    end
  end

  defp active_project(_tenant_id, _project_id, _kinds), do: {:error, "can't be blank"}

  defp project_kind_message([:work]),
    do: "must be an active work project"

  defp project_kind_message(_ledger_kinds),
    do: "must be an active kb scope or work project"

  defp valid(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(changeset), do: {:error, changeset}

  # `mint_chg_root: true` (the operator's way to give a source a chg root, US-50 follow-up):
  # loopctl inserts the root itself, keyless and agentless (`Dispatches.mint_chg_root/3`), in
  # the source write's own transaction. Its id is chosen HERE and placed in the attrs as
  # `chg_root_dispatch_id`, so the changeset validates exactly as for a named root (the mode
  # rule needs a root on a `chg` or `ledger` source) and nothing downstream has a second path.
  # Naming a root AND asking for one is refused in `refuse_root_and_mint/2`.
  defp take_root_mint(attrs) do
    wanted? = fetch_either(attrs, :mint_chg_root, "mint_chg_root") == {:ok, true}
    attrs = attrs |> Map.delete(:mint_chg_root) |> Map.delete("mint_chg_root")

    cond do
      not wanted? ->
        {attrs, nil}

      match?({:ok, _}, fetch_either(attrs, :chg_root_dispatch_id, "chg_root_dispatch_id")) ->
        {attrs, :conflict}

      true ->
        root_id = Ecto.UUID.generate()
        {Map.put(attrs, :chg_root_dispatch_id, root_id), {:mint, root_id}}
    end
  end

  defp refuse_root_and_mint(changeset, :conflict),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :chg_root_dispatch_id,
        "name a chg_root_dispatch_id or set mint_chg_root, not both"
      )

  defp refuse_root_and_mint(changeset, _mint), do: changeset

  defp root_mint_opts({:mint, root_id}, opts), do: Keyword.put(opts, :mint_chg_root, root_id)
  defp root_mint_opts(_mint, opts), do: Keyword.delete(opts, :mint_chg_root)

  defp mint_root(tenant_id, opts) do
    case Keyword.get(opts, :mint_chg_root) do
      nil ->
        :ok

      root_id ->
        case Dispatches.mint_chg_root(tenant_id, root_id, Keyword.take(opts, [:actor_lineage])) do
          {:ok, _dispatch} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp insert_source(tenant_id, changeset, opts) do
    AdminRepo.transaction(fn ->
      with :ok <- mint_root(tenant_id, opts),
           :ok <- check_chg_root(tenant_id, changeset),
           :ok <- close_pr_route(tenant_id, changeset),
           {:ok, claim} <- prepare_project(tenant_id, changeset),
           {:ok, source} <- AdminRepo.insert(changeset),
           :ok <- audit_claim(tenant_id, source, claim, opts),
           {:ok, _entry} <-
             AuditChain.append(tenant_id, %{
               action: "intake_source_created",
               actor_lineage: Keyword.get(opts, :actor_lineage, []),
               entity_type: "intake_source",
               entity_id: source.id,
               payload: %{
                 "repo_full_name" => source.repo_full_name,
                 "project_id" => source.project_id,
                 "target_epic_id" => source.target_epic_id,
                 # RECORDED, now that a caller can name it at enrolment: a later repoint
                 # appends `intake_source_base_branch_set` carrying the new value, so without
                 # this the chain could say what a branch was changed TO and never what it
                 # started as.
                 "base_branch" => source.base_branch,
                 # Which route the merge gate reads, recorded for the same reason
                 # as the branch — a later `intake_source_mode_set` says what it changed TO.
                 "mode" => Atom.to_string(source.mode),
                 # Which issues are triaged at all, so a later `intake_source_triage_requires_ticket_set`
                 # has a starting value to be read against.
                 "triage_requires_ticket" => source.triage_requires_ticket,
                 # The custody input a `chg` source names (PRD §6). The secret itself is never
                 # on the chain; only whether one was set.
                 "chg_root_dispatch_id" => source.chg_root_dispatch_id,
                 "change_events_secret_set" => is_binary(source.change_events_secret)
               }
             }) do
        source
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  @doc """
  Repoints an ACTIVE source at `target_epic_id`, or clears it with `nil` (#803 §4).

  The remedy three review rounds named and nothing implemented. `target_epic_id` was
  writable only at enrolment, so a source enrolled before the column existed — which the
  migration promises keeps working — could never be given one, and the worker's own
  escalation message told an operator to do something no API could do.

  ACTIVE only. A revoked source has had its target cleared deliberately
  (`Source.revoke_changeset/2`) so the epic it named can be deleted; letting a repoint
  resurrect that reference would restore the delete-block on a source that will never report
  again.

  The epic must belong to this source's project, checked the same way enrolment checks it —
  one derivation, so the two cannot disagree about what a valid target is.
  """
  @spec repoint_source(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Source.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def repoint_source(tenant_id, source_id, target_epic_id, opts \\ [])
      when is_binary(tenant_id) and is_binary(source_id) do
    case active_source_of(tenant_id, source_id) do
      nil ->
        {:error, :not_found}

      %Source{} = source ->
        changeset =
          source
          |> Ecto.Changeset.change()
          |> put_target_epic(tenant_id, target_epic_id)

        with {:ok, changeset} <- valid(changeset) do
          repoint(tenant_id, changeset, opts)
        end
    end
  end

  @doc """
  Updates an ACTIVE source's mutable fields in ONE transaction (#803 round 2).

  `attrs` is a map that may carry `:target_epic_id` (nullable — an explicit `nil` clears it),
  `:base_branch` (NOT nullable), `:mode` (`"pr"` or `"chg"`, NOT nullable),
  `:required_checks`, `:triage_requires_ticket` (NOT nullable; `true` triages only ticket-filed issues),
  `:change_events_secret` and `:chg_root_dispatch_id` (both nullable on a
  `pr` source and required on a `chg` one). A key that is ABSENT is left alone, which is why this
  takes a map rather than two positional arguments: "absent" and "explicitly null" are
  different requests for the epic, and only the map can carry that difference.

  ATOMIC, and it has to be. The controller used to call `repoint_source/4` and then
  `set_base_branch/4`, so a PATCH whose branch was invalid had already committed the repoint
  AND appended its chain entry before the 422 — a caller reading the refusal would believe
  neither field had changed.

  One chain entry per field that actually changed, under the action that names it, so an
  operator reading the chain still sees a repoint as a repoint and a rebase as a rebase.

  SWITCHING MODE. To `chg`: the RESULTING row must carry both credentials, from this update or
  kept from an earlier `chg` stint, and the root is re-checked against `dispatches` on EVERY
  update whose resulting source is `chg`, and whenever a root is named
  (`{:error, :chg_root_invalid}`), so a kept root that has since been revoked is refused
  rather than trusted — a secret rotation on a revoked root included. To `pr`: both
  credentials are KEPT and ignored; nothing is cleared that the caller did not name.

  A switch to `chg` is refused with `{:error, {:pr_route_in_flight, story_ids}}` while any
  story of the source's project sits at `ci` holding a recorded merge allow
  (`merge_gate_allowed_sha`): that allow licenses a pull-request merge, and the `ci -> merged`
  edge that consumes it does not read the mode, so switching under it would merge through the
  route the switch closes. Merge or escalate those stories first. See `close_pr_route/2`.
  """
  @updatable_fields [
    :target_epic_id,
    :base_branch,
    :mode,
    :required_checks,
    :triage_requires_ticket,
    :change_events_secret,
    :chg_root_dispatch_id
  ]

  @spec update_source(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Source.t()}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :nothing_to_update
             | :chg_root_invalid
             | {:pr_route_in_flight, [Ecto.UUID.t()]}}
  def update_source(tenant_id, source_id, attrs, opts \\ [])
      when is_binary(tenant_id) and is_binary(source_id) and is_map(attrs) do
    {attrs, mint} = take_root_mint(attrs)

    fields =
      for key <- @updatable_fields,
          Map.has_key?(attrs, key),
          do: key

    if fields == [] and mint != :conflict do
      {:error, :nothing_to_update}
    else
      case active_source_of(tenant_id, source_id) do
        nil ->
          {:error, :not_found}

        %Source{} = source when mint == :conflict ->
          {:error, source |> Ecto.Changeset.change() |> refuse_root_and_mint(mint)}

        %Source{} = source ->
          apply_update(tenant_id, source, attrs, fields, root_mint_opts(mint, opts))
      end
    end
  end

  defp apply_update(tenant_id, source, attrs, fields, opts) do
    epic? = :target_epic_id in fields
    branch? = :base_branch in fields
    mode? = :mode in fields
    changeset = Ecto.Changeset.change(source)

    changeset =
      if epic?,
        do: put_target_epic(changeset, tenant_id, Map.get(attrs, :target_epic_id)),
        else: changeset

    changeset =
      if branch?, do: cast_base_branch(changeset, Map.get(attrs, :base_branch)), else: changeset

    # The mode and the `chg` credentials are cast TOGETHER and validated once, because the rule
    # that binds them reads the resulting row: a switch to `chg` in one field is judged with the
    # credentials named beside it, or kept on the row.
    changeset =
      if mode? or :change_events_secret in fields or :chg_root_dispatch_id in fields,
        do:
          cast_mode(
            changeset,
            Map.take(attrs, [:mode, :change_events_secret, :chg_root_dispatch_id])
          )
          |> check_mode_switch(),
        else: changeset

    changeset =
      if :required_checks in fields,
        do: cast_required_checks(changeset, attrs),
        else: changeset

    changeset = Source.put_triage_requires_ticket(changeset, attrs)

    with {:ok, changeset} <- valid(changeset) do
      write_update(tenant_id, changeset, fields, opts)
    end
  end

  # No mode switch crosses the ledger boundary (issue #1047). A `ledger` source is a credential
  # and nothing else; a `pr` or `chg` source is its project's dispatch binding and merge route.
  # Switching a ledger source to `pr` would make a binding nobody enrolled (on a kb scope, the
  # binding a kb scope is barred from), and switching a `pr`/`chg` source to `ledger` would
  # silently stop binding its project's stories. With the crossing refused the project kind
  # needs no re-check: a `pr`/`chg` source was enrolled on a work project and stays on it.
  defp check_mode_switch(%Ecto.Changeset{valid?: true, data: %Source{mode: from}} = changeset) do
    to = Ecto.Changeset.get_field(changeset, :mode)

    if Ecto.Changeset.changed?(changeset, :mode) and ledger?(from) != ledger?(to) do
      Ecto.Changeset.add_error(
        changeset,
        :mode,
        "cannot switch a source into or out of ledger: a ledger source is a credential, " <>
          "pr and chg are its project's merge route; revoke it and enrol a new one"
      )
    else
      changeset
    end
  end

  defp check_mode_switch(changeset), do: changeset

  defp ledger?(mode), do: mode == :ledger

  defp cast_required_checks(changeset, attrs) do
    changeset
    |> Ecto.Changeset.cast(Map.take(attrs, [:required_checks]), [:required_checks],
      empty_values: []
    )
    |> Source.validate_required_checks()
  end

  # `empty_values: []` for the reason `cast_base_branch/2` gives: a caller that SENT a value
  # gets an answer about it, so an explicit null or `""` is a 422, never a kept old value.
  defp cast_mode(changeset, attrs) do
    changeset
    |> Ecto.Changeset.cast(attrs, [:mode, :change_events_secret, :chg_root_dispatch_id],
      empty_values: []
    )
    |> Source.validate_mode()
  end

  # `empty_values: []`, which is NOT the default and matters here: Ecto's default treats `""`
  # as an absent value, so an empty branch was dropped from the changeset and the source kept
  # its old one while the caller got a 200 — a silent no-op for a request that was plainly
  # wrong. A caller that SENT a value gets an answer about the value it sent.
  #
  # The VALIDATION is `Source.validate_base_branch/1`, the same function `create_changeset/2`
  # runs, so enrolment and repoint cannot disagree about what a usable branch is — and neither
  # of them restates the ref-name rule, which lives in `Loopctl.GitRef` (#874 round 2,
  # finding 1). Two paths write this column and it is handed to git.
  defp cast_base_branch(changeset, value) do
    changeset
    |> Ecto.Changeset.cast(%{base_branch: value}, [:base_branch], empty_values: [])
    |> Source.validate_base_branch()
  end

  # ONE transaction for the row and BOTH chain entries: a rebase recorded without its repoint,
  # or either recorded against an update that did not commit, is a chain that disagrees with
  # the table it describes.
  defp write_update(tenant_id, changeset, fields, opts) do
    AdminRepo.transaction(fn ->
      with :ok <- mint_root(tenant_id, opts),
           :ok <- check_chg_root(tenant_id, changeset),
           :ok <- close_pr_route(tenant_id, changeset),
           {:ok, source} <- AdminRepo.update(changeset),
           :ok <- append_if(fields, :target_epic_id, tenant_id, source, opts),
           :ok <- append_if(fields, :base_branch, tenant_id, source, opts),
           :ok <- append_if(fields, :mode, tenant_id, source, opts),
           :ok <- append_if(fields, :required_checks, tenant_id, source, opts),
           :ok <- append_if(fields, :triage_requires_ticket, tenant_id, source, opts),
           :ok <- append_if(fields, :chg_root_dispatch_id, tenant_id, source, opts),
           :ok <- append_if(fields, :change_events_secret, tenant_id, source, opts) do
        source
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  # One chain entry per field the update NAMED, under the action that names that field.
  defp append_if(fields, field, tenant_id, source, opts) do
    if field in fields, do: append_update(field, tenant_id, source, opts), else: :ok
  end

  defp append_update(field, tenant_id, source, opts) do
    {action, payload} = update_entry(field, source)

    case AuditChain.append(tenant_id, %{
           action: action,
           actor_lineage: Keyword.get(opts, :actor_lineage, []),
           entity_type: "intake_source",
           entity_id: source.id,
           payload: payload
         }) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_entry(:target_epic_id, source),
    do: {"intake_source_repointed", %{"target_epic_id" => source.target_epic_id}}

  defp update_entry(:base_branch, source),
    do: {"intake_source_base_branch_set", %{"base_branch" => source.base_branch}}

  defp update_entry(:mode, source),
    do: {"intake_source_mode_set", %{"mode" => Atom.to_string(source.mode)}}

  defp update_entry(:required_checks, source),
    do: {"intake_source_required_checks_set", %{"required_checks" => source.required_checks}}

  defp update_entry(:triage_requires_ticket, source),
    do:
      {"intake_source_triage_requires_ticket_set",
       %{"triage_requires_ticket" => source.triage_requires_ticket}}

  defp update_entry(:chg_root_dispatch_id, source),
    do: {"intake_source_chg_root_set", %{"chg_root_dispatch_id" => source.chg_root_dispatch_id}}

  # Whether a secret is set, never the secret: the chain is readable by every auditor.
  defp update_entry(:change_events_secret, source),
    do:
      {"intake_source_change_events_secret_set",
       %{"change_events_secret_set" => is_binary(source.change_events_secret)}}

  # AC-47.2.2: the root a `chg` source names is a CUSTODY INPUT (PRD §6) — later stories accept a
  # review only from a child of it and refuse it as a verifier — so it is checked against the
  # `dispatches` row, not taken on the caller's word.
  #
  # Judged whenever a write NAMES a root (whatever the mode), and on EVERY write whose resulting
  # source is `chg` or `ledger` (`Source.credentials_required?/1`) — a switch, a secret
  # rotation, a base-branch edit alike — so a root kept from an earlier stint, or revoked since
  # it was named, is re-judged rather than trusted. A write on a
  # `chg` source whose root has been revoked is therefore `chg_root_invalid` until it names a live
  # root (or switches to `pr`, which is never blocked by the root it leaves behind). Naming one on
  # a `pr` source is judged too, and that is not tidiness: unjudged, an unknown id would fail the
  # foreign key (422) while another tenant's id would be stored (200) — an existence oracle
  # across tenants.
  #
  # This guards the REGISTRATION only. Nothing here stops a source whose root is revoked between
  # writes from staying `chg`; the change-events webhook (US-47.3, AC-47.3.7) refuses an event
  # for a source whose root is revoked (`hold_chg_source/3`), and every later gate that reads
  # the root must judge it the same way.
  #
  # INSIDE the write's transaction and `FOR SHARE`, so a concurrent `Dispatches.revoke/3` of the
  # root either commits first (and this read sees `revoked_at`) or waits for this write to
  # commit; there is no window in which a revoked root is enrolled.
  #
  # By id AND tenant: another tenant's dispatch is `nil` here, exactly like an id that names
  # nothing, so the two refusals are one and the same.
  #
  # Expiry of a root ALREADY registered is NOT judged: a root is a lineage anchor, not a held
  # key, and `RevokeExpiredDispatchesWorker` leaves a row a live source names unrevoked.
  #
  # A root being NAMED by this write is judged for expiry, though, with a margin of
  # `Source.chg_root_naming_margin_seconds/0`. The sweep's exemption reads which roots a live source
  # names in its own statement, and a source write that commits WHILE that statement runs is
  # not in its snapshot: naming a root on the edge of its expiry could commit just as the sweep
  # revokes it, and every post from the source would then be 401. A root with the margin left
  # cannot be a sweep candidate before this write commits.
  defp check_chg_root(tenant_id, %Ecto.Changeset{} = changeset) do
    mode = Ecto.Changeset.get_field(changeset, :mode)
    root_id = Ecto.Changeset.get_field(changeset, :chg_root_dispatch_id)
    named_root? = Ecto.Changeset.changed?(changeset, :chg_root_dispatch_id) and root_id != nil

    cond do
      named_root? ->
        with :ok <- judge_chg_root(tenant_id, root_id), do: judge_root_fresh(tenant_id, root_id)

      Source.credentials_required?(mode) ->
        judge_chg_root(tenant_id, root_id)

      true ->
        :ok
    end
  end

  defp judge_root_fresh(tenant_id, root_id) do
    floor = DateTime.add(DateTime.utc_now(), Source.chg_root_naming_margin_seconds(), :second)

    if AdminRepo.exists?(
         from d in Dispatch,
           where: d.id == ^root_id and d.tenant_id == ^tenant_id and d.expires_at > ^floor
       ),
       do: :ok,
       else: {:error, :chg_root_invalid}
  end

  @pr_route_in_flight_message "A story on this source's project is at `ci` holding a recorded " <>
                                "merge allow it has not merged on yet. That allow licenses a " <>
                                "pull-request merge, and switching the source to `chg` under " <>
                                "it would let that merge land through the route `chg` closes. " <>
                                "Merge the story (or let the merge gate escalate it) and retry; " <>
                                "`story_ids` names every story holding one."

  @doc "The message `{:error, {:pr_route_in_flight, story_ids}}` is rendered and documented with."
  @spec pr_route_in_flight_message() :: String.t()
  def pr_route_in_flight_message, do: @pr_route_in_flight_message

  # Finding 1 of the US-47.2 review: the PR route used to be closed only inside the merge
  # precondition, so an allow recorded BEFORE a switch to `chg` still merged afterwards — the
  # `ci -> merged` edge does not read the mode. A write that makes a source `chg` is therefore
  # refused while any story of its project holds an unconsumed allow (stage `ci`, allow set:
  # `ci -> merged` is the only edge that consumes one, and every edge out of `ci` toward
  # `implementing` clears it).
  #
  # The project's live sources are locked FOR UPDATE first, and that lock is the whole race
  # story. The one writer of an allow (`MergePrecondition`, through `Stages.record_effect/5`)
  # re-reads the mode under FOR SHARE on the same rows inside its write (`hold_pr_route/3`), so
  # either it commits first and the stage read below — a fresh READ COMMITTED snapshot taken
  # after the lock — sees its allow, or this write commits first and it reads `chg` and records
  # nothing. The stage rows are deliberately NOT locked here: the allow writer holds its stage row
  # FOR UPDATE while it waits on the source, so locking stages after the source would be a
  # lock-order cycle.
  defp close_pr_route(tenant_id, %Ecto.Changeset{} = changeset) do
    if Ecto.Changeset.get_field(changeset, :mode) == :chg and
         Ecto.Changeset.changed?(changeset, :mode) do
      project_id = Ecto.Changeset.get_field(changeset, :project_id)

      AdminRepo.all(
        from s in live_sources_query(tenant_id),
          where: s.project_id == ^project_id,
          select: s.id,
          lock: "FOR UPDATE"
      )

      case unmerged_allows(tenant_id, project_id) do
        [] -> :ok
        story_ids -> {:error, {:pr_route_in_flight, story_ids}}
      end
    else
      :ok
    end
  end

  defp unmerged_allows(tenant_id, project_id) do
    AdminRepo.all(
      from st in StoryStage,
        join: story in Story,
        on: story.id == st.story_id and story.tenant_id == st.tenant_id,
        where:
          st.tenant_id == ^tenant_id and story.project_id == ^project_id and st.stage == :ci and
            not is_nil(st.merge_gate_allowed_sha),
        order_by: st.story_id,
        select: st.story_id
    )
  end

  @doc """
  Whether `story_id` is a PR-ROUTE delivery story (US-48.18): it has a delivery stage row, and
  every live intake source of its project is in mode `pr` (at least one). Read on `repo` with
  explicit `tenant_id` predicates, so it holds on `Loopctl.AdminRepo` as well as under RLS.

  The custody consequence of the answer is the caller's: `Loopctl.Progress` refuses an
  unlineaged reject on such a story, and `Loopctl.Delivery.Stages` retires its verification on
  every edge that clears its head.
  """
  @spec pr_route?(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) :: boolean()
  # A story with no id was never persisted, so it has no stage row and no route.
  def pr_route?(_repo, _tenant_id, nil), do: false

  def pr_route?(repo, tenant_id, story_id) do
    staged? =
      repo.exists?(
        from st in StoryStage, where: st.tenant_id == ^tenant_id and st.story_id == ^story_id
      )

    staged? and pr_modes?(repo, tenant_id, story_id)
  end

  defp pr_modes?(repo, tenant_id, story_id) do
    modes =
      repo.all(
        from s in binding_sources_query(tenant_id),
          join: story in Story,
          on: story.project_id == s.project_id and story.tenant_id == s.tenant_id,
          where: story.id == ^story_id,
          select: s.mode
      )

    modes != [] and Enum.all?(modes, &(&1 == :pr))
  end

  @doc """
  Whether a merge allow may be recorded for `story_id`: `{:error, :change_protocol_enrolled}`
  when a live intake source of the story's project is in mode `chg`, `:ok` otherwise.

  For the allow writer to call INSIDE its write transaction, on `repo` (`Loopctl.Repo` under
  the tenant there): the project's live sources are read `FOR SHARE`, which waits on a
  concurrent switch to `chg` holding them `FOR UPDATE` (`update_source/4`) and makes that
  switch wait on this write. It is the second half of the rule `update_source/4` enforces —
  between them no allow is ever recorded on a `chg` source, whichever commits first.
  """
  @spec hold_pr_route(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :change_protocol_enrolled}
  def hold_pr_route(repo, tenant_id, story_id) do
    project_id =
      repo.one(
        from s in Story,
          where: s.id == ^story_id and s.tenant_id == ^tenant_id,
          select: s.project_id
      )

    # A story that is not there has no source to hold; the caller's own write refuses it.
    modes =
      if project_id,
        do:
          repo.all(
            from s in live_sources_query(tenant_id),
              where: s.project_id == ^project_id,
              select: s.mode,
              lock: "FOR SHARE"
          ),
        else: []

    if :chg in modes, do: {:error, :change_protocol_enrolled}, else: :ok
  end

  @doc """
  Re-reads a live source holding the chg SENDER's credentials INSIDE the caller's transaction
  on `repo` and judges its root by the same rule enrolment does (`check_chg_root/2`'s
  `judge_chg_root/3`): `{:ok, source}`, `{:error, :not_chg_source}` (revoked, another
  tenant's, unknown, or holding no `change_events_secret`), `{:error, :tenant_inactive}` or
  `{:error, :chg_root_invalid}` (a root that is not a live chg root, or none at all).

  ANY MODE (issue #1047): sending is not routing. A `pr` source that holds both credentials
  sends its ledger and its change events, and so does a `ledger` one; what an event then DOES
  is decided by the held source's `mode` (`Loopctl.Changes.Events`), and a caller that must be
  `chg` checks the mode itself (`Loopctl.Changes.ReviewDispatches`).

  For the change-events webhook (US-47.3, AC-47.3.7). Enrolment judges the root only when a
  source is WRITTEN, so a root revoked between writes is caught here, on every event. Both
  reads are `FOR SHARE`, so a concurrent revoke of the source or of its root, a mode switch or
  a secret rotation either commits first and is seen, or waits for the event to commit. The
  tenant's status is read here too, so a suspension committed since the caller's own
  pre-check refuses the event. `repo` is `Loopctl.Repo` under the source's tenant there; the
  explicit `tenant_id` predicates hold on any repo.

  The held source is what the caller authenticates against: its `change_events_secret` is the
  one that counts, not a copy read before the transaction.
  """
  @spec hold_chg_source(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Source.t()} | {:error, :not_chg_source | :tenant_inactive | :chg_root_invalid}
  def hold_chg_source(repo, tenant_id, source_id)
      when is_binary(tenant_id) and is_binary(source_id) do
    source =
      repo.one(
        from s in live_sources_query(tenant_id),
          where: s.id == ^source_id,
          lock: "FOR SHARE"
      )

    case source do
      %Source{change_events_secret: secret} = source when is_binary(secret) ->
        with :ok <- judge_tenant_active(repo, tenant_id),
             :ok <- judge_chg_root(repo, tenant_id, source.chg_root_dispatch_id),
             do: {:ok, source}

      _other ->
        {:error, :not_chg_source}
    end
  end

  defp judge_tenant_active(repo, tenant_id) do
    if repo.exists?(from t in Tenant, where: t.id == ^tenant_id and t.status == :active),
      do: :ok,
      else: {:error, :tenant_inactive}
  end

  defp judge_chg_root(repo \\ AdminRepo, tenant_id, root_id)

  defp judge_chg_root(repo, tenant_id, root_id) when is_binary(root_id) do
    dispatch =
      repo.one(
        from d in Dispatch,
          where: d.id == ^root_id and d.tenant_id == ^tenant_id,
          lock: "FOR SHARE"
      )

    if chg_root?(dispatch), do: :ok, else: {:error, :chg_root_invalid}
  end

  # `validate_mode/1` already required it, so a nil here is a caller bypassing the changeset.
  defp judge_chg_root(_repo, _tenant_id, _root_id), do: {:error, :chg_root_invalid}

  # `lineage_path == [id]` is what a parentless dispatch carries (`Loopctl.Dispatches`); a row
  # where the two disagree is not trusted as a root.
  defp chg_root?(%Dispatch{} = d),
    do:
      is_nil(d.parent_dispatch_id) and is_nil(d.revoked_at) and d.role == :orchestrator and
        d.lineage_path == [d.id]

  defp chg_root?(_none), do: false

  @doc """
  Sets the branch dispatches for this source's repository are cut FROM (#803 round 1).

  ACTIVE sources only, for the same reason `repoint_source/4` is: a revoked source will never
  report again, and its rows exist to keep history readable rather than to be configured.

  NOT NULLABLE, unlike the epic. An absent base branch is not a question loopctl can leave
  unanswered — every `implement` dispatch must name one — so there is no clearing form here,
  and a caller that wants the old behaviour sets `"master"` explicitly.
  """
  @spec set_base_branch(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Source.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_base_branch(tenant_id, source_id, base_branch, opts \\ [])
      when is_binary(tenant_id) and is_binary(source_id) do
    case active_source_of(tenant_id, source_id) do
      nil ->
        {:error, :not_found}

      %Source{} = source ->
        changeset =
          source
          |> Ecto.Changeset.cast(%{base_branch: base_branch}, [:base_branch])
          |> Ecto.Changeset.validate_required([:base_branch])
          |> Ecto.Changeset.validate_length(:base_branch, min: 1, max: 255)

        with {:ok, changeset} <- valid(changeset) do
          rebase(tenant_id, changeset, opts)
        end
    end
  end

  @doc """
  The ACTIVE intake source bound to `project_id`, which is what a dispatch reads its
  repository and base branch from (#803 §3).

  `{:error, {:no_intake_source, project_id}}` when the project has none and
  `{:error, {:ambiguous_intake_source, project_id, count}}` when it has more than one — the
  same two refusals `Loopctl.Delivery.MergePrecondition.repo_for_story/1` gives, because that
  function is now a reading of this one. Two sources on one project is a configuration a
  dispatcher must not choose between: each names its own repository, and picking either would
  send the work to a repository nobody nominated.
  """
  @spec source_for_project(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Source.t()}
          | {:error,
             {:no_intake_source, Ecto.UUID.t()}
             | {:ambiguous_intake_source, Ecto.UUID.t(), pos_integer()}}
  def source_for_project(tenant_id, project_id)
      when is_binary(tenant_id) and is_binary(project_id) do
    # The project is filtered IN SQL, so a tenant's other sources are never loaded; the
    # exactly-one rule stays `select_project_source/2`'s, the one derivation of it.
    tenant_id
    |> binding_sources_query()
    |> where([s], s.project_id == ^project_id)
    |> AdminRepo.all()
    |> select_project_source(project_id)
  end

  @doc """
  The ONE rule by which a project's repository is chosen from a tenant's live intake sources:
  exactly one, or a refusal naming why. Shared by `source_for_project/2` (on `AdminRepo`) and
  by the triage gate screen (on `Loopctl.Repo`, alongside every other read that module makes),
  so the two gates cannot resolve a story to two different repositories (US-44.2).

  A `ledger` source is never chosen and never counted (issue #1047): it is a ledger-only
  credential, on a kb scope or a work project, so it is no project's repository for a
  dispatch, and it does not make a project's one real source `ambiguous` either.
  """
  @spec select_project_source([Source.t()], Ecto.UUID.t()) ::
          {:ok, Source.t()}
          | {:error,
             {:no_intake_source, Ecto.UUID.t()}
             | {:ambiguous_intake_source, Ecto.UUID.t(), pos_integer()}}
  def select_project_source(sources, project_id) do
    sources
    |> Enum.filter(&(&1.project_id == project_id and binding_mode?(&1.mode)))
    |> case do
      [source] -> {:ok, source}
      [] -> {:error, {:no_intake_source, project_id}}
      sources -> {:error, {:ambiguous_intake_source, project_id, length(sources)}}
    end
  end

  @doc "The query for a tenant's live (unrevoked) intake sources, for any repo to run."
  @spec live_sources_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def live_sources_query(tenant_id) do
    from s in Source,
      where: s.tenant_id == ^tenant_id and is_nil(s.revoked_at),
      order_by: [desc: s.inserted_at]
  end

  @doc """
  A tenant's live sources that may BIND a project to a repository — every live source but a
  `ledger` one (issue #1047). The query for any read that resolves a story's repository or
  merge route; `binding_mode?/1` is the same rule for a list already read.
  """
  @spec binding_sources_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def binding_sources_query(tenant_id) do
    from s in live_sources_query(tenant_id), where: s.mode != ^:ledger
  end

  @doc "Whether a source in `mode` may bind a project to a repository: every mode but `ledger`."
  @spec binding_mode?(atom()) :: boolean()
  def binding_mode?(mode), do: mode != :ledger

  # The same shape as `repoint/3`, under its own action name: an operator reading the chain
  # must be able to tell a repoint from a rebase without opening the payload.
  defp rebase(tenant_id, changeset, opts) do
    AdminRepo.transaction(fn ->
      with {:ok, source} <- AdminRepo.update(changeset),
           {:ok, _entry} <-
             AuditChain.append(tenant_id, %{
               action: "intake_source_base_branch_set",
               actor_lineage: Keyword.get(opts, :actor_lineage, []),
               entity_type: "intake_source",
               entity_id: source.id,
               payload: %{"base_branch" => source.base_branch}
             }) do
        source
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  defp active_source_of(tenant_id, source_id) do
    case Ecto.UUID.cast(source_id) do
      {:ok, id} ->
        AdminRepo.one(
          from s in Source,
            where: s.id == ^id and s.tenant_id == ^tenant_id and is_nil(s.revoked_at)
        )

      :error ->
        nil
    end
  end

  defp repoint(tenant_id, changeset, opts) do
    AdminRepo.transaction(fn ->
      with {:ok, source} <- AdminRepo.update(changeset),
           {:ok, _entry} <-
             AuditChain.append(tenant_id, %{
               action: "intake_source_repointed",
               actor_lineage: Keyword.get(opts, :actor_lineage, []),
               entity_type: "intake_source",
               entity_id: source.id,
               payload: %{"target_epic_id" => source.target_epic_id}
             }) do
        source
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  @doc "Lists a tenant's intake sources, newest first. Pass `include_revoked: true` for all."
  @spec list_sources(Ecto.UUID.t(), keyword()) :: [Source.t()]
  def list_sources(tenant_id, opts \\ []) when is_binary(tenant_id) do
    query =
      if Keyword.get(opts, :include_revoked, false),
        do: from(s in Source, where: s.tenant_id == ^tenant_id, order_by: [desc: s.inserted_at]),
        else: live_sources_query(tenant_id)

    AdminRepo.all(query)
  end

  @doc "Gets one intake source of a tenant."
  @spec get_source(Ecto.UUID.t(), term()) :: {:ok, Source.t()} | {:error, :not_found}
  def get_source(tenant_id, source_id) when is_binary(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(source_id),
         %Source{} = source <- AdminRepo.get_by(Source, id: id, tenant_id: tenant_id) do
      {:ok, source}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Revokes an intake source, after which every delivery to it is refused exactly like a bad
  signature. The row is locked, so concurrent revokes write one `revoked_at` and one
  `intake_source_revoked` audit entry. Idempotent.
  """
  @spec revoke_source(Ecto.UUID.t(), term(), keyword()) ::
          {:ok, Source.t()} | {:error, :not_found | term()}
  def revoke_source(tenant_id, source_id, opts \\ []) when is_binary(tenant_id) do
    with {:ok, id} <- cast_not_found(source_id) do
      AdminRepo.transaction(fn -> revoke_locked(tenant_id, id, opts) end)
    end
  end

  defp revoke_locked(tenant_id, id, opts) do
    case lock_source(tenant_id, id) do
      nil -> AdminRepo.rollback(:not_found)
      %Source{revoked_at: nil} = source -> do_revoke(tenant_id, source, opts)
      %Source{} = source -> source
    end
  end

  defp cast_not_found(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp lock_source(tenant_id, id) do
    AdminRepo.one(
      from s in Source, where: s.id == ^id and s.tenant_id == ^tenant_id, lock: "FOR UPDATE"
    )
  end

  defp do_revoke(tenant_id, source, opts) do
    with {:ok, revoked} <- AdminRepo.update(Source.revoke_changeset(source, DateTime.utc_now())),
         {:ok, _entry} <-
           AuditChain.append(tenant_id, %{
             action: "intake_source_revoked",
             actor_lineage: Keyword.get(opts, :actor_lineage, []),
             entity_type: "intake_source",
             entity_id: revoked.id,
             payload: %{"repo_full_name" => revoked.repo_full_name}
           }) do
      revoked
    else
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Records
  # ---------------------------------------------------------------------------

  @doc """
  Lists a tenant's intake records, oldest first — the order triage consumes them in.

  ## Options

  - `:status` — only records with this status.
  - `:source_id` — only this source's records.
  - `:limit` — at most this many (default 100, max 500).
  """
  @spec list_records(Ecto.UUID.t(), keyword()) :: [Record.t()]
  def list_records(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(500)

    from(r in Record,
      where: r.tenant_id == ^tenant_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      limit: ^limit
    )
    |> filter_records(opts)
    |> AdminRepo.all()
  end

  defp filter_records(query, opts) do
    Enum.reduce(opts, query, fn
      {:status, status}, q -> where(q, [r], r.status == ^status)
      {:source_id, source_id}, q -> where(q, [r], r.source_id == ^source_id)
      _other, q -> q
    end)
  end

  @doc "Gets one intake record of a tenant."
  @spec get_record(Ecto.UUID.t(), term()) :: {:ok, Record.t()} | {:error, :not_found}
  def get_record(tenant_id, record_id) when is_binary(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(record_id),
         %Record{} = record <- AdminRepo.get_by(Record, id: id, tenant_id: tenant_id) do
      {:ok, record}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Lists the deliveries a tenant's source accepted, oldest first."
  @spec list_deliveries(Ecto.UUID.t(), Ecto.UUID.t()) :: [Delivery.t()]
  def list_deliveries(tenant_id, source_id) when is_binary(tenant_id) and is_binary(source_id) do
    AdminRepo.all(
      from d in Delivery,
        where: d.tenant_id == ^tenant_id and d.source_id == ^source_id,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
  end

  # ---------------------------------------------------------------------------
  # Deliveries
  # ---------------------------------------------------------------------------

  @doc "The rows one retention DELETE statement takes."
  @spec prune_batch_size() :: pos_integer()
  def prune_batch_size, do: @prune_batch_size

  @doc "The delivery rows one retention run may delete for one tenant."
  @spec prune_budget() :: pos_integer()
  def prune_budget, do: @prune_budget

  @doc """
  Deletes one tenant's delivery rows past `cutoff` that are no longer idempotency evidence,
  oldest first, in batches of `:batch_size` up to `:budget` rows. See "Retention" in the
  moduledoc for what a row is FOR and why the window has a floor.

  Returns `%{deleted: n, budget_exhausted: bool, error: nil | term()}`, with the same contract
  `Loopctl.Runners.DispatchLedger.prune_trace_events/3` documents: `budget_exhausted` is
  PROBED rather than inferred, and a fault comes back in `:error` alongside the count of
  everything the earlier batches committed rather than being raised.

  Each batch is its own transaction under its own `statement_timeout` and `lock_timeout`, so
  no transaction is held across a large delete and an interrupted run keeps every committed
  batch. Candidates are taken `FOR UPDATE SKIP LOCKED`: two overlapping runs prune disjoint
  sets rather than queueing, and a row a webhook is inserting is never in the set anyway
  (it is newer than any cutoff).

  `opts` (`:batch_size`, `:budget`) are an INTERNAL contract and are not validated here —
  `Loopctl.Workers.DeliveryLoopPruneWorker` validates everything an operator can supply, and
  additionally caps both at this module's own constants, which are sized for `AdminRepo`'s
  three connections.
  """
  @spec prune_deliveries(Ecto.UUID.t(), DateTime.t(), keyword()) ::
          %{deleted: non_neg_integer(), budget_exhausted: boolean(), error: nil | term()}
  def prune_deliveries(tenant_id, %DateTime{} = cutoff, opts \\ []) when is_binary(tenant_id) do
    batch_size = Keyword.get(opts, :batch_size, @prune_batch_size)
    budget = Keyword.get(opts, :budget, @prune_budget)

    prune_deliveries_loop(tenant_id, cutoff, batch_size, budget, 0)
  end

  # The ONE stop, as in `Loopctl.Runners.DispatchLedger.prune_trace_events/3`: every batch
  # recurses through here, so this clause is the only place `budget_exhausted` becomes true.
  # It PROBES rather than assuming — a tenant with exactly `budget` eligible rows has none
  # left, and reporting that as "budget reached, rows left" is a false positive on the very
  # signal an operator alerts on.
  # The probe reads WITHOUT the row lock: it decides a report, so it must not take locks a
  # concurrent run would then skip, and `SKIP LOCKED` would make the answer depend on what
  # another run happens to hold.
  defp prune_deliveries_loop(tenant_id, cutoff, _batch, budget, deleted) when deleted >= budget do
    case attempt(fn ->
           tenant_id
           |> prunable_deliveries(cutoff, 1)
           |> exclude(:lock)
           |> AdminRepo.exists?()
         end) do
      # A probe that could not run cannot say the backlog is empty, so it says it is not.
      {:ok, more?} -> %{deleted: deleted, budget_exhausted: more?, error: nil}
      {:error, error} -> %{deleted: deleted, budget_exhausted: true, error: error}
    end
  end

  defp prune_deliveries_loop(tenant_id, cutoff, batch_size, budget, deleted) do
    take = min(batch_size, budget - deleted)

    batch =
      attempt(fn ->
        delete_deliveries(
          tenant_id,
          AdminRepo.all(prunable_deliveries(tenant_id, cutoff, take))
        )
      end)

    case batch do
      {:ok, 0} ->
        %{deleted: deleted, budget_exhausted: false, error: nil}

      {:ok, count} ->
        prune_deliveries_loop(tenant_id, cutoff, batch_size, budget, deleted + count)

      {:error, error} ->
        %{deleted: deleted, budget_exhausted: false, error: error}
    end
  end

  # One batch, or the probe, RETURNING its fault instead of raising it — see
  # `Loopctl.Runners.DispatchLedger.prune_trace_events/3`: raising discards the count of every
  # batch already committed, which is most of a long run.
  defp attempt(fun) do
    {:ok, bounded(fun)}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # One batch, or the probe: its own transaction under its own bounded timeouts, scoped by
  # `LocalGuc` so neither outlives it. Both GUCs go in ONE round trip — this runs on the
  # 3-connection `AdminRepo` pool, where every avoidable round trip is a request's turn.
  defp bounded(fun) do
    {:ok, result} =
      AdminRepo.transaction(fn ->
        LocalGuc.scoped(AdminRepo, ["statement_timeout", "lock_timeout"], fn ->
          AdminRepo.query!(
            "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true)",
            ["#{@prune_statement_timeout_ms}ms", "#{@prune_lock_timeout_ms}ms"]
          )

          fun.()
        end)
      end)

    result
  end

  defp delete_deliveries(_tenant_id, []), do: 0

  defp delete_deliveries(tenant_id, ids) do
    {count, _} =
      AdminRepo.delete_all(from(d in Delivery, where: d.tenant_id == ^tenant_id and d.id in ^ids))

    count
  end

  # A batch of one tenant's prunable delivery ids, oldest first. The row a record still names
  # as `last_delivery_id` is kept whatever its age: it is the provenance of content triage
  # has not consumed yet, and it is one row per record, not per delivery.
  #
  # SELECTED first and deleted by id in a SECOND statement of the SAME transaction, for the
  # reason `Loopctl.Runners.DispatchLedger.prunable_events/3` states: `DELETE ... WHERE id IN
  # (SELECT ... FOR UPDATE SKIP LOCKED LIMIT n)` can re-execute the subplan per row and delete
  # a multiple of `n`.
  defp prunable_deliveries(tenant_id, cutoff, limit) do
    still_cited =
      from r in Record,
        where: r.tenant_id == parent_as(:prunable).tenant_id,
        where: r.source_id == parent_as(:prunable).source_id,
        where: r.last_delivery_id == parent_as(:prunable).github_delivery_id,
        select: 1

    from d in Delivery,
      as: :prunable,
      where: d.tenant_id == ^tenant_id,
      where: d.inserted_at < ^cutoff,
      where: not exists(still_cited),
      order_by: [asc: d.inserted_at],
      limit: ^limit,
      lock: "FOR UPDATE SKIP LOCKED",
      select: d.id
  end

  @doc """
  Receives one GitHub webhook delivery for the source `source_id`. See the moduledoc for
  the order of checks.

  Returns `{:ok, outcome}` where outcome is `:ping`, `:recorded`, `:ignored` or
  `:duplicate`; `{:error, :unauthorized}` for every authentication and repository-binding
  failure; `{:error, {:bad_request, code}}` for a signed delivery that is malformed.
  """
  @spec receive_github_delivery(term(), delivery_input()) ::
          {:ok, outcome()}
          | {:error, :unauthorized | {:bad_request, String.t()} | term()}
  def receive_github_delivery(source_id, %{raw_body: raw_body} = input)
      when is_binary(raw_body) do
    with {:ok, source} <- authenticate(source_id, raw_body, input[:signature]),
         {:ok, payload} <- decode(raw_body, input[:content_type]),
         :ok <- bind_repository(source, payload),
         {:ok, event, delivery_id} <- delivery_headers(input[:event], input[:delivery_id]),
         {:ok, plan} <- plan(event, payload, source) do
      Logger.metadata(tenant_id: source.tenant_id)
      apply_delivery(source, event, delivery_id, raw_body, plan)
    end
  end

  # A `ledger` source is refused like an unknown one (issue #1047): it is a ledger credential
  # only, and a GitHub delivery to it would put outside text into an intake queue its project
  # never asked for (a kb scope never carries work at all).
  defp authenticate(source_id, raw_body, signature) do
    case active_source(source_id) do
      %Source{mode: mode, webhook_secret: secret} = source
      when is_binary(secret) and mode != :ledger ->
        if Signature.valid?(secret, raw_body, signature),
          do: {:ok, source},
          else: {:error, :unauthorized}

      _ ->
        _ = Signature.valid?(@timing_key, raw_body, signature)
        {:error, :unauthorized}
    end
  end

  @doc """
  The live source a delivery to `source_id` addresses, on an active tenant, or `nil` — the one
  cross-tenant read (by id) a webhook makes before it knows its tenant. Any `source_id` that is
  not a UUID is `nil` too, so an unknown, a revoked, a malformed and another deployment's id are
  one answer. Shared by the GitHub intake webhook and the change-events webhook (US-47.3).
  """
  @spec delivery_source(term()) :: Source.t() | nil
  def delivery_source(source_id), do: active_source(source_id)

  defp active_source(source_id) do
    case Ecto.UUID.cast(source_id) do
      {:ok, id} ->
        AdminRepo.one(
          from s in Source,
            join: t in Tenant,
            on: t.id == s.tenant_id,
            where: s.id == ^id and is_nil(s.revoked_at) and t.status == :active
        )

      :error ->
        nil
    end
  end

  defp decode(raw_body, content_type) do
    case GithubPayload.decode(raw_body, content_type) do
      {:ok, payload} -> {:ok, payload}
      {:error, :invalid_payload} -> {:error, {:bad_request, "invalid_payload"}}
    end
  end

  defp bind_repository(%Source{repo_full_name: repo}, payload) do
    case GithubPayload.repository_full_name(payload) do
      name when is_binary(name) ->
        if String.downcase(name) == String.downcase(repo),
          do: :ok,
          else: {:error, :unauthorized}

      nil ->
        {:error, :unauthorized}
    end
  end

  defp delivery_headers(event, delivery_id) when is_binary(event) and is_binary(delivery_id) do
    if Regex.match?(@event_format, event) and Regex.match?(@delivery_id_format, delivery_id),
      do: {:ok, event, delivery_id},
      else: {:error, {:bad_request, "invalid_delivery_headers"}}
  end

  defp delivery_headers(_event, _delivery_id),
    do: {:error, {:bad_request, "invalid_delivery_headers"}}

  defp plan("ping", _payload, _source), do: {:ok, {:ping, nil}}

  defp plan("issues", payload, source) do
    action = GithubPayload.action(payload)

    if action in @issue_actions do
      case GithubPayload.issue(payload, source.repo_full_name) do
        {:ok, issue} -> {:ok, {:issue, action, issue}}
        {:error, :invalid_payload} -> {:error, {:bad_request, "invalid_payload"}}
      end
    else
      {:ok, {:ignored, action}}
    end
  end

  # US-50.4: a merged pull request queues one read of its review outcome. Only the number is
  # taken from the payload; the job reads the body itself, through the tenant's credential.
  defp plan(
         "pull_request",
         %{
           "action" => "closed",
           "pull_request" => %{"merged" => true, "number" => number}
         },
         _source
       )
       when is_integer(number) and number > 0 and number <= 2_147_483_647,
       do: {:ok, {:pr_merged, "closed", number}}

  defp plan(_event, payload, _source), do: {:ok, {:ignored, GithubPayload.action(payload)}}

  defp apply_delivery(source, event, delivery_id, raw_body, plan) do
    AdminRepo.transaction(fn ->
      case insert_delivery(source, event, delivery_id, raw_body, plan) do
        :duplicate -> :duplicate
        :inserted -> apply_plan(source, delivery_id, plan)
      end
    end)
  end

  # The unique index decides a replay: `ON CONFLICT DO NOTHING` inserts zero rows for a
  # delivery id this source has already seen, including when two posts race.
  defp insert_delivery(source, event, delivery_id, raw_body, plan) do
    now = DateTime.utc_now()

    {outcome, action, issue_number} =
      case plan do
        {:ping, _} -> {"ping", nil, nil}
        {:issue, action, issue} -> {"recorded", action, issue.number}
        {:pr_merged, action, _number} -> {"recorded", action, nil}
        {:ignored, action} -> {"ignored", action, nil}
      end

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: source.tenant_id,
      source_id: source.id,
      github_delivery_id: delivery_id,
      event: event,
      action: action,
      outcome: outcome,
      issue_number: issue_number,
      payload_sha256: :sha256 |> :crypto.hash(raw_body) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    }

    case AdminRepo.insert_all(Delivery, [row],
           on_conflict: :nothing,
           conflict_target: [:source_id, :github_delivery_id]
         ) do
      {1, _} -> :inserted
      {0, _} -> :duplicate
    end
  end

  defp apply_plan(_source, _delivery_id, {:ping, _}), do: :ping
  defp apply_plan(_source, _delivery_id, {:ignored, _action}), do: :ignored

  # The enqueue never fails the delivery: a lost review-outcome read costs an audit row, while
  # failing here would make GitHub redeliver, and a redelivery is a duplicate the unique index
  # answers without queueing anything.
  defp apply_plan(source, _delivery_id, {:pr_merged, _action, number}) do
    case Oban.insert(PrReviewOutcomeWorker.new_for(source, number)) do
      {:ok, _job} ->
        :recorded

      {:error, reason} ->
        Logger.error(
          "intake: review-outcome job not queued source_id=#{source.id} pr=#{number} " <>
            "reason=#{inspect(reason)}"
        )

        :recorded
    end
  end

  defp apply_plan(source, delivery_id, {:issue, action, issue}) do
    extraction = TicketFacts.extract(issue.title, issue.body)
    {record, content} = target_record(source, action, issue, extraction, delivery_id)
    new_reasons = scan(issue, extraction) -- record.escalation_reasons
    now = DateTime.utc_now()

    changes = Map.merge(content, escalation_changes(record, new_reasons, now))

    with {:ok, updated} <- AdminRepo.update(Record.apply_changeset(record, changes)),
         :ok <- escalate(updated, new_reasons, delivery_id) do
      :recorded
    else
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  # The record this delivery applies to and the content changes it makes there: the issue's
  # newest generation, or a new one (see "Generations" in the moduledoc).
  #
  # The changes are computed against the NEWEST record before a new one is started, and they
  # are what goes onto the new record. That keeps the same-second case honest: a reopen
  # stamped with the same second as the close it follows is applied with `order_ambiguous`
  # set, on the new record too, so triage re-reads the live issue.
  defp target_record(source, action, issue, extraction, delivery_id) do
    newest = ensure_record(source, issue.number)
    content = content_changes(newest, issue, extraction, action, delivery_id)

    if starts_generation?(newest, action, content) do
      {insert_generation(source, newest, delivery_id), content}
    else
      {newest, content}
    end
  end

  # Only a reopen, only one that would be applied (an older or restating one changes
  # nothing, so it starts nothing), and only on a record whose story has reached the end.
  defp starts_generation?(_record, _action, content) when content == %{}, do: false
  defp starts_generation?(record, "reopened", _content), do: loop_ended?(record)
  defp starts_generation?(_record, _action, _content), do: false

  @doc """
  Whether `record` has reached the end of the delivery loop: it has an issue-closure row,
  or its story's stage is in `generation_end_stages/0`. A `reopened` delivery starts the
  issue's next generation only then (see "Generations" in the moduledoc).

  Read on `AdminRepo` with the record's tenant on every source. Committed state, unlocked:
  a story that moves out of the set afterwards (a revert, `merged -> implementing`) leaves
  the new generation in place. The two are separate work items for the same issue, and
  either can be resolved without the other.
  """
  @spec loop_ended?(Record.t()) :: boolean()
  def loop_ended?(%Record{tenant_id: tenant_id, id: record_id}) do
    AdminRepo.exists?(
      from c in IssueClosure,
        where: c.tenant_id == ^tenant_id and c.intake_record_id == ^record_id
    ) or
      AdminRepo.exists?(
        from s in Story,
          join: st in StoryStage,
          on: st.story_id == s.id and st.tenant_id == s.tenant_id,
          where: s.tenant_id == ^tenant_id and s.intake_record_id == ^record_id,
          where: st.stage in ^@generation_end_stages
      )
  end

  # The issue's next generation, inheriting the predecessor's escalation (see the moduledoc).
  # A plain insert: the caller holds `previous` locked and has seen no newer generation
  # (`newest_locked/2`), so nothing else can be inserting this one. The unique index is the
  # backstop, and a conflict there raises.
  defp insert_generation(source, %Record{} = previous, delivery_id) do
    now = DateTime.utc_now()

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: source.tenant_id,
      source_id: source.id,
      project_id: source.project_id,
      issue_number: previous.issue_number,
      generation: previous.generation + 1,
      status: previous.status,
      escalation_reasons: previous.escalation_reasons,
      escalated_at: previous.escalated_at,
      inserted_at: now,
      updated_at: now
    }

    {1, [fresh]} = AdminRepo.insert_all(Record, [row], returning: true)

    Logger.info(
      "intake: issue ##{fresh.issue_number} of source #{fresh.source_id} reopened after " <>
        "its loop ended; generation #{fresh.generation} is record #{fresh.id} " <>
        "(previous #{previous.id})"
    )

    inherited = %{
      "inherited_from_generation" => previous.generation,
      "inherited_from_record_id" => previous.id
    }

    case escalate(fresh, fresh.escalation_reasons, delivery_id, inherited) do
      :ok -> fresh
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  # Insert-or-nothing of generation 1, then lock the NEWEST generation: two deliveries for a
  # new issue cannot both create it, and the second waits for the first's changes before it
  # merges its own. When a later generation exists the insert conflicts on generation 1 and
  # the newest is still the one read.
  defp ensure_record(source, number) do
    now = DateTime.utc_now()

    AdminRepo.insert_all(
      Record,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: source.tenant_id,
          source_id: source.id,
          project_id: source.project_id,
          issue_number: number,
          generation: 1,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :source_id, :issue_number, :generation]
    )

    newest_locked(source, number)
  end

  # Locks the newest generation, deciding "newest" AFTER the lock: see "Generations" in the
  # moduledoc. The existence check is a new statement, so it sees a generation committed
  # while this one waited.
  defp newest_locked(source, number) do
    issue =
      from r in Record,
        where: r.tenant_id == ^source.tenant_id,
        where: r.source_id == ^source.id and r.issue_number == ^number

    locked =
      AdminRepo.one!(
        from r in issue, order_by: [desc: r.generation], limit: 1, lock: "FOR UPDATE"
      )

    if AdminRepo.exists?(from r in issue, where: r.generation > ^locked.generation),
      do: newest_locked(source, number),
      else: locked
  end

  # Everything the detector and the fact extractor read is the UNCAPPED payload text.
  defp scan(issue, extraction) do
    detected =
      InjectionDetector.scan([
        {"untrusted_title", issue.title},
        {"untrusted_body", issue.body},
        {"untrusted_labels", Enum.join(issue.labels, "\n")},
        {"untrusted_author_login", issue.author_login},
        {"page_url", extraction.page_url}
      ]) ++ InjectionDetector.scan_user_agent("user_agent", extraction.user_agent)

    Enum.sort(Enum.uniq(detected ++ extraction.reasons))
  end

  # The content, `last_action` and `last_delivery_id` move together, so the record always
  # describes one delivery. See "Delivery order" in the moduledoc for the four cases.
  defp content_changes(record, issue, extraction, action, delivery_id) do
    content =
      issue
      |> GithubPayload.untrusted_fields()
      |> Map.merge(extraction.facts)
      |> Map.merge(%{
        github_issue_id: issue.github_issue_id,
        html_url: issue.html_url,
        issue_state: issue.state,
        issue_updated_at: issue.updated_at
      })

    delivery = %{last_action: action, last_delivery_id: delivery_id}

    case order(record.issue_updated_at, issue.updated_at) do
      :older ->
        %{}

      :same ->
        if same_content?(record, content),
          do: %{},
          else: content |> Map.merge(delivery) |> Map.merge(ambiguous_at(issue.updated_at))

      :newer ->
        content |> Map.merge(delivery) |> Map.merge(ambiguous_at(nil))
    end
  end

  defp order(nil, _incoming), do: :newer
  defp order(%DateTime{}, nil), do: :older

  defp order(%DateTime{} = stored, %DateTime{} = incoming) do
    case DateTime.compare(incoming, stored) do
      :gt -> :newer
      :eq -> :same
      :lt -> :older
    end
  end

  defp same_content?(record, content),
    do: Map.take(record, Map.keys(content)) == content

  defp ambiguous_at(nil), do: %{order_ambiguous: false, order_ambiguous_at: nil}
  defp ambiguous_at(%DateTime{} = at), do: %{order_ambiguous: true, order_ambiguous_at: at}

  @doc """
  Escalates `record` to a human with `reason`, idempotently (#803 §4).

  The delivery loop's counterpart to the detector's own escalation: the trigger cannot make a
  story from this record — its source names no epic, or names one that cannot carry a story
  number — and that is a question for a person rather than something to guess at or retry.

  Idempotent, and the SUBTRACTION is what makes it so rather than the union. A reason this
  record already carries yields `{:ok, record}` with nothing written at all — no update, no
  log line, and no second `intake_escalated` entry on the hash-chained audit log. The first
  version relied on `escalation_changes/3` unioning the list, which made the row converge but
  appended a chain entry on every call; the delivery path avoids that by computing
  `new_reasons` BEFORE it calls, and this now does the same.

  Until this existed, four places — this module's schema comment, the trigger's moduledoc, the
  migration and the OpenAPI description — all said a record with no target epic was ESCALATED,
  and nothing set the status. The record simply stayed `pending_triage` and was retried for
  ever against a condition only a human could clear.
  """
  @spec escalate_record(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Record.t()} | {:error, :not_found | term()}
  def escalate_record(tenant_id, record_id, reason)
      when is_binary(tenant_id) and is_binary(record_id) and is_binary(reason) do
    # THE READ IS INSIDE THE WRITE'S TRANSACTION AND TAKES THE ROW LOCK, because the whole
    # function is a read-modify-write of a LIST. Unlocked, two escalations of the same record
    # — the delivery path recording an injection signal, this worker recording a triage
    # failure — both read `escalation_reasons`, each subtracts against its own snapshot, and
    # the second update writes a list assembled from the first's PRE-state. The loser's reason
    # is gone from the row, and gone SILENTLY: both calls return `{:ok, record}`, both append
    # an `intake_escalated` entry, so the audit chain records two escalations for a record
    # that shows one. The signal dropped that way is the one worth keeping — an
    # `untrusted_text` injection marker outranks "no target epic" every time.
    AdminRepo.transaction(fn ->
      tenant_id
      |> locked_record(record_id)
      |> escalate_locked(reason)
    end)
  end

  defp escalate_locked(nil, _reason), do: AdminRepo.rollback(:not_found)

  defp escalate_locked(%Record{} = record, reason) do
    case escalate_new(record, [reason] -- record.escalation_reasons) do
      {:ok, updated} -> updated
      {:error, failure} -> AdminRepo.rollback(failure)
    end
  end

  # `FOR UPDATE`, and a cast that answers `:not_found` rather than raising: `get_by/3` on a
  # malformed id raises `Ecto.Query.CastError`, which in the worker is a rescued exception and
  # an `:errored` candidate instead of the plain not-found it is.
  defp locked_record(tenant_id, record_id) do
    case Ecto.UUID.cast(record_id) do
      {:ok, id} ->
        from(r in Record,
          where: r.id == ^id and r.tenant_id == ^tenant_id,
          lock: "FOR UPDATE"
        )
        |> AdminRepo.one()

      :error ->
        nil
    end
  end

  defp escalate_new(record, []), do: {:ok, record}

  defp escalate_new(record, new_reasons) do
    changes = escalation_changes(record, new_reasons, DateTime.utc_now())

    # `updated`, not `record`, and the two are not interchangeable: `escalate/3` writes
    # `escalation_reasons` into the audit entry, so passing the pre-update struct recorded
    # the state BEFORE this escalation while `signals` carried the new reason — an entry
    # disagreeing with itself, and disagreeing with what the delivery path writes for the
    # same action.
    with {:ok, updated} <- AdminRepo.update(Record.apply_changeset(record, changes)),
         :ok <- escalate(updated, new_reasons, record.last_delivery_id) do
      {:ok, updated}
    end
  end

  defp escalation_changes(_record, [], _now), do: %{}

  defp escalation_changes(record, new_reasons, now) do
    %{
      status: :escalated,
      escalation_reasons: Enum.sort(Enum.uniq(record.escalation_reasons ++ new_reasons)),
      escalated_at: record.escalated_at || now
    }
  end

  defp escalate(record, new_reasons, delivery_id, detail \\ %{})

  defp escalate(_record, [], _delivery_id, _detail), do: :ok

  defp escalate(record, new_reasons, delivery_id, detail) do
    Logger.warning(
      "intake: escalated issue ##{record.issue_number} of source #{record.source_id} " <>
        "(record #{record.id}): #{Enum.join(new_reasons, ", ")}"
    )

    case AuditChain.append(record.tenant_id, %{
           action: "intake_escalated",
           actor_lineage: [],
           entity_type: "intake_record",
           entity_id: record.id,
           payload:
             %{
               "source_id" => record.source_id,
               "issue_number" => record.issue_number,
               "generation" => record.generation,
               "github_delivery_id" => delivery_id,
               "signals" => new_reasons,
               "escalation_reasons" => record.escalation_reasons
             }
             |> Map.merge(detail)
         }) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
