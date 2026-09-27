defmodule Loopctl.Delivery.RunnerReviews do
  @moduledoc """
  Applies a runner's `review_finding` and `review_verdict` messages (epic 45, US-45.3, runner
  contract 1.21.0) to the story's change thread. The review's session reports its judgements
  here and nowhere else: no API key is minted for a review, so there is no other way in.

  A COORDINATOR, as `Loopctl.Delivery.RunnerThreads` is for checkpoints and notes, and built the
  same way:

  1. resolve the runner's dispatch to its story from the LEDGER row the runner holds — the
     story is never taken off the wire — and refuse any kind but `review` as
     `:unknown_dispatch`;
  2. refuse an epoch that is not even the dispatch's;
  3. hand the judgement to `Loopctl.Threads.record_judgement/5`, which binds it to the review
     loopctl recorded for THIS dispatch and THIS runner, under the thread lock, and decides
     separation, openness and the round there;
  4. translate the refusals into the reasons the contract publishes.

  ## After a verdict

  The verdict ends the review, so the runner's capacity slot for it is released at once
  (`Loopctl.Runners.DispatchLedger.release_slot/3`); a release that does not land is left to
  `Loopctl.Workers.HealRunnerCapacityWorker`, which frees a slot whose session can no longer be
  running. A verdict that recorded a `review_ceiling` escalation is followed by one immediate
  attempt to move the stage (`Loopctl.Workers.ReviewCeilingWorker.reconcile/2`); the worker's
  sweep is what makes it durable.

  ## A dispatch no longer accepted

  A NEW judgement needs the dispatch `accepted`. A RESEND of one already recorded is answered
  from its row whatever the dispatch's status, as `RunnerThreads` answers a checkpoint.

  ## Database failures

  Contention is `:busy` (`Loopctl.Delivery.Stages.answering_busy/4`), and the tenant's chain
  refusing the append as a hash violation is `:audit_chain_append_failed`
  (`Loopctl.Delivery.RunnerStages.answering_broken_chain/3`) — the one copy of each policy.
  """

  import Ecto.Query

  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.RunnerThreads
  alias Loopctl.Delivery.Stages
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
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
  round. `escalated?` is true when the verdict reached the ceiling with a material finding.
  """
  @spec record_verdict(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{entry: Entry.t(), replayed?: boolean(), escalated?: boolean()}}
          | {:error, term()}
  def record_verdict(tenant_id, runner, %{} = message) do
    with {:ok, %{entry: entry, escalation: escalation}, status, session} <-
           judge(tenant_id, runner, message, base_attrs(message, "verdict"), "review_verdict") do
      if status == :created, do: after_verdict(tenant_id, message, session, escalation)
      {:ok, %{entry: entry, replayed?: status == :existing, escalated?: escalation != nil}}
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

  # The slot first: the review is over whatever the stage machine does next.
  defp after_verdict(tenant_id, message, session, escalation) do
    _ = DispatchLedger.release_slot(tenant_id, message.dispatch_id, session.slot_generation)
    if escalation, do: ReviewCeilingWorker.reconcile(tenant_id, session.story_id)
    :ok
  end

  # --- the session -----------------------------------------------------------------------

  defp session(tenant_id, runner_id, message) do
    read = fn ->
      {:ok, row} =
        Repo.with_tenant(tenant_id, fn ->
          Repo.one(
            from r in DispatchRecord,
              where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
              where: r.dispatch_id == ^message.dispatch_id,
              select: %{
                status: r.status,
                kind: r.kind,
                story_id: r.story_id,
                claim_epoch: r.claim_epoch,
                slot_generation: r.slot_generation
              }
          )
        end)

      {:ok, row}
    end

    with {:ok, row} <-
           Stages.answering_busy(
             tenant_id,
             [:loopctl, :threads, :busy],
             "runner review read",
             read
           ),
         {:ok, row} <- found(row),
         :ok <- review_kind(row),
         :ok <- dispatch_epoch_matches(row, message) do
      {:ok,
       %{
         story_id: row.story_id,
         accepted?: row.status == "accepted",
         slot_generation: row.slot_generation
       }}
    end
  end

  defp found(nil), do: {:error, :unknown_dispatch}
  defp found(row), do: {:ok, row}

  defp review_kind(%{kind: @kind}), do: :ok
  defp review_kind(_row), do: {:error, :unknown_dispatch}

  defp dispatch_epoch_matches(%{claim_epoch: epoch}, %{claim_epoch: epoch}), do: :ok
  defp dispatch_epoch_matches(_row, _message), do: {:error, :stale_claim_epoch}

  # --- answers ---------------------------------------------------------------------------

  defp answer({:ok, written, status}, session), do: {:ok, written, status, session}
  defp answer({:error, reason}, _session), do: {:error, classify(reason)}

  defp answer({:error, :unprocessable_entity, detail}, _session),
    do: {:error, unprocessable(detail)}

  # The review rules' own refusals, by the code each carries. A 422 from them is a field the
  # contract could not state (a severity, an `introduced_by`), answered `invalid_payload`.
  @review_codes %{
    "review_closed" => :review_closed,
    "review_round_superseded" => :review_round_superseded,
    "reviewer_not_separate" => :reviewer_not_separate,
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

  defp classify(%Ecto.Changeset{} = changeset), do: {:invalid, changeset_messages(changeset)}

  # `:tenant_halted`, `:dispatch_not_accepted`, `:busy` and `:audit_chain_append_failed` pass
  # through to `LoopctlWeb.RunnerChannel.Refusal` under their own names; anything else reaches
  # its catch-all, which logs it and answers `internal_error`.
  defp classify(reason), do: reason

  defp unprocessable(%{code: "secret_blocked"}), do: :secret_blocked
  defp unprocessable(%{message: message}) when is_binary(message), do: {:invalid, [message]}
  defp unprocessable(message) when is_binary(message), do: {:invalid, [message]}
  defp unprocessable(detail), do: {:invalid, [inspect(detail)]}

  defp changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string_safe(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
  end

  defp to_string_safe(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp to_string_safe(value), do: inspect(value)
end
