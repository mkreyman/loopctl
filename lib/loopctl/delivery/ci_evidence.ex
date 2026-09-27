defmodule Loopctl.Delivery.CiEvidence do
  @moduledoc """
  What CI says about ONE commit, judged against a list of required checks (US-45.6). Pure.

  A thread-mode story merges the checkpoint's exact commit with no pull request, so the merge
  gate cannot lean on a forge rule to hold the merge to green CI: it reads the evidence for
  the checkpoint's SHA itself (`Loopctl.Delivery.PullRequestSource.check_evidence/3`) and
  this module decides what it says.

  ## Where evidence comes from, and why both

  From BOTH the check-runs API and the commit-status API, by SHA. GitHub Actions reports
  check runs, which the combined-status API never lists, so a green combined status says
  nothing about Actions; an external CI or a hand-posted status reports commit statuses,
  which the check-runs API never lists. A required name is satisfied by either.

  Evidence for ANY OTHER commit never counts: nothing here reads a branch, a parent or a pull
  request, only the one SHA the caller names.

  ## How one required check is judged

  - a check run that is not `completed`, or a status that is `pending`, is `:pending`
  - a completed run concluding `success`, `neutral` or `skipped` (what GitHub itself counts
    as passing a required check), or a status in `success`, is `:passed`
  - any other conclusion or state (`failure`, `cancelled`, `timed_out`, `action_required`,
    `stale`, `error`) is `:failed`
  - no run and no status under that name is `:missing`

  Where a name has more than one source, a failure anywhere is a failure, then anything still
  running keeps it pending, and only then does a pass count.

  ## The local gate is recorded, never trusted

  `local-gate` (`Loopctl.Intake.Source.local_gate/0`) is posted by whoever pushed, so on the
  thread path it is the implementer attesting its own work, which chain of custody refuses
  (PRD §5). Its state is reported under `local_gate` and it is never looked up as a required
  check, even by a caller that lists it: the intake source refuses to store it, and this
  module drops it from the list as the backstop.
  """

  alias Loopctl.Intake.Source

  @passing_conclusions ["success", "neutral", "skipped"]

  @type check_run :: %{
          required(:name) => String.t(),
          required(:status) => String.t(),
          required(:conclusion) => String.t() | nil,
          optional(:url) => String.t() | nil
        }
  @type status :: %{
          required(:context) => String.t(),
          required(:state) => String.t(),
          optional(:url) => String.t() | nil
        }
  @type evidence :: %{check_runs: [check_run()], statuses: [status()]}
  @type result :: %{
          passed: [String.t()],
          pending: [String.t()],
          missing: [String.t()],
          failed: [{String.t(), String.t()}],
          local_gate: String.t() | nil
        }

  @doc "The required names this module will look up: `required` without `local-gate`."
  @spec lookup_names([String.t()]) :: [String.t()]
  def lookup_names(required), do: Enum.reject(required, &(&1 == Source.local_gate()))

  @doc "Judges `evidence` for one commit against `required`. See the moduledoc."
  @spec judge([String.t()], evidence()) :: result()
  def judge(required, %{check_runs: runs, statuses: statuses}) do
    acc = %{passed: [], pending: [], missing: [], failed: []}

    judged =
      required
      |> lookup_names()
      |> Enum.reduce(acc, fn name, acc ->
        case check_state(name, runs, statuses) do
          {:failed, conclusion} -> Map.update!(acc, :failed, &[{name, conclusion} | &1])
          state -> Map.update!(acc, state, &[name | &1])
        end
      end)
      |> Map.new(fn {key, names} -> {key, Enum.reverse(names)} end)

    Map.put(judged, :local_gate, local_gate_state(statuses))
  end

  defp check_state(name, runs, statuses) do
    states =
      for(%{name: ^name} = run <- runs, do: run_state(run)) ++
        for %{context: ^name} = status <- statuses, do: status_state(status)

    cond do
      states == [] -> :missing
      failed = Enum.find(states, &match?({:failed, _}, &1)) -> failed
      :pending in states -> :pending
      true -> :passed
    end
  end

  defp run_state(%{status: "completed", conclusion: conclusion})
       when conclusion in @passing_conclusions,
       do: :passed

  defp run_state(%{status: "completed", conclusion: conclusion}),
    do: {:failed, conclusion || "none"}

  defp run_state(_running), do: :pending

  defp status_state(%{state: "success"}), do: :passed
  defp status_state(%{state: "pending"}), do: :pending
  defp status_state(%{state: state}), do: {:failed, state}

  defp local_gate_state(statuses) do
    local_gate = Source.local_gate()

    Enum.find_value(statuses, fn
      %{context: ^local_gate, state: state} -> state
      _other -> nil
    end)
  end

  @doc """
  The evidence and its judgement as stored on the checkpoint's `gate_evidence` under `"ci"`
  (AC-45.6.1): string keys, so it reads back as it was written.
  """
  @spec to_record(String.t(), [String.t()], evidence(), result(), DateTime.t()) :: map()
  def to_record(sha, required, %{check_runs: runs, statuses: statuses}, result, read_at) do
    %{
      "sha" => sha,
      "read_at" => DateTime.to_iso8601(read_at),
      "required" => required,
      "check_runs" =>
        Enum.map(runs, fn run ->
          %{
            "name" => run.name,
            "status" => run.status,
            "conclusion" => run.conclusion,
            "url" => Map.get(run, :url)
          }
        end),
      "statuses" =>
        Enum.map(statuses, fn status ->
          %{"context" => status.context, "state" => status.state, "url" => Map.get(status, :url)}
        end),
      "local_gate" => result.local_gate,
      "passed" => result.passed,
      "pending" => result.pending,
      "missing" => result.missing,
      "failed" => Enum.map(result.failed, fn {name, why} -> %{"name" => name, "why" => why} end)
    }
  end
end
