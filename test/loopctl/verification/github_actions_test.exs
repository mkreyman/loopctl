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

  describe "summarize_workflow_runs/1 (#913)" do
    defp run(workflow_id, status, conclusion, event \\ "push") do
      %{
        "workflow_id" => workflow_id,
        "event" => event,
        "status" => status,
        "conclusion" => conclusion
      }
    end

    test "every workflow concluded success is a pass" do
      assert %{status: "completed", conclusion: "success"} =
               GitHubActions.summarize_workflow_runs([
                 run(1, "completed", "success"),
                 run(2, "completed", "success")
               ])
    end

    test "no runs yet is NOT a pass: CI that has not started snoozes" do
      assert %{status: "in_progress", conclusion: nil} =
               GitHubActions.summarize_workflow_runs([])
    end

    test "a run still going keeps the commit in progress" do
      assert %{status: "in_progress"} =
               GitHubActions.summarize_workflow_runs([
                 run(1, "completed", "success"),
                 run(2, "in_progress", nil)
               ])
    end

    test "cancelled, timed out and skipped are failures, not a wait that never ends" do
      for conclusion <- ["cancelled", "timed_out", "skipped", "failure"] do
        assert %{status: "completed", conclusion: "failure"} =
                 GitHubActions.summarize_workflow_runs([
                   run(1, "completed", "success"),
                   run(2, "completed", conclusion)
                 ]),
               "#{conclusion} must not pass"
      end
    end

    test "only the newest run of a workflow counts: a green re-run supersedes the failure" do
      # GitHub lists runs newest first.
      assert %{conclusion: "success"} =
               GitHubActions.summarize_workflow_runs([
                 run(1, "completed", "success"),
                 run(1, "completed", "failure")
               ])

      assert %{conclusion: "failure"} =
               GitHubActions.summarize_workflow_runs([
                 run(1, "completed", "failure"),
                 run(1, "completed", "success")
               ])
    end

    test "the same workflow under another event is judged on its own" do
      assert %{conclusion: "failure"} =
               GitHubActions.summarize_workflow_runs([
                 run(1, "completed", "success", "push"),
                 run(1, "completed", "failure", "pull_request")
               ])
    end
  end

  describe "get_status/2 (#913)" do
    test "reads the commit's Actions workflow runs, never its check runs" do
      Req.Test.stub(GitHubActions, fn conn ->
        assert conn.request_path == "/repos/mkreyman/infra/actions/runs"
        assert conn.query_params["head_sha"] == "abc123"

        Req.Test.json(conn, %{
          "workflow_runs" => [
            %{
              "workflow_id" => 1,
              "event" => "push",
              "status" => "completed",
              "conclusion" => "success"
            }
          ]
        })
      end)

      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.get_status("git@github.com:mkreyman/infra.git", "abc123")
    end

    test "a refused read is an API error, not a verdict" do
      Req.Test.stub(GitHubActions, &Plug.Conn.send_resp(&1, 403, "{}"))

      assert {:error, {:github_api_error, 403}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", "abc123")
    end
  end
end
