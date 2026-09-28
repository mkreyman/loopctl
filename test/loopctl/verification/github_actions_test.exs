defmodule Loopctl.Verification.GitHubActionsTest do
  use ExUnit.Case, async: true

  alias Loopctl.Delivery.GitHubPullRequestSource
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
    defp run(status, conclusion, url \\ "https://github.com/o/r/actions/runs/1") do
      %{status: status, conclusion: conclusion, url: url}
    end

    test "every run concluded success is a pass" do
      assert {:ok, %{status: "completed", conclusion: "success"}} =
               GitHubActions.summarize_workflow_runs([
                 run("completed", "success"),
                 run("completed", "success")
               ])
    end

    test "no runs is no evidence, never a pass and never a wait" do
      assert {:error, :no_workflow_runs} = GitHubActions.summarize_workflow_runs([])
    end

    test "a run still going keeps the commit in progress" do
      assert {:ok, %{status: "in_progress"}} =
               GitHubActions.summarize_workflow_runs([
                 run("completed", "success"),
                 run("queued", nil)
               ])
    end

    test "a failing run is a failure that links to the run" do
      for conclusion <- ["failure", "timed_out", "action_required", "startup_failure"] do
        assert {:ok, %{conclusion: "failure", url: "https://x/failed"}} =
                 GitHubActions.summarize_workflow_runs([
                   run("completed", "success"),
                   run("completed", conclusion, "https://x/failed")
                 ]),
               "#{conclusion} must not pass"
      end
    end

    test "a skipped or neutral run did not run CI and is left out" do
      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.summarize_workflow_runs([
                 run("completed", "success"),
                 run("completed", "skipped"),
                 run("completed", "neutral")
               ])

      assert {:error, :no_workflow_runs} =
               GitHubActions.summarize_workflow_runs([run("completed", "skipped")])
    end

    test "a run waiting on an environment approval is no evidence, not an endless wait" do
      assert {:error, :ci_waiting} =
               GitHubActions.summarize_workflow_runs([
                 run("completed", "success"),
                 run("waiting", nil)
               ])

      assert {:ok, %{conclusion: "failure"}} =
               GitHubActions.summarize_workflow_runs([
                 run("waiting", nil),
                 run("completed", "failure")
               ])
    end

    test "a cancelled run is no evidence, not a failure, unless another run failed" do
      assert {:error, :ci_cancelled} =
               GitHubActions.summarize_workflow_runs([
                 run("completed", "success"),
                 run("completed", "cancelled")
               ])

      assert {:ok, %{conclusion: "failure"}} =
               GitHubActions.summarize_workflow_runs([
                 run("completed", "cancelled"),
                 run("completed", "failure")
               ])
    end
  end

  describe "get_status/2 (#913)" do
    @sha "abc123"

    defp api_run(id, path, event, branch, conclusion, sha \\ @sha) do
      %{
        "id" => id,
        "path" => path,
        "event" => event,
        "head_branch" => branch,
        "head_sha" => sha,
        "status" => "completed",
        "conclusion" => conclusion,
        "html_url" => "https://github.com/mkreyman/infra/actions/runs/#{id}"
      }
    end

    # Answers each event's runs page as GitHub would (filtered by `event`, with that event's
    # own total) and a tag-ref read with 200 for a name in `tags`, 404 otherwise.
    defp stub_runs(runs, opts \\ []) do
      tags = Keyword.get(opts, :tags, [])
      totals = Keyword.get(opts, :totals, %{})
      test_pid = self()

      Req.Test.stub(GitHubPullRequestSource, fn conn ->
        case conn.request_path do
          "/repos/mkreyman/infra/actions/runs" ->
            event = conn.query_params["event"]
            send(test_pid, {:runs_read, event, conn.query_params["head_sha"]})

            page = runs_page(runs, event, opts[:api_ignores_event])

            Req.Test.json(conn, %{
              "total_count" => Map.get(totals, event, length(page)),
              "workflow_runs" => page
            })

          "/repos/mkreyman/infra/git/ref/tags/" <> name ->
            tag_ref(conn, name in tags, name)
        end
      end)
    end

    defp runs_page(runs, _event, true), do: runs
    defp runs_page(runs, event, _filters), do: Enum.filter(runs, &(&1["event"] == event))

    defp tag_ref(conn, true, name), do: Req.Test.json(conn, %{"ref" => "refs/tags/" <> name})
    defp tag_ref(conn, false, _name), do: Plug.Conn.send_resp(conn, 404, "{}")

    test "reads the commit's push and pull_request workflow runs, never its check runs" do
      stub_runs([
        api_run(1, ".github/workflows/ci.yml", "push", "main", "success"),
        api_run(2, ".github/workflows/ci.yml", "pull_request", "main", "success")
      ])

      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.get_status("git@github.com:mkreyman/infra.git", @sha)

      assert_received {:runs_read, "push", @sha}
      assert_received {:runs_read, "pull_request", @sha}
    end

    test "a pull_request run's failure fails the commit" do
      stub_runs([
        api_run(1, ".github/workflows/ci.yml", "push", "main", "success"),
        api_run(2, ".github/workflows/ci.yml", "pull_request", "main", "failure")
      ])

      assert {:ok, %{conclusion: "failure"}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "a failure on ANY branch the commit was pushed to fails it" do
      stub_runs([
        api_run(1, ".github/workflows/ci.yml", "push", "feature/x", "failure"),
        api_run(2, ".github/workflows/ci.yml", "push", "main", "success")
      ])

      assert {:ok, %{conclusion: "failure", url: url}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)

      assert url =~ "/actions/runs/1"
    end

    test "the newest run of a workflow on a branch supersedes an older one" do
      stub_runs([
        api_run(1, ".github/workflows/ci.yml", "push", "main", "failure"),
        api_run(2, ".github/workflows/ci.yml", "push", "main", "success")
      ])

      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "a newer CANCELLED run does not hide an older run that finished" do
      stub_runs([
        api_run(10, ".github/workflows/ci.yml", "push", "main", "success"),
        api_run(11, ".github/workflows/ci.yml", "push", "main", "cancelled")
      ])

      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "a push of a TAG is a release, not the commit's CI" do
      stub_runs(
        [
          api_run(1, ".github/workflows/ci.yml", "push", "main", "success"),
          api_run(2, ".github/workflows/publish.yml", "push", "mcp-v1.2.3", "failure")
        ],
        tags: ["mcp-v1.2.3"]
      )

      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "runs of another commit are not this commit's CI" do
      stub_runs([
        api_run(1, ".github/workflows/ci.yml", "push", "main", "success"),
        api_run(3, ".github/workflows/ci.yml", "push", "other", "failure", "def456")
      ])

      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "a run of another event is not counted even when the API ignores the filter" do
      stub_runs(
        [
          api_run(1, ".github/workflows/ci.yml", "push", "main", "success"),
          api_run(2, ".github/workflows/nightly.yml", "schedule", "main", "failure")
        ],
        api_ignores_event: true
      )

      assert {:ok, %{conclusion: "success"}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "a truncated run list is refused, never judged on the part it has" do
      stub_runs([api_run(1, ".github/workflows/ci.yml", "push", "main", "success")],
        totals: %{"push" => 150}
      )

      assert {:error, {:workflow_runs_truncated, 150, 1}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "a refused read is the forge's permission error, not a verdict" do
      Req.Test.stub(GitHubPullRequestSource, &Plug.Conn.send_resp(&1, 403, "{}"))

      assert {:error, {:github_api_error, 403}} =
               GitHubActions.get_status("https://github.com/mkreyman/infra", @sha)
    end

    test "a repository name with a dot is read whole" do
      Req.Test.stub(GitHubPullRequestSource, fn conn ->
        assert conn.request_path == "/repos/mkreyman/loopctl.com/actions/runs"
        Req.Test.json(conn, %{"total_count" => 0, "workflow_runs" => []})
      end)

      for url <- [
            "https://github.com/mkreyman/loopctl.com",
            "git@github.com:mkreyman/loopctl.com.git"
          ] do
        assert {:error, :no_workflow_runs} = GitHubActions.get_status(url, @sha)
      end
    end

    test "a URL that names no GitHub repository is an error, not a lookup" do
      assert {:error, {:unrecognized_repo_url, _}} =
               GitHubActions.get_status("https://example.com/x", @sha)
    end
  end
end
