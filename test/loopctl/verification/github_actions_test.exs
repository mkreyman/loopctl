defmodule Loopctl.Verification.GitHubActionsTest do
  use ExUnit.Case, async: true

  alias Loopctl.Verification.GitHubActions

  describe "auth_headers/1" do
    test "a usable token becomes a bearer header" do
      assert GitHubActions.auth_headers("ghp_abc") == [{"authorization", "Bearer ghp_abc"}]
      assert GitHubActions.auth_headers(" ghp_abc\n") == [{"authorization", "Bearer ghp_abc"}]
    end

    test "no token sends no authorization header" do
      assert GitHubActions.auth_headers(nil) == []
    end

    test "a BLANK token sends none either — an empty bearer is worse than none" do
      # `if token do` is truthy for "", which is the shape a templated deploy config
      # produces for an unset secret. That sent `Authorization: Bearer ` and GitHub 401'd
      # every check-run lookup, so verification reported github_api_error instead of a CI
      # verdict — strictly worse than the anonymous path, which works for a public repo.
      for blank <- ["", "   ", "\n", "\t "] do
        assert GitHubActions.auth_headers(blank) == [],
               "a blank token must not become a bearer header"
      end
    end
  end

  describe "get_status/2" do
    @repo "https://github.com/acme/app"
    @sha "0123456789abcdef0123456789abcdef01234567"

    defp stub_runs(runs, total \\ nil) do
      Req.Test.stub(GitHubActions, fn conn ->
        assert conn.request_path == "/repos/acme/app/actions/runs"
        assert conn.query_string =~ "head_sha=#{@sha}"
        Req.Test.json(conn, %{"total_count" => total || length(runs), "workflow_runs" => runs})
      end)
    end

    defp run(workflow, status, conclusion, number \\ 1) do
      %{
        "workflow_id" => workflow,
        "status" => status,
        "conclusion" => conclusion,
        "run_number" => number,
        "run_attempt" => 1
      }
    end

    test "every workflow's newest run succeeded is a pass" do
      stub_runs([run(1, "completed", "success"), run(2, "completed", "skipped")])
      assert {:ok, %{conclusion: "success"}} = GitHubActions.get_status(@repo, @sha)
    end

    test "a failed workflow fails the commit, even beside a passing one" do
      stub_runs([run(1, "completed", "success"), run(2, "completed", "failure")])
      assert {:ok, %{conclusion: "failure"}} = GitHubActions.get_status(@repo, @sha)
    end

    test "a cancelled newest run fails rather than passes" do
      stub_runs([run(1, "completed", "cancelled")])
      assert {:ok, %{conclusion: "failure"}} = GitHubActions.get_status(@repo, @sha)
    end

    test "no runs yet is in progress, never a pass" do
      stub_runs([])
      assert {:ok, %{status: "in_progress"}} = GitHubActions.get_status(@repo, @sha)
    end

    test "an unfinished or approval-waiting workflow keeps the commit in progress" do
      stub_runs([run(1, "completed", "success"), run(2, "in_progress", nil)])
      assert {:ok, %{status: "in_progress"}} = GitHubActions.get_status(@repo, @sha)

      stub_runs([run(1, "completed", "action_required")])
      assert {:ok, %{status: "in_progress"}} = GitHubActions.get_status(@repo, @sha)
    end

    test "a workflow's newest run supersedes its older one" do
      stub_runs([run(1, "completed", "failure", 1), run(1, "completed", "success", 2)])
      assert {:ok, %{conclusion: "success"}} = GitHubActions.get_status(@repo, @sha)
    end

    test "more runs than one page is refused, not summarised from part of them" do
      stub_runs([run(1, "completed", "success")], 150)

      assert {:error, {:workflow_runs_truncated, 150}} =
               GitHubActions.get_status(@repo, @sha)
    end

    test "a refused read is an error carrying the status" do
      Req.Test.stub(GitHubActions, &Plug.Conn.send_resp(&1, 403, "{}"))
      assert {:error, {:github_api_error, 403}} = GitHubActions.get_status(@repo, @sha)
    end
  end
end
