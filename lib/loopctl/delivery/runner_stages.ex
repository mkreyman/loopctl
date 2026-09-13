defmodule Loopctl.Delivery.RunnerStages do
  @moduledoc """
  Applies a runner's `stage` message to the story's delivery stage row (issue #803, design
  §3 and §11, contract 1.4.0).

  This module is a COORDINATOR, not a second writer. `Loopctl.Delivery.Stages` remains the
  only thing that writes `story_stages`; what happens here is the three steps around one
  `Stages.advance/4` call that the channel process should not be carrying:

  1. resolve the runner's ACCEPTED dispatch to the story it is for
     (`Loopctl.Runners.DispatchLedger.accepted_session/3`) — the story is NEVER taken off
     the wire, so a runner cannot report a transition on a story it was not dispatched;
  2. refuse an epoch that is not even the dispatch's, before a transaction is opened;
  3. resolve a REPLAY, and give the session's slot back when the replay is of a message that
     ended it.

  ## Where the state lives, and how a caller reaches it after a restart

  Postgres. The message is a request; the row is the answer. No process owns a story, so a
  runner that reconnects to a different loopctl node — which happens on every rolling
  deploy — sends the same message to whatever node accepted its socket, and that node reads
  and compare-and-sets the same row. The reply carries the row's `stage`, `claim_epoch`,
  `lock_version` and `attempts`, which is how a session that lost its acknowledgement learns
  where the story actually is without a second endpoint.

  ## Partitions

  A runner cut off from the control plane writes nothing while it is gone, and its claim
  lease runs out. The reclaimer bumps `stories.claim_epoch` and moves the row back to
  `queued`. When the runner returns, every `stage` message it sends presents the OLD epoch:
  `Stages.advance/4` reads the story's epoch under a share lock in the same transaction as
  the write it gates and refuses `:stale_claim_epoch`. The zombie is fenced by the epoch, not
  by noticing it is a zombie — and its own `dispatch_reply`/`trace` path marks the ledger row
  `superseded`, after which `accepted_session/3` refuses it here too.

  A message that arrives after the SOCKET dropped is the same case with a shorter clock:
  Phoenix has no delivery guarantee either way, the runner's on-disk record is the source of
  truth, and it re-sends on rejoin.

  ## Retries

  Every call is safe to repeat, by two independent mechanisms.

  - The transition itself is a compare-and-set on `from`. A replay whose first copy committed
    finds the row past `from` and `Stages.advance/4` refuses `:stale_stage`. `apply/3` then
    RE-READS the row: at `to` under the caller's epoch, the replay is the runner asking for
    something that already happened, and it is answered `{:ok, row}`. Anywhere else it is a
    genuine `:stale_stage` — the story moved somewhere the runner did not expect — and the
    runner must re-read rather than resend.
  - The slot release is idempotent by `slot_generation`
    (`Loopctl.Runners.Capacity.release/4`): the second call matches no row and decrements
    nothing. That is what makes the replay path safe to release on, which it must be — the
    session may have ended through `POST /stories/:id/escalate` (which holds no dispatch id
    and so releases nothing) and then been reported by the runner, and without a release on
    the replay path that slot would wait out the heal sweep.

  ## Slow connections

  Every wait is bounded inside `Stages.advance/4` (a 2s `lock_timeout`, a 5s
  `statement_timeout`), which answers `{:error, :busy}` rather than holding a pooled
  connection behind a claim release. The channel turns that into the contract's
  `rate_limited` with an interval longer than the wait that just ran out, so the runner backs
  off instead of re-queueing behind the same lock.
  """

  require Logger

  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger

  @type error ::
          :unknown_dispatch
          | :dispatch_not_accepted
          | :stale_claim_epoch
          | :stale_stage
          | :unknown_story_stage
          | {:effect_conflict, map()}
          | :audit_chain_append_failed
          | :busy
          | {:invalid, [String.t()]}

  @doc """
  Applies `stage` — a message already cast by `Loopctl.ApiSpec.RunnerContract.cast_stage/1` —
  as `runner_id` in `tenant_id`. Returns the story's stage row.

  See the moduledoc for the refusals; `{:invalid, messages}` carries everything
  `Stages.advance/4` refused about the message's own content, which no resend can fix.
  """
  @spec apply(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: {:ok, StoryStage.t()} | {:error, error()}
  def apply(tenant_id, runner_id, %{} = stage) do
    with {:ok, session} <-
           DispatchLedger.accepted_session(tenant_id, runner_id, stage.dispatch_id),
         :ok <- dispatch_epoch_matches(session, stage) do
      advance(tenant_id, runner_id, session, stage)
    end
  end

  # The dispatch's own epoch, checked before a transaction is opened. It is NOT the fence —
  # `Stages.advance/4` reads the story's current epoch under a share lock, which is the value
  # that decides — but a message that does not even match the dispatch it names is refused
  # here for the cost of a read the caller already made.
  defp dispatch_epoch_matches(%{claim_epoch: epoch}, %{claim_epoch: epoch}), do: :ok
  defp dispatch_epoch_matches(_session, _stage), do: {:error, :stale_claim_epoch}

  defp advance(tenant_id, runner_id, session, stage) do
    opts = [
      claim_epoch: stage.claim_epoch,
      effects: Map.to_list(Map.get(stage, :effects, %{})),
      reason: Map.get(stage, :reason),
      actor_label: "runner:" <> runner_id,
      # A runner's credential is a plain `api_keys` row minted by `POST /api/v1/runners`, so
      # no dispatch minted it and its lineage is genuinely EMPTY. Stated explicitly, because
      # `Stages.advance/4` treats an ABSENT `:actor_lineage` on a chained transition as a
      # caller that forgot to resolve one and refuses it. `:agent` is the role that key
      # carries, and naming it keeps the human-only edge out of reach whatever the default
      # becomes.
      actor_role: :agent,
      actor_lineage: [],
      session_dispatch: {stage.dispatch_id, session.slot_generation}
    ]

    case Stages.advance(tenant_id, session.story_id, {stage.from, stage.to, stage.edge}, opts) do
      {:ok, row} -> {:ok, row}
      {:error, :stale_stage} -> resolve_replay(tenant_id, session, stage)
      {:error, :not_found} -> {:error, :unknown_story_stage}
      {:error, :effect_conflict} -> effect_conflict(tenant_id, session.story_id)
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  @doc """
  The identities a story's stage row holds, as a `stage` ack and an `effect_conflict` refusal
  report them: every effect a runner may carry (`StageMachine.reportable_effects/0`) that is
  actually set. An absent key means nothing was recorded.
  """
  @spec recorded_effects(StoryStage.t()) :: map()
  def recorded_effects(%StoryStage{} = row) do
    for effect <- StageMachine.reportable_effects(),
        value = Map.get(row, effect),
        not is_nil(value),
        into: %{},
        do: {effect, value}
  end

  # An `effect_conflict` CARRIES the recorded identities (#824 round 3, finding 4). Without
  # them the documented remedy — read the recorded values off the ack and reconcile — is
  # unreachable in the one case it was written for: a LOST ack. The runner never saw the ack
  # that named the surviving sha, which is precisely why it re-sent a different one.
  defp effect_conflict(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      nil -> {:error, :unknown_story_stage}
      row -> {:error, {:effect_conflict, recorded_effects(row)}}
    end
  end

  # A compare-and-set that matched nothing is either a replay of a message that already
  # landed or a runner working from a stale picture, and the two need opposite answers. The
  # row says which: already AT the destination under this caller's epoch is the replay.
  #
  # Reaching here PROVES the caller's epoch is the story's, and that is what makes judging the
  # replay on the stage row safe. `Stages.advance/4` reads the story's `claim_epoch` under a
  # share lock and rolls back `:stale_claim_epoch` BEFORE its compare-and-set, so
  # `:stale_stage` — which only `diagnose/3` produces, after that check passed — cannot come
  # back to a zombie. Re-reading the story's epoch here would therefore be a guard nothing can
  # make fail; it was written, mutation-tested (`bin/mutate.sh`, exit 1) and removed rather
  # than left in reading as protection. If a future change lets `advance/4` answer
  # `:stale_stage` without having fenced the epoch first, this comment is the one to revisit:
  # the row's own `claim_epoch` is what it was last WRITTEN under and can never establish that
  # a caller's claim is still live.
  #
  # Neither read is in the transition's transaction, and neither needs to be: the only writer
  # that can put the row at `to` under this epoch is this claim's own session, because every
  # other writer bumps the epoch. Two copies of one message resolve the same way whichever
  # order they land in.
  defp resolve_replay(tenant_id, session, stage) do
    %{to: to, claim_epoch: epoch} = stage

    case Stages.get(tenant_id, session.story_id) do
      nil ->
        {:error, :unknown_story_stage}

      %StoryStage{stage: ^to, claim_epoch: ^epoch} = row ->
        replayed_effects_agree(row, stage, tenant_id, session)

      %StoryStage{} ->
        {:error, :stale_stage}
    end
  end

  # The replay is only a replay if it carries the SAME identities the first copy recorded.
  #
  # `Stages.record_effect/5` and `advance/4`'s `:effects` both hold the rule "the same value
  # again is fine, a DIFFERENT value is `:effect_conflict`" — and the replay path went round
  # both of them, because it answers off a read instead of a write (#824 round 2). The case
  # that makes it matter is the merge: `ci -> merged` with `merge_sha` A commits, the ack is
  # lost, the runner retries and its retry names merge commit B. Answered `ok`, the row and
  # the `story_stage_merged` chain entry keep A, B is dropped silently, and the chain now
  # NAMES A MERGE THAT IS NOT THE BRANCH'S — the one identity the entry exists to assert.
  #
  # A nil recorded value with a value supplied is a conflict too, not a late record: the row
  # is at the destination without that identity, so this is a different message that happens
  # to share a stage, and accepting it would let an effect be attached after the chain entry
  # that should have named it.
  defp replayed_effects_agree(row, stage, tenant_id, session) do
    supplied = Map.get(stage, :effects, %{})

    if Enum.all?(supplied, fn {effect, value} -> Map.get(row, effect) == value end) do
      release_on_replay(tenant_id, session, stage)
      {:ok, row}
    else
      {:error, {:effect_conflict, recorded_effects(row)}}
    end
  end

  # The replayed message ended the session, so the slot goes back — a separate transaction
  # this time, because there is no transition to commit with. Idempotent by generation, so
  # the copy that DID transition having released it already makes this a no-op. It also
  # covers the one path that cannot release inline: `POST /stories/:id/escalate` is called by
  # the session's own agent key, which holds no runner dispatch id, so the slot waits for the
  # runner's own `stage` message — this one — to give it back.
  defp release_on_replay(tenant_id, session, stage) do
    if StageMachine.ends_session?(stage.to) do
      case Runners.release_slot(tenant_id, stage.dispatch_id, session.slot_generation) do
        {:ok, _outcome} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "replayed terminal stage did not release its slot; the heal sweep bounds it: " <>
              "tenant_id=#{tenant_id} dispatch_id=#{stage.dispatch_id} " <>
              "reason=#{inspect(reason)}"
          )
      end
    end
  end

  # Everything `Stages.advance/4` refuses about the MESSAGE — a transition the machine does
  # not have, a missing or over-long reason, an effect the destination stage does not
  # produce, one already set to something else — is one class to the runner: resending it
  # unchanged cannot help. The atom is carried so the refusal names what was wrong.
  # `:effect_conflict` is deliberately NOT here. The others say "your message is wrong, fix
  # it"; that one says "the server already recorded a DIFFERENT identity for this transition",
  # whose remedy is to read the recorded value and reconcile — never to re-send. Folding it
  # into `invalid_payload` would tell a runner whose merge sha was dropped that its payload
  # was malformed. It reaches the wire under its own code, and the ack carries the recorded
  # identities so the runner can see what it is reconciling against.
  @message_faults [
    :invalid_transition,
    :human_required,
    :reason_required,
    :invalid_reason,
    :invalid_event_data,
    :missing_required_effect,
    :invalid_effect,
    :wrong_stage,
    :not_claimed
  ]

  defp classify(reason) when reason in @message_faults, do: {:invalid, [Atom.to_string(reason)]}

  # NOT `:busy`, which is what it was (#824 round 3, finding 5). `:busy` tells the runner to
  # send it again, and this is a DETERMINISTIC failure: the tenant's hash chain refused the
  # entry, so it will refuse the next one too, and every custody transition in that tenant is
  # failing until an operator acts. A retry instruction there is a re-send loop against a
  # broken chain. It also disagreed with the HTTP surface, which answers 500 for the same
  # condition and says plainly that retrying will not help — one condition, opposite advice.
  # It passes through under its own name and reaches the wire as its own permanent code.
  defp classify(reason), do: reason
end
