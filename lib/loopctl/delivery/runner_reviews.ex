defmodule Loopctl.Delivery.RunnerReviews do
  @moduledoc """
  Applies a runner's `review_finding` and `review_verdict` messages (epic 45, US-45.3, runner
  contract 1.21.0) to the story's change thread. The review's session reports its judgements
  here and nowhere else: no API key is minted for a review, so there is no other way in.

  A COORDINATOR, as `Loopctl.Delivery.RunnerThreads` is for checkpoints and notes, and built the
  same way:

  1. resolve the runner's dispatch to its story from the LEDGER row the runner holds — the
     story is never taken off the wire — and refuse any kind but `review` as
     `:wrong_dispatch_kind`;
  2. refuse an epoch that is not even the dispatch's;
  3. hand the judgement to `Loopctl.Threads.record_judgement/5`, which binds it to the review
     loopctl recorded for THIS dispatch and THIS runner, under the thread lock, and decides
     separation, openness and the round there;
  4. translate the refusals into the reasons the contract publishes.

  ## After a verdict

  The verdict ends the REVIEW, not the SESSION: the runner is still running it when it sends
  the verdict, so the slot stays held until the session's `session_ended` (`end_session/3`),
  exactly as an implement session's does. A session that never reports is freed by
  `Loopctl.Workers.HealRunnerCapacityWorker`. A verdict that recorded a `review_ceiling`
  escalation ENQUEUES one `Loopctl.Workers.ReviewCeilingWorker` job for its story (unique per
  story) rather than moving the stage inline: this runs inside the runner channel's
  `handle_in`, where a raised database error takes down every session on the socket, and the
  job is the durable path anyway. An enqueue that fails is logged and left to the worker's
  minute sweep. The enqueue is idempotent, so a RESEND of a verdict already recorded runs it
  again and answers what was recorded, `escalated` included.

  ## When a review session ends

  `session_ended` for a review dispatch (`end_session/3`) records the report on the ledger row
  and frees the slot, with or without a verdict before it. That is ALL it does: a review holds
  no claim, so there is no stage effect and nothing counted against the retry ceiling. The
  release never raises into the channel: contention or any database error is logged and the
  slot is left to `Loopctl.Workers.HealRunnerCapacityWorker`.

  ## A dispatch no longer accepted

  A NEW judgement needs the dispatch `accepted` AND its session not reported ended: once
  `session_ended` is recorded for it the review is over, and a late judgement is
  `dispatch_not_accepted`. A RESEND of one already recorded is answered from its row whatever
  the dispatch's status, as `RunnerThreads` answers a checkpoint.

  ## Database failures

  Contention is `:busy` (`Loopctl.Delivery.RunnerThreadSession.read/4`, through
  `Loopctl.Delivery.Stages.answering_busy/4`), and the tenant's chain
  refusing the append as a hash violation is `:audit_chain_append_failed`
  (`Loopctl.Delivery.RunnerStages.answering_broken_chain/3`) — the one copy of each policy.
  """

  require Logger

  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.RunnerThreads
  alias Loopctl.Delivery.RunnerThreadSession
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.Workers.ReviewCeilingWorker

  @kind "review"

  @typedoc "The runner the socket authenticated: its id and the agent its sessions work as."
  @type runner :: %{required(:id) => Ecto.UUID.t(), required(:agent_id) => Ecto.UUID.t()}

  @doc "The dispatch kind a review is pushed as."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  Records `message` — already cast by `Loopctl.ApiSpec.RunnerContract.cast_review_finding/1` —
  as a `finding` of the review `runner`'s dispatch carries.
  """
  @spec record_finding(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{entry: Entry.t(), replayed?: boolean()}} | {:error, term()}
  def record_finding(tenant_id, runner, %{} = message) do
    attrs =
      message
      |> base_attrs("finding")
      |> put_present("severity", Map.get(message, :severity))
      |> put_present("location", Map.get(message, :location))
      |> put_present("introduced_by", Map.get(message, :introduced_by))

    with {:ok, %{entry: entry}, status, _session} <-
           judge(tenant_id, runner, message, attrs, "review_finding") do
      {:ok, %{entry: entry, replayed?: status == :existing}}
    end
  end

  @doc """
  Records `message` — already cast by `Loopctl.ApiSpec.RunnerContract.cast_review_verdict/1` —
  as the verdict of the review `runner`'s dispatch carries: the one entry that completes its
  round. `escalated?` is true when the verdict reached the ceiling with a material finding,
  on a resend as on the first delivery.
  """
  @spec record_verdict(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{entry: Entry.t(), replayed?: boolean(), escalated?: boolean()}}
          | {:error, term()}
  def record_verdict(tenant_id, runner, %{} = message) do
    with {:ok, %{entry: entry, escalation: escalation}, status, session} <-
           judge(tenant_id, runner, message, base_attrs(message, "verdict"), "review_verdict") do
      after_verdict(tenant_id, session, escalation)
      {:ok, %{entry: entry, replayed?: status == :existing, escalated?: escalation != nil}}
    end
  end

  @doc """
  Records a `session_ended` report for a REVIEW dispatch and frees the runner's slot for it.
  The caller has read the row once and routed on its kind
  (`Loopctl.Delivery.RunnerStages.held_dispatch/3`); the record re-checks the kind under the
  row lock.

  A review holds no claim, so the report has no stage effect and counts toward no retry
  ceiling: all it can do is say the session is gone, which is what the slot waits on. Once it
  is recorded the review may only have judgements it already made answered again. Idempotent
  on the report's digest, as an implement session's is.
  """
  @spec end_session(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{replayed?: boolean()}} | {:error, term()}
  def end_session(tenant_id, runner, %{} = message) do
    with {:ok, {outcome, session}} <-
           DispatchLedger.record_review_session_end(
             tenant_id,
             runner.id,
             message,
             TriageVerdictRecord.digest(message)
           ) do
      free_slot(tenant_id, message.dispatch_id, session.slot_generation)
      {:ok, %{replayed?: outcome == :replayed}}
    end
  end

  defp base_attrs(message, kind) do
    %{
      "kind" => kind,
      "idempotency_key" => RunnerThreads.idempotency_key(message),
      "body" => message.body
    }
  end

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp judge(tenant_id, runner, message, attrs, write) do
    with {:ok, session} <- session(tenant_id, runner.id, message) do
      tenant_id
      |> RunnerStages.answering_broken_chain(
        fn -> "write=#{write} dispatch_id=#{message.dispatch_id}" end,
        fn ->
          Threads.record_judgement(tenant_id, session.story_id, message.dispatch_id, attrs,
            runner_id: runner.id,
            author_principal: RunnerThreads.principal(runner),
            replay_only: not session.accepted?
          )
        end
      )
      |> answer(session)
    end
  end

  # The ceiling job only: the slot belongs to the SESSION, which `end_session/3` frees. The
  # enqueue is idempotent, so a resend runs it again.
  defp after_verdict(tenant_id, session, escalation) do
    if escalation, do: ReviewCeilingWorker.enqueue(tenant_id, session.story_id)
    :ok
  end

  @doc false
  # Frees a review session's slot, and NEVER RAISES: this runs in the runner channel's
  # `handle_in`. Contention is answered by `Stages.answering_busy/4`, and anything else the
  # database raises is rescued; either way the outcome is logged and the slot is left to
  # `HealRunnerCapacityWorker`, which frees a slot whose session can no longer be running.
  # Public only so its test can drive it with the database refusing; `end_session/3` is the
  # caller.
  @spec free_slot(Ecto.UUID.t(), Ecto.UUID.t(), integer()) :: :ok
  def free_slot(tenant_id, dispatch_id, generation) do
    release = fn -> DispatchLedger.release_slot(tenant_id, dispatch_id, generation) end

    case Stages.answering_busy(
           tenant_id,
           [:loopctl, :threads, :busy],
           "review slot release",
           release
         ) do
      {:error, _reason} = error -> log_unreleased(tenant_id, dispatch_id, error)
      _released_or_not -> :ok
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      log_unreleased(tenant_id, dispatch_id, error)
  end

  defp log_unreleased(tenant_id, dispatch_id, reason) do
    Logger.warning(
      "review slot not released; HealRunnerCapacityWorker frees it: #{inspect(reason)} " <>
        "tenant_id=#{tenant_id} dispatch_id=#{dispatch_id}",
      tenant_id: tenant_id,
      dispatch_id: dispatch_id
    )
  end

  # --- the session -----------------------------------------------------------------------

  # The REVIEW row this runner holds for the message's dispatch, asked for by kind
  # (`Loopctl.Delivery.RunnerThreadSession.read/5`): only a review session judges, and a row
  # of any other kind is `:wrong_dispatch_kind`.
  defp session(tenant_id, runner_id, message) do
    with {:ok, row} <-
           RunnerThreadSession.read(tenant_id, runner_id, message, "runner review read",
             kind: @kind
           ) do
      {:ok,
       %{
         story_id: row.story_id,
         # A session that REPORTED ending (`end_session/3`) is over even though its row
         # stays `accepted`: it may only have a judgement it already made answered again.
         accepted?: row.status == "accepted" and not row.session_ended?,
         slot_generation: row.slot_generation
       }}
    end
  end

  # --- answers ---------------------------------------------------------------------------

  defp answer({:ok, written, status}, session), do: {:ok, written, status, session}
  defp answer({:error, reason}, _session), do: {:error, classify(reason)}

  defp answer({:error, :unprocessable_entity, detail}, _session),
    do: {:error, RunnerThreadSession.unprocessable(detail)}

  # The review rules' own refusals, by the code each carries. A 422 from them is a field the
  # contract could not state (a severity, an `introduced_by`), answered `invalid_payload`.
  @review_codes %{
    "review_closed" => :review_closed,
    "review_claim_ended" => :review_claim_ended,
    "review_round_superseded" => :review_round_superseded,
    "reviewer_not_separate" => :reviewer_not_separate,
    # US-45.9: the implementer's lineage cannot be read, so this runner cannot be SHOWN
    # separate from it (`Loopctl.Threads.Reviews.reviewer_separate/3` fails closed). To the
    # runner that is the same permanent refusal as a proven overlap: this agent may not judge
    # this story, and resending the judgement cannot change it. Answered under the contract's
    # existing code rather than the catch-all's retryable-looking `internal_error`.
    "unresolvable_dispatch_lineage" => :reviewer_not_separate,
    "idempotency_key_reused" => :idempotency_key_reused
  }

  defp classify({status, code, _message})
       when is_map_key(@review_codes, code) and is_atom(status),
       do: Map.fetch!(@review_codes, code)

  defp classify({:unprocessable_entity, _code, message}), do: {:invalid, [message]}

  # A review this runner does not hold for this dispatch, or a story that is gone: the
  # dispatch names nothing this runner may judge under.
  defp classify(:unknown_review), do: :unknown_dispatch
  defp classify(:not_found), do: :unknown_dispatch

  defp classify(%Ecto.Changeset{} = changeset),
    do: {:invalid, RunnerThreadSession.changeset_messages(changeset)}

  # `:tenant_halted`, `:dispatch_not_accepted`, `:busy` and `:audit_chain_append_failed` pass
  # through to `LoopctlWeb.RunnerChannel.Refusal` under their own names; anything else reaches
  # its catch-all, which logs it and answers `internal_error`.
  defp classify(reason), do: reason
end
