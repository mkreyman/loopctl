defmodule Loopctl.Delivery.CiEvidence do
  @moduledoc """
  What CI says about ONE commit, judged against a list of required checks (US-45.6). Pure.

  A thread-mode story merges the checkpoint's exact commit with no pull request, so the merge
  gate cannot lean on a forge rule to hold the merge to green CI: it reads the evidence for
  the checkpoint's SHA itself (`Loopctl.Delivery.PullRequestSource.check_evidence/3`) and
  this module decides what it says.

  ## What may satisfy a required check: a GitHub Actions check run, and nothing else

  Both the check-runs and the commit-status APIs are READ, by SHA, and both are recorded on
  the checkpoint — GitHub Actions reports check runs, which the combined status never lists.
  But only a CHECK RUN created by GitHub Actions (`@trusted_check_apps`) can satisfy a
  required name (US-45.6 review round 2, finding 1). A commit status can be posted by anyone
  holding `statuses: write` on the repository, which includes the implementer's own runner
  (it posts `local-gate`), so letting a status satisfy a required name let the implementer
  post `test = success` over a failing run and merge its own work — the self-attestation this
  gate exists to refuse, one name over from `local-gate`. A check run needs a GitHub App to
  create; the implementer holds none. Statuses are therefore evidence to READ, never to trust.

  Evidence for ANY OTHER commit never counts: nothing here reads a branch, a parent or a pull
  request, only the one SHA the caller names.

  ## How one required check is judged

  Only the LATEST trusted run under a name counts, as GitHub's own required-check rule judges
  it (round 1, finding 5): the highest id, because ids only grow and a re-run queued a moment
  ago has no timestamp yet. Then:

  - not `completed` is `:pending`
  - `completed` concluding `success`, `neutral` or `skipped` (what GitHub itself counts as
    passing a required check) is `:passed`
  - any other conclusion (`failure`, `cancelled`, `timed_out`, `action_required`, `stale`) is
    `:failed`
  - no trusted run under that name is `:missing`, whatever statuses say

  ## The local gate is recorded, never trusted

  `local-gate` (`Loopctl.Intake.Source.local_gate/0`) is reported under `local_gate` and never
  looked up as a required check, even by a caller that lists it: the intake source refuses to
  store it, and this module drops it from the list as the backstop.
  """

  alias Loopctl.Intake.Source

  @passing_conclusions ["success", "neutral", "skipped"]

  # The apps whose check runs may satisfy a required check. See the moduledoc.
  @trusted_check_apps ["github-actions"]

  @doc "The GitHub App slugs whose check runs may satisfy a required check."
  @spec trusted_check_apps() :: [String.t()]
  def trusted_check_apps, do: @trusted_check_apps

  @type check_run :: %{
          required(:name) => String.t(),
          required(:status) => String.t(),
          required(:conclusion) => String.t() | nil,
          optional(:id) => integer() | nil,
          optional(:app) => String.t() | nil,
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
        case check_state(name, runs) do
          {:failed, conclusion} -> Map.update!(acc, :failed, &[{name, conclusion} | &1])
          state -> Map.update!(acc, state, &[name | &1])
        end
      end)
      |> Map.new(fn {key, names} -> {key, Enum.reverse(names)} end)

    Map.put(judged, :local_gate, local_gate_state(statuses))
  end

  defp check_state(name, runs) do
    runs
    |> Enum.filter(&(&1.name == name and Map.get(&1, :app) in @trusted_check_apps))
    |> Enum.max_by(&(Map.get(&1, :id) || 0), fn -> nil end)
    |> case do
      nil -> :missing
      run -> run_state(run)
    end
  end

  defp run_state(%{status: "completed", conclusion: conclusion})
       when conclusion in @passing_conclusions,
       do: :passed

  defp run_state(%{status: "completed", conclusion: conclusion}),
    do: {:failed, conclusion || "none"}

  defp run_state(_running), do: :pending

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
            "app" => Map.get(run, :app),
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
