defmodule Loopctl.Agents.AgentResult do
  @moduledoc """
  What a session's generic `agent_result` message does (runner contract 1.25.0, US-48.8).

  `RunnerContract.cast_agent_result_message/1` admits the ENVELOPE — the dispatch, its epoch,
  a spec reference and a bounded `result` object. This module decides the rest, in this order,
  and every refusal before the last step writes nothing:

  1. the spec is one loopctl HOLDS (an entry of `Loopctl.Agents.Registry.all/0` with that id
     AND version), else `invalid_payload`;
  2. it REPORTS THROUGH `agent_result` (`Loopctl.Agents.Spec.reports_agent_result?/1`: a
     `:draft` with a result schema), else `invalid_payload` — `triage@1` keeps
     `triage_verdict` and `implement@1` keeps `stage` and `session_ended`, because their
     results drive custody edges that a schema check alone cannot judge;
  3. `result` satisfies THAT spec's `result_schema` (`RunnerContract.cast_agent_result/2`),
     else `invalid_payload` with the schema's own messages;
  4. the result is recorded ONCE on the dispatch's ledger row
     (`DispatchLedger.record_agent_result/4`), which refuses another runner's or tenant's
     dispatch, one of another kind than the spec's, one whose epoch the message does not echo,
     and one never accepted.

  ## The caller is the socket, never the payload

  `tenant_id` and `runner_id` are the runner channel's own assigns, resolved from the runner
  credential when the socket connected. Nothing in the message names a tenant, a runner or a
  story, so a session cannot record a result anywhere but on a dispatch its own runner holds.

  ## Where a result goes (until US-48.12)

  On the dispatch's ledger row — `agent_result`, `agent_result_spec`, `agent_result_digest`,
  `agent_result_at` — the storage `session_ended` already uses for "one report per dispatch".
  US-48.12 adds the outcome ledger a result feeds. A `:draft` result moves no story: that is
  what the archetype MEANS, and why one generic message is safe for it.

  ## The spec's effect, in the same transaction (US-48.9)

  A `:draft` may name one kind of effect, the stored artifact a person releases. `reply_draft@1`
  names `:reply_draft`: its body is screened (`:injection_detector_draft`) and a `reply_drafts`
  row is written — `drafted`, or `refused` with the screen's codes and no body — inside the
  ledger's own transaction, so the two commit together, once per dispatch. A refused body is
  not kept on the ledger row either. Nothing is sent anywhere (`Loopctl.ReplyDrafts`).

  ## The audit row is enums and counts, never the session's words

  The result was composed by a session that may have read attacker-controllable text, so —
  as `Loopctl.Delivery.TriageVerdict` does with escalation reasons — none of it reaches the
  audit log. The row records the spec's REGISTRY id and version (loopctl's own values, not the
  wire's) and the result's size under the byte rule; the result itself is data on the ledger
  row, where an operator reads it as such.

  ## Specs are an input, and only code supplies them

  `:specs` replaces `Loopctl.Agents.Registry.all/0` — a list of compiled specs, never request
  data — so a test can exercise the accepting path with a spec no production code holds. The
  channel passes none.
  """

  require Logger

  alias Loopctl.Agents.Registry
  alias Loopctl.Agents.Spec
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.ByteRule
  alias Loopctl.Audit
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.ReplyDrafts
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord

  @actor_label "control:agent_result"

  @type error ::
          {:invalid, [String.t()]}
          | :unknown_dispatch
          | :wrong_dispatch_kind
          | :claim_epoch_mismatch
          | :dispatch_not_accepted
          | :already_recorded
          | :rejected_by_database
          | :capacity_busy

  @doc """
  Applies an `agent_result` message already cast by
  `RunnerContract.cast_agent_result_message/1`, as `runner_id` in `tenant_id`.

  Returns `{:ok, %{record: record, replayed?: boolean}}`; `replayed?` is true for a
  byte-identical resend, which records nothing a second time.
  """
  @spec apply(Ecto.UUID.t(), Ecto.UUID.t(), map(), [{:specs, [Spec.t()]}]) ::
          {:ok, %{record: DispatchRecord.t(), replayed?: boolean()}} | {:error, error()}
  def apply(tenant_id, runner_id, %{spec: spec_ref, result: result} = message, opts \\ []) do
    specs = Keyword.get_lazy(opts, :specs, &Registry.all/0)

    with {:ok, spec} <- held_spec(specs, spec_ref),
         :ok <- reports_here(spec),
         {:ok, validated} <- RunnerContract.cast_agent_result(result, spec.result_schema),
         {stored, effect} = effects(spec, validated),
         attrs = record_attrs(spec, validated, stored),
         {:ok, {outcome, record}} <-
           DispatchLedger.record_agent_result(tenant_id, runner_id, message, attrs, effect) do
      if outcome == :recorded, do: audit(tenant_id, record, spec, validated)
      {:ok, %{record: record, replayed?: outcome == :replayed}}
    end
  end

  # The registry's own entry. A refusal names no runner-supplied value: the spec reference is
  # pattern-bounded, but it is still the runner's string.
  defp held_spec(specs, %{id: id, version: version}) do
    case Enum.find(specs, &(&1.id == id and &1.version == version)) do
      %Spec{} = spec -> {:ok, spec}
      nil -> {:error, {:invalid, ["spec is not one loopctl holds"]}}
    end
  end

  defp reports_here(spec) do
    if Spec.reports_agent_result?(spec),
      do: :ok,
      else: {:error, {:invalid, ["spec does not report through agent_result"]}}
  end

  # THE SPEC'S EFFECTS, by name (US-48.9), and what the ledger row keeps of the result. Each
  # effect is code here, never a spec field's behaviour: a spec names `:reply_draft` and this
  # is what that name does. The effect runs inside the ledger's transaction, once, on a result
  # that was recorded rather than replayed (`DispatchLedger.record_agent_result/5`).
  #
  # `:reply_draft` screens the body first (`ReplyDrafts.screen/1`, `:injection_detector_draft`).
  # A refused body is stored NOWHERE: the draft row is `refused` with the screen's codes, and the
  # ledger row keeps the screen's name in place of the result (`ReplyDrafts.withheld_result/1`).
  # The digest is still over the result as sent, so a byte-identical resend still replays.
  defp effects(%Spec{effects: effects}, validated) do
    if :reply_draft in effects do
      screened = ReplyDrafts.screen(validated.body)

      {ReplyDrafts.withheld_result(screened) || validated,
       fn record -> ReplyDrafts.write_result(record, screened) end}
    else
      {validated, fn _record -> :ok end}
    end
  end

  # Everything written is loopctl's: the kind and the label from the registry entry, the
  # result as the spec's schema shaped it (or what its effect withheld of it). The digest
  # covers the spec too, so the same object under another spec is a different result.
  defp record_attrs(spec, validated, stored) do
    label = "#{spec.id}@#{spec.version}"

    %{
      kind: spec.kind,
      spec: label,
      result: stored,
      digest: TriageVerdictRecord.digest(%{spec: label, result: validated})
    }
  end

  # Fire and forget is not silent: the record committed, and a failed audit insert is logged
  # with the dispatch so the write is never unattributed. On `AdminRepo`, after the ledger
  # transaction, exactly as `TriageVerdict` writes its draft's audit row.
  defp audit(tenant_id, record, spec, validated) do
    tenant_id
    |> Audit.create_log_entry(%{
      entity_type: "runner_dispatch",
      entity_id: record.dispatch_id,
      action: "agent_result_recorded",
      actor_type: "system",
      actor_label: @actor_label,
      metadata: %{
        "spec_id" => spec.id,
        "spec_version" => spec.version,
        "result_bytes" => ByteRule.bytes(validated)
      }
    })
    |> case do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "agent_result recorded with NO audit row: dispatch_id=#{record.dispatch_id} " <>
            "error=#{inspect(reason)}",
          tenant_id: tenant_id,
          dispatch_id: record.dispatch_id
        )

        :ok
    end
  end
end
