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
  take the story `FOR UPDATE` first and the stage row second, the same way round.

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
  `AuditChain.append_in_tenant_transaction/2`. Every transition and every newly recorded
  effect is in `story_stage_events`.

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
  alias Loopctl.Auth.Role
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.Untrusted
  alias Loopctl.LocalGuc
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  @lock_timeout "2000ms"
  @statement_timeout "5000ms"

  # The story statuses a claim holds. Entering `claimed` needs one.
  @claimed_statuses [:assigned, :implementing]

  @sha ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @max_pr_number 9_223_372_036_854_775_807

  # The `story_stages_text_bounds` CHECK on `escalation_reason`.
  @max_reason_chars 4_000

  # The encoded size of the caller-supplied `:event_data` a transition may carry into
  # `story_stage_events.data`. Counted on the JSON actually stored, so the bound is exact
  # rather than an estimate. It exists because that column is jsonb with no CHECK: an
  # unbounded structured payload from a session is a write amplifier on the event stream.
  @max_event_data_bytes 8_000

  @type advance_error ::
          :invalid_transition
          | :human_required
          | :reason_required
          | :not_found
          | :not_claimed
          | :stale_claim_epoch
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

  @doc "A tenant's stage row for `story_id`, or nil."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: StoryStage.t() | nil
  def get(tenant_id, story_id) do
    {:ok, row} =
      Repo.with_tenant(tenant_id, fn -> row_query(tenant_id, story_id) |> Repo.one() end)

    row
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

  - `:invalid_transition` — not in the table, or a release edge (`:runner_lost`,
    `:claim_released`), which only the releasing transaction takes (`follow_release/5`)
  - `:human_required` — `:human_resolution` from anything but a human principal: a role of
    at least `:user` holding a key no dispatch minted (`actor_lineage` empty). The same
    positive operator test the lineage ceiling uses; a dispatch-minted `:user` key is an
    agent's, not Mark's.
  - `:reason_required` — entering `escalated` without a `:reason`

  Refused in the transaction, in this order:

  - `:not_found` — no such story, or no stage row, in the tenant
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
    reason = Keyword.get(opts, :reason)

    with :ok <- allowed_for_caller(from, to, edge),
         :ok <- lineage_declared(from, to, edge, opts),
         :ok <- human_gate(edge, opts),
         :ok <- reason_given(to, edge, reason),
         :ok <- event_data_ok(opts),
         {:ok, effects} <- validate_effects(opts),
         :ok <- required_effects_present(to, effects) do
      in_tenant(tenant_id, fn ->
        transition(tenant_id, story_id, {from, to, edge}, epoch, effects, opts)
      end)
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

    row = compare_and_set(tenant_id, story, transition, reason)
    insert_event(Repo, row, "transitioned", from, edge, opts[:actor_label], note(reason, opts))

    # BEFORE the chain entry is built, in this same transaction: the entry has to NAME the
    # effect the transition asserts. `ci -> merged` carrying the sha GitHub just returned is
    # the case that forces it — recorded afterwards, the `story_stage_merged` entry says a
    # merge happened and identifies nothing.
    row = put_effects(row, effects, opts)
    release_session_slot(row, to, opts)
    {row, maybe_chain(row, previous, transition, reason, opts)}
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

  # Why the compare-and-set matched nothing.
  defp diagnose(tenant_id, story, from) do
    case Repo.one(row_query(tenant_id, story.id)) do
      nil -> :not_found
      %StoryStage{stage: stage} when stage != from -> :stale_stage
      %StoryStage{} -> :stale_claim_epoch
    end
  end

  @doc """
  Records the identity of a side effect on the story's stage row, idempotently.

  `effect` is one of `StageMachine.effects/0`: `:runner_id` (a runner UUID),
  `:worktree_path` (1..4096 characters), `:branch` and `:release_id` (1..255),
  `:pr_number` (positive integer), `:head_sha` and `:merge_sha` (40 or 64 lowercase hex).

  - `{:ok, row}` — recorded, or ALREADY recorded with this same value (a replay)
  - `:invalid_effect` — unknown effect or malformed value
  - `:not_found` — no such story or stage row in the tenant
  - `:stale_claim_epoch` — the caller's epoch, or the row's, is not the story's current one
  - `:wrong_stage` — the row is not in a stage that produces this effect
    (`StageMachine.effect_stages/1`)
  - `:effect_conflict` — the identity is already set to a DIFFERENT value
  - `:transition_only_effect` — `:merge_sha`, which only the transition into `merged` may
    write (`advance/4`'s `:effects`), so that its chained entry names the merge

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
  Makes a story's stage row follow a claim RELEASE, inside the releasing transaction.
  Every path that bumps `stories.claim_epoch` by releasing a claim calls it:

  - `:runner_lost` — `Loopctl.Progress.reclaim_expired_claim/3` (the lease ran out)
  - `:claim_released` — `Loopctl.Progress.unclaim_story/3`,
    `Loopctl.Progress.force_unclaim_story/3`, the reject auto-reset in `Loopctl.Progress`,
    and `Loopctl.BulkOperations`' bulk-reject auto-reset. A separate edge so `runner_lost`
    in `attempts` counts only runners that actually disappeared.

  What happens to the row:

  - in flight (`StageMachine.in_flight_stages/0`) — back to `queued` over `edge`, bound to
    `new_epoch`, the edge counted in `attempts`, and the identities the released holder
    held cleared (`StageMachine.clears/3`). Recorded as `transitioned`.
  - any other stage except `done` and `failed` — the stage stays and the row is rebound to
    `new_epoch`, recorded as `rebound`. The effect a merged or deployed story already had
    cannot be taken back by a release, and a queued, triage-stage or escalated row is not
    held by the released claim; rebinding keeps every one of them advanceable. Left behind
    the story's epoch, it would be refused on every advance with nothing able to move it.
  - `done`, `failed`, or no row — untouched, `{:ok, nil}`.

  The holder of the released claim is fenced either way: it still presents the OLD epoch,
  and `advance/4` and `record_effect/5` refuse that before they look at the row.

  Runs on `AdminRepo` inside the caller's transaction, which already holds the story's row
  lock (the order every writer here takes: story, then stage row), so the release and the
  row commit together or not at all. It takes no connection of its own. Raises outside an
  `AdminRepo` transaction; the explicit `tenant_id` predicate is the only isolation here.
  Also correct on a story already at `pending` (`force_unclaim_story/3`'s idempotent
  branch passes the current epoch), which is how an operator recovers a row stranded by a
  release that predates this function.

  ## Options

  - `:actor_label` — recorded on the event
  """
  @spec follow_release(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          :runner_lost | :claim_released,
          keyword()
        ) :: {:ok, StoryStage.t() | nil}
  def follow_release(tenant_id, story_id, new_epoch, edge, opts \\ [])
      when edge in [:runner_lost, :claim_released] do
    unless AdminRepo.in_transaction?(),
      do: raise(ArgumentError, "follow_release/5 runs inside the releasing transaction")

    row = live_row(tenant_id, story_id)

    cond do
      is_nil(row) -> {:ok, nil}
      row.stage in StageMachine.in_flight_stages() -> requeue(row, new_epoch, edge, opts)
      true -> rebind(row, new_epoch, opts)
    end
  end

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

  defp requeue(%StoryStage{stage: from} = row, new_epoch, edge, opts) do
    true = StageMachine.allowed?(from, :queued, edge)

    {1, [updated]} =
      from(s in StoryStage, where: s.id == ^row.id and s.tenant_id == ^row.tenant_id, select: s)
      |> transition_update(from, :queued, edge, claim_epoch: new_epoch)
      |> AdminRepo.update_all([])

    insert_event(AdminRepo, updated, "transitioned", from, edge, opts[:actor_label], %{
      "released_claim_epoch" => row.claim_epoch
    })

    {:ok, updated}
  end

  # A row already at the new epoch (an idempotent force-unclaim) is left exactly as it is.
  defp rebind(%StoryStage{claim_epoch: epoch}, epoch, _opts), do: {:ok, nil}

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

  # --- transition mechanics -------------------------------------------------------------

  # The one UPDATE every transition writes, on either repo: the new stage, the identities the
  # edge clears, `attempts` counted in SQL (never read-modify-write), and `lock_version`.
  defp transition_update(query, from, to, edge, extra) do
    clears = Enum.map(StageMachine.clears(from, to, edge), &{&1, nil})
    set = [stage: to, updated_at: DateTime.utc_now()] ++ clears ++ extra

    query = update(query, set: ^set, inc: [lock_version: 1])

    if StageMachine.counted?(edge) do
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

  defp allowed_for_caller(_from, _to, edge) when edge in [:runner_lost, :claim_released],
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

      match?({:ok, _}, bounded_text(reason, @max_reason_chars)) ->
        :ok

      true ->
        {:error, :invalid_reason}
    end
  end

  defp present?(reason), do: is_binary(reason) and String.trim(reason) != ""

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
  reads gets the raw value, because a fence there would hide what was actually written; the
  fence exists for the one hop where the text lands in front of a model.

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

  defp maybe_chain(row, previous, {from, to, edge}, reason, opts) do
    if StageMachine.chained?(from, to, edge) do
      row.tenant_id
      |> AuditChain.append_in_tenant_transaction(%{
        action: chain_action(from, to, edge),
        # Present by construction: `lineage_declared/3` refuses a chained transition whose
        # caller did not state one, so this never records an unattributed custody entry.
        actor_lineage: Keyword.fetch!(opts, :actor_lineage),
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
      })
      |> chained_entry(row, to)
    end
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

  defp validate_effect(:runner_id, value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect}
    end
  end

  defp validate_effect(:pr_number, value)
       when is_integer(value) and value > 0 and value <= @max_pr_number,
       do: {:ok, value}

  defp validate_effect(sha, value) when sha in [:head_sha, :merge_sha] and is_binary(value) do
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
      select: %{id: s.id, claim_epoch: s.claim_epoch, agent_status: s.agent_status}
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
