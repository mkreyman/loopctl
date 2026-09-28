defmodule Loopctl.Verification.GitHubActions do
  @moduledoc """
  US-26.4.3 — GitHub Actions CI integration.

  Queries GitHub's API for a commit's Actions workflow runs and test results.
  Uses the GITHUB_TOKEN env var for authentication.
  """

  @behaviour Loopctl.Verification.CiBehaviour

  require Logger

  @per_page 100
  # Completed conclusions. `cancelled` fails rather than waits: a superseded run of the same
  # workflow is dropped below by recency, so a cancelled newest run is no evidence of a pass.
  # Any other (`action_required`, a run waiting for someone to approve it) is neither, and
  # reads as in progress.
  @passed ~w(success skipped neutral)
  @failed ~w(failure timed_out cancelled startup_failure stale)

  # #913: CI is read from the commit's Actions workflow runs, not its check runs. The
  # check-runs endpoint needs `checks: read`, which GitHub does not offer to fine-grained
  # personal access tokens, so on a private repository it 403'd on every lookup. Every CI
  # this fleet reports is an Actions workflow, and `actions: read` is on offer.
  @impl true
  def get_status(repo_url, commit_sha) do
    {owner, repo} = parse_repo_url(repo_url)

    url =
      "https://api.github.com/repos/#{owner}/#{repo}/actions/runs" <>
        "?head_sha=#{URI.encode_www_form(commit_sha)}&per_page=#{@per_page}"

    case Req.get(url, req_options()) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs, "total_count" => total}}}
      when total > length(runs) ->
        # More runs than one page holds: summarising the page could miss a failure.
        {:error, {:workflow_runs_truncated, total}}

      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}} ->
        {:ok, summarize_runs(runs)}

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

  defp req_options do
    opts = [headers: github_headers(), retry: false]

    # The `Req.Test` seam, as in `Loopctl.Delivery.GitHubPullRequestSource`, so the mapping
    # above is exercised against real response bytes.
    case Application.get_env(:loopctl, :verification_github_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp github_headers do
    auth_headers(System.get_env("GITHUB_TOKEN")) ++
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "loopctl-verification"}
      ]
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

  # One verdict per workflow, from its newest run: a re-run or a second trigger of the same
  # workflow on this commit supersedes the older one. Then every workflow must have passed.
  # No runs at all is NOT a pass - GitHub creates them a moment after the push, so it reads
  # as in progress and the worker waits, within its run window, like any unfinished CI.
  defp summarize_runs(runs) do
    latest =
      runs
      |> Enum.group_by(& &1["workflow_id"])
      |> Enum.map(fn {_, per_workflow} ->
        Enum.max_by(per_workflow, &{&1["run_number"], &1["run_attempt"]})
      end)

    cond do
      Enum.any?(latest, &(&1["status"] == "completed" and &1["conclusion"] in @failed)) ->
        %{status: "completed", conclusion: "failure", url: ""}

      latest != [] and
          Enum.all?(latest, &(&1["status"] == "completed" and &1["conclusion"] in @passed)) ->
        %{status: "completed", conclusion: "success", url: ""}

      true ->
        %{status: "in_progress", conclusion: nil, url: ""}
    end
  end
end
