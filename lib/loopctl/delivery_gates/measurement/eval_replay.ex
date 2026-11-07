defmodule Loopctl.DeliveryGates.Measurement.EvalReplay do
  @moduledoc """
  Replays a RECORDED eval result through loopctl's own screens (US-48.10, AC-48.10.3).

  `loopctl-runner`'s `mix loopctl_runner.eval <spec>` runs a synthetic case through the real
  launcher, offline, and writes the message the runner WOULD have pushed into a result file
  (format 1, below). This module answers the half the runner cannot: given that message, which
  of loopctl's screens refuse it. A prompt or spec change is then measured against both halves
  before it reaches a live ticket.

  It lives beside `GateAReplay` and `GateBReplay` because it is the same kind of instrument:
  a replay of recorded inputs through the gates' pure code, reading no database.

  ## The same code path as the live channel, not a model of it

  1. The message is cast exactly as `LoopctlWeb.RunnerChannel` casts it:
     `RunnerContract.cast_triage_verdict_message/1` for `triage_verdict`,
     `RunnerContract.cast_agent_result_message/1` for `agent_result`. A message the contract
     refuses is `{:error, {:message_refused, reason}}`, never screened.
  2. The cast message goes through the function the live ingest calls before it writes:
     `Loopctl.Delivery.TriageVerdict.screen_message/2` for a `:judge` answering with
     `triage_verdict` (Gate A over the lens verdicts, Gate B over the predicted touches, then
     the draft screens — `InjectionDetector` through `draft_flags/1`, and dispatchability),
     `Loopctl.Agents.AgentResult.admit/2` for a spec reporting through `agent_result` (the
     spec's result schema, then `Loopctl.ReplyDrafts.screen/1`).

  ## The inputs a replay supplies in place of a read

  Live, Gate B resolves the story's repository from its one live intake source. A replay has
  no story row, so it reads the dispatch the case sent: `input["repo"]` — the same repository,
  because a triage dispatch's `repo` IS that source's (`Loopctl.Agents.Dispatcher`). A dispatch
  with no `repo` fails closed as live does with no source, `repository_unresolved:<reason>`.
  The trigger configuration is the deployment's (`DeliveryGates.load_triggers/0`), as live: a
  case for a repository loopctl does not configure escalates `unknown_repo`, because the live
  path would. The stub row the draft replaces is `%Story{id: input["story_id"]}`.

  ## What is NOT replayed

  - `:payload_too_large` and `:story_not_dispatchable` are DISPATCH-time screens: a dispatch
    they refused was never sent, so no result exists to replay.
  - `implement@1` answers with `stage` and `session_ended`, whose ingest runs no spec screen;
    it is refused `{:no_result_screens, "implement@1"}` rather than answered `[]`, which would
    claim a screen ran and passed.
  - Write-time outcomes that depend on rows: a draft row the database refuses, a reply whose
    ticket disappeared (`:ticket_missing`).

  ## The result file (format 1)

      {"format": 1, "spec": {"id", "version"}, "case", "machine", "recorded_at",
       "input": <the dispatch object>, "event": "triage_verdict" | "agent_result" | "session_ended",
       "message": <the message, or null when the run produced none>, "runner_outcome",
       "expected": {"screens": [<screen name>, ...]}}

  A screen NAME is the spec's own key (`Loopctl.Agents.Spec.screen_names/0`): `gate_a`,
  `gate_b`, `draft_injection`, `draft_dispatchable` for `triage@1`,
  `injection_detector_draft` for `reply_draft@1`.
  """

  alias Loopctl.Agents.AgentResult
  alias Loopctl.Agents.Registry
  alias Loopctl.Agents.Spec
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.TriageVerdict
  alias Loopctl.WorkBreakdown.Story

  @format 1

  @typedoc "What a replay found: the refusing screens' names, and each one's codes."
  @type t :: %{screens: [String.t()], codes: %{String.t() => [String.t()]}}

  @type error ::
          :not_a_result
          | :unknown_spec
          | {:unknown_format, term()}
          | {:event_not_answered_by_spec, term()}
          | {:no_result_screens, String.t()}
          | {:message_refused, term()}
          | {:spec_mismatch, String.t()}
          | {:unreadable, term()}

  @doc "Reads and decodes one result file."
  @spec load(Path.t()) :: {:ok, map()} | {:error, {:unreadable, term()}}
  def load(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = result} <- Jason.decode(bytes) do
      {:ok, result}
    else
      {:ok, _not_an_object} -> {:error, {:unreadable, :not_an_object}}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  @doc """
  The screens the live path would produce for a decoded result's message. `[]` is clean, and
  is also the answer for a run that produced no message (`"message": null`): nothing reached
  loopctl, so nothing was screened.
  """
  @spec replay(map()) :: {:ok, t()} | {:error, error()}
  def replay(%{"format" => @format, "spec" => %{"id" => id, "version" => version}} = result)
      when is_map_key(result, "message") and is_map_key(result, "event") do
    with {:ok, spec} <- fetch_spec(id, version),
         :ok <- answered_by(spec, result["event"]) do
      screen(spec, result["event"], result["message"], Map.get(result, "input") || %{})
    end
  end

  def replay(%{"format" => format}) when format != @format,
    do: {:error, {:unknown_format, format}}

  def replay(_result), do: {:error, :not_a_result}

  defp fetch_spec(id, version) when is_binary(id) and is_integer(version) do
    case Registry.fetch(id, version) do
      {:ok, spec} -> {:ok, spec}
      {:error, :unknown_spec} -> {:error, :unknown_spec}
    end
  end

  defp fetch_spec(_id, _version), do: {:error, :unknown_spec}

  defp answered_by(%Spec{result: events}, event) do
    if event in events, do: :ok, else: {:error, {:event_not_answered_by_spec, event}}
  end

  @screened_events ["triage_verdict", "agent_result"]

  defp screen(spec, event, _message, _input) when event not in @screened_events,
    do: {:error, {:no_result_screens, "#{spec.id}@#{spec.version}"}}

  defp screen(_spec, _event, nil, _input), do: {:ok, %{screens: [], codes: %{}}}

  defp screen(_spec, "triage_verdict", message, input) do
    with {:ok, cast} <- cast(&RunnerContract.cast_triage_verdict_message/1, message),
         {:ok, refused} <-
           cast
           |> TriageVerdict.screen_message(
             resolve_repo: fn -> repo_of(input) end,
             story: %Story{id: story_id_of(input)}
           )
           |> refused_as_message() do
      {:ok, shape(refused)}
    end
  end

  # The message names its own spec, and that is the one the live path admits it under; a file
  # filed under another spec would be screened as a spec it does not claim to be.
  defp screen(spec, "agent_result", message, _input) do
    with {:ok, cast} <- cast(&RunnerContract.cast_agent_result_message/1, message),
         :ok <- same_spec(spec, cast.spec),
         {:ok, %{screened: screened}} <- refused_as_message(AgentResult.admit(cast)) do
      {:ok, shape(refusals(screened))}
    end
  end

  defp same_spec(%Spec{id: id, version: version}, %{id: id, version: version}), do: :ok
  defp same_spec(_spec, ref), do: {:error, {:spec_mismatch, "#{ref.id}@#{ref.version}"}}

  # A refusal BEFORE any screen — the spec's result schema, a spec loopctl does not hold — is
  # the live path's `invalid_payload`: the message was refused, not screened.
  defp refused_as_message({:error, reason}), do: {:error, {:message_refused, reason}}
  defp refused_as_message(ok), do: ok

  defp cast(caster, message) do
    case caster.(message) do
      {:ok, cast} -> {:ok, cast}
      {:error, reason} -> {:error, {:message_refused, reason}}
    end
  end

  defp refusals({:refused, screen, signals}), do: [{screen, signals}]
  defp refusals(_drafted_or_unscreened), do: []

  defp repo_of(%{"repo" => repo}) when is_binary(repo) and repo != "", do: {:ok, repo}
  defp repo_of(_input), do: {:error, :repo_not_in_input}

  defp story_id_of(%{"story_id" => id}) when is_binary(id), do: id
  defp story_id_of(_input), do: nil

  defp shape(refused) do
    %{
      screens: Enum.map(refused, fn {screen, _codes} -> Atom.to_string(screen) end),
      codes: Map.new(refused, fn {screen, codes} -> {Atom.to_string(screen), codes} end)
    }
  end
end
