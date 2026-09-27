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

  ONLY THE LATEST RESULT UNDER A NAME COUNTS, as it does for GitHub's own required-check rule
  (US-45.6 review round 1, finding 5). Two workflows can each have a job `test`, and an old
  external status can share a name with a newer Actions run; judging a failure anywhere as
  decisive refused a green change for ever on the stale one. Among check runs the latest is
  the highest id (ids only grow, and a re-run queued a moment ago has no timestamp yet); the
  combined status is already the latest per context. Between a run and a status the later
  timestamp wins, and a run with no timestamp is the newest there is (it was just queued).

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
          optional(:id) => integer() | nil,
          optional(:started_at) => String.t() | nil,
          optional(:completed_at) => String.t() | nil,
          optional(:url) => String.t() | nil
        }
  @type status :: %{
          required(:context) => String.t(),
          required(:state) => String.t(),
          optional(:at) => String.t() | nil,
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
    run = runs |> Enum.filter(&(&1.name == name)) |> Enum.max_by(&run_order/1, fn -> nil end)
    status = Enum.find(statuses, &(&1.context == name))

    case {run, status} do
      {nil, nil} -> :missing
      {run, nil} -> run_state(run)
      {nil, status} -> status_state(status)
      {run, status} -> if run_newer?(run, status), do: run_state(run), else: status_state(status)
    end
  end

  defp run_order(run), do: Map.get(run, :id) || 0

  defp run_newer?(run, status) do
    case {run_at(run), Map.get(status, :at)} do
      {nil, _status_at} -> true
      {_run_at, nil} -> true
      {run_at, status_at} -> run_at >= status_at
    end
  end

  defp run_at(run), do: Map.get(run, :completed_at) || Map.get(run, :started_at)

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
      "read_at" => fixed_width_iso8601(read_at),
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

  # ALWAYS six fractional digits, so two records order correctly as TEXT: the evidence write
  # compares `read_at` in SQL (`Loopctl.Threads.record_gate_evidence/5`), and
  # `"...:00Z"` sorts after `"...:00.5Z"` although it is earlier.
  defp fixed_width_iso8601(%DateTime{microsecond: {micro, _precision}} = at),
    do: DateTime.to_iso8601(%{at | microsecond: {micro, 6}})
end
