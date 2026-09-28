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

    defp run(workflow, status, conclusion, opts \\ []) do
      %{
        "id" => Keyword.get(opts, :id, workflow),
        "workflow_id" => workflow,
        "event" => Keyword.get(opts, :event, "push"),
        "status" => status,
        "conclusion" => conclusion
      }
    end

    defp status, do: GitHubActions.get_status(@repo, @sha)

    test "every workflow's newest run succeeded is a pass" do
      stub_runs([run(1, "completed", "success"), run(2, "completed", "success")])
      assert {:ok, %{conclusion: "success"}} = status()
    end

    test "a failed workflow fails the commit, even beside a passing one" do
      stub_runs([run(1, "completed", "success"), run(2, "completed", "failure")])
      assert {:ok, %{conclusion: "failure"}} = status()
    end

    test "a skipped, neutral or cancelled run is no evidence either way" do
      for dropped <- ~w(skipped neutral cancelled) do
        stub_runs([run(1, "completed", "success"), run(2, "completed", dropped)])
        assert {:ok, %{conclusion: "success"}} = status(), dropped

        stub_runs([run(2, "completed", dropped)])
        assert {:error, :no_workflow_runs} = status(), dropped
      end
    end

    test "a run the commit's own push or pull request did not trigger is not its CI" do
      stub_runs([
        run(1, "completed", "success", event: "pull_request"),
        run(2, "completed", "failure", event: "schedule"),
        run(3, "waiting", nil, event: "workflow_dispatch")
      ])

      assert {:ok, %{conclusion: "success"}} = status()
    end

    test "no runs is no verdict, never a pass" do
      stub_runs([])
      assert {:error, :no_workflow_runs} = status()
    end

    test "an unfinished or approval-waiting run keeps the commit in progress" do
      stub_runs([run(1, "completed", "success"), run(2, "in_progress", nil)])
      assert {:ok, %{status: "in_progress"}} = status()

      stub_runs([run(1, "completed", "action_required")])
      assert {:ok, %{status: "in_progress"}} = status()
    end

    test "a workflow's newest run supersedes its older one" do
      stub_runs([run(1, "completed", "failure", id: 10), run(1, "completed", "success", id: 11)])
      assert {:ok, %{conclusion: "success"}} = status()

      stub_runs([run(1, "completed", "success", id: 11), run(1, "completed", "failure", id: 12)])
      assert {:ok, %{conclusion: "failure"}} = status()
    end

    test "more runs than one page is refused, not judged from part of them" do
      stub_runs([run(1, "completed", "success")], 150)
      assert {:error, {:workflow_runs_truncated, 150}} = status()
    end

    test "a body of another shape is unreadable, not a crash" do
      for body <- [
            %{"workflow_runs" => "x", "total_count" => 1},
            %{"workflow_runs" => ["x"], "total_count" => 1},
            %{}
          ] do
        Req.Test.stub(GitHubActions, &Req.Test.json(&1, body))
        assert {:error, :unreadable_workflow_runs} = status(), inspect(body)
      end
    end

    test "a refused read is an error carrying the status" do
      Req.Test.stub(GitHubActions, &Plug.Conn.send_resp(&1, 403, "{}"))
      assert {:error, {:github_api_error, 403}} = status()
    end
  end
end
