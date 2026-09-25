defmodule LoopctlWeb.RunnerChannel.Refusal do
  @moduledoc """
  The refusal a runner sees, from the reason a context gave (#824 round 2).

  Pure, and public, for the same reason `LoopctlWeb.RunnerChannel.ReplyBucket` is: the
  mapping is where a gap hides, and a gap here is not a wrong status but a DEAD SOCKET.
  `message_error/1` lived in the channel as a private function whose last clause delegated to
  `join_error/1`, which has five clauses and no catch-all — so a reason no clause named raised
  inside `handle_in/3`, which does not refuse one message: it takes the channel down and every
  in-flight session on that socket with it. `stage` widened the reachable set to the whole of
  `Loopctl.Delivery.Stages.advance_error/0` and made that reachable in principle
  (`:actor_lineage_required` is the one), latent only because
  `Loopctl.Delivery.RunnerStages` hardcodes an empty lineage — a property of one caller, not
  of this function.

  Out here it is a unit with a `catch_all` a test can call directly. In the channel it was
  private, and the only way to reach the missing clause was to crash a socket.

  Every `reason` string is one the contract publishes (`RunnerContract.error_reasons/0`).
  """

  require Logger

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Runners.Capacity

  @doc """
  The refusal map for a JOIN. Its reasons are the join-time ones; a shape it does not name
  falls through to `for_message/1`'s catch-all rather than raising.
  """
  @spec for_join(term(), keyword()) :: map()
  def for_join(:not_authorized, _opts),
    do: %{reason: "not_authorized", disconnecting: "join_refused_not_authorized"}

  def for_join(:join_rate_limited, opts),
    do: %{
      reason: "rate_limited",
      max_joins: Keyword.fetch!(opts, :max_joins),
      window_ms: Keyword.fetch!(opts, :window_ms)
    }

  def for_join({:invalid, messages}, _opts),
    do: %{reason: "invalid_payload", details: messages}

  def for_join({:unsupported_contract_version, sent, speaks}, _opts),
    do: %{reason: "unsupported_contract_version", sent: sent, supported: speaks}

  def for_join({:machine_mismatch, declared}, _opts),
    do: %{reason: "machine_mismatch", declared: declared}

  def for_join(reason, _opts), do: for_message(reason)

  @doc """
  The refusal map for a runner-to-control MESSAGE. Total: every term returns a map carrying a
  `reason` the contract publishes, and nothing raises.
  """
  @spec for_message(term()) :: map()
  def for_message({:batch_too_large, max_events, max_bytes}),
    do: %{reason: "batch_too_large", max_events: max_events, max_bytes: max_bytes}

  def for_message({:event_data_too_large, seq, max_data_bytes, max_event_bytes}),
    do: %{
      reason: "event_data_too_large",
      seq: seq,
      max_data_bytes: max_data_bytes,
      max_event_bytes: max_event_bytes
    }

  def for_message({:invalid, messages}), do: %{reason: "invalid_payload", details: messages}

  # The refusal CARRIES the recorded identities (#824 round 3, finding 4). Without them the
  # documented remedy — read the recorded values and reconcile — is unreachable in the one
  # case it was written for: a LOST ack. The runner never saw the ack naming the surviving
  # sha, which is exactly why it re-sent a different one.
  def for_message({:effect_conflict, effects}) when is_map(effects),
    do: %{reason: "effect_conflict", effects: effects}

  # `stale_stage` CARRIES THE ROW (#849) — the same shape the `ok` ack sends, so a runner
  # parses one thing either way. The contract's remedy for this code is "re-read the story and
  # send the transition that applies", and `story_stages` has no runner-facing endpoint: the
  # ack IS the read, by design. Without the row the instruction was unfollowable, and the
  # deployed runner did the only thing left — brute-forced three `from` values in turn, all
  # refused, none of them naming where the row was.
  #
  # The BARE atom keeps its clause below, for a caller with no row to hand back.
  def for_message({:stale_stage, %StoryStage{} = row}),
    do: Map.put(RunnerStages.row_state(row), :reason, "stale_stage")

  # A DISPATCH THAT DID NOT TRIAGE THIS STORY (epic 44, US-44.1): `Stages.advance/4` refusing a
  # transition out of `triaged` that names another dispatch, and `Loopctl.Delivery.TriageVerdict`
  # refusing that dispatch's verdict. Its own code inside loopctl, so no internal caller can
  # read it as the ordinary "already done" `stale_stage`; on the wire it IS `stale_stage` as the
  # contract publishes it — the story has moved on and this message decides nothing — with no
  # row, because it is PERMANENT for that message and a row would suggest a retry. Mapped HERE,
  # at the one wire boundary, so every caller that reaches it is answered the same way rather
  # than `internal_error` from the catch-all.
  def for_message(:triage_not_bound), do: %{reason: "stale_stage"}

  # The tenant's hash chain refused this transition's entry, so nothing was written. NOT
  # `rate_limited`: it is deterministic, the next attempt fails the same way, and every
  # custody transition in the tenant is failing until an operator acts. Its own permanent code,
  # matching what the HTTP surface answers for the same condition. Do not retry.
  def for_message(:audit_chain_append_failed), do: %{reason: "audit_chain_append_failed"}

  # Reasons whose atom IS the published code.
  #
  # `stale_stage`, `unknown_story_stage` and `effect_conflict` arrived with `stage` (1.4.0) and
  # are refusals of the CONTROL PLANE's state rather than of the message, which is why none is
  # `invalid_payload`: a `stale_stage` runner re-reads the story and sends what applies — off
  # the row the clause above hands it, when there is one to hand — an
  # `unknown_story_stage` one has hit a condition it cannot clear by resending or by giving up
  # its claim, and an `effect_conflict` one must read the recorded identity off its last ack
  # and reconcile — never re-send, which is exactly what `invalid_payload` would tell it.
  #
  # `already_recorded` arrived with `triage_verdict` (1.9.0) and is PERMANENT, which is the
  # opposite of how a resend is normally treated on that message: an identical resend is
  # answered `ok` and never reaches here, so seeing this code means the bytes DIFFER from the
  # verdict already recorded for this dispatch. A session cannot restate its verdict by
  # design, so the two sides disagree about what it decided and no retry can settle that.
  @verbatim ~w(unknown_dispatch stale_claim_epoch already_replied dispatch_not_accepted
               run_mismatch stale_stage unknown_story_stage effect_conflict
               already_recorded)a

  def for_message(reason) when reason in @verbatim, do: %{reason: Atom.to_string(reason)}

  # A value the contract let through and Postgres still refused (DispatchLedger's backstop).
  def for_message(:rejected_by_database),
    do: %{reason: "invalid_payload", details: ["a value was refused by the database"]}

  # A lock this write could not get in time, or a deadlock Postgres broke by choosing it.
  # Nothing was written and the message is fine, so the runner is told to SEND IT AGAIN —
  # never `invalid_payload`, which tells it to stop. The interval is LONGER than the wait that
  # just ran out: retrying after exactly that wait puts the runner back in the same queue with
  # no backoff. `:capacity_busy` is the ledger's name and `:busy` is
  # `Loopctl.Delivery.Stages`' name for the same thing.
  def for_message(reason) when reason in [:capacity_busy, :busy],
    do: %{reason: "rate_limited", min_interval_ms: Capacity.busy_retry_ms()}

  # A DRAFTED STORY POSTGRES REFUSED. The verdict itself is well-formed — it passed the
  # contract's caps — and what failed is the row write, so the runner is told its PAYLOAD was
  # invalid rather than being sent back to resend a message that will fail identically. The
  # detail names the field class without echoing the draft: that text was composed by a
  # session reading reporter input and this string reaches a log the runner controls.
  def for_message(:story_draft_invalid),
    do: %{
      reason: "invalid_payload",
      details: ["the drafted story was refused when written to the story row"]
    }

  def for_message(reason), do: catch_all(reason)

  @doc """
  THE CATCH-ALL: a reason no clause names. Answers the contract's `internal_error` and LOGS
  the reason, which is never sent — a context's internal vocabulary is not a wire code, and a
  runner cannot act on it.

  Public so a test can call it. That is the point of this module: the clause it replaces could
  only be reached by killing a socket.
  """
  @spec catch_all(term()) :: %{reason: String.t()}
  def catch_all(reason) do
    Logger.error(
      "runner message refused with a reason no clause names: #{inspect(reason)}; " <>
        "answered internal_error. Add a clause here, or map it in " <>
        "Loopctl.Delivery.RunnerStages."
    )

    %{reason: "internal_error"}
  end

  @doc "Every `reason` string this module can produce, for the contract-binding test."
  @spec reasons() :: [String.t()]
  def reasons do
    Enum.sort([
      "not_authorized",
      "rate_limited",
      "invalid_payload",
      "unsupported_contract_version",
      "machine_mismatch",
      "batch_too_large",
      "event_data_too_large",
      "internal_error",
      "audit_chain_append_failed"
      | Enum.map(@verbatim, &Atom.to_string/1)
    ])
  end

  @doc "The published codes this module must be able to produce."
  @spec published_reasons() :: [String.t()]
  def published_reasons do
    RunnerContract.error_reasons()
    |> Map.drop(["unknown_event"])
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end
end
