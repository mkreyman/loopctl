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

  # Conclusions of a run that did not run the commit's CI at all.
  @not_run ["skipped", "neutral"]

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
    case Regex.run(~r|github\.com[:/]([^/]+)/([^/.]+)|, url) do
      [_, owner, repo] -> {:ok, owner <> "/" <> repo}
      _ -> {:error, {:unrecognized_repo_url, url}}
    end
  end

  @doc """
  The `Authorization` header for `token`, or none when there is no usable token.

  Takes the VALUE so the rule is unit-testable. A BLANK value is not a token, and used to
  be treated as one: `if token do` is truthy for `""`, so a variable set-but-empty (the
  shape a templated deploy config produces) sent `Authorization: Bearer ` and GitHub 401'd
  every lookup. Verification then reported `github_api_error` instead of a CI verdict —
  strictly WORSE than sending nothing, which at least works for a public repo.
  """
  @spec auth_headers(String.t() | nil) :: [{String.t(), String.t()}]
  def auth_headers(token)

  def auth_headers(nil), do: []

  def auth_headers(token) when is_binary(token) do
    case String.trim(token) do
      "" -> []
      trimmed -> [{"authorization", "Bearer #{trimmed}"}]
    end
  end

  @doc """
  The CI verdict for a commit's workflow runs, as `GitHubPullRequestSource.commit_ci_runs/2`
  returns them (newest run per workflow, event and branch).

    * any run not `completed` - `in_progress`; the caller snoozes until it finishes;
    * a run that concluded `skipped` or `neutral` did not run the commit's CI and is left
      out;
    * any remaining run that did not succeed and was not cancelled - `failure`, with that
      run's URL;
    * otherwise a `cancelled` run - `{:error, :ci_cancelled}`. A run cancelled by a newer
      push (`cancel-in-progress`) says nothing about this commit, so it is no evidence
      rather than a failure, and the caller falls back to local re-execution;
    * nothing left at all - `{:error, :no_workflow_runs}`: a repository without Actions CI,
      or a commit a path filter skipped, is no evidence either, never a pass. (An empty
      list once read as SUCCESS, since `Enum.all?/2` of nothing is true.)
    * otherwise - `success`.
  """
  @spec summarize_workflow_runs([map()]) ::
          {:ok, %{status: String.t(), conclusion: String.t() | nil, url: String.t()}}
          | {:error, :ci_cancelled | :no_workflow_runs}
  def summarize_workflow_runs(runs) do
    counted = Enum.reject(runs, &(&1.status == "completed" and &1.conclusion in @not_run))

    cond do
      Enum.any?(runs, &(&1.status != "completed")) ->
        {:ok, %{status: "in_progress", conclusion: nil, url: ""}}

      failed = Enum.find(counted, &(&1.conclusion not in ["success", "cancelled"])) ->
        {:ok, %{status: "completed", conclusion: "failure", url: failed.url || ""}}

      Enum.any?(counted, &(&1.conclusion == "cancelled")) ->
        {:error, :ci_cancelled}

      counted == [] ->
        {:error, :no_workflow_runs}

      true ->
        {:ok, %{status: "completed", conclusion: "success", url: ""}}
    end
  end
end
