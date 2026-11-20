defmodule LoopctlRunner.Eval.Result do
  @moduledoc """
  The recorded result of one eval case (US-48.10), in the format loopctl-runner and loopctl
  share: loopctl copies these files verbatim into its own `test/fixtures/eval_results/` and
  replays each `message` through its pure screens (AC-48.10.3).

      eval/results/<spec>@<version>/<case>.json

      {"format": 1,
       "spec": {"id": "triage", "version": 1},
       "case": "<case file basename>",
       "machine": "<hostname the eval ran on>",
       "recorded_at": "<ISO-8601 UTC>",
       "input": { ...the dispatch exactly as the case gave it... },
       "event": "triage_verdict | agent_result | session_ended",
       "message": { ...what the runner would have pushed for that event, or null... },
       "runner_outcome": "<the run's terminal status>",
       "expected": {"screens": [ ...the case's expectations.screens... ]}}

  Exactly these keys, and nothing of the harness's own judgement: whether a case passed is the
  table's to say, and a field loopctl does not read is a field the two sides drift on. `machine`
  is what makes a `:build` result readable at all — an implement session inherits the operator's
  `~/.claude`, so the same case can end differently on two machines — and a run on the fake CLI
  says so there.
  """

  @format 1

  @keys ~w(format spec case machine recorded_at input event message runner_outcome expected)

  @doc "The keys a result file carries, exactly."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The result for one case's run."
  @spec build(%{
          case: map(),
          machine: String.t(),
          recorded_at: DateTime.t(),
          event: String.t(),
          message: map() | nil,
          runner_outcome: String.t()
        }) :: map()
  def build(%{case: c} = run) do
    %{
      "format" => @format,
      "spec" => %{"id" => c.template.id, "version" => c.template.version},
      "case" => c.name,
      "machine" => run.machine,
      "recorded_at" => run.recorded_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "input" => c.input,
      "event" => run.event,
      "message" => run.message,
      "runner_outcome" => run.runner_outcome,
      "expected" => %{"screens" => c.expectations["screens"]}
    }
  end

  @doc "Writes `result` to `results_dir/<set>/<case>.json` and returns the path."
  @spec write!(map(), String.t(), String.t(), String.t()) :: String.t()
  def write!(result, results_dir, set, name) do
    path = Path.join([results_dir, set, name <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    LoopctlRunner.AtomicFile.write!(path, Jason.encode!(result, pretty: true) <> "\n")
    path
  end
end
