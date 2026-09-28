defmodule Loopctl.Verification.GitHubActions do
  @moduledoc """
  US-26.4.3 — GitHub Actions CI integration.

  Queries GitHub's API for a commit's Actions workflow runs and test results.
  Uses the GITHUB_TOKEN env var for authentication.
  """

  @behaviour Loopctl.Verification.CiBehaviour

  require Logger

  @per_page 100
  # The runs that can carry CI evidence for a commit: those its own push or pull request
  # triggered. A scheduled, dispatched or workflow_run-triggered run on the same commit
  # (a deploy, a nightly) is not the commit's CI and neither passes nor fails it.
  @ci_events ~w(push pull_request)
  # Of a completed run, only `success` passes and these fail. `skipped`, `neutral` and
  # `cancelled` are no evidence either way: a skipped run ran no tests, and a run is
  # cancelled when a newer commit on the same ref supersedes it (cancel-in-progress), so
  # its tests never finished. They are dropped, and a commit left with no run at all has
  # no CI verdict.
  @failed ~w(failure timed_out startup_failure stale)
  @no_evidence ~w(skipped neutral cancelled)

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
      when is_list(runs) and is_integer(total) ->
        cond do
          # More runs than one page holds: judging the page could miss a failure.
          total > length(runs) -> {:error, {:workflow_runs_truncated, total}}
          Enum.all?(runs, &is_map/1) -> summarize(runs)
          true -> {:error, :unreadable_workflow_runs}
        end

      {:ok, %{status: 200}} ->
        {:error, :unreadable_workflow_runs}

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
    opts = [headers: github_headers()]

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

  # One verdict per workflow, from its newest run (the highest run id): a re-run or a second
  # trigger of the same workflow on this commit supersedes the older one. A failed newest
  # run fails the commit; an unfinished one (queued, in progress, waiting for approval)
  # keeps it in progress, which the worker bounds; otherwise every remaining run passed.
  defp summarize(runs) do
    latest =
      runs
      |> Enum.filter(&(&1["event"] in @ci_events))
      |> Enum.group_by(& &1["workflow_id"])
      |> Enum.map(fn {_, per_workflow} -> Enum.max_by(per_workflow, & &1["id"]) end)
      |> Enum.reject(&(&1["status"] == "completed" and &1["conclusion"] in @no_evidence))

    cond do
      latest == [] ->
        {:error, :no_workflow_runs}

      Enum.any?(latest, &(&1["status"] == "completed" and &1["conclusion"] in @failed)) ->
        {:ok, %{status: "completed", conclusion: "failure", url: ""}}

      Enum.all?(latest, &(&1["status"] == "completed" and &1["conclusion"] == "success")) ->
        {:ok, %{status: "completed", conclusion: "success", url: ""}}

      true ->
        {:ok, %{status: "in_progress", conclusion: nil, url: ""}}
    end
  end
end
