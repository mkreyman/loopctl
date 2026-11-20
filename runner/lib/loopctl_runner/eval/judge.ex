defmodule LoopctlRunner.Eval.Judge do
  @moduledoc """
  A case's expectations held against what its run produced (US-48.10, AC-48.10.1). Pure.

  What is judged is the MESSAGE the runner would have pushed — built by its own builders, read
  off disk as the live path reads it — plus the run's outcome, never the session's prose:

    * `schema_valid` — `true`: there is a message, and it passes the vendored contract's definition
      for its event and the sender's own rules beside it (`TriageDispatch.sendable/1`,
      `AgentResult.sendable/1`). `false`: the run produced no message that would be sent.
    * `outcomes_allowed` — the run's outcome is one of them (`outcome/3`).
    * `escalation_codes` — every code appears among the lens verdicts' or the verdict's
      `escalation_reasons`, matched as whole strings, the way Gate A reads them.
    * `lens_agreement` — `true`: three lens verdicts, each with the verdict's outcome; `false`:
      they do not all agree; `null`: not judged.
    * `forbidden` — no string the SESSION authored matches any of them: every string value of the
      message except the envelope the runner stamps on it (`dispatch_id`, `story_id`,
      `claim_epoch`, `spec`), so a pattern guarding against a leaked id is never tripped by the
      runner's own correlation fields.

  `rubric` is a person's to judge and never scored here; `screens` are loopctl's, which replays
  the recorded message through its own screens (AC-48.10.3).
  """

  alias LoopctlRunner.{AgentResult, Contract, TriageDispatch}

  @type check :: {String.t(), :ok | {:fail, String.t()}}

  @envelope ["dispatch_id", "story_id", "claim_epoch", "spec"]

  @definitions %{
    "triage_verdict" => "RunnerTriageVerdictMessage",
    "agent_result" => "RunnerAgentResultMessage",
    "session_ended" => "RunnerSessionEnded"
  }

  @doc "The contract definition a message of `event` is validated against."
  @spec definition(String.t()) :: String.t()
  def definition(event), do: Map.fetch!(@definitions, event)

  @doc """
  The run's outcome as `outcomes_allowed` names it, per event:

    * `triage_verdict` — the verdict's `outcome` (`story`, `escalate`, `reject`), or
      `incomplete:<reason>`;
    * `agent_result` — `agent_result`, or `no_result` when the run sent nothing; a verify@1
      result is its `verdict` (`pass`, `reject`), loopctl's own names for the spec's outcomes,
      because a verifier's job is that distinction and `agent_result` alone would score a pass
      on a broken pull request as correct;
    * `session_ended` — the `reason` (`completed`, `max_turns_exceeded`, ...), or
      `no_session_ended` when the run's end is no session end (it started no session).

  A dispatch the runner's own policy refused is `refused:<reason>` whatever the event.
  """
  @spec outcome(String.t(), map() | nil, String.t()) :: String.t()
  def outcome(_event, _message, "refused:" <> _ = refused), do: refused
  def outcome("triage_verdict", %{"verdict" => %{"outcome" => outcome}}, _runner), do: outcome
  def outcome("triage_verdict", %{"incomplete" => reason}, _runner), do: "incomplete:#{reason}"
  def outcome("triage_verdict", nil, _runner), do: "no_message"

  def outcome(
        "agent_result",
        %{"spec" => %{"id" => "verify"}, "result" => %{"verdict" => verdict}},
        _runner
      )
      when is_binary(verdict),
      do: verdict

  def outcome("agent_result", %{"result" => _}, _runner), do: "agent_result"
  def outcome("agent_result", nil, _runner), do: "no_result"
  def outcome("session_ended", %{"reason" => reason}, _runner), do: reason
  def outcome("session_ended", nil, _runner), do: "no_session_ended"

  @doc "Every expectation's check, in a fixed order."
  @spec judge(map(), [Regex.t()], String.t(), map() | nil, String.t()) :: [check()]
  def judge(expectations, forbidden, event, message, runner_outcome) do
    [
      {"schema_valid", schema_valid(expectations["schema_valid"], event, message)},
      {"outcome",
       outcome_allowed(expectations["outcomes_allowed"], event, message, runner_outcome)},
      {"escalation_codes", codes(expectations["escalation_codes"], message)},
      {"lens_agreement", lens_agreement(expectations["lens_agreement"], message)},
      {"forbidden", forbidden(forbidden, message)}
    ]
  end

  @doc "Whether every check passed."
  @spec passed?([check()]) :: boolean()
  def passed?(checks), do: Enum.all?(checks, fn {_name, result} -> result == :ok end)

  defp schema_valid(true, _event, nil), do: {:fail, "the run produced no message"}

  defp schema_valid(true, event, message) do
    with :ok <- Contract.validate(definition(event), message),
         {:ok, _} <- sendable(event, message) do
      :ok
    else
      {:error, errors} -> {:fail, Enum.join(List.wrap(errors), "; ")}
    end
  end

  defp schema_valid(false, _event, nil), do: :ok
  defp schema_valid(false, _event, _message), do: {:fail, "the run produced a message"}

  defp sendable("triage_verdict", message), do: TriageDispatch.sendable(message)
  defp sendable("agent_result", message), do: AgentResult.sendable(message)
  defp sendable("session_ended", message), do: {:ok, message}

  defp outcome_allowed(allowed, event, message, runner_outcome) do
    got = outcome(event, message, runner_outcome)

    if got in allowed,
      do: :ok,
      else: {:fail, "outcome #{got} is not one of #{Enum.join(allowed, ", ")}"}
  end

  defp codes([], _message), do: :ok

  defp codes(required, message) do
    stated = stated_codes(message)

    case Enum.reject(required, &(&1 in stated)) do
      [] -> :ok
      missing -> {:fail, "escalation codes not stated: #{Enum.join(missing, ", ")}"}
    end
  end

  defp stated_codes(%{} = message) do
    lens =
      for %{} = lens <- List.wrap(message["lens_verdicts"]),
          code <- List.wrap(lens["escalation_reasons"]),
          do: code

    lens ++ List.wrap(get_in(message, ["verdict", "escalation_reasons"]))
  end

  defp stated_codes(nil), do: []

  defp lens_agreement(nil, _message), do: :ok

  defp lens_agreement(expected, message) do
    case agreement(message) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:fail, "lens agreement is #{actual}, expected #{expected}"}
      {:error, why} -> {:fail, why}
    end
  end

  defp agreement(%{"verdict" => %{"outcome" => outcome}, "lens_verdicts" => [_, _, _] = lenses}),
    do: {:ok, Enum.all?(lenses, &(&1["outcome"] == outcome))}

  defp agreement(_message),
    do: {:error, "the message carries no verdict with three lens verdicts"}

  defp forbidden([], _message), do: :ok
  defp forbidden(_patterns, nil), do: :ok

  defp forbidden(patterns, message) do
    texts = message |> Map.drop(@envelope) |> strings()

    case for(p <- patterns, Enum.any?(texts, &Regex.match?(p, &1)), do: Regex.source(p)) do
      [] -> :ok
      hit -> {:fail, "forbidden content matched: #{Enum.join(hit, ", ")}"}
    end
  end

  @doc """
  Every string VALUE in `value`, depth first. Keys are the contract's own words, never the
  session's, so a pattern is never matched against them.
  """
  @spec strings(term()) :: [String.t()]
  def strings(value) when is_binary(value), do: [value]
  def strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  def strings(value) when is_map(value), do: Enum.flat_map(Map.values(value), &strings/1)

  def strings(_value), do: []
end
