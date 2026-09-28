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
  # Of a completed run, only `success` passes and these fail. `skipped`, `neutral`,
  # `cancelled` and `stale` are no evidence either way: a skipped run ran no tests, a run is
  # cancelled when a newer commit on the same ref supersedes it (cancel-in-progress), and
  # GitHub marks a run `stale` when it sat unfinished for 14 days. They are dropped, and a
  # commit left with no run at all has no CI verdict. `action_required` is a run waiting
  # for someone to approve it, so it waits like an unfinished one. Any other conclusion is
  # one this module does not know, and gets no verdict rather than a guess.
  @failed ~w(failure timed_out startup_failure)
  @no_evidence ~w(skipped neutral cancelled stale)
  @awaiting ~w(action_required)
  @known ["success" | @failed ++ @awaiting]

  # #913: CI is read from the commit's Actions workflow runs, not its check runs. The
  # check-runs endpoint needs `checks: read`, which GitHub does not offer to fine-grained
  # personal access tokens, so on a private repository it 403'd on every lookup. Every CI
  # this fleet reports is an Actions workflow, and `actions: read` is on offer. The cost is
  # that CI which is NOT an Actions workflow (CircleCI, Buildkite, a third-party check app)
  # is no longer seen at all: such a commit has no CI verdict and falls back.
  @impl true
  def get_status(repo_url, commit_sha) do
    {owner, repo} = parse_repo_url(repo_url)

    url =
      "https://api.github.com/repos/#{owner}/#{repo}/actions/runs" <>
        "?head_sha=#{URI.encode_www_form(commit_sha)}&per_page=#{@per_page}"

    url |> Req.get(req_options()) |> from_response()
  end

  defp from_response(
         {:ok, %{status: 200, body: %{"workflow_runs" => runs, "total_count" => total}}}
       )
       when is_list(runs) and is_integer(total) do
    cond do
      # More runs than one page holds: judging the page could miss a failure.
      total > length(runs) -> {:error, {:workflow_runs_truncated, total}}
      Enum.all?(runs, &run?/1) -> summarize(runs)
      true -> {:error, :unreadable_workflow_runs}
    end
  end

  defp from_response({:ok, %{status: 200}}), do: {:error, :unreadable_workflow_runs}

  # GitHub answers an exhausted rate limit 403, not 429; the header tells them apart from a
  # permission refusal, which is permanent.
  defp from_response({:ok, %{status: 403, headers: %{"x-ratelimit-remaining" => ["0" | _]}}}),
    do: {:error, :github_rate_limited}

  defp from_response({:ok, %{status: status}}), do: {:error, {:github_api_error, status}}
  defp from_response({:error, reason}), do: {:error, reason}

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

  defp run?(%{"id" => id, "workflow_id" => workflow})
       when is_integer(id) and is_integer(workflow),
       do: true

  defp run?(_), do: false

  # One verdict per workflow and triggering event, from its newest run. A commit's push run
  # and its pull_request run of the same workflow test different trees (the commit, and its
  # merge with the base), so neither hides the other. Within one, the highest id is the run
  # created last: a re-run keeps its id, and this list already reports its latest attempt.
  # A failed run fails the commit; a completed run with a conclusion this module does not
  # know gets no verdict; an unfinished one keeps it in progress, which the worker bounds;
  # otherwise every remaining run passed.
  defp summarize(runs) do
    runs |> latest_runs() |> verdict()
  end

  defp latest_runs(runs) do
    runs
    |> Enum.filter(&(&1["event"] in @ci_events))
    |> Enum.group_by(&{&1["workflow_id"], &1["event"]})
    |> Enum.map(fn {_, runs} -> Enum.max_by(runs, & &1["id"]) end)
    |> Enum.reject(&concluded?(&1, @no_evidence))
  end

  defp verdict([]), do: {:error, :no_workflow_runs}

  defp verdict(latest) do
    cond do
      Enum.any?(latest, &concluded?(&1, @failed)) ->
        {:ok, %{status: "completed", conclusion: "failure", url: ""}}

      unknown = Enum.find(latest, &(completed?(&1) and not concluded?(&1, @known))) ->
        {:error, {:unknown_conclusion, unknown["conclusion"]}}

      Enum.all?(latest, &concluded?(&1, ["success"])) ->
        {:ok, %{status: "completed", conclusion: "success", url: ""}}

      true ->
        {:ok, %{status: "in_progress", conclusion: nil, url: ""}}
    end
  end

  defp concluded?(run, conclusions), do: completed?(run) and run["conclusion"] in conclusions

  defp completed?(run), do: run["status"] == "completed"
end
