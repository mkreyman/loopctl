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

  require Logger

  @impl true
  def get_status(repo_url, commit_sha) do
    {owner, repo} = parse_repo_url(repo_url)

    case Req.get(
           "https://api.github.com/repos/#{owner}/#{repo}/actions/runs",
           req_options(params: [head_sha: commit_sha, per_page: 100])
         ) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}} when is_list(runs) ->
        {:ok, summarize_workflow_runs(runs)}

      {:ok, %{status: status}} ->
        {:error, {:github_api_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_test_results(_repo_url, _run_id) do
    {:ok, []}
  end

  defp parse_repo_url(url) do
    case Regex.run(~r|github\.com[:/]([^/]+)/([^/.]+)|, url) do
      [_, owner, repo] -> {owner, repo}
      _ -> {"unknown", "unknown"}
    end
  end

  # A Req.Test plug is injected from config in the test env (config/test.exs), the same
  # config-based seam `Loopctl.Delivery.GitHubPullRequestSource` uses.
  defp req_options(opts) do
    opts = Keyword.put(opts, :headers, github_headers())

    case Application.get_env(:loopctl, :verification_github_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp github_headers do
    auth_headers(System.get_env("GITHUB_TOKEN")) ++
      [{"accept", "application/vnd.github+json"}, {"user-agent", "loopctl-verification"}]
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
  Summarizes a commit's workflow runs, as `GET /actions/runs?head_sha=` returns them.

  Only the NEWEST run of each workflow per triggering event counts: GitHub lists runs
  newest first, and a re-run of a failed workflow is a new run that supersedes it.

    * no runs yet, or any counted run not `completed` - `in_progress` (the caller snoozes);
    * every counted run concluded `success` - `success`;
    * otherwise - `failure`. A `cancelled`, `timed_out`, `skipped` or `action_required`
      run is not a pass, and used to read as `in_progress` for ever.

  An empty list used to read as SUCCESS (`Enum.all?/2` of nothing is true), so a commit
  whose CI had not started yet was verified.
  """
  @spec summarize_workflow_runs([map()]) :: %{
          status: String.t(),
          conclusion: String.t() | nil,
          url: String.t()
        }
  def summarize_workflow_runs(runs) do
    counted = Enum.uniq_by(runs, &{&1["workflow_id"], &1["event"]})

    cond do
      counted == [] or Enum.any?(counted, &(&1["status"] != "completed")) ->
        %{status: "in_progress", conclusion: nil, url: ""}

      Enum.all?(counted, &(&1["conclusion"] == "success")) ->
        %{status: "completed", conclusion: "success", url: ""}

      true ->
        %{status: "completed", conclusion: "failure", url: ""}
    end
  end
end
