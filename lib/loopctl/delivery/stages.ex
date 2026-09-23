defmodule Loopctl.Delivery.Stages do
  @moduledoc """
  The Postgres-owned per-story delivery stage machine (issue #803, design §3, §6, §11).

  One `Loopctl.Delivery.StoryStage` row per story holds its stage, the claim epoch it was
  written under, and the identity of every outward side effect. The transition table lives
  in `Loopctl.Delivery.StageMachine`; this module is the only writer.

  ## Where the state lives, and who runs the work

  Postgres, and nowhere else. No process owns a story: a runner, a DurableServer on a
  runner, or ANY loopctl node advances a row by reading it and compare-and-setting it in
  one transaction. A process that restarts, or a caller that reconnects to a different
  node of the cluster, reads the row again and carries on from what committed — anything
  it held in memory is a cache of this row and is never consulted in place of it. There is
  no registry to find a story's owner in, because there is no owner.

  ## Partitions

  A runner cut off from the control plane cannot advance anything — every write is a
  transaction here — and while it is gone its claim lease runs out. The reclaimer releases
  the claim, bumps `stories.claim_epoch`, and moves an in-flight row back to `queued` in
  the same transaction (`follow_release/5`, which every claim release calls). When the runner comes back, every write
  it attempts presents the OLD epoch and is refused `:stale_claim_epoch`: the zombie is
  fenced by the epoch, not by noticing it is a zombie. Two loopctl nodes are not a
  partition of the state at all: both write the one row, and the compare-and-set lets
  exactly one of two concurrent transitions commit.

  ## Retries

  Every call is safe to repeat.

  - `advance/4` is a compare-and-set on the expected stage. A retried transition whose
    first attempt committed finds the row already past `from` and is refused
    `:stale_stage` — it does not happen twice. The caller reads `get/2` to learn where the
    row is; the row, not the caller's memory, is the truth.
  - `record_effect/5` records an identity once — the worktree, the branch, the head, the PR,
    the release, the runner; everything except the merge sha, which only a transition may
    write. The same value again is `{:ok, row}`, so a replayed stage finds what its first
    run recorded and reuses it; a DIFFERENT value for an identity already set is
    `:effect_conflict`, so a replay can never record a second one. Record the identity
    BEFORE performing the effect.
  - The MERGE is the one identity that cannot be written first, because the merge commit
    does not exist until GitHub makes it. Its shape is: perform the merge, take the sha
    GitHub returns, then `advance(…, {:ci, :merged}, effects: [merge_sha: sha])` — one
    transaction, so the row and the `story_stage_merged` chain entry name the same merge.
    Its replay anchor is `pr_number` + `head_sha`: a resuming runner asks GitHub whether
    that head is already merged and adopts the answer instead of merging again. A merge
    that did not hold takes `{merged, implementing, :merge_refused}`, whose chained
    retraction names the sha it withdraws.
  - `open/3` inserts `ON CONFLICT DO NOTHING` and returns the one row either way.

  ## Slow connections

  Every transaction here sets `lock_timeout` (2s) and `statement_timeout` (5s) locally, so a transaction waiting behind a lock holder — the reclaimer, a
  claim, a concurrent transition, the tenant's audit-chain head — gives up instead of
  waiting without bound while holding a pooled connection. That, and a pool checkout that
  times out, is `{:error, :busy}`: nothing committed, and the call may be retried.

  ## Locks and their order

  ONE order, fleet-wide (#822 review, corrected in #824 review), and every writer follows the
  part of it that it needs:

      capacity advisory lock (0x41050803) -> story row -> runner_dispatches / story_stages
      row -> runners row -> chain advisory lock (0x4105A1D7) -> audit-chain head

  **The chain append is always LAST.** The order published by #822 had the `runners` row
  after the chain, and it was wrong about the fleet as it stands: `Loopctl.Runners`'
  `revoke_runner/3` takes the `runners` row and THEN appends, and so does the session-end
  release below. Nothing anywhere takes the chain first and a `runners` row second, so the
  table is the one that moves, not the code. Keeping the chain last is also what makes the
  order safe to extend — the tenant's chain head is the row every writer in the tenant
  contends on, so it is the one to hold for the shortest possible time.

  Here that is: `FOR SHARE` on the story (so a claim release cannot commit between reading
  `claim_epoch` and the write it fences), then the stage row, then — for a session-end
  transition — the dispatch row and the `runners` row, then, only for a chained transition,
  the tenant's chain advisory lock and its head
  (`Loopctl.AuditChain.append_in_tenant_transaction/2`). `Loopctl.Progress`' release paths
  take the story `FOR UPDATE` first, the stage row second and, for a release's escalation, the
  chain last, the same way round.

  Two consequences worth stating rather than rediscovering:

  - **This module never takes the capacity advisory lock.** Nothing here raises a tenant's
    in-flight sum — a release only lowers it — so acquiring it would add a lock ahead of
    everything else for no admission decision.

    What that costs an OPERATOR reading a burst of `:capacity_busy` (#822's wording,
    repeated here because this module owns the other half of the order): the capacity lock
    is taken FIRST, so a dispatch holding it and waiting on a story row makes every other
    dispatch in that tenant queue behind the capacity lock and fall out as
    `:capacity_busy` once the 5s `lock_timeout` elapses. A burst of them therefore means a
    LONG-HELD STORY LOCK — a claim release, a reclaim sweep, a transition that is waiting
    on something — not a capacity shortage. Look at what is holding the story row before
    raising a tenant's cap.
  - **The session-end release (`:session_dispatch`) runs BEFORE `AuditChain.append`, never
    after** — which is simply the order above, since the `runners` row it ends at comes
    before the chain. Appending first would hold the tenant's chain lock while waiting on a
    `runners` row, and `Loopctl.Runners.revoke_runner/3` takes that row and then appends, so
    the two together would close a cycle. Committing in one transaction is the other half:
    a release that landed while its transition rolled back would free the slot of a session
    the story does not know ended.

  Only ACQUIRED locks are ordered; the tenant-scoped `runners` SELECT in `record_effect/5`
  takes none. Taking any pair the other way round can deadlock; `lock_timeout` turns that
  into `{:error, :busy}` rather than a wait without end, and a deadlock Postgres does break
  is classified retryable too.

  ## The audit chain

  Only the custody-critical transitions (`StageMachine.chained?/3`: into `claimed`,
  `merged` or `escalated`, out of `escalated`, and the `:merge_refused` retraction of a
  merge) are appended to the hash chain, inside the transition's own transaction via
  `AuditChain.append_in_tenant_transaction/2` — or, for the escalation a claim release decides,
  inside the release's `AdminRepo` transaction via `AuditChain.append_in_admin_transaction/2`.
  Either way the entry is announced only after that transaction commits. Every transition and
  every newly recorded effect is in `story_stage_events`.

  ## Repo

  `Loopctl.Repo` inside `Repo.with_tenant/2`, with an explicit `tenant_id` predicate on
  every query as well. Never `AdminRepo` — its pool is three connections — except
  `follow_release/5`, which is a step of a claim release's existing `AdminRepo`
  transaction and takes no connection of its own. Like every `with_tenant/2` caller, none
  of the other functions may be called inside a `Repo` transaction.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Auth.Role
  alias Loopctl.Delivery.RetryCeiling
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.Untrusted
  alias Loopctl.Intake.IssueClosures
  alias Loopctl.LocalGuc
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  @lock_timeout "2000ms"
  @statement_timeout "5000ms"

  # The story statuses a claim holds. Entering `claimed` needs one.
  @claimed_statuses [:assigned, :implementing]

  @sha ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  # Edges only a claim release takes, inside its own transaction (`follow_release/5`), and
  # `advance/4` therefore refuses from every caller: the release itself, and what the release
  # decides once it has requeued the row (US-44.4).
  @release_only_edges [:runner_lost, :claim_released] ++
                        StageMachine.release_escalation_edges()

  # WHY a claim was released, which decides where the story goes next (US-44.4, #877). Every
  # caller of `follow_release/5` names one; see its doc for the table.
  @release_causes [:attempt, :usage_exhausted, :placement_refused, :operator]

  # The reason an operator's release escalates with. Control's own words: entering
  # `escalated` is chained, and nothing a caller supplied belongs in the chain entry.
  @operator_released_reason "operator_released: an operator force-unclaimed a story the " <>
                              "delivery loop was working. A human decides what it does next " <>
                              "— resolve it from escalated."

  @max_pr_number 9_223_372_036_854_775_807

  # The `story_stages_text_bounds` CHECK on `escalation_reason`, read from the ONE place it is
  # declared (#824 round 2). It was a fourth copy of the number.
  @max_reason_chars StageMachine.max_reason_length()

  # The encoded size of the caller-supplied `:event_data` a transition may carry into
  # `story_stage_events.data`. Counted on the JSON actually stored, so the bound is exact
  # rather than an estimate. It exists because that column is jsonb with no CHECK: an
  # unbounded structured payload from a session is a write amplifier on the event stream.
  @max_event_data_bytes 8_000

  @typedoc """
  What `follow_release/5` returns inside `{:ok, _}`: the row as the release left it (`nil` for
  a story with no row) and the chain entry its escalation appended (`nil` when none), which the
  caller announces after commit (`announce_release/1`).
  """
  @type released :: {StoryStage.t() | nil, Entry.t() | nil}

  @type advance_error ::
          :invalid_transition
          | :human_required
          | :reason_required
          | :not_found
          | :not_claimed
          | :stale_claim_epoch
          | :triage_not_bound
          | :stale_stage
          | :actor_lineage_required
          | :invalid_reason
          | :missing_required_effect
          | :invalid_effect
          | :wrong_stage
          | :effect_conflict
          | :audit_chain_append_failed
          | :invalid_event_data
          | :busy

  @type effect_error ::
          :invalid_effect
          | :transition_only_effect
          | :not_found
          | :stale_claim_epoch
          | :wrong_stage
          | :effect_conflict
          | :busy

  @doc """
  Creates a story's stage row at `detected`, bound to the story's current `claim_epoch`,
  or returns the row that already exists. Refuses a story that is not in the tenant.

  ## Options

  - `:actor_label` — recorded on the `opened` event
  """
  @spec open(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, StoryStage.t()} | {:error, :not_found | :busy}
  def open(tenant_id, story_id, opts \\ []) do
    in_tenant(tenant_id, fn ->
      story = share_lock_story(tenant_id, story_id)
      now = DateTime.utc_now()
      id = Ecto.UUID.generate()

      Repo.insert_all(
        StoryStage,
        [
          %{
            id: id,
            tenant_id: tenant_id,
            story_id: story_id,
            stage: :detected,
            claim_epoch: story.claim_epoch,
            attempts: %{},
            lock_version: 0,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :story_id]
      )

      row = fetch_row!(tenant_id, story_id)

      # Only the insert that won writes the event; a replay finds the row and adds nothing.
      if row.id == id do
        insert_event(Repo, row, "opened", nil, nil, Keyword.get(opts, :actor_label), %{})
      end

      {row, nil}
    end)
  end

  @doc """
  The encoded size of the `:event_data` a transition may carry, in bytes.

  Public so a CALLER that composes `event_data` can fit it rather than discover the bound as
  an `:invalid_event_data` refusal — which, on a transition the caller cannot skip, turns
  "record this" into "the story went nowhere" (`Loopctl.Delivery.StoryPayload` is the case
  that forced it). This is the ONE declaration; nothing restates the number.
  """
  @spec max_event_data_bytes() :: pos_integer()
  def max_event_data_bytes, do: @max_event_data_bytes

  @doc "A tenant's stage row for `story_id`, or nil."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: StoryStage.t() | nil
  def get(tenant_id, story_id) do
    {:ok, row} =
      Repo.with_tenant(tenant_id, fn -> row_query(tenant_id, story_id) |> Repo.one() end)

    row
  end

  @doc """
  A story's TRANSITIONS only, oldest first, as `%{from:, to:, edge:, data:}` — filtered and
  projected in SQL, in the same order `list_events/2` reads. For a caller that walks the
  transition history on a hot path (the merge gate's Gate A input) and has no use for effect
  and counter events or the other columns.
  """
  @spec list_transitions(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  def list_transitions(tenant_id, story_id) do
    {:ok, transitions} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(
          from e in StageEvent,
            where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
            where: e.event == "transitioned",
            order_by: [asc: e.inserted_at, asc: e.lock_version],
            select: %{from: e.from_stage, to: e.to_stage, edge: e.edge, data: e.data}
        )
      end)

    transitions
  end

  @doc "A story's stage events, oldest first."
  @spec list_events(Ecto.UUID.t(), Ecto.UUID.t()) :: [StageEvent.t()]
  def list_events(tenant_id, story_id) do
    {:ok, events} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(
          from e in StageEvent,
            where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
            order_by: [asc: e.inserted_at, asc: e.lock_version]
        )
      end)

    events
  end

  @doc """
  Moves a story's stage row over one transition of `StageMachine.transitions/0` — a
  compare-and-set on the expected stage, fenced by the story's claim epoch.

  `transition` is `{from, to}` for a `:forward` transition or `{from, to, edge}`.

  Refused before touching the database:

  - `:invalid_transition` — not in the table, or an edge only the releasing transaction
    takes (`follow_release/5`): the release edges `:runner_lost` and `:claim_released`, and
    the two escalations a release decides, `:attempts_exhausted` and `:operator_released`
  - `:human_required` — `:human_resolution` from anything but a human principal: a role of
    at least `:user` holding a key no dispatch minted (`actor_lineage` empty). The same
    positive operator test the lineage ceiling uses; a dispatch-minted `:user` key is an
    agent's, not Mark's.
  - `:reason_required` — entering `escalated` without a `:reason`

  Refused in the transaction, in this order:

  - `:not_found` — no such story, or no stage row, in the tenant
  - `:triage_not_bound` — a transition out of `triaged` naming a session dispatch that is not
    the one bound to the story (`triage_dispatch_id`), or a row bound to nobody; only the bound
    dispatch may take it further. Checked AFTER the story's epoch, so a stale caller hears
    `:stale_claim_epoch` first
  - `:stale_claim_epoch` — `:claim_epoch` is not the story's current one (the caller's
    claim has ended), or the ROW is behind the story's epoch (the claim that drove it was
    released and nobody re-queued it)
  - `:not_claimed` — entering `claimed` on a story no claim holds
  - `:stale_stage` — the row is not at `from`: another writer, or this caller's own earlier
    attempt, already moved it
  - `:invalid_effect`, `:wrong_stage`, `:effect_conflict` — from the `:effects` this
    transition carries, on the same terms as `record_effect/5`. `:invalid_effect` is
    decided before the transaction; the other two roll it back.

  And refused before the database, with everything else in that list:

  - `:missing_required_effect` — a transition into `merged` that does not carry
    `merge_sha` (`StageMachine.required_effects/1`). The chained entry has to name the
    merge it asserts.

  Entering `claimed` rebinds the row to the story's current epoch — the claim just made.
  Every other transition requires the row to already be at it.

  ## Options

  - `:claim_epoch` (required) — the epoch the caller acts under
  - `:effects` — identities to record AS PART OF this transition, e.g.
    `effects: [merge_sha: sha]` on `ci -> merged`. They are applied in the transition's own
    transaction, after the stage moves and BEFORE the chain entry is built, so a chained
    transition's entry names the effect it asserts. Same rules as `record_effect/5`
    (validated first, idempotent on the same value, `:effect_conflict` on a different one),
    and the destination stage is what `StageMachine.effect_stages/1` is checked against.
  - `:reason` — the escalation reason (required into `escalated`), or a note. UNTRUSTED
    session-authored text: stored verbatim so an operator reads what was actually written,
    capped at #{@max_reason_chars} codepoints, never executed, and rendered through
    `escalation_block/1` by anything that puts it in a prompt.
  - `:event_data` — a JSON-encodable map recorded under `"payload"` on this transition's
    `story_stage_events` row, for a caller with structure to record alongside the reason.
    At most #{@max_event_data_bytes} bytes encoded, no NUL, else `:invalid_event_data`. It
    NEVER reaches `story_stages` and never reaches the chain entry.
  - `:session_dispatch` — `{dispatch_id, slot_generation}` of the runner dispatch whose
    session is driving this story. The slot is released in THIS transaction, before the
    chain append, if and ONLY if `StageMachine.ends_session?/1` holds for the destination —
    derived from the stage, never from the caller, so no message can free a slot its session
    is still using. Idempotent by generation: a replay releases nothing a second time
    (`Loopctl.Runners.Capacity.release/4`). A dispatch row that has gone missing is LOGGED
    and the transition still commits — the heal sweep bounds an unreleased slot within a
    minute, while a rollback would strand the story at a stage nothing can move it off.
  - `:actor_label`, `:actor_role`, `:actor_lineage` — attribution; role and lineage are
    SERVER-resolved by the caller from the authenticating key, never taken from a request
  """
  @spec advance(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          {StageMachine.stage(), StageMachine.stage()} | StageMachine.transition(),
          keyword()
        ) :: {:ok, StoryStage.t()} | {:error, advance_error()}
  def advance(tenant_id, story_id, {from, to}, opts),
    do: advance(tenant_id, story_id, {from, to, :forward}, opts)

  def advance(tenant_id, story_id, {from, to, edge}, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)

    with {:ok, effects} <- precheck_effects({from, to, edge}, opts) do
      # ESCAPED ONLY AFTER EVERY REFUSAL THE CALLER CAN PREDICT. See `sanitise_reason/1`:
      # the caller is bounded on the text it sent, the column holds the escaped form, and the
      # two numbers are deliberately different.
      in_tenant(tenant_id, fn ->
        transition(tenant_id, story_id, {from, to, edge}, epoch, effects, sanitise_reason(opts))
      end)
    end
  end

  @doc """
  Every refusal `advance/4` decides BEFORE it opens a transaction, asked WITHOUT advancing
  anything — the authorization half of a transition, available to a caller that has
  irreversible work to do first.

  ## Why this is public, and what it is for

  `Escalations.resolve/3` is the caller that forced it. Resolving an escalation to `queued`
  has to RELEASE THE CLAIM before it can advance the stage row — the release bumps the epoch
  the transition is then fenced on — and since #862 that release also revokes the story's
  session credential and cascades to every descendant dispatch. Run before the human gate,
  that made a REFUSED resolve destructive: a dispatch-minted `:user`-role key (a session
  claiming to be a person, precisely what `human?/1` exists to refuse) got its refusal only
  after the implementer's live credential was dead and its claim was gone, repeatably, on any
  escalated story (#862 review round 3, finding 1).

  So the gate is asked FIRST and the destruction happens only on a caller that will pass it.

  ## It is the SAME chain `advance/4` runs, never a copy

  `advance/4` calls the identical private function; this returns `:ok` where that keeps the
  validated effects. A duplicated gate would be a gate that drifts, and the copy that drifts
  is always the one guarding the side effect.

  ## What it does NOT decide

  Anything that needs the row or the transaction — among them `:not_found`, `:stale_stage`,
  `:stale_claim_epoch`, `:not_claimed`, `:wrong_stage`, `:effect_conflict`, `:busy` and
  `:audit_chain_append_failed`. So an `:ok` here is NOT a promise that the advance will
  succeed; it is only the promise that it will not be refused for a reason the caller could
  have been told before it did anything. Nor does passing it LATCH: `advance/4` re-runs this
  chain itself, so a caller cannot pass the gate here and then hand it different
  attribution.
  """
  @spec precheck(
          {StageMachine.stage(), StageMachine.stage()} | StageMachine.transition(),
          keyword()
        ) :: :ok | {:error, advance_error()}
  def precheck(transition, opts)

  def precheck({from, to}, opts), do: precheck({from, to, :forward}, opts)

  def precheck({_from, _to, _edge} = transition, opts) do
    with {:ok, _effects} <- precheck_effects(transition, opts), do: :ok
  end

  # THE ONE DEFINITION of "what this caller may be refused before the database". Order is
  # load-bearing and unchanged: the transition has to exist, its attribution has to be
  # declared, the principal has to be allowed, and only then is its PAYLOAD examined — so a
  # caller the gate refuses learns that rather than learning its reason was too long.
  defp precheck_effects({from, to, edge}, opts) do
    with :ok <- allowed_for_caller(from, to, edge),
         :ok <- lineage_declared(from, to, edge, opts),
         :ok <- human_gate(edge, opts),
         :ok <- reason_given(to, edge, Keyword.get(opts, :reason)),
         :ok <- event_data_ok(opts),
         {:ok, effects} <- validate_effects(opts),
         :ok <- required_effects_present(to, effects) do
      {:ok, effects}
    end
  end

  defp transition(tenant_id, story_id, {from, to, edge} = transition, epoch, effects, opts) do
    reason = Keyword.get(opts, :reason)
    story = share_lock_story(tenant_id, story_id)

    # The fence against a zombie: a caller whose claim has ended presents an old epoch.
    if story.claim_epoch != epoch, do: Repo.rollback(:stale_claim_epoch)

    if to == :claimed and story.agent_status not in @claimed_statuses,
      do: Repo.rollback(:not_claimed)

    # The PRE-IMAGE, under the stage row's own lock, so a chained retraction can record the
    # identity it retracts: the compare-and-set below returns the row AFTER the edge cleared
    # it. The lock is what makes the pre-image exact — without it a concurrent
    # `record_effect/5` could set the value between this read and the clear, and the chain
    # would say nothing was retracted.
    previous = lock_row(tenant_id, story_id)
    bound_to_caller!(previous, from, Keyword.get(opts, :session_dispatch))

    row = compare_and_set(tenant_id, story, transition, reason)
    insert_event(Repo, row, "transitioned", from, edge, opts[:actor_label], note(reason, opts))

    # BEFORE the chain entry is built, in this same transaction: the entry has to NAME the
    # effect the transition asserts. `ci -> merged` carrying the sha GitHub just returned is
    # the case that forces it — recorded afterwards, the `story_stage_merged` entry says a
    # merge happened and identifies nothing.
    row = put_effects(row, effects, opts)
    release_session_slot(row, to, opts)
    record_issue_closure(row, story, transition)
    {row, maybe_chain(row, previous, transition, reason, opts)}
  end

  # THE OUTBOX for what the reporter is told (#805 item 1), written in THIS transaction.
  #
  # A terminal verdict on a story that came from a reported GitHub issue is the moment
  # loopctl learns what to tell the person who filed it. Recording it here — atomically with
  # the verdict — is what makes the outward close at-most-once and never-lost: a transition
  # that rolls back records no intent, and one that commits cannot lose it to a node dying
  # between the commit and an enqueue.
  #
  # The CLOSE itself is emphatically not here. `Loopctl.Workers.IntakeIssueCloseWorker` drains
  # these rows outside any transaction, so no GitHub call ever holds a pooled connection or
  # the story row this transaction is holding.
  #
  # Which transitions produce one is the MACHINE's decision (`resolution_verdict/1`), read off
  # the whole `{from, to, edge}` — `failed` and `done` are each reachable two ways that mean
  # different things to a reporter. Almost every transition produces nothing, and so does
  # every story that came from no intake record, which is the ordinary case.
  #
  # BEFORE `maybe_chain/5`, keeping the chain append last per the moduledoc's lock order. This
  # takes no lock anything else in that order contends on: an insert of a fresh row plus one
  # indexed read of the tenant's own record and source.
  defp record_issue_closure(row, story, transition) do
    case StageMachine.resolution_verdict(transition) do
      nil ->
        :ok

      verdict ->
        IssueClosures.record_in(
          Repo,
          row.tenant_id,
          row.story_id,
          story.intake_record_id,
          verdict
        )
    end
  end

  # The session's runner slot, given back in the transition that ends the session — never in
  # a second commit afterwards, which a node dying in between would lose to the heal sweep's
  # bound. BEFORE the chain append: see the moduledoc's lock order.
  #
  # `ends_session?/1` is read off the DESTINATION STAGE, so the decision is the machine's and
  # not the caller's; a caller that passes `:session_dispatch` on a live transition releases
  # nothing.
  defp release_session_slot(row, to, opts) do
    with {dispatch_id, generation} when is_binary(dispatch_id) and is_integer(generation) <-
           Keyword.get(opts, :session_dispatch),
         true <- StageMachine.ends_session?(to) do
      case DispatchLedger.release_slot_in(Repo, row.tenant_id, dispatch_id, generation) do
        {:ok, _outcome} ->
          :ok

        {:error, :unknown_dispatch} ->
          Logger.warning(
            "story stage ended a session whose dispatch row is gone; the slot waits for the " <>
              "heal sweep: tenant_id=#{row.tenant_id} story_id=#{row.story_id} " <>
              "dispatch_id=#{dispatch_id} to=#{to}"
          )
      end
    else
      _not_a_session_end -> :ok
    end
  end

  defp lock_row(tenant_id, story_id) do
    row_query(tenant_id, story_id) |> lock("FOR UPDATE") |> Repo.one()
  end

  # The compare-and-set. The WHERE carries the expected stage and, except into `claimed`,
  # the story's epoch, so the UPDATE matches only a row still at `from` under the current
  # claim. Two concurrent transitions from the same stage both reach it; the second blocks
  # on the first's row lock, and once that commits Postgres re-checks the WHERE against the
  # committed row (READ COMMITTED), matches nothing, and this caller is refused.
  defp compare_and_set(tenant_id, story, {from, to, edge}, reason) do
    query =
      from(s in StoryStage,
        where: s.tenant_id == ^tenant_id and s.story_id == ^story.id,
        where: s.stage == ^from,
        select: s
      )

    query =
      if to == :claimed,
        do: query,
        else: where(query, [s], s.claim_epoch == ^story.claim_epoch)

    rebind = if to == :claimed, do: [claim_epoch: story.claim_epoch], else: []
    escalation = if to == :escalated, do: [escalation_reason: reason], else: []
    extra = rebind ++ escalation

    case query |> transition_update(from, to, edge, extra) |> Repo.update_all([]) do
      {1, [row]} -> row
      {0, _} -> Repo.rollback(diagnose(tenant_id, story, from))
    end
  end

  # ONLY THE DISPATCH THAT TRIAGED A STORY MAY TAKE IT OUT OF `triaged` (epic 44, US-44.1).
  # `detected -> triaged` records the deciding dispatch as `triage_dispatch_id`; any later
  # transition out of `triaged` that names a session dispatch must name THAT one, whatever
  # path it came by — a fresh verdict, a replay, a reclaim repair. Checked here, on the row
  # this transaction holds locked, so no caller can forget it. A row bound to NOBODY (the
  # dispatcher's too-large route, or triaged before the binding existed) is no session's to
  # move either. Only a transition naming no session dispatch — control's own, such as that
  # too-large escalation — passes unbound. The story's epoch is checked BEFORE this, so a
  # caller with a stale epoch hears `:stale_claim_epoch` first.
  defp bound_to_caller!(
         %StoryStage{stage: :triaged, triage_dispatch_id: bound},
         :triaged,
         {id, _}
       )
       when bound != id,
       do: Repo.rollback(:triage_not_bound)

  defp bound_to_caller!(_row, _from, _session_dispatch), do: :ok

  # Why the compare-and-set matched nothing.
  defp diagnose(tenant_id, story, from) do
    case Repo.one(row_query(tenant_id, story.id)) do
      nil -> :not_found
      %StoryStage{stage: stage} when stage != from -> :stale_stage
      %StoryStage{} -> :stale_claim_epoch
    end
  end

  # The two NO-VERDICT counters, as data, so one implementation serves both and a third
  # cannot arrive with its own copy of the arithmetic (#803 §9).
  #
  # Each belongs to ONE gate at ONE stage, keyed to the identity that gate is about:
  #
  # - `:merge_gate` — the merge precondition at `ci`, keyed to `head_sha`. Head-keyed, so
  #   every edge that clears the head clears it (`StageMachine.head_keyed/0`).
  # - `:post_deploy` — post-deploy verification at `deployed`, keyed to `merge_sha`.
  #   Merge-keyed instead (`StageMachine.merge_keyed/0`), because a sweep asks whether THIS
  #   merge is deployed and a retracted merge takes its count with it.
  #
  # They are separate COLUMNS rather than two keys of one map: clearing a verdict at one
  # gate must not clear the other's count, and the two are cleared by different edges.
  # `totalled_by` is the subset of the identity that a SECOND, coarser count is kept over.
  #
  # The post-deploy counter's identity carries a `kind`, and the per-kind count RESTARTS
  # when the kind changes — right for the two different bounds, and wrong on its own: an
  # intermittently 5xx-ing forge alternating with a wedged deploy resets each count before
  # either reaches its bound, so the story sits at `deployed` for ever and nobody is told.
  # That is the ONE outcome the counter exists to prevent. The total is kept over the merge
  # ALONE, so alternating kinds still accumulate, and a verdict clears both together.
  #
  # The merge gate has one kind and therefore no total; its stored shape is unchanged.
  @counters %{
    merge_gate: %{
      column: :merge_gate_unevaluated,
      stage: :ci,
      event: "merge_gate_unevaluated",
      totalled_by: nil
    },
    post_deploy: %{
      column: :post_deploy_unresolved,
      stage: :deployed,
      event: "post_deploy_unresolved",
      totalled_by: ["merge_sha"]
    }
  }

  @doc """
  Counts a merge-gate evaluation at `head_sha` that produced NO verdict (#803), and returns
  the CONSECUTIVE count at that head.

  `Loopctl.Delivery.MergePrecondition` answers `:unevaluated` and transitions nothing when
  the forge is transiently unavailable, on purpose: one blip must not park a story on a
  human, and `escalated` is human-only. A fault that never clears would then produce that
  same answer for ever, with no escalation written and nobody told — so the gate escalates
  once this count passes its bound.

  The count RESETS when `head_sha` differs from the one it was last kept for: a new head is
  new material, and a story's blips at an older head should not escalate it. It is not an
  `attempts` key (those are EDGE names, per `StageMachine.counted?/1`) and it cannot be a
  side-effect identity (a second, different value there is `:effect_conflict` by design), so
  it has its own column and this writer.

  Fenced by the claim epoch like every other write here, and refused off `ci` — no other
  stage runs this gate.

  ## Options

  - `:claim_epoch` (required), `:actor_label`
  """
  @spec note_unevaluated(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, pos_integer()} | {:error, :not_found | :stale_claim_epoch | :wrong_stage | :busy}
  # The merge gate keeps its ORIGINAL return — a bare count. It has one kind, so it carries
  # no total, and `Loopctl.Delivery.MergePrecondition` matches on the integer.
  def note_unevaluated(tenant_id, story_id, head_sha, opts) do
    case note_counter(:merge_gate, tenant_id, story_id, %{"head_sha" => head_sha}, opts) do
      {:ok, %{count: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Counts a post-deploy verification sweep at `merge_sha` that reached NO verdict (#803 §9),
  and returns the CONSECUTIVE count at that merge.

  The same backstop `note_unevaluated/4` gives the merge gate, for the other control-side
  gate. `Loopctl.Delivery.PostDeployVerification` answers `:unresolved` and transitions
  nothing when the forge is transiently unavailable or the deploy has not settled, on
  purpose: one blip, or one deploy still running, must not park a story on a human, and
  `escalated` is human-only. A fault that never clears would then answer that way for ever
  with nobody told, so the verifier escalates once this count passes its bound.

  Keyed to the MERGE, not the head: the question a sweep asks is whether THIS merge is
  running in the target deployment. Every edge that clears `merge_sha` clears it
  (`StageMachine.merge_keyed/0`).

  **`kind` is part of the identity, and the count RESETS when it changes.** Two conditions
  reach `:unresolved` and they want different bounds: a transient forge fault is a blip
  measured in minutes, while a deploy that has not settled is measured in however long a
  queued build takes. Counting them on one number meant the slower condition inherited the
  faster one's bound and escalated every story on the normal path. A run of forge faults
  followed by a run of waiting is two different conditions, so the second starts at 1.

  Fenced by the claim epoch like every other write here, and refused off `deployed` — no
  other stage runs this gate.

  ## Options

  - `:claim_epoch` (required), `:actor_label`
  """
  @spec note_post_deploy_unresolved(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t() | nil,
          atom(),
          keyword()
        ) ::
          {:ok, %{count: pos_integer(), total: pos_integer()}}
          | {:error, :not_found | :stale_claim_epoch | :wrong_stage | :busy}
  def note_post_deploy_unresolved(tenant_id, story_id, merge_sha, kind, opts)
      when is_atom(kind) do
    identity = %{"merge_sha" => merge_sha, "kind" => Atom.to_string(kind)}
    note_counter(:post_deploy, tenant_id, story_id, identity, opts)
  end

  defp note_counter(name, tenant_id, story_id, identity, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)
    counter = Map.fetch!(@counters, name)

    in_tenant(tenant_id, fn ->
      story = share_lock_story(tenant_id, story_id)
      if story.claim_epoch != epoch, do: Repo.rollback(:stale_claim_epoch)

      case lock_row(tenant_id, story_id) do
        nil -> Repo.rollback(:not_found)
        row -> {count_unresolved(counter, row, story, identity, opts), nil}
      end
    end)
  end

  defp count_unresolved(counter, row, story, identity, opts) do
    if row.claim_epoch != story.claim_epoch, do: Repo.rollback(:stale_claim_epoch)
    if row.stage != counter.stage, do: Repo.rollback(:wrong_stage)

    counts = next_counts(Map.fetch!(row, counter.column), identity, counter.totalled_by)
    value = identity |> Map.put("count", counts.count) |> put_total(counter, counts)

    {1, [row]} =
      from(s in StoryStage,
        where: s.id == ^row.id and s.tenant_id == ^row.tenant_id,
        select: s,
        update: [
          set: ^[{counter.column, value}, {:updated_at, DateTime.utc_now()}],
          inc: [lock_version: 1]
        ]
      )
      |> Repo.update_all([])

    insert_event(Repo, row, counter.event, nil, nil, opts[:actor_label], value)
    counts
  end

  defp put_total(value, %{totalled_by: nil}, _counts), do: value
  defp put_total(value, _counter, counts), do: Map.put(value, "total", counts.total)

  @doc """
  Clears the consecutive-unevaluated count after an evaluation that DID produce a verdict.

  A no-op when there is nothing to clear, so a successful gate run in the ordinary case
  writes nothing and leaves no event. Without it the count outlives the fault it recorded,
  and a later blip at the same head escalates on a predecessor's arithmetic.

  Every edge that clears `head_sha` clears the count too (`StageMachine.head_keyed/0`); this
  is the path for the case where nothing transitions at all.

  ## Options

  - `:claim_epoch` (required), `:actor_label`
  """
  @spec clear_unevaluated(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, :cleared | :nothing_to_clear} | {:error, :not_found | :stale_claim_epoch | :busy}
  def clear_unevaluated(tenant_id, story_id, opts),
    do: clear_counter(:merge_gate, tenant_id, story_id, opts)

  @doc """
  Clears the consecutive post-deploy-unresolved count after a sweep that DID reach a
  verdict. `note_post_deploy_unresolved/4`'s other half; see `clear_unevaluated/3` for the
  shape and for why a no-op writes nothing.

  ## Options

  - `:claim_epoch` (required), `:actor_label`
  """
  @spec clear_post_deploy_unresolved(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, :cleared | :nothing_to_clear} | {:error, :not_found | :stale_claim_epoch | :busy}
  def clear_post_deploy_unresolved(tenant_id, story_id, opts),
    do: clear_counter(:post_deploy, tenant_id, story_id, opts)

  defp clear_counter(name, tenant_id, story_id, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)
    counter = Map.fetch!(@counters, name)

    in_tenant(tenant_id, fn ->
      story = share_lock_story(tenant_id, story_id)
      if story.claim_epoch != epoch, do: Repo.rollback(:stale_claim_epoch)

      case lock_row(tenant_id, story_id) do
        nil -> Repo.rollback(:not_found)
        row -> {maybe_clear_counter(counter, row, opts), nil}
      end
    end)
  end

  defp maybe_clear_counter(counter, row, opts) do
    case Map.fetch!(row, counter.column) do
      nil -> :nothing_to_clear
      previous -> do_clear_counter(counter, row, previous, opts)
    end
  end

  defp do_clear_counter(counter, row, previous, opts) do
    {1, [row]} =
      from(s in StoryStage,
        where: s.id == ^row.id and s.tenant_id == ^row.tenant_id,
        select: s,
        update: [
          set: ^[{counter.column, nil}, {:updated_at, DateTime.utc_now()}],
          inc: [lock_version: 1]
        ]
      )
      |> Repo.update_all([])

    insert_event(Repo, row, counter.event, nil, nil, opts[:actor_label], %{"cleared" => previous})
    :cleared
  end

  # Two counts from one stored map.
  #
  # `count` needs the WHOLE identity to match — a changed sha, a changed kind, a missing key
  # and an extra one all restart it. `total` needs only `totalled_by` to match, so a run
  # that alternates kinds keeps accumulating instead of the two resetting each other to 1
  # and reaching neither bound.
  #
  # A malformed or differently-shaped stored value is not "a count at something", it is no
  # count, and both restart at 1.
  defp next_counts(%{"count" => count} = previous, identity, totalled_by)
       when is_integer(count) and count >= 0 do
    stored = previous |> Map.delete("count") |> Map.delete("total")

    %{
      count: if(stored == identity, do: count + 1, else: 1),
      total: next_total(stored, identity, totalled_by, Map.get(previous, "total", count))
    }
  end

  defp next_counts(_previous, _identity, _totalled_by), do: %{count: 1, total: 1}

  defp next_total(_stored, _identity, nil, _total), do: 1

  defp next_total(stored, identity, totalled_by, total) when is_integer(total) and total >= 0 do
    if Map.take(stored, totalled_by) == Map.take(identity, totalled_by), do: total + 1, else: 1
  end

  defp next_total(_stored, _identity, _totalled_by, _total), do: 1

  @doc """
  Records the identity of a side effect on the story's stage row, idempotently.

  `effect` is one of `StageMachine.effects/0`: `:runner_id` (a runner UUID),
  `:worktree_path` (1..4096 characters), `:branch` and `:release_id` (1..255),
  `:pr_number` (positive integer), and `:head_sha`, `:merge_sha` and
  `:merge_gate_allowed_sha` (40 or 64 lowercase hex).

  - `{:ok, row}` — recorded, or ALREADY recorded with this same value (a replay)
  - `:invalid_effect` — unknown effect or malformed value
  - `:not_found` — no such story or stage row in the tenant
  - `:stale_claim_epoch` — the caller's epoch, or the row's, is not the story's current one
  - `:wrong_stage` — the row is not in a stage that produces this effect
    (`StageMachine.effect_stages/1`)
  - `:effect_conflict` — the identity is already set to a DIFFERENT value
  - `:transition_only_effect` — `:merge_sha`, which only the transition into `merged` may
    write (`advance/4`'s `:effects`), so that its chained entry names the merge; and
    `:triage_dispatch_id`, which only `detected -> triaged` writes, so the story leaves
    `detected` and names its deciding dispatch in one transaction

  ## Options

  - `:claim_epoch` (required), `:actor_label`
  """
  @spec record_effect(Ecto.UUID.t(), Ecto.UUID.t(), atom(), term(), keyword()) ::
          {:ok, StoryStage.t()} | {:error, effect_error()}
  def record_effect(tenant_id, story_id, effect, value, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)

    with :ok <- recordable(effect),
         {:ok, value} <- validate_effect(effect, value) do
      in_tenant(tenant_id, fn ->
        effect_write(tenant_id, story_id, {effect, value}, epoch, opts)
      end)
    end
  end

  # The merge sha is the transition's to write (see `advance/4`'s `:effects`). Recorded
  # here it would land with a `story_stage_events` row and NO chain entry, so the chain
  # would say the story merged at nothing while the row named a sha the chain never saw —
  # and a later retraction would withdraw a sha nothing had asserted.
  defp recordable(effect) do
    if StageMachine.transition_only?(effect), do: {:error, :transition_only_effect}, else: :ok
  end

  defp effect_write(tenant_id, story_id, {effect, value}, epoch, opts) do
    story = share_lock_story(tenant_id, story_id)
    if story.claim_epoch != epoch, do: Repo.rollback(:stale_claim_epoch)

    row =
      row_query(tenant_id, story_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    {apply_effect(row, story, effect, value, opts), nil}
  end

  defp apply_effect(nil, _story, _effect, _value, _opts), do: Repo.rollback(:not_found)

  defp apply_effect(row, story, effect, value, opts) do
    if row.claim_epoch != story.claim_epoch, do: Repo.rollback(:stale_claim_epoch)
    put_effect(row, effect, value, opts)
  end

  # The one place an identity is written, shared by `record_effect/5` and by the `:effects`
  # a transition carries. The caller has already validated the value and the epoch.
  defp put_effect(row, effect, value, opts) do
    current = Map.fetch!(row, effect)

    cond do
      not runner_resolvable?(effect, value, row.tenant_id) -> Repo.rollback(:invalid_effect)
      # A replay of the write that already landed, from any stage: nothing to do.
      current == value -> row
      row.stage not in StageMachine.effect_stages(effect) -> Repo.rollback(:wrong_stage)
      not is_nil(current) -> Repo.rollback(:effect_conflict)
      true -> set_effect(row, effect, value, opts)
    end
  end

  defp put_effects(row, effects, opts) do
    Enum.reduce(effects, row, fn {effect, value}, acc -> put_effect(acc, effect, value, opts) end)
  end

  defp set_effect(row, effect, value, opts) do
    {1, [row]} =
      from(s in StoryStage,
        where: s.id == ^row.id and s.tenant_id == ^row.tenant_id,
        where: is_nil(field(s, ^effect)),
        select: s,
        update: [
          set: ^[{effect, value}, {:updated_at, DateTime.utc_now()}],
          inc: [lock_version: 1]
        ]
      )
      |> Repo.update_all([])

    data = %{"effect" => Atom.to_string(effect), "value" => event_value(value)}
    insert_event(Repo, row, "effect_recorded", nil, nil, opts[:actor_label], data)
    row
  end

  # A foreign key does NOT scope a runner to the tenant: FK checks bypass RLS, so ANOTHER
  # tenant's runner id satisfies `story_stages_runner_id_fkey` and would be recorded as this
  # story's runner. A stale id is no better — it raises 23503 from the write, which is not a
  # retryable class and would crash the caller. Both are `:invalid_effect`.
  #
  # KEEP THE EXPLICIT `tenant_id` PREDICATE. In TEST the connection is a superuser and
  # `Repo.set_rls_context/1` switches to the non-superuser `:rls_role`, so the policy on
  # `runners` does the scoping and a mutation removing the predicate stays green — that is
  # a property of the test role, not evidence the predicate is redundant. In production
  # `maybe_set_local_role/0` is a no-op and the policy is ENABLE (not FORCE), so for a
  # connection that owns the table the predicate may be the ONLY isolation this read has.
  defp runner_resolvable?(:runner_id, runner_id, tenant_id) do
    Repo.exists?(from r in Runner, where: r.tenant_id == ^tenant_id and r.id == ^runner_id)
  end

  defp runner_resolvable?(_effect, _value, _tenant_id), do: true

  defp event_value(value) when is_integer(value), do: value
  defp event_value(value), do: to_string(value)

  @doc """
  Makes a story's stage row follow a claim RELEASE, inside the releasing transaction, and
  decides where the story goes next. Every path that bumps `stories.claim_epoch` by releasing
  a claim calls it:

  - `:runner_lost` — `Loopctl.Progress.reclaim_expired_claim/3` (the lease ran out) and
    `Loopctl.Progress.release_ended_session/4` (a runner reported the session ended)
  - `:claim_released` — `Loopctl.Progress.unclaim_story/3`,
    `Loopctl.Progress.force_unclaim_story/3`, the reject auto-reset in `Loopctl.Progress`,
    and `Loopctl.BulkOperations`' bulk-reject auto-reset. A separate edge so `runner_lost`
    in `attempts` counts only runners that actually disappeared.

  What happens to the row:

  - in flight (`StageMachine.in_flight_stages/0`) — back to `queued` over `edge`, bound to
    `new_epoch`, and the identities the released holder held cleared
    (`StageMachine.clears/3`). Recorded as `transitioned`. The edge is counted in `attempts`
    only when the release SPENT an attempt (`:cause` `:attempt`).
  - any other stage except `done` and `failed` — the stage stays and the row is rebound to
    `new_epoch`, recorded as `rebound` (nothing written when it is already there). The effect
    a merged or deployed story already had cannot be taken back by a release, and a queued,
    triage-stage or escalated row is not held by the released claim; rebinding keeps every
    one of them advanceable. Left behind the story's epoch, it would be refused on every
    advance with nothing able to move it.
  - `done`, `failed`, or no row — untouched, `{:ok, {nil, nil}}`.

  ## Where the story goes next (US-44.4, #877)

  A release sets `agent_status: :pending`, and the dispatch driver selects `queued` +
  `:contracted` only — so a row the release leaves at `queued` would be UNREACHABLE: no
  placement takes it, no alert fires, and nothing re-contracts it. Every release therefore
  ends somewhere the driver or a human acts on, decided here by the `:cause`, only for a row
  that is at `queued` once the release is done:

  | `:cause` | outcome | counted |
  |---|---|---|
  | `:placement_refused` — the runner refused before any work | stays `queued`; the caller re-contracts | no |
  | `:usage_exhausted` — the session's subscription ran dry | stays `queued`; the caller re-contracts | no |
  | `:attempt` — lease expiry, `crashed`, a verifier reject, the claimant's own unclaim | stays `queued` below the ceiling; `{queued, escalated, :attempts_exhausted}` at it | yes |
  | `:operator` — an operator's force-unclaim | `{queued, escalated, :operator_released}` | no |

  The ceiling is `Loopctl.Delivery.RetryCeiling`: counted releases INCLUDING this one, against
  `DISPATCH_MAX_ATTEMPTS`, which has no default — unset, the first counted release escalates.
  Only a release that actually REQUEUED an in-flight row is counted and can reach it; a row
  that was already `queued` spent nothing and is left for the caller to re-contract.

  The RE-CONTRACT is the caller's, not this function's, and that split is deliberate: it
  writes its own audit entry and `story.status_changed` webhook
  (`Loopctl.Progress.recontract_in_transaction/3`). Run from here it would land BEFORE the
  release's own audit entry and webhook, so the log and every webhook consumer would read the
  story as contracted and then pending. Each caller runs it after its own audit, as a step of
  the same transaction, when this returns a row at `queued` — `recontract_released/4`.

  The escalation is written HERE, in the same transaction: the row, a `transitioned` event, and
  the chain entry every transition into `escalated` carries
  (`AuditChain.append_in_admin_transaction/2`). That entry is NOT announced here — this
  transaction is the caller's and has not committed — so it is returned, and the caller passes
  the whole result to `announce_release/1` once its transaction has. A chain append that is
  refused returns `{:error, :audit_chain_append_failed}` and leaves the row and event this
  function wrote in the caller's transaction, which the caller must roll back: a custody
  transition whose chain entry did not land must not commit. The reason is control's own text,
  the count in it for `:attempts_exhausted`.

  ## Races, retries and partitions

  - A lease reclaim racing any other release: every caller holds the story `FOR UPDATE`, so the
    second one to lock reads a story the first already released. Its own guard refuses it
    (`:claim_not_expired`, `:claim_not_held`) or, for force-unclaim's idempotent `:pending`
    branch, it finds the row at the SAME epoch and rebinds nothing — and an escalated row is not
    `queued`, so it is not escalated twice.
  - A resend after a lost acknowledgement (a runner's `session_ended`) reaches no second release
    at all: the claim it was about has ended, so `:claim_not_held` answers before this runs.
  - A release after the claim already moved on (a re-claim bumped the epoch) is refused by the
    caller's own epoch guard; it never reaches a row a later claim holds.
  - A runner cut off from the control plane keeps no claim: its lease is what releases it, over
    `:attempt`, and every write it tries afterwards presents the old epoch and is fenced.

  The holder of the released claim is fenced either way: it still presents the OLD epoch,
  and `advance/4` and `record_effect/5` refuse that before they look at the row.

  Runs on `AdminRepo` inside the caller's transaction, which already holds the story's row
  lock (the order every writer here takes: story, then stage row, then the chain), so the
  release, the row and any escalation commit together or not at all. It takes no connection of
  its own. Raises outside an `AdminRepo` transaction; the explicit `tenant_id` predicate is the
  only isolation here. Also correct on a story already at `pending` (`force_unclaim_story/3`'s
  idempotent branch passes the current epoch), which is how an operator recovers a row stranded
  by a release that predates this function.

  ## Options

  - `:cause` (required) — one of `#{inspect(@release_causes)}`; see the table above
  - `:actor_lineage` (required) — the releasing principal's SERVER-resolved lineage, recorded
    on the chain entry of an escalation. `[]` is an attested absence (a system actor, a key no
    dispatch minted) and must be stated, never defaulted
  - `:actor_label` — recorded on the events

  ## Returns

  `{:ok, {row, chain_entry}}` — the row as the release left it (`nil` when there is none) and
  the chain entry an escalation appended (`nil` when it escalated nothing), for
  `recontract_released/4` and `announce_release/1`. `{:error, :audit_chain_append_failed}`
  when the escalation's chain entry was refused; see above.
  """
  @spec follow_release(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          :runner_lost | :claim_released,
          keyword()
        ) :: {:ok, released()} | {:error, :audit_chain_append_failed}
  def follow_release(tenant_id, story_id, new_epoch, edge, opts \\ [])
      when edge in [:runner_lost, :claim_released] do
    unless AdminRepo.in_transaction?(),
      do: raise(ArgumentError, "follow_release/5 runs inside the releasing transaction")

    cause = Keyword.get(opts, :cause)

    unless cause in @release_causes,
      do:
        raise(ArgumentError, "follow_release/5 requires a :cause in #{inspect(@release_causes)}")

    # Checked up front, not where the escalation needs it: a caller that forgot it must fail on
    # every release, not only on the one that happens to escalate.
    unless Keyword.has_key?(opts, :actor_lineage),
      do:
        raise(ArgumentError, "follow_release/5 requires :actor_lineage (an attested [] is fine)")

    row = live_row(tenant_id, story_id)

    cond do
      is_nil(row) ->
        {:ok, {nil, nil}}

      row.stage in StageMachine.in_flight_stages() ->
        counted? = cause == :attempt

        row
        |> requeue(new_epoch, edge, counted?, opts)
        |> settle(cause, counted?, opts)

      true ->
        row
        |> rebind(new_epoch, opts)
        |> settle(cause, false, opts)
    end
  end

  @doc """
  Makes a released DELIVERY story placeable again, when `follow_release/5` left its stage row at
  `queued` (US-44.4, #877) — and does nothing otherwise. Returns the story as it now stands.

  A release sets `agent_status: :pending`; the dispatch driver selects `queued` +
  `:contracted` only, so without this the story is unreachable, with no alert. A row
  `follow_release/5` left anywhere else — escalated for a human, merged, no row at all — says
  who acts next, and the story is left exactly as the release wrote it.

  Through `Loopctl.Progress.recontract_in_transaction/3`: a guarded `pending -> contracted`
  UPDATE plus the audit entry and `story.status_changed` webhook `Progress.contract_story/4`
  writes, built by the same functions — a write in the caller's transaction, not a transaction
  of its own. So every release path calls this AFTER its own audit entry and webhook: run
  earlier, the log and the webhook stream would say contracted and then pending, the opposite
  of what happened. `released` is what `follow_release/5` returned.
  """
  @spec recontract_released(Ecto.UUID.t(), released(), Story.t(), String.t() | nil) ::
          {:ok, Story.t()}
  def recontract_released(
        tenant_id,
        {%StoryStage{stage: :queued}, _entry},
        %Story{} = story,
        label
      ),
      do: Progress.recontract_in_transaction(tenant_id, story, label)

  def recontract_released(_tenant_id, {_row, _entry}, %Story{} = story, _label), do: {:ok, story}

  @doc """
  Announces the chain entry a release's escalation appended (`follow_release/5`), once the
  releasing transaction has COMMITTED — the broadcast `AuditChain.announce_entry/1` makes must
  never name an entry a rollback took back. Nothing to do when the release escalated nothing.
  `released` is what `follow_release/5` returned.
  """
  @spec announce_release(released()) :: :ok
  def announce_release({_row, nil}), do: :ok
  def announce_release({_row, %Entry{} = entry}), do: AuditChain.announce_entry(entry)

  @doc """
  Makes a story's stage row follow a CLAIM, inside the claiming transaction
  (`Loopctl.Progress.claim_story/3` and `Loopctl.BulkOperations`' bulk claim).

  A claim bumps `stories.claim_epoch` exactly as a release does, so a row left at the old
  epoch would be refused on every advance with nothing able to move it — a story claimed
  by hand while its row is still at `detected` or `triaged` got stuck there. The row keeps
  its STAGE and takes the new epoch (a `rebound` event); `done` and `failed`, or no row,
  are untouched.

  It never moves a row INTO `claimed`: that transition is the loop's own
  `advance(queued -> claimed)`, which is where the claimed row's chain entry and its
  `runner_id` come from. Rebinding first is what lets that advance present the new epoch
  and match.

  Same repo, transaction and lock rules as `follow_release/5`.

  ## Options

  - `:actor_label` — recorded on the event
  """
  @spec follow_claim(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer(), keyword()) ::
          {:ok, StoryStage.t() | nil}
  def follow_claim(tenant_id, story_id, new_epoch, opts \\ []) do
    unless AdminRepo.in_transaction?(),
      do: raise(ArgumentError, "follow_claim/4 runs inside the claiming transaction")

    case live_row(tenant_id, story_id) do
      nil -> {:ok, nil}
      row -> rebind(row, new_epoch, opts)
    end
  end

  # Every row a claim or a release may touch: `done` and `failed` are finished with.
  defp live_row(tenant_id, story_id) do
    from(s in StoryStage,
      where: s.tenant_id == ^tenant_id and s.story_id == ^story_id,
      where: s.stage not in [:done, :failed],
      lock: "FOR UPDATE"
    )
    |> AdminRepo.one()
  end

  defp requeue(%StoryStage{stage: from} = row, new_epoch, edge, counted?, opts) do
    true = StageMachine.allowed?(from, :queued, edge)

    {1, [updated]} =
      from(s in StoryStage, where: s.id == ^row.id and s.tenant_id == ^row.tenant_id, select: s)
      |> transition_update(from, :queued, edge, [claim_epoch: new_epoch], counted?)
      |> AdminRepo.update_all([])

    insert_event(AdminRepo, updated, "transitioned", from, edge, opts[:actor_label], %{
      "released_claim_epoch" => row.claim_epoch
    })

    {:ok, updated}
  end

  # A row already at the new epoch (an idempotent force-unclaim) is left exactly as it is —
  # and returned, because what the release decides next depends on the stage it is at.
  defp rebind(%StoryStage{claim_epoch: epoch} = row, epoch, _opts), do: {:ok, row}

  defp rebind(%StoryStage{} = row, new_epoch, opts) do
    {1, [updated]} =
      from(s in StoryStage,
        where: s.id == ^row.id and s.tenant_id == ^row.tenant_id,
        select: s,
        update: [
          set: [claim_epoch: ^new_epoch, updated_at: ^DateTime.utc_now()],
          inc: [lock_version: 1]
        ]
      )
      |> AdminRepo.update_all([])

    insert_event(AdminRepo, updated, "rebound", nil, nil, opts[:actor_label], %{
      "released_claim_epoch" => row.claim_epoch
    })

    {:ok, updated}
  end

  # WHERE THE RELEASED STORY GOES (US-44.4). Only a row at `queued` is decided: anywhere else
  # the release did not put the story in front of the driver, and the stage row already says
  # who acts on it. See `follow_release/5`'s table.
  defp settle({:ok, %StoryStage{stage: :queued} = row}, :operator, _counted?, opts),
    do: escalate_released(row, :operator_released, @operator_released_reason, opts)

  defp settle({:ok, %StoryStage{stage: :queued} = row}, :attempt, true, opts) do
    count = RetryCeiling.counted_releases(row.attempts)
    ceiling = RetryCeiling.max_attempts()

    case RetryCeiling.decide(count, ceiling) do
      :retry ->
        {:ok, {row, nil}}

      {:escalate, :attempts_exhausted} ->
        escalate_released(
          row,
          :attempts_exhausted,
          RetryCeiling.exhausted_reason(count, ceiling),
          opts
        )
    end
  end

  defp settle({:ok, row}, _cause, _counted?, _opts), do: {:ok, {row, nil}}

  # `queued -> escalated` over a release escalation edge, on `AdminRepo` in the releasing
  # transaction. The same write `compare_and_set/4` makes — the UPDATE, the event, the chain
  # entry — but with no compare to lose: this transaction holds the story `FOR UPDATE` and the
  # row `FOR UPDATE` (`live_row/2`), and has just written the row itself.
  defp escalate_released(%StoryStage{} = row, edge, reason, opts) do
    true = StageMachine.allowed?(:queued, :escalated, edge)

    {1, [escalated]} =
      from(s in StoryStage,
        where: s.id == ^row.id and s.tenant_id == ^row.tenant_id and s.stage == :queued,
        select: s
      )
      |> transition_update(:queued, :escalated, edge, escalation_reason: reason)
      |> AdminRepo.update_all([])

    insert_event(AdminRepo, escalated, "transitioned", :queued, edge, opts[:actor_label], %{
      "reason" => reason
    })

    # A custody transition whose chain entry did not land must not commit — so the refusal is
    # RETURNED, and every caller rolls its transaction back on it (see `follow_release/5`).
    # In this transaction and unannounced: `announce_release/1` broadcasts it after the
    # caller commits, never before.
    row.tenant_id
    |> AuditChain.append_in_admin_transaction(
      chain_attrs(
        escalated,
        row,
        {:queued, :escalated, edge},
        reason,
        Keyword.fetch!(opts, :actor_lineage)
      )
    )
    |> case do
      {:ok, entry} ->
        {:ok, {escalated, entry}}

      {:error, changeset} ->
        Logger.error(
          "release escalation chain append refused; the release must roll back: " <>
            "tenant_id=#{row.tenant_id} story_id=#{row.story_id} edge=#{edge} " <>
            "errors=#{inspect(Keyword.keys(changeset.errors))}"
        )

        {:error, :audit_chain_append_failed}
    end
  end

  # --- transition mechanics -------------------------------------------------------------

  # The one UPDATE every transition writes, on either repo: the new stage, the identities the
  # edge clears, `attempts` counted in SQL (never read-modify-write), and `lock_version`.
  defp transition_update(query, from, to, edge, extra, counted? \\ true) do
    clears = Enum.map(StageMachine.clears(from, to, edge), &{&1, nil})
    set = [stage: to, updated_at: DateTime.utc_now()] ++ clears ++ extra

    query = update(query, set: ^set, inc: [lock_version: 1])

    if counted? and StageMachine.counted?(edge) do
      name = Atom.to_string(edge)

      update(query, [s],
        set: [
          attempts:
            fragment(
              "jsonb_set(?, ARRAY[?::text], to_jsonb(COALESCE((? ->> ?::text)::bigint, 0) + 1))",
              s.attempts,
              ^name,
              s.attempts,
              ^name
            )
        ]
      )
    else
      query
    end
  end

  defp allowed_for_caller(_from, _to, edge) when edge in @release_only_edges,
    do: {:error, :invalid_transition}

  defp allowed_for_caller(from, to, edge) do
    if StageMachine.allowed?(from, to, edge), do: :ok, else: {:error, :invalid_transition}
  end

  # A CHAINED transition writes a custody entry, and that entry records who made it. The
  # caller's lineage is resolved SERVER-SIDE from its key, so an ABSENT `:actor_lineage` is
  # a caller that never resolved one — not a caller that has none. There is no default, for
  # the same reason `Progress`' custody gates give `caller_lineage` none: a defaulted `[]`
  # makes "resolved, and empty" indistinguishable from "forgot to resolve", and here it
  # would also hand the human-only edge to any dispatch-minted `:user` key that simply
  # omitted the option. An explicit `[]` is an attested absence and is accepted.
  defp lineage_declared(from, to, edge, opts) do
    if StageMachine.chained?(from, to, edge) and not Keyword.has_key?(opts, :actor_lineage),
      do: {:error, :actor_lineage_required},
      else: :ok
  end

  defp human_gate(edge, opts) do
    if StageMachine.human_only?(edge) and not human?(opts),
      do: {:error, :human_required},
      else: :ok
  end

  # Every human-only edge is chained, so `lineage_declared/3` has already refused an absent
  # lineage by the time this runs; `fetch!` keeps that true if a future edge is not.
  defp human?(opts) do
    Role.role_at_least?(Keyword.get(opts, :actor_role, :agent), :user) and
      Keyword.fetch!(opts, :actor_lineage) == []
  end

  # A reason is REQUIRED entering `escalated` and bounded wherever it is given: it lands in
  # `story_stages.escalation_reason` under the `story_stages_text_bounds` CHECK and in the
  # event's jsonb, so a pasted CI log or a NUL byte would be refused by Postgres AFTER the
  # transition was decided, losing the escalation.
  defp reason_given(to, edge, reason) do
    cond do
      StageMachine.reason_required?(to, edge) and not present?(reason) ->
        {:error, :reason_required}

      is_nil(reason) ->
        :ok

      reason_within_bound?(reason) ->
        :ok

      true ->
        {:error, :invalid_reason}
    end
  end

  defp present?(reason), do: is_binary(reason) and String.trim(reason) != ""

  # THE REASON'S OWN BOUND, and not `bounded_text/2`, which is the EFFECTS' bound and rejects
  # a NUL and invalid UTF-8 outright.
  #
  # Neither of those is a refusal any more: both are things `sanitise/1` ESCAPES on the way to
  # storage, and refusing them here would be the old behaviour under a new name — a session
  # asking for a human got nothing because its log tail carried one stray byte. What is left
  # is the LENGTH, measured on the text the caller actually sent, which is the number the
  # controller and the contract publish.
  #
  # `replace_invalid/1` first so the count is defined at all: `String.to_charlist/1` raises on
  # invalid UTF-8, and a reason carrying a truncated multi-byte sequence would crash the count
  # rather than be measured. It replaces each bad byte with one replacement character, so the
  # length it yields is the caller's own, and it is the same first step `sanitise/1` takes.
  defp reason_within_bound?(reason) do
    reason
    |> String.replace_invalid()
    |> codepoints()
    |> Kernel.in(1..@max_reason_chars)
  end

  # THE REASON IS ESCAPED BEFORE IT IS STORED, AND BOUNDED BEFORE IT IS ESCAPED.
  #
  # `escalation_reason` is written by a SESSION — a model that had just read reporter text —
  # and it lands in two places nobody can edit afterwards: the `story_stages` column an
  # operator reads, and, on a chained transition, the tenant's append-only hash chain. A
  # bidirectional override or a run of zero-width characters in it is invisible in both, so
  # the text an operator sees is not the text that was written, permanently.
  #
  # `sanitise/1` does NOT change what was said — it rewrites invisible and invalid codepoints
  # to `<U+XXXX>`, which is strictly better for the operator this field exists for, so the
  # VERBATIM promise `Loopctl.Delivery.Escalations` makes is kept rather than broken. What it
  # is not is a fence: prose stays prose, which is `escalation_block/1`'s job at the one hop
  # where the text goes in front of a model.
  #
  # AFTER every validation, and this ORDER is what round 1 of #859's review corrected. The
  # first version escaped first and bounded the escaped text, which split one published number
  # into two: `StoryEscalationController` and `RunnerContract` bound the RAW reason at
  # #{@max_reason_chars} codepoints, so a reason of exactly that length carrying one zero-width
  # space passed the HTTP check and was then refused `:invalid_reason` here. The escalation was
  # lost — the precise failure this escaping exists to end, reintroduced one layer up.
  #
  # A caller cannot predict the escaped length without implementing this escape table, and the
  # contract PUBLISHES the bound for a runner to validate against before sending. So the caller
  # is held to what it can measure and the COLUMN holds what it actually stores, with its CHECK
  # widened to `#{@max_reason_chars} * 10` (migration `20260921170000`) — a ceiling a conforming
  # caller cannot reach rather than a limit anyone approaches.
  #
  # It rewrites `opts` rather than a local because `transition/6` reads `:reason` again from
  # there, and a second read of the raw value is how the escaped form would reach the event
  # while the raw one reached the column.
  #
  # `present?/1` runs on the RAW text, above, for the same ordering reason: `sanitise/1` turns
  # a blank C0 control into visible text, so a reason of `"\f"` alone would satisfy
  # "a reason is required" with nothing a person can read.
  defp sanitise_reason(opts) do
    case Keyword.get(opts, :reason) do
      reason when is_binary(reason) -> Keyword.put(opts, :reason, Untrusted.sanitise(reason))
      _ -> opts
    end
  end

  # The caller's structured payload, bounded on the JSON that is actually stored. Refused
  # BEFORE the transaction, like every other value: a jsonb Postgres will not take (a NUL in
  # a key or a value) raises 23514/22021 after the transition is already decided, and that
  # class is not retryable, so the escalation would be lost to a 500.
  defp event_data_ok(opts) do
    case Keyword.get(opts, :event_data) do
      nil -> :ok
      data when is_map(data) -> encoded_data_ok(data)
      _other -> {:error, :invalid_event_data}
    end
  end

  defp encoded_data_ok(data) do
    case Jason.encode(data) do
      {:ok, json} ->
        if byte_size(json) <= @max_event_data_bytes and not String.contains?(json, "\\u0000"),
          do: :ok,
          else: {:error, :invalid_event_data}

      {:error, _reason} ->
        {:error, :invalid_event_data}
    end
  rescue
    # A term Jason has no encoder for (a struct, a PID, a tuple) raises rather than
    # answering, and a bad argument must not reach the caller as a 500.
    _error -> {:error, :invalid_event_data}
  end

  # The transition event's `data`. The caller's payload is namespaced under `"payload"` so it
  # can never shadow a key this module writes.
  defp note(reason, opts) do
    %{}
    |> then(fn data -> if is_nil(reason), do: data, else: Map.put(data, "reason", reason) end)
    |> then(fn data ->
      case Keyword.get(opts, :event_data) do
        nil -> data
        payload -> Map.put(data, "payload", payload)
      end
    end)
  end

  @doc """
  A story stage's `escalation_reason` rendered as a fenced UNTRUSTED DATA block
  (`Loopctl.Delivery.Untrusted`), or `nil` when the row carries none.

  The reason is written by an unattended session — `POST /stories/:id/escalate`, or a line
  the runner read out of `escalations.ndjson` — so it is reporter-shaped text under design
  §8 and §10: recorded and capped, never executed. **Any prompt that carries an escalation
  reason renders it through this and nothing else.** The JSON an operator or a dashboard
  reads gets the STORED value — escaped for invisible characters by `sanitise_reason/1` on
  the way in, never fenced — because a fence there would hide what was actually written while
  the escape makes hidden characters visible without changing the words. The fence exists for
  the one hop where the text lands in front of a model.

  > **This is a CONVENTION with no binding guard, and it is on the next story to make it
  > one.** Nothing in `lib/` renders `escalation_reason` into a prompt today — the prompt
  > that will carry an escalation back to a human, or to a resumed session, does not exist
  > yet — so this function is exercised only by its test and no mechanism forces a future
  > caller through it. `Loopctl.Delivery.ImplementerInput` shows the shape the binding takes
  > when there is something to bind: a test that names the untrusted fields and fails when
  > they appear anywhere in `lib/` outside the modules that own the boundary. Whoever builds
  > that prompt adds `escalation_reason` to a guard of that kind in the same change; until
  > then the only thing stopping a raw interpolation is this paragraph.
  """
  @spec escalation_block(StoryStage.t()) :: String.t() | nil
  def escalation_block(%StoryStage{escalation_reason: nil}), do: nil

  def escalation_block(%StoryStage{escalation_reason: reason}),
    do: Untrusted.render("escalation_reason", reason)

  defp maybe_chain(row, previous, {from, to, edge} = transition, reason, opts) do
    if StageMachine.chained?(from, to, edge) do
      # Present by construction: `lineage_declared/3` refuses a chained transition whose
      # caller did not state one, so this never records an unattributed custody entry.
      lineage = Keyword.fetch!(opts, :actor_lineage)

      row.tenant_id
      |> AuditChain.append_in_tenant_transaction(
        chain_attrs(row, previous, transition, reason, lineage)
      )
      |> chained_entry(row, to)
    end
  end

  # ONE shape for every stage chain entry, whichever repo writes it — `maybe_chain/5` on the
  # RLS repo, `escalate_released/4` inside a release's `AdminRepo` transaction — so a verifier
  # reading the chain cannot tell them apart by anything but what happened.
  defp chain_attrs(row, previous, {from, to, edge}, reason, actor_lineage) do
    %{
      action: chain_action(from, to, edge),
      actor_lineage: actor_lineage,
      entity_type: "story",
      entity_id: row.story_id,
      payload: %{
        "story_stage_id" => row.id,
        "from" => Atom.to_string(from),
        "to" => Atom.to_string(to),
        "edge" => Atom.to_string(edge),
        "claim_epoch" => row.claim_epoch,
        "lock_version" => row.lock_version,
        "reason" => reason,
        "runner_id" => row.runner_id,
        "pr_number" => row.pr_number,
        "head_sha" => row.head_sha,
        "merge_sha" => row.merge_sha,
        "retracted" => retracted(previous, from, to, edge)
      }
    }
  end

  # The append's error contract. A custody transition whose chain entry did not land must
  # not commit — a `MatchError` here would have crashed inside the transaction and answered
  # the caller with a 500 instead of a reason it can act on.
  defp chained_entry({:ok, entry}, _row, _to), do: entry

  defp chained_entry({:error, reason}, row, to) do
    Logger.error(
      "story stage chain append refused, transition rolled back: tenant_id=#{row.tenant_id} " <>
        "story_id=#{row.story_id} to=#{to} reason=#{inspect(reason)}"
    )

    Repo.rollback(:audit_chain_append_failed)
  end

  # What the edge TOOK AWAY, read from the pre-image. A `story_stage_merge_retracted` entry
  # whose `merge_sha` is null (the row's, after the clear) would not say which merge it
  # retracts; this is the half that does.
  defp retracted(nil, _from, _to, _edge), do: %{}

  defp retracted(previous, from, to, edge) do
    from
    |> StageMachine.clears(to, edge)
    |> Map.new(fn effect -> {Atom.to_string(effect), Map.fetch!(previous, effect)} end)
  end

  # A retraction is named for what it retracts, not for where the story went next.
  defp chain_action(:merged, :implementing, :merge_refused), do: "story_stage_merge_retracted"
  defp chain_action(:escalated, _to, _edge), do: "story_stage_escalation_resolved"
  defp chain_action(_from, to, _edge), do: "story_stage_" <> Atom.to_string(to)

  # --- effects ------------------------------------------------------------------------------

  # The `:effects` a transition carries, validated the same way `record_effect/5` validates
  # its one — before the transaction, so a malformed value never opens one. The SHAPE is
  # checked first: `:effects` is a brand-new public option, and a caller's typo (`nil`, a
  # bare list, a map of strings) reached `Enum.reduce/3` and raised a Protocol or
  # FunctionClause error that `in_tenant/2`'s rescue does not catch — a 500 for a bad
  # argument.
  defp validate_effects(opts) do
    with {:ok, effects} <- effect_pairs(Keyword.get(opts, :effects, [])) do
      Enum.reduce_while(effects, {:ok, []}, &validate_pair/2)
    end
  end

  defp validate_pair({effect, value}, {:ok, acc}) do
    case validate_effect(effect, value) do
      {:ok, value} -> {:cont, {:ok, acc ++ [{effect, value}]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp effect_pairs(effects) when is_map(effects), do: effects |> Map.to_list() |> effect_pairs()

  defp effect_pairs(effects) when is_list(effects) do
    if Enum.all?(effects, &match?({key, _value} when is_atom(key), &1)),
      do: {:ok, effects},
      else: {:error, :invalid_effect}
  end

  defp effect_pairs(_effects), do: {:error, :invalid_effect}

  # An identity the destination stage's chained entry must name.
  defp required_effects_present(to, effects) do
    if Enum.all?(StageMachine.required_effects(to), &Keyword.has_key?(effects, &1)),
      do: :ok,
      else: {:error, :missing_required_effect}
  end

  defp validate_effect(:triage_dispatch_id, value), do: validate_effect(:runner_id, value)

  defp validate_effect(:runner_id, value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect}
    end
  end

  defp validate_effect(:pr_number, value)
       when is_integer(value) and value > 0 and value <= @max_pr_number,
       do: {:ok, value}

  defp validate_effect(sha, value)
       when sha in [:head_sha, :merge_sha, :merge_gate_allowed_sha] and is_binary(value) do
    if Regex.match?(@sha, value), do: {:ok, value}, else: {:error, :invalid_effect}
  end

  defp validate_effect(:worktree_path, value), do: bounded_text(value, 4096)
  defp validate_effect(:branch, value), do: bounded_text(value, 255)
  defp validate_effect(:release_id, value), do: bounded_text(value, 255)
  defp validate_effect(_effect, _value), do: {:error, :invalid_effect}

  # Postgres text refuses a NUL; the bounds match the `story_stages_text_bounds` CHECK.
  #
  # CODEPOINTS, not graphemes: `char_length` counts codepoints, so an emoji family or a
  # combining mark is ONE `String.length/1` grapheme and several characters to Postgres. A
  # grapheme count let a value through this guard that the CHECK then refused as 23514 —
  # which is not retryable, so the write died with a 500 and the escalation was lost, the
  # exact failure this bound exists to prevent.
  defp bounded_text(value, max) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) and
         codepoints(value) in 1..max,
       do: {:ok, value},
       else: {:error, :invalid_effect}
  end

  defp bounded_text(_value, _max), do: {:error, :invalid_effect}

  defp codepoints(value), do: value |> String.to_charlist() |> length()

  # --- plumbing ----------------------------------------------------------------------------

  # Every stage-row transaction: an RLS transaction this module owns, with local lock and
  # statement timeouts. The body returns `{row, chain_entry | nil}` or rolls back with a
  # reason; a committed chain entry is announced only after the commit.
  defp in_tenant(tenant_id, fun) do
    result =
      Repo.with_tenant(tenant_id, fn ->
        LocalGuc.scoped(Repo, ["lock_timeout", "statement_timeout"], fn ->
          Repo.query!(
            "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $2, true)",
            [@lock_timeout, @statement_timeout]
          )

          fun.()
        end)
      end)

    case result do
      {:ok, {row, nil}} ->
        {:ok, row}

      {:ok, {row, entry}} ->
        AuditChain.announce_entry(entry)
        {:ok, row}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      if retryable_error?(error) do
        Logger.warning(
          "story stage write gave up waiting: tenant_id=#{tenant_id} " <>
            "error=#{inspect(busy_code(error))}"
        )

        :telemetry.execute([:loopctl, :delivery, :stage_busy], %{count: 1}, %{
          tenant_id: tenant_id,
          reason: busy_code(error)
        })

        {:error, :busy}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  @doc """
  Whether a database error is CONTENTION this caller can retry out of, rather than a fault
  in the transition. `in_tenant/2` answers `{:error, :busy}` for these and reraises
  everything else, so an unclassified error LOSES the transition — which is why the audit
  chain's own `P0001` is classified even though its advisory lock makes it unreachable
  from here.

  Public only so the classes can be asserted directly; nothing outside this module and its
  test should call it.
  """
  @spec retryable_error?(Exception.t()) :: boolean()
  # Contention this caller can retry out of, none of which is a fault in the transition:
  # 55P03 lock_not_available (lock_timeout), 57014 query_canceled (statement_timeout), 40P01
  # deadlock_detected (one side is chosen and killed) and 40001 serialization_failure.
  #
  # P0001 is EVERY plpgsql RAISE in this schema, so it is matched on the exception itself
  # rather than on the code: only `audit_chain_position_violation` — a concurrent append
  # taking the position this one computed, which the chain's advisory lock already makes
  # unreachable from here — is transient. `audit_chain_hash_violation` is an L6 integrity
  # signal: reporting it as `:busy` would spin retries against a broken chain forever, so
  # it reraises like any other fault.
  @position_violation "audit_chain_position_violation"

  def retryable_error?(%Postgrex.Error{postgres: %{pg_code: "P0001"} = postgres}),
    do: String.starts_with?(Map.get(postgres, :message) || "", @position_violation)

  def retryable_error?(%Postgrex.Error{postgres: %{pg_code: code}}),
    do: code in ["55P03", "57014", "40P01", "40001"]

  def retryable_error?(%DBConnection.ConnectionError{}), do: true
  def retryable_error?(_error), do: false

  defp busy_code(%Postgrex.Error{postgres: %{pg_code: code}}), do: code
  defp busy_code(%DBConnection.ConnectionError{reason: reason}), do: reason

  # FOR SHARE: a release or a claim (FOR UPDATE on the story) cannot commit between this
  # read of `claim_epoch` and the write it fences. Taken BEFORE the stage row (see moduledoc).
  defp share_lock_story(tenant_id, story_id) do
    from(s in Story,
      where: s.id == ^story_id and s.tenant_id == ^tenant_id,
      lock: "FOR SHARE",
      select: %{
        id: s.id,
        claim_epoch: s.claim_epoch,
        agent_status: s.agent_status,
        # Read under the SAME share lock as the epoch, so the closure outbox below cannot
        # record a link the story does not have. It is write-once provenance, so nothing can
        # change it under us anyway — the lock is what makes that a fact and not a hope.
        intake_record_id: s.intake_record_id
      }
    )
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:not_found)
      story -> story
    end
  end

  defp row_query(tenant_id, story_id) do
    from s in StoryStage, where: s.tenant_id == ^tenant_id and s.story_id == ^story_id
  end

  defp fetch_row!(tenant_id, story_id), do: Repo.one!(row_query(tenant_id, story_id))

  defp insert_event(repo, %StoryStage{} = row, event, from, edge, actor_label, data) do
    repo.insert_all(StageEvent, [
      %{
        id: Ecto.UUID.generate(),
        tenant_id: row.tenant_id,
        story_stage_id: row.id,
        story_id: row.story_id,
        event: event,
        from_stage: from && Atom.to_string(from),
        to_stage: Atom.to_string(row.stage),
        edge: edge && Atom.to_string(edge),
        claim_epoch: row.claim_epoch,
        lock_version: row.lock_version,
        actor_label: actor_label,
        data: data,
        inserted_at: DateTime.utc_now()
      }
    ])
  end
end
