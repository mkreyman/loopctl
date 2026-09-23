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

  ## Session end (contract 1.16.0, US-44.3)

  `end_session/3` applies a runner's `session_ended` message: WHY the session under a dispatch
  stopped. It is a FACT the runner reports, never a verdict it takes, so what happens to the
  story is decided here from the reason:

  - `completed` — nothing. The session's own `stage` messages already said where it got to.
  - `wall_clock_exceeded`, `max_turns_exceeded` — an in-flight story is ESCALATED over
    `:budget_reported`, a control-only edge (`Loopctl.Delivery.StageMachine`), and the
    session's slot goes back in that transition; then the claim it ran under is ENDED as a
    `crashed` one is, which only rebinds the escalated row. Never `failed`: a runner's word
    must not make a story terminal with no way out. Never retried either — the same budget
    kills it again — so an escalation that fails is answered as a retry, never as a refusal.
  - `crashed` — the claim is released NOW rather than at lease expiry, over `:runner_lost`
    with the reclaim's audit shape (`Loopctl.Progress.release_ended_session/4`), and the slot
    goes back.
  - `usage_exhausted` — released the same way, and recorded on the ledger row as NOT counting
    toward the retry ceiling: the subscription ran out, the work was never judged.

  RECORDED ONCE PER DISPATCH, first, on the dispatch's ledger row
  (`Loopctl.Runners.DispatchLedger.record_session_end/4`), with a digest compared BEFORE the
  epoch fence — a release bumps the epoch, and the honest resend of the report that bumped it
  must still be answered `ok`. The action FOLLOWS the record in transactions of its own, and a
  resend RE-DRIVES it rather than trusting the record, exactly as
  `Loopctl.Delivery.TriageVerdict` does: a record whose action did not land (a lock that was
  not free, a node that died between the two) is completed by the resend. Every action on the
  story is fenced on the dispatch's epoch, so a re-drive after the claim moved on changes
  nothing there — it only gives back the session's slot, which the heal sweep would give back
  for the same reason.

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
    genuine `{:stale_stage, row}` — the story moved somewhere the runner did not expect — and
    the refusal CARRIES that row (`row_state/1`, the same shape as the ack), because the
    remedy is to send the transition that applies and the row is the only thing that says
    which one that is.
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
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger

  @type error ::
          :unknown_dispatch
          | :dispatch_not_accepted
          | :stale_claim_epoch
          | {:stale_stage, StoryStage.t()}
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

  # --- session_ended (contract 1.16.0, US-44.3) ------------------------------------------

  # The two reasons that are the session's BUDGET running out. A kill at either is the same
  # kill again if the work is retried, so neither re-queues: control escalates to a human.
  @budget_reasons ~w(wall_clock_exceeded max_turns_exceeded)

  # How many times the budget escalation re-reads a row that moved under it before telling the
  # runner to resend. The row moving is another message of the same session landing between
  # the read and the compare-and-set; it settles in one or two re-reads or not at all.
  @escalation_attempts 3

  @type end_error ::
          :unknown_dispatch
          | :dispatch_not_accepted
          | :stale_claim_epoch
          | :already_recorded
          | :unknown_story_stage
          | :busy
          | :capacity_busy
          | :rejected_by_database
          | :audit_chain_append_failed
          | :recontract_audit_refused
          | :release_failed
          | {:release_refused, [atom()]}

  @doc """
  Applies a `session_ended` message — already cast by
  `Loopctl.ApiSpec.RunnerContract.cast_session_ended/1` — as `runner_id` in `tenant_id`, and
  returns the story's stage row as it stands afterwards, with whether this message was a
  resend of one already recorded. See "Session end" in the moduledoc for what each reason does.

  Refused before anything is recorded: `:unknown_dispatch` (not this runner's, or not an
  implement dispatch), `:unknown_story_stage` (the story has no stage row), and — for a FIRST
  report only — `:stale_claim_epoch` and `:dispatch_not_accepted`. A second report whose bytes
  differ from the first is `:already_recorded`, whatever has happened since. `:busy` and
  `:capacity_busy` mean a lock was not free, or a budget escalation did not land: the record
  may or may not have landed, and the resend completes the work either way.
  """
  @spec end_session(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{row: StoryStage.t(), replayed?: boolean()}} | {:error, end_error()}
  def end_session(tenant_id, runner_id, %{} = message) do
    # ONE read of the stage row up front, carried through: the ledger record in between
    # changes nothing on it, so it is re-read only after a transition this call made or saw.
    with {:ok, story_id} <-
           DispatchLedger.held_story(tenant_id, runner_id, message.dispatch_id),
         {:ok, row} <- stage_row(tenant_id, story_id),
         {:ok, {outcome, session}} <-
           DispatchLedger.record_session_end(
             tenant_id,
             runner_id,
             message,
             session_end_attrs(message, story_id)
           ),
         :ok <- log_recorded(outcome, tenant_id, runner_id, session, message),
         {:ok, row} <- act_on_session_end(tenant_id, runner_id, session, message, row) do
      release_if_session_over(tenant_id, session, message, row)
      {:ok, %{row: row, replayed?: outcome == :replayed}}
    end
  end

  defp stage_row(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      nil -> {:error, :unknown_story_stage}
      row -> {:ok, row}
    end
  end

  # The digest is over the WHOLE cast message — dispatch, epoch and reason — in the canonical
  # form `TriageVerdictRecord.digest/1` already defines for the same job, so "the same bytes"
  # means one thing on both idempotent runner messages.
  defp session_end_attrs(%{reason: reason} = message, story_id) do
    %{
      reason: reason,
      digest: TriageVerdictRecord.digest(message),
      counts_toward_retry_ceiling: counts_toward_retry_ceiling(reason),
      story_id: story_id
    }
  end

  # WHICH RELEASES ARE SPENT against the retry ceiling (US-44.4 builds the ceiling; this only
  # records the fact). A crash is an attempt that was made and lost. An exhausted subscription
  # is not: the work was never judged, and counting it would escalate a story because the
  # account ran dry. `nil` for the reasons that re-queue nothing — a budget kill ends the claim
  # too, but its story is escalated, never retried.
  defp counts_toward_retry_ceiling("crashed"), do: true
  defp counts_toward_retry_ceiling("usage_exhausted"), do: false
  defp counts_toward_retry_ceiling(_reason), do: nil

  defp log_recorded(:recorded, tenant_id, runner_id, session, message) do
    Logger.info(
      "runner session ended: reason=#{message.reason} tenant_id=#{tenant_id} " <>
        "runner_id=#{runner_id} dispatch_id=#{message.dispatch_id} " <>
        "story_id=#{session.story_id} claim_epoch=#{message.claim_epoch}"
    )
  end

  defp log_recorded(:replayed, _tenant_id, _runner_id, _session, _message), do: :ok

  # Each clause returns the stage row as it stands after the action: the row it was handed
  # when nothing moved it, a fresh read when something did.
  #
  # `completed` changes no stage: the session reported where it got to with `stage` messages,
  # and "it finished" adds nothing a transition could record.
  defp act_on_session_end(_tenant_id, _runner_id, _session, %{reason: "completed"}, row),
    do: {:ok, row}

  # A budget kill ESCALATES the stage row, then ENDS THE CLAIM the session ran under — in that
  # order, so the release finds the row already at `escalated` and only rebinds it: the story
  # is held by nobody and never re-queued. Left held, the lease reclaim would release it later
  # as `claim_lease_expired`, which is not what happened. A resend re-drives both halves and
  # neither twice: an escalated row is not in flight, and a claim already ended is
  # `:claim_not_held`.
  defp act_on_session_end(tenant_id, runner_id, session, %{reason: reason} = message, row)
       when reason in @budget_reasons do
    with {:ok, row} <-
           escalate_budget(tenant_id, runner_id, session, message, row, @escalation_attempts),
         do: release_claim(tenant_id, runner_id, session, reason, row)
  end

  defp act_on_session_end(tenant_id, runner_id, session, %{reason: reason}, row)
       when reason in ["crashed", "usage_exhausted"] do
    release_claim(tenant_id, runner_id, session, reason, row)
  end

  # THE CLAIM, released over `:runner_lost` with the reclaim's audit shape. Attributed to the
  # runner's KEY, whose message this is: one read of the runner row, on this path only.
  defp release_claim(tenant_id, runner_id, session, reason, row) do
    case Progress.release_ended_session(tenant_id, session.story_id, session.claim_epoch,
           session_reason: reason,
           actor_id: runner_key_id(tenant_id, runner_id),
           actor_label: "runner:" <> runner_id
         ) do
      # The release moved the stage row — re-queued, or rebound at `escalated` — so read it.
      {:ok, _released} ->
        stage_row(tenant_id, session.story_id)

      # The claim this session ran under has ALREADY ended — a lease reclaim, an operator, or
      # this report's own first copy. Nothing is left to release, and nothing here moved the row.
      {:error, reason} when reason in [:claim_not_held, :not_found] ->
        {:ok, row}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:release_refused, Keyword.keys(changeset.errors)}}

      # The release rolled back whole (US-44.4): its escalation could not append its chain
      # entry, or the re-contract's audit entry was invalid. Each is `end_error/0`'s, and
      # `LoopctlWeb.RunnerChannel.Refusal` names both.
      {:error, reason} when reason in [:audit_chain_append_failed, :recontract_audit_refused] ->
        {:error, reason}

      # A reason `Progress.release_ended_session/4` gains later must not crash the channel every
      # session on the machine shares, and must not widen `end_error/0` to `atom()` either —
      # that is what let this drift unseen. It is logged as it came and answered as the one
      # enumerated `:release_failed`.
      {:error, reason} ->
        Logger.error(
          "session_ended release refused with a reason RunnerStages does not name: " <>
            "#{inspect(reason)}; answered :release_failed. tenant_id=#{tenant_id} " <>
            "story_id=#{session.story_id}",
          tenant_id: tenant_id,
          story_id: session.story_id
        )

        {:error, :release_failed}
    end
  rescue
    # Runs in the runner channel's process: a raise here would take down the socket every
    # session on the machine shares. A lock that was not free is a retry; nothing committed.
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      if match?(%DBConnection.ConnectionError{}, error) or Capacity.retryable?(error),
        do: {:error, :busy},
        else: reraise(error, __STACKTRACE__)
  end

  # A runner row is revoked, never deleted, so a dispatch's runner always has one; `nil` would
  # leave the entry unattributed rather than take the channel down.
  defp runner_key_id(tenant_id, runner_id) do
    case Runners.get_runner(tenant_id, runner_id) do
      {:ok, runner} -> runner.api_key_id
      {:error, :not_found} -> nil
    end
  end

  # THE BUDGET KILL, and control takes the edge — never the runner. Only from an in-flight
  # stage under THIS session's epoch: a row elsewhere (queued after a reclaim, merged, already
  # escalated by the session itself) has nothing a budget kill should change, and a row under
  # a later epoch belongs to a claim this session never held.
  #
  # The reason is built from the ENUM, never from anything the session wrote: entering
  # `escalated` is chained, and the chain cannot be corrected afterwards.
  defp escalate_budget(tenant_id, runner_id, session, message, row, attempts_left) do
    epoch = message.claim_epoch

    case row do
      %StoryStage{stage: stage, claim_epoch: ^epoch} ->
        if stage in StageMachine.in_flight_stages(),
          do: take_budget_edge(tenant_id, runner_id, session, message, row, attempts_left),
          else: {:ok, row}

      _elsewhere ->
        {:ok, row}
    end
  end

  defp take_budget_edge(tenant_id, runner_id, session, message, row, attempts_left) do
    opts = [
      claim_epoch: message.claim_epoch,
      reason: "session_ended:" <> message.reason,
      actor_label: "runner:" <> runner_id,
      # The runner's credential is a plain `api_keys` row no dispatch minted, so its lineage
      # is genuinely empty; stated, because a chained transition refuses an ABSENT lineage.
      actor_role: :agent,
      actor_lineage: [],
      # Escalated ends the session, so the slot goes back IN this transition.
      session_dispatch: {message.dispatch_id, session.slot_generation}
    ]

    case Stages.advance(
           tenant_id,
           session.story_id,
           {row.stage, :escalated, :budget_reported},
           opts
         ) do
      {:ok, escalated} ->
        {:ok, escalated}

      # Another message of the same session moved the row between the read and the write.
      # Read again; after `@escalation_attempts` tell the runner to resend, which re-drives
      # this — never answer `ok` over an escalation that did not happen.
      {:error, :stale_stage} when attempts_left > 1 ->
        with {:ok, moved} <- stage_row(tenant_id, session.story_id),
             do: escalate_budget(tenant_id, runner_id, session, message, moved, attempts_left - 1)

      {:error, :stale_stage} ->
        {:error, :busy}

      # NOTHING IS LEFT TO ESCALATE: the claim ended between the ledger's fence and this
      # transition, or the row is gone. The only two exits that are not a retry; read where the
      # row went, since something other than this call moved it.
      {:error, reason} when reason in [:stale_claim_epoch, :not_found] ->
        stage_row(tenant_id, session.story_id)

      # EVERY OTHER FAILURE IS A RETRY, whatever `classify/1` would call it on a `stage`
      # message. The report is already recorded, so a permanent refusal here would leave the
      # row in flight with nothing to move it but the lease reclaim — which RE-QUEUES a story a
      # budget kill must never retry. The resend replays this and re-drives the escalation.
      {:error, reason} ->
        Logger.error(
          "budget escalation failed after the session end was recorded; answered as a " <>
            "retry: tenant_id=#{tenant_id} story_id=#{session.story_id} " <>
            "dispatch_id=#{message.dispatch_id} reason=#{inspect(reason)}"
        )

        {:error, :busy}
    end
  end

  # THE SLOT, released when the session is over by a rule the SERVER can check — never on the
  # runner's word alone, which is the rule `StageMachine.ends_session?/1` exists to hold: a
  # message able to say "my session is over" while it ran could free a slot still in use.
  #
  # So a report frees the slot only where the heal sweep would: the claim it ran under has
  # ENDED (the row is bound to a later epoch — a `crashed` release, a reclaim), or the row sits
  # at a stage that ends a session. A `completed` report at `pr_open` frees nothing; the heal
  # sweep's wall-clock bound still does. Idempotent by generation, so the transition that
  # already released inline makes this a no-op.
  defp release_if_session_over(tenant_id, session, message, row) do
    if session_over?(row, session) do
      case Runners.release_slot(tenant_id, message.dispatch_id, session.slot_generation) do
        {:ok, _outcome} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "ended session did not release its slot; the heal sweep bounds it: " <>
              "tenant_id=#{tenant_id} dispatch_id=#{message.dispatch_id} " <>
              "reason=#{inspect(reason)}"
          )
      end
    end
  end

  defp session_over?(%StoryStage{claim_epoch: epoch}, %{claim_epoch: ours}) when epoch > ours,
    do: true

  defp session_over?(%StoryStage{claim_epoch: epoch, stage: stage}, %{claim_epoch: epoch}),
    do: StageMachine.ends_session?(stage)

  defp session_over?(_row, _session), do: false

  @doc """
  A stage row as the wire states it: where the story IS, under which claim, and what
  identities it holds.

  ONE renderer, because two things send it and they must not be able to disagree — the `ok`
  ack after a transition or a replay, and the `stale_stage` refusal, which is the same
  question asked by a runner that guessed `from` wrong. A runner parses one shape either way,
  and a field added here reaches both.
  """
  @spec row_state(StoryStage.t()) :: map()
  def row_state(%StoryStage{} = row) do
    %{
      stage: Atom.to_string(row.stage),
      claim_epoch: row.claim_epoch,
      lock_version: row.lock_version,
      attempts: row.attempts,
      effects: recorded_effects(row)
    }
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

      # THE REFUSAL CARRIES THE ROW (#849). The contract's remedy for `stale_stage` is "re-read
      # the story and send the transition that applies", and until this carried the row there
      # was nothing to read: `story_stages` has no runner-facing endpoint, by design, because
      # the ack IS the read. A runner refused here could only guess, and the deployed one
      # guessed by brute force — three `from` values in turn, three round trips, none of which
      # could name where the row actually was, and an operator reading the journal could not
      # either. The row is in hand at the moment of the refusal; sending it costs one map.
      %StoryStage{} = row ->
        {:error, {:stale_stage, row}}
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
