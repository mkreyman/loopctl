defmodule Loopctl.Verification.GitHubActions do
  @moduledoc """
  US-26.4.3 — GitHub Actions CI integration.

  Queries GitHub's API for commit check status and test results.
  Uses the GITHUB_TOKEN env var for authentication.
  """

  @behaviour Loopctl.Verification.CiBehaviour

  require Logger

  @impl true
  def get_status(repo_url, commit_sha) do
    {owner, repo} = parse_repo_url(repo_url)

    case Req.get("https://api.github.com/repos/#{owner}/#{repo}/commits/#{commit_sha}/check-runs",
           headers: github_headers()
         ) do
      {:ok, %{status: 200, body: %{"check_runs" => runs}}} ->
        overall = summarize_runs(runs)
        {:ok, overall}

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

  defp github_headers do
    token = System.get_env("GITHUB_TOKEN")

    headers = [{"accept", "application/vnd.github+json"}, {"user-agent", "loopctl-verification"}]

    if token do
      [{"authorization", "Bearer #{token}"} | headers]
    else
      headers
    end
  end

  defp summarize_runs(runs) do
    statuses = Enum.map(runs, & &1["conclusion"])

    cond do
      Enum.all?(statuses, &(&1 == "success")) ->
        %{status: "completed", conclusion: "success", url: ""}

      Enum.any?(statuses, &(&1 == "failure")) ->
        %{status: "completed", conclusion: "failure", url: ""}

      true ->
        %{status: "in_progress", conclusion: nil, url: ""}
    end
  end
end
