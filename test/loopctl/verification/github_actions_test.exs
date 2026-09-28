defmodule Loopctl.Verification.GitHubActionsTest do
  @moduledoc """
  US-26.4.6: story verification's CI adapter judges a commit by the merge gate's rules, through
  the merge gate's adapter (`Loopctl.MockPullRequestSource` here), and answers only the
  outcomes `Loopctl.Verification.CiBehaviour` declares.

  No default stubs: every forge read a test does not name is an unexpected call, so a test
  also proves which reads were NOT made.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Loopctl.MockPullRequestSource
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.GitHubActions

  setup :set_mox_from_context
  setup :verify_on_exit!

  @repo "acme/widgets"
  @sha String.duplicate("a", 40)
  @fork_point String.duplicate("b", 40)
  @head_tree String.duplicate("e", 40)
  @base_tree String.duplicate("f", 40)
  @branch "loop/story-7-abcd1234"
  @credential %Credential{kind: :operator_token}

  defp request(extra \\ %{}) do
    Map.merge(
      %{
        repo: @repo,
        branch: @branch,
        base_branch: "master",
        sha: @sha,
        required_checks: ["test"],
        credential: @credential
      },
      extra
    )
  end

  defp compare(files, renames \\ []),
    do:
      {:ok,
       %{
         merge_base_sha: @fork_point,
         base_tree_sha: @base_tree,
         diffstat: %{files: length(files), changed_lines: 3 * length(files)},
         diff: {:ok, %{files: files, renames: renames}}
       }}

  # The change check reads the commit's tree, then compares it with the base.
  defp expect_compare(answer, tree \\ @head_tree) do
    expect_commit({:ok, %{tree_sha: tree, parents: [@fork_point]}})
    expect(MockPullRequestSource, :compare, fn @repo, "master", @sha -> answer end)
  end

  defp expect_commit(answer) do
    expect(MockPullRequestSource, :commit, fn @repo, @sha -> answer end)
  end

  defp job(id, run_id, name, status, conclusion, workflow \\ ".github/workflows/ci.yml") do
    %{
      id: id,
      run_id: run_id,
      name: name,
      status: status,
      conclusion: conclusion,
      workflow: workflow,
      url: "https://evil.example/not-this"
    }
  end

  defp run(id, status, conclusion, workflow \\ ".github/workflows/ci.yml"),
    do: %{id: id, workflow: workflow, status: status, conclusion: conclusion}

  defp evidence(runs, jobs), do: {:ok, %{runs: runs, jobs: jobs, statuses: []}}

  defp stub_evidence(result) do
    expect(MockPullRequestSource, :check_evidence, fn @repo, @sha, @branch -> result end)
  end

  describe "auth_headers/1" do
    test "a present token becomes a bearer header, trimmed" do
      assert GitHubActions.auth_headers("ghp_abc") == [{"authorization", "Bearer ghp_abc"}]
      assert GitHubActions.auth_headers(" ghp_abc\n") == [{"authorization", "Bearer ghp_abc"}]
    end

    test "no token sends no header" do
      assert GitHubActions.auth_headers(nil) == []
    end

    test "a blank token is not a token" do
      for blank <- ["", "   ", "\n"] do
        assert GitHubActions.auth_headers(blank) == [],
               "#{inspect(blank)} produced an Authorization header"
      end
    end
  end

  describe "TC-26.4.6.2 required checks decide" do
    # An unrelated workflow that succeeded is in every one of these: it never passes a run.
    defp lint, do: job(90, 9, "lint", "completed", "success", ".github/workflows/lint.yml")
    defp lint_run, do: run(9, "completed", "success", ".github/workflows/lint.yml")

    test "a required check still running is a wait" do
      stub_evidence(
        evidence([run(5, "in_progress", nil), lint_run()], [
          job(50, 5, "test", "in_progress", nil),
          lint()
        ])
      )

      assert GitHubActions.verdict(request()) == {:wait, :ci_pending}
    end

    test "a required check missing from the commit is a wait, whatever else passed" do
      stub_evidence(evidence([lint_run()], [lint()]))

      assert GitHubActions.verdict(request()) == {:wait, :ci_pending}
    end

    test "a failed required check is a fail naming the failing job inside the repository" do
      stub_evidence(
        evidence([run(5, "completed", "failure"), lint_run()], [
          job(50, 5, "test", "completed", "failure"),
          lint()
        ])
      )

      assert {:fail, evidence} = GitHubActions.verdict(request())
      assert evidence.check == "test"
      assert evidence.conclusion == "failure"
      # Built from the repository and the ids, never echoed from the forge's `url`.
      assert evidence.url == "https://github.com/acme/widgets/actions/runs/5/job/50"
    end

    test "every required check concluded success is a pass pointing at the judged run" do
      stub_evidence(
        evidence([run(5, "completed", "success"), lint_run()], [
          job(50, 5, "test", "completed", "success"),
          lint()
        ])
      )

      assert {:pass, %{url: "https://github.com/acme/widgets/actions/runs/5"}} =
               GitHubActions.verdict(request())
    end

    test "a required check whose run ended with no jobs is a fail on run_<conclusion>" do
      stub_evidence(evidence([run(5, "completed", "startup_failure")], []))

      assert {:fail, %{check: "test", conclusion: "run_startup_failure", url: url}} =
               GitHubActions.verdict(request())

      assert url == "https://github.com/acme/widgets/actions/runs/5"
    end

    # Review round 1, finding 6: a workflow that concluded success (or skipped, or neutral)
    # with no jobs ran nothing and failed nothing, so it is no evidence; and the failing URL
    # points at the run that DID fail the name, never at an unrelated jobless success.
    test "a jobless run that concluded success, skipped or neutral is no evidence" do
      for conclusion <- ["success", "skipped", "neutral"] do
        stub_evidence(evidence([run(5, "completed", conclusion)], []))
        assert GitHubActions.verdict(request()) == {:wait, :ci_pending}, conclusion
      end
    end

    test "the failing URL is the run that died, not a jobless success of another workflow" do
      stub_evidence(
        evidence(
          [
            # `build.yml` sorts before `ci.yml`, so a URL taken from the first completed
            # jobless run would point here.
            run(4, "completed", "success", ".github/workflows/build.yml"),
            run(5, "completed", "startup_failure")
          ],
          []
        )
      )

      assert {:fail, %{conclusion: "run_startup_failure", url: url}} =
               GitHubActions.verdict(request())

      assert url == "https://github.com/acme/widgets/actions/runs/5"
    end

    # #931 finding c: a NEWER run of a workflow that was cancelled or skipped must not hide
    # an OLDER failed run of it by reading as anything but a failure itself.
    test "a newer cancelled run of the workflow is a fail, never a pass over the older failure" do
      stub_evidence(
        evidence(
          [run(5, "completed", "failure"), run(6, "completed", "cancelled")],
          [
            job(50, 5, "test", "completed", "failure"),
            job(60, 6, "test", "completed", "cancelled")
          ]
        )
      )

      assert {:fail, %{conclusion: "cancelled", url: url}} = GitHubActions.verdict(request())
      assert url == "https://github.com/acme/widgets/actions/runs/6/job/60"
    end

    test "a newer skipped run of the workflow is a fail too" do
      stub_evidence(
        evidence(
          [run(5, "completed", "failure"), run(6, "completed", "skipped")],
          [job(50, 5, "test", "completed", "failure"), job(60, 6, "test", "completed", "skipped")]
        )
      )

      assert {:fail, %{conclusion: "skipped"}} = GitHubActions.verdict(request())
    end

    test "only local-gate required is no required checks, and nothing is read" do
      assert GitHubActions.verdict(request(%{required_checks: ["local-gate"]})) ==
               {:refused, "no_required_checks"}
    end
  end

  describe "TC-26.4.6.3 the change check: an empty change and a CI-definition edit are refused" do
    # No `check_evidence` expectation anywhere here: Mox fails any CI read.
    for {label, files} <- [
          {"a workflow edit", [".github/workflows/ci.yml"]},
          {"a composite action", [".github/actions/setup/action.yml"]},
          {"an action.yml anywhere", ["tools/deploy/action.yaml"]}
        ] do
      test "#{label} is ci_definition_changed" do
        expect_compare(compare(unquote(files)))
        assert GitHubActions.check_change(request()) == {:refused, "ci_definition_changed"}
      end
    end

    test "a workflow file renamed away is ci_definition_changed" do
      expect_compare(compare(["ci.yml.bak"], [{".github/workflows/ci.yml", "ci.yml.bak"}]))
      assert GitHubActions.check_change(request()) == {:refused, "ci_definition_changed"}
    end

    test "a diff that could not be listed is ci_definition_unknown" do
      expect_compare(
        {:ok,
         %{
           merge_base_sha: @fork_point,
           base_tree_sha: @base_tree,
           diffstat: %{files: 300, changed_lines: 900},
           diff: {:error, {:file_list_truncated, 300}}
         }}
      )

      assert GitHubActions.check_change(request()) == {:refused, "ci_definition_unknown"}
    end

    # Round 3: an EMPTY three-dot diff is the merge gate's `empty_change`, however the commit
    # got there — an old green commit of the base (its merge base is itself) and an empty
    # commit on top of one (its merge base is its parent) alike.
    test "an empty diff is empty_change, whatever the merge base" do
      for merge_base <- [@sha, @fork_point] do
        expect_compare(
          {:ok,
           %{
             merge_base_sha: merge_base,
             base_tree_sha: @base_tree,
             diffstat: %{files: 0, changed_lines: 0},
             diff: {:ok, %{files: [], renames: []}}
           }}
        )

        assert GitHubActions.check_change(request()) == {:refused, "empty_change"}
      end
    end

    # Round 4, finding 5: the merge gate's rule has two halves, and this is the other one. A
    # head whose tree IS the base's is empty whatever its three-dot diff lists.
    test "a head whose tree is the base's is empty_change, whatever the diff lists" do
      expect_compare(compare(["lib/widgets/thing.ex"]), @base_tree)
      assert GitHubActions.check_change(request()) == {:refused, "empty_change"}
    end

    test "a base tree the forge answered unreadably is forge_unreadable, never a pass" do
      {:ok, comparison} = compare(["lib/widgets/thing.ex"])
      expect_compare({:ok, Map.delete(comparison, :base_tree_sha)})
      assert GitHubActions.check_change(request()) == {:no_verdict, "forge_unreadable"}
    end

    test "a fault reading the commit is classified, and nothing is compared" do
      expect_commit({:error, {:github_api_error, 502}})
      assert GitHubActions.check_change(request()) == {:wait, {:transient, nil}}

      expect_commit({:error, {:github_api_error, 404}})
      assert GitHubActions.check_change(request()) == {:no_verdict, "forge_not_found"}
    end

    test "a change to anything else passes the check, with no CI read" do
      expect_compare(compare(["lib/widgets/thing.ex"]))
      assert GitHubActions.check_change(request()) == :ok
    end

    test "a transient fault on the comparison is a wait, a permanent one a no-verdict" do
      expect_compare({:error, {:github_api_error, 502}})
      assert GitHubActions.check_change(request()) == {:wait, {:transient, nil}}

      expect_compare({:error, {:github_api_error, 404}})
      assert GitHubActions.check_change(request()) == {:no_verdict, "forge_not_found"}
    end

    # The verdict compares nothing: no `compare` expectation, so Mox fails one.
    test "verdict/1 reads only the evidence" do
      stub_evidence(
        evidence([run(5, "completed", "success")], [job(50, 5, "test", "completed", "success")])
      )

      assert {:pass, %{url: "https://github.com/acme/widgets/actions/runs/5"}} =
               GitHubActions.verdict(request())
    end
  end

  describe "classification: the only place that knows GitHub's error terms" do
    test "a 5xx, a timeout and a rate limit are transient waits carrying the forge's delay" do
      for {reason, delay} <- [
            {{:github_api_error, 502}, nil},
            {{:github_unreachable, :timeout}, nil},
            # #931 finding e: a SECONDARY rate limit is a 403 with a retry-after.
            {{:github_rate_limited, 403, 45}, 45},
            {{:github_rate_limited, 429, nil}, nil}
          ] do
        stub_evidence({:error, reason})

        assert GitHubActions.verdict(request()) == {:wait, {:transient, delay}},
               inspect(reason)
      end
    end

    # Round 2, finding 1: a fault on the evidence read is the same wait as one on the
    # comparison, so the worker's streak counts either.
    test "a transient fault on the evidence read is the same wait as one on the comparison" do
      stub_evidence({:error, {:github_api_error, 503}})
      assert GitHubActions.verdict(request()) == {:wait, {:transient, nil}}

      expect_compare({:error, {:github_api_error, 503}})
      assert GitHubActions.check_change(request()) == {:wait, {:transient, nil}}
    end

    test "a permanent answer is a no-verdict code with no number in it" do
      for {reason, code} <- [
            {{:github_api_error, 401}, "forge_unauthorized"},
            {{:github_api_error, 403}, "forge_forbidden"},
            {{:github_api_error, 404}, "forge_not_found"},
            {{:github_api_error, 422}, "forge_unprocessable"},
            {{:github_api_error, 410}, "forge_rejected"},
            {{:too_many_workflow_runs, 11}, "too_many_workflow_runs"},
            # #915 round 3, finding 8: a count is never rendered where a status would be.
            {{:workflow_runs_truncated, 150, 100}, "workflow_runs_truncated"},
            {{:jobs_truncated, 150, 100}, "jobs_truncated"},
            {{:unreadable_workflow_runs, {:list, 1}}, "forge_unreadable"}
          ] do
        stub_evidence({:error, reason})
        assert GitHubActions.verdict(request()) == {:no_verdict, code}, inspect(reason)
      end
    end

    # Measured against GitHub on 2026-09-28: `GET /repos/:r/commits/<ref>` answers 422 "No
    # commit found for SHA" for an unknown prefix and an unknown full id alike, and 404 for a
    # repository that is missing or unreadable.
    test "resolving an abbreviated SHA: 422 unresolved_sha, 404 repository_unreadable" do
      expect(MockPullRequestSource, :resolve_commit, fn @repo, "aaaaaaa" ->
        {:error, {:github_api_error, 422}}
      end)

      assert GitHubActions.resolve_commit(@repo, "aaaaaaa", @credential) ==
               {:no_verdict, "unresolved_sha"}

      expect(MockPullRequestSource, :resolve_commit, fn @repo, "aaaaaaa" ->
        {:error, {:github_api_error, 404}}
      end)

      assert GitHubActions.resolve_commit(@repo, "aaaaaaa", @credential) ==
               {:no_verdict, "repository_unreadable"}

      expect(MockPullRequestSource, :resolve_commit, fn @repo, "aaaaaaa" ->
        {:error, {:github_api_error, 502}}
      end)

      assert GitHubActions.resolve_commit(@repo, "aaaaaaa", @credential) ==
               {:wait, {:transient, nil}}

      expect(MockPullRequestSource, :resolve_commit, fn @repo, "aaaaaaa" -> {:ok, @sha} end)
      assert GitHubActions.resolve_commit(@repo, "aaaaaaa", @credential) == {:ok, @sha}
    end
  end

  test "without an operator credential nothing is read" do
    assert GitHubActions.verdict(request(%{credential: nil})) ==
             {:refused, "credential_unavailable"}

    assert GitHubActions.check_change(request(%{credential: nil})) ==
             {:refused, "credential_unavailable"}

    assert GitHubActions.resolve_commit(@repo, "aaaaaaa", nil) ==
             {:refused, "credential_unavailable"}
  end
end
