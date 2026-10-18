defmodule Loopctl.Delivery.CiEvidence do
  @moduledoc """
  What CI said about ONE commit of a story's branch, judged against the required checks.
  Pure. Story verification (`Loopctl.Verification.GitHubActions`) reads the evidence
  (`Loopctl.Delivery.PullRequestSource.check_evidence/3`) and this module decides what it
  says.

  ## What may satisfy a required check: a job of the branch's own push run

  Only a JOB of a GitHub Actions WORKFLOW RUN that a PUSH of the story's branch at exactly
  this commit triggered. Anything weaker is something the implementer can produce itself:

  - a commit STATUS can be posted by anyone holding `statuses: write`, which includes the
    implementer's runner (it posts `local-gate`)
  - a CHECK RUN, even one attributed to the `github-actions` app, can be created on any commit
    under any name by a workflow on ANOTHER branch the implementer pushed, through its
    `GITHUB_TOKEN`
  - a workflow run triggered some other way (`workflow_dispatch`, a different branch) runs
    workflow files the change's review never saw

  A push run of the story branch runs the workflow files of the commit's own tree, and a
  change that CHANGES those files is refused before this is consulted
  (`Loopctl.Delivery.CiDefinition.reasons/1`), so the definitions a trusted job ran are the
  base's.

  What those jobs EXECUTE is repository code — test files, scripts — which the implementer
  writes, exactly as it writes the change itself. Tampering there is a defect in the change,
  and the change's review is what judges it; this module proves that the
  required jobs ran on this commit and passed, not that they test the right thing.

  ## How one required check is judged

  Per workflow file, only its NEWEST run counts (a later push run of the same commit
  supersedes an earlier one), and in it EVERY job carrying the name — matrix legs are separate
  jobs, and one green leg must never hide a red one. Each job is its latest attempt (the jobs
  read is `filter=latest`), so a re-run that went green supersedes the failure it re-ran.
  ACROSS workflows nothing supersedes anything either: two workflows with a job `test` are two
  checks under one name. So a name is `:failed` when any counted job failed, `:pending` when none failed and any
  is still running, `:passed` only when every one passed, and `:missing` when no trusted job
  carries it. A job:

  - not `completed` is `:pending`
  - `completed` with conclusion `success` is `:passed` — and NOTHING ELSE is. A job GitHub
    `skipped` did not run: a required job skipped because a job it `needs:` failed, or because
    an `if:` the commit controls said so, must never read as green
  - any other conclusion is `:failed`, naming it

  ## The local gate is recorded, never trusted

  `local-gate` (`Loopctl.Intake.Source.local_gate/0`) is read from the commit statuses, best
  effort, and reported under `local_gate` (`"unread"` when the statuses could not be read). It
  is never looked up as a required check, even by a caller that lists it: the intake source
  refuses to store it, and this module drops it from the list as the backstop.
  """

  alias Loopctl.Intake.Source

  # A jobless run that concluded one of these ran nothing and failed nothing (`dead_run?/1`).
  @harmless_jobless_conclusions ~w(success skipped neutral)

  @type job :: %{
          required(:name) => String.t(),
          required(:status) => String.t(),
          required(:conclusion) => String.t() | nil,
          optional(:id) => integer() | nil,
          optional(:run_id) => integer() | nil,
          optional(:workflow) => String.t() | nil,
          optional(:url) => String.t() | nil
        }
  @type status :: %{required(:context) => String.t(), required(:state) => String.t()}
  @type evidence :: %{jobs: [job()], statuses: [status()] | {:unread, term()}}
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
  def judge(required, %{statuses: statuses} = evidence) do
    # The newest run of each workflow, and its jobs, computed ONCE per judgement.
    %{jobs: counted, jobless_runs: jobless} = counted(evidence)
    acc = %{passed: [], pending: [], missing: [], failed: []}

    judged =
      required
      |> lookup_names()
      |> Enum.reduce(acc, fn name, acc ->
        case check_state(name, counted, jobless) do
          {:failed, conclusion} -> Map.update!(acc, :failed, &[{name, conclusion} | &1])
          state -> Map.update!(acc, state, &[name | &1])
        end
      end)
      |> Map.new(fn {key, names} -> {key, Enum.reverse(names)} end)

    Map.put(judged, :local_gate, local_gate_state(statuses))
  end

  @doc """
  What `judge/2` COUNTS from `evidence`: the jobs of each workflow's newest run, and the newest
  runs that carry no job at all. Public so a caller that has to POINT at the evidence — story
  verification records the failing job's or the judged run's URL (US-26.4.6) — points at a job
  this judgement counted, never at one a newer run of its workflow superseded.
  """
  @spec counted(evidence()) :: %{jobs: [job()], jobless_runs: [map()]}
  def counted(%{jobs: jobs} = evidence) do
    runs = newest_runs(Map.get(evidence, :runs), jobs)
    newest_ids = MapSet.new(runs, & &1.id)
    job_run_ids = MapSet.new(jobs, &run_id/1)

    %{
      jobs: Enum.filter(jobs, &(run_id(&1) in newest_ids)),
      jobless_runs: Enum.reject(runs, &(&1.id in job_run_ids))
    }
  end

  # Every job carrying the name, in each workflow's newest run. A newest run with NO jobs yet
  # that is still running may be about to create one, so it holds the name pending (#910 round
  # 3, finding 3). One that DIED with no jobs at all (`startup_failure`, an invalid workflow)
  # fails the name when no job carries it — otherwise it read as missing and waited out the CI
  # limit before anyone was told CI never ran (finding 4). Only a DEAD one (`dead_run?/1`): a
  # workflow that concluded `success`, `skipped` or `neutral` with no jobs (every job's `if:`
  # false, a path filter) ran nothing and failed nothing, so it is no evidence about any name.
  defp check_state(name, jobs, jobless) do
    states =
      for(%{name: ^name} = job <- jobs, do: job_state(job)) ++
        for %{status: status} <- jobless, status != "completed", do: :pending

    dead = for run <- jobless, dead_run?(run), do: run_conclusion(run)

    combine(states, dead)
  end

  @doc """
  Whether a run from `counted/1`'s `jobless_runs` ENDED without running what it should have —
  completed with a conclusion other than `success`, `skipped` or `neutral` (`startup_failure`,
  `failure`, `cancelled`, `timed_out`, `action_required`, none at all). Such a run fails every
  required name no job carries, as `run_<conclusion>` (`run_conclusion/1`). Public so a caller
  pointing at the evidence (story verification's failing URL) points at a run that COUNTED.
  """
  @spec dead_run?(map()) :: boolean()
  def dead_run?(%{status: "completed"} = run),
    do: Map.get(run, :conclusion) not in @harmless_jobless_conclusions

  def dead_run?(_run), do: false

  @doc "The `run_<conclusion>` a dead jobless run fails a name with (see `dead_run?/1`)."
  @spec run_conclusion(map()) :: String.t()
  def run_conclusion(run), do: "run_" <> (Map.get(run, :conclusion) || "none")

  defp combine([], [conclusion | _]), do: {:failed, conclusion}
  defp combine([], []), do: :missing

  defp combine(states, _dead) do
    cond do
      failed = Enum.find(states, &match?({:failed, _}, &1)) -> failed
      :pending in states -> :pending
      true -> :passed
    end
  end

  # The newest run of each workflow file. The runs come from the adapter already reduced to
  # that (`GitHubPullRequestSource`); a caller that names no runs gets them derived from the
  # jobs, which is all an older caller carried.
  defp newest_runs(runs, _jobs) when is_list(runs) do
    runs
    |> Enum.group_by(&Map.get(&1, :workflow))
    |> Enum.map(fn {_workflow, same} -> Enum.max_by(same, & &1.id) end)
  end

  defp newest_runs(nil, jobs) do
    jobs
    |> Enum.group_by(&Map.get(&1, :workflow), &run_id/1)
    |> Enum.map(fn {workflow, ids} ->
      %{id: Enum.max(ids), workflow: workflow, status: "completed", conclusion: nil}
    end)
  end

  defp run_id(job), do: Map.get(job, :run_id) || 0

  defp job_state(%{status: "completed", conclusion: "success"}), do: :passed

  defp job_state(%{status: "completed", conclusion: conclusion}),
    do: {:failed, conclusion || "none"}

  defp job_state(_running), do: :pending

  defp local_gate_state({:unread, _reason}), do: "unread"

  defp local_gate_state(statuses) do
    local_gate = Source.local_gate()

    Enum.find_value(statuses, fn
      %{context: ^local_gate, state: state} -> state
      _other -> nil
    end)
  end
end
