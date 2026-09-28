defmodule Loopctl.Verification.GitHubActions do
  @moduledoc """
  US-26.4.3 — GitHub Actions CI integration.

  Queries GitHub's API for a commit's CI status and test results.
  Uses the GITHUB_TOKEN env var for authentication.

  The status comes from the Actions WORKFLOW RUNS of the commit, not from its check runs
  (#913). The check-runs endpoint needs the Checks permission, which GitHub offers to Apps
  only: a fine-grained personal access token cannot hold it, so on a private repository
  every lookup 403'd and verification never reached a CI verdict. Workflow runs need
  `actions: read`, which a fine-grained token can hold, and every CI this fleet reports
  is an Actions workflow.
  """

  @behaviour Loopctl.Verification.CiBehaviour

  alias Loopctl.Delivery.GitHubPullRequestSource

  # A completed run that ran and failed. Every other non-success conclusion did not run the
  # commit's CI to a result.
  @failed ["failure", "timed_out", "startup_failure"]

  # Still going. `waiting` is not here: an approval can take weeks.
  @running ["queued", "in_progress", "requested", "pending"]

  @impl true
  def get_status(repo_url, commit_sha) do
    with {:ok, repo} <- repo_full_name(repo_url),
         {:ok, runs} <- GitHubPullRequestSource.commit_ci_runs(repo, commit_sha) do
      summarize_workflow_runs(runs)
    end
  end

  @impl true
  def get_test_results(_repo_url, _run_id) do
    {:ok, []}
  end

  defp repo_full_name(url) do
    # The repository name may contain dots (`loopctl.com`); only a trailing `.git` is not
    # part of it.
    case Regex.run(~r|github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?(?:/.*)?$|, url) do
      [_, owner, repo] -> {:ok, owner <> "/" <> repo}
      _ -> {:error, {:unrecognized_repo_url, url}}
    end
  end

  @doc """
  The CI verdict for a commit's workflow runs, as `GitHubPullRequestSource.commit_ci_runs/2`
  returns them. One rule, in order, and it does not try to tell a CI workflow from a deploy
  or release workflow, which nothing in a run says:

    1. any run that concluded `failure`, `timed_out` or `startup_failure` - `failure`, with
       that run's URL. A known failure is recorded at once, never held behind a run that is
       still queued;
    2. any run queued or running - `in_progress`; the caller snoozes until it finishes;
    3. any run that concluded `success` - `success`;
    4. otherwise - `{:error, :no_ci_evidence}`: no runs at all (a repository without Actions
       CI, or a commit a path filter skipped), or only runs that did not run the commit's
       CI to a result - `cancelled`, `skipped`, `neutral`, `action_required`, `stale`, or
       `waiting` on an approval. An empty list once read as SUCCESS, since `Enum.all?/2` of
       nothing is true.

  A run that did not reach a result never outweighs one that did: a deploy workflow waiting
  on an approval, or cancelled by a newer merge, leaves a green CI run green.
  """
  @spec summarize_workflow_runs([map()]) ::
          {:ok, %{status: String.t(), conclusion: String.t() | nil, url: String.t()}}
          | {:error, :no_ci_evidence}
  def summarize_workflow_runs(runs) do
    completed = Enum.filter(runs, &(&1.status == "completed"))

    cond do
      failed = Enum.find(completed, &(&1.conclusion in @failed)) ->
        {:ok, %{status: "completed", conclusion: "failure", url: failed.url || ""}}

      Enum.any?(runs, &(&1.status in @running)) ->
        {:ok, %{status: "in_progress", conclusion: nil, url: ""}}

      Enum.any?(completed, &(&1.conclusion == "success")) ->
        {:ok, %{status: "completed", conclusion: "success", url: ""}}

      true ->
        {:error, :no_ci_evidence}
    end
  end
end
