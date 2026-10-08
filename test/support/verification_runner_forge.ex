defmodule Loopctl.Test.VerificationRunnerForge do
  @moduledoc """
  The forge stubs, evidence builders and run helpers shared by
  `Loopctl.Workers.VerificationRunnerWorkerIntegrationTest` (async, sandboxed) and
  `Loopctl.Workers.VerificationRunnerWorkerLockTest` (sync, committed: its subject is a lock
  another connection holds).

  The forge is `Loopctl.MockPullRequestSource`. Each stub answers ONLY for the intake source's
  repository and the story's own branch; anything else is recorded as `{:wrong_read, ...}`
  and answered with green evidence, so reading the wrong repository or branch shows up as a
  wrong VERDICT, not only as a missing message. Stubs are process-scoped (Mox private mode):
  the worker runs in the test process, so no test can answer another's reads.
  """

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures
  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.MockPullRequestSource
  alias Loopctl.MockVerificationCredential
  alias Loopctl.Verification
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.VerificationRun
  alias Loopctl.Workers.VerificationRunnerWorker

  @repo "acme/widgets"
  @branch "loop/story-branch"
  @sha String.duplicate("a", 40)
  @short "aaaaaaa"
  @fork_point String.duplicate("b", 40)
  @head_tree String.duplicate("e", 40)
  @base_tree String.duplicate("f", 40)

  @run_fields [
    :status,
    :started_at,
    :completed_at,
    :ac_results,
    :ci_forge_faults,
    :resolved_commit_sha,
    :change_checked_at,
    :updated_at
  ]

  @doc "The intake source's repository: the only one the stubs answer for."
  def repo, do: @repo
  @doc "The story's branch the stage row records."
  def branch, do: @branch
  @doc "The full commit SHA a run judges."
  def sha, do: @sha
  @doc "An abbreviated form of `sha/0`."
  def short, do: @short
  @doc "The merge base the comparison answers."
  def fork_point, do: @fork_point
  @doc "The head commit's tree."
  def head_tree, do: @head_tree
  @doc "The base's tree."
  def base_tree, do: @base_tree

  @doc """
  The project, epic, story and intake source a run needs, under `tenant_id`, plus the
  credential stubs; returns the test context. `projects.repo_url` names ANOTHER repository:
  nothing may read it (#931 finding a).
  """
  def setup_story!(tenant_id) do
    project =
      fixture(:project, %{tenant_id: tenant_id, repo_url: "https://github.com/evil/other"})

    epic = fixture(:epic, %{tenant_id: tenant_id, project_id: project.id})
    story = fixture(:story, %{tenant_id: tenant_id, epic_id: epic.id, project_id: project.id})

    fixture(:intake_source, %{
      tenant_id: tenant_id,
      project_id: project.id,
      repo_full_name: @repo,
      required_checks: ["test"]
    })

    test_pid = self()

    stub(MockVerificationCredential, :any_for_tenant?, fn _tenant_id -> true end)

    stub(MockVerificationCredential, :for_read, fn tenant_id, repo ->
      send(test_pid, {:credential_asked, tenant_id, repo})
      {:ok, %Credential{kind: :operator_token, repo: ForgeRepo.operator(repo)}}
    end)

    %{tenant_id: tenant_id, project_id: project.id, story_id: story.id, test_pid: test_pid}
  end

  @doc "The stage row recording `branch` for the story."
  def stage_branch!(ctx, branch) do
    fixture(:story_stage, %{
      tenant_id: ctx.tenant_id,
      story_id: ctx.story_id,
      stage: :implementing,
      branch: branch
    })
  end

  @doc "A new verification run of `sha`."
  def run!(ctx, sha \\ @sha) do
    {:ok, run} = Verification.create_run(ctx.tenant_id, ctx.story_id, %{commit_sha: sha})
    run
  end

  @doc "One poll of the worker, in the calling process."
  def perform(ctx, run) do
    VerificationRunnerWorker.perform(%Oban.Job{
      args: %{"run_id" => run.id, "tenant_id" => ctx.tenant_id}
    })
  end

  @doc "The run as stored now."
  def reload(ctx, run) do
    {:ok, reloaded} = Verification.get_run(ctx.tenant_id, run.id)
    reloaded
  end

  @doc "Everything a poll may write on the run, `updated_at` included."
  def snapshot(ctx, run), do: ctx |> reload(run) |> Map.take(@run_fields)

  @doc "Moves the run's creation (and, when `started?`, its start) `seconds_ago` back."
  def age!(run, seconds_ago, started? \\ true) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    set = [inserted_at: at] ++ if(started?, do: [started_at: at, status: "running"], else: [])
    {1, _} = AdminRepo.update_all(from(r in VerificationRun, where: r.id == ^run.id), set: set)
    run
  end

  @doc "Sets the run's consecutive forge-fault streak."
  def set_faults!(run, faults) do
    {1, _} =
      AdminRepo.update_all(from(r in VerificationRun, where: r.id == ^run.id),
        set: [ci_forge_faults: faults]
      )

    run
  end

  @doc "Started and change-checked, so a poll's only write is the one after the forge's answer."
  def ready!(run) do
    now = DateTime.utc_now()

    {1, _} =
      AdminRepo.update_all(from(r in VerificationRun, where: r.id == ^run.id),
        set: [status: "running", started_at: now, change_checked_at: now]
      )

    run
  end

  @doc "Green evidence: required check `test` succeeded in workflow run `run_id`."
  def green(run_id \\ 5),
    do:
      evidence([ci_run(run_id, "completed", "success")], [ci_job(run_id, "completed", "success")])

  @doc "A forge evidence answer."
  def evidence(runs, jobs), do: {:ok, %{runs: runs, jobs: jobs, statuses: []}}

  @doc "A workflow run of `ci.yml` (or `workflow`)."
  def ci_run(id, status, conclusion, workflow \\ ".github/workflows/ci.yml"),
    do: %{id: id, workflow: workflow, status: status, conclusion: conclusion}

  @doc "An unrelated workflow file (`lint.yml`) that succeeded, carrying its own job."
  def lint_run(id), do: ci_run(id, "completed", "success", ".github/workflows/lint.yml")

  @doc "The job of `lint_run/1`."
  def lint_job(run_id),
    do: %{ci_job(run_id, "completed", "success", "lint") | workflow: ".github/workflows/lint.yml"}

  @doc "A job of a `ci.yml` run, named `test` unless `name` says otherwise."
  def ci_job(run_id, status, conclusion, name \\ "test"),
    do: %{
      id: run_id * 10,
      run_id: run_id,
      name: name,
      status: status,
      conclusion: conclusion,
      workflow: ".github/workflows/ci.yml"
    }

  @doc """
  The story's own reads answer `answers`; any other repository, branch or base is recorded
  and answered GREEN, so a read of the wrong target would pass a run that must not pass.
  """
  def stub_forge(ctx, answers) do
    base = Map.get(answers, :base, "master")
    branch = Map.get(answers, :branch, @branch)
    diff = Map.get(answers, :diff, ["lib/widgets/thing.ex"])

    stub(MockPullRequestSource, :commit, fn
      %ForgeRepo{full_name: @repo}, sha ->
        send(ctx.test_pid, {:commit, sha})
        {:ok, %{tree_sha: Map.get(answers, :tree, @head_tree), parents: [@fork_point]}}

      repo, _sha ->
        send(ctx.test_pid, {:wrong_read, :commit, repo, nil})
        {:ok, %{tree_sha: @head_tree, parents: []}}
    end)

    stub(MockPullRequestSource, :compare, fn
      %ForgeRepo{full_name: @repo}, ^base, sha ->
        send(ctx.test_pid, {:compare, sha})
        answers |> Map.get_lazy(:compare, fn -> {:ok, clean(diff)} end) |> answer()

      repo, other_base, _sha ->
        send(ctx.test_pid, {:wrong_read, :compare, repo, other_base})
        {:ok, clean(["lib/x.ex"])}
    end)

    stub(MockPullRequestSource, :check_evidence, fn
      %ForgeRepo{full_name: @repo}, sha, ^branch ->
        send(ctx.test_pid, {:evidence, sha})
        answers |> Map.fetch!(:evidence) |> answer()

      repo, _sha, other_branch ->
        send(ctx.test_pid, {:wrong_read, :check_evidence, repo, other_branch})
        green(99)
    end)
  end

  @doc "A comparison answer listing `files` changed since `merge_base`."
  def clean(files, merge_base \\ @fork_point),
    do: %{
      merge_base_sha: merge_base,
      base_tree_sha: @base_tree,
      diffstat: %{files: length(files), changed_lines: 3 * length(files)},
      diff: {:ok, %{files: files, renames: []}}
    }

  @doc "A sequence of answers, one per call, from a process-held queue; the last repeats."
  def sequence(answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)

    fn ->
      Agent.get_and_update(agent, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end
  end

  # An answer given as a value, or as a function called at the read.
  defp answer(fun) when is_function(fun, 0), do: fun.()
  defp answer(value), do: value
end
