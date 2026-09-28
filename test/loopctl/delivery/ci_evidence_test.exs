defmodule Loopctl.Delivery.CiEvidenceTest do
  @moduledoc """
  `Loopctl.Delivery.CiEvidence` (US-45.6): what CI said about one commit of a thread, judged
  against the required checks. Pure, so every case is evidence in and a judgement out. The
  jobs here are the ones the adapter already filtered to a push of the thread branch at the
  commit (`GitHubPullRequestSourceTest` pins that filter).
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.CiEvidence

  defp job(name, status, conclusion \\ nil, extra \\ %{}) do
    Map.merge(
      %{
        id: 1,
        name: name,
        status: status,
        conclusion: conclusion,
        run_id: 10,
        workflow: "ci.yml"
      },
      extra
    )
  end

  defp status(context, state), do: %{context: context, state: state}

  defp judge(required, jobs, statuses \\ []),
    do: CiEvidence.judge(required, %{jobs: jobs, statuses: statuses})

  test "a completed job passes only by concluding success" do
    assert %{passed: ["test"], failed: []} =
             judge(["test"], [job("test", "completed", "success")])
  end

  # Review round 1 of #910, finding 1: a job GitHub skipped did not run — a required job
  # skipped because a job it `needs:` failed must never read as green.
  test "any other conclusion fails, skipped and neutral included" do
    for conclusion <- ["skipped", "neutral", "failure", "cancelled", "timed_out"] do
      assert %{failed: [{"test", ^conclusion}], passed: []} =
               judge(["test"], [job("test", "completed", conclusion)])
    end
  end

  test "a job that has not completed is pending" do
    for state <- ["queued", "in_progress", "waiting"] do
      assert %{pending: ["test"], passed: []} = judge(["test"], [job("test", state)])
    end
  end

  test "a required name no trusted job carries is missing, whatever statuses say" do
    assert %{missing: ["test"], passed: []} =
             judge(["test"], [job("lint", "completed", "success")], [status("test", "success")])
  end

  # Per workflow, only its newest run counts; across workflows nothing hides anything.
  test "a newer run of the same workflow supersedes an older one" do
    old = job("test", "completed", "failure", %{id: 1, run_id: 10})
    new = job("test", "completed", "success", %{id: 2, run_id: 11})

    assert %{passed: ["test"]} = judge(["test"], [old, new])
  end

  test "a passing job in one workflow never hides a failing one in another" do
    ci = job("test", "completed", "failure", %{id: 1, run_id: 10, workflow: "ci.yml"})
    lint = job("test", "completed", "success", %{id: 2, run_id: 20, workflow: "lint.yml"})

    assert %{failed: [{"test", "failure"}], passed: []} = judge(["test"], [ci, lint])

    running = job("test", "in_progress", nil, %{id: 3, run_id: 30, workflow: "e2e.yml"})
    green = job("test", "completed", "success", %{id: 4, run_id: 11, workflow: "ci.yml"})
    assert %{pending: ["test"]} = judge(["test"], [green, running])
  end

  # #910 round 2, finding 1: attempts are already collapsed by the `filter=latest` read, so two
  # jobs of one run sharing a name are separate jobs (matrix legs), and every one must pass.
  test "within one run, every job carrying the name must pass" do
    leg_a = job("test", "completed", "failure", %{id: 1})
    leg_b = job("test", "completed", "success", %{id: 2})

    assert %{failed: [{"test", "failure"}], passed: []} = judge(["test"], [leg_a, leg_b])

    assert %{passed: ["test"]} =
             judge(["test"], [%{leg_a | conclusion: "success"}, leg_b])
  end

  # #910 round 3, findings 3 and 4: the newest run of a workflow is taken from the RUNS, so a
  # re-run with no jobs yet holds the name pending, and a run that died before creating any
  # job fails a name no job carries.
  test "a newest run with no jobs yet holds the name pending, over an older run's failure" do
    old_fail = job("test", "completed", "failure", %{run_id: 10})

    runs = [
      %{id: 10, workflow: "ci.yml", status: "completed", conclusion: "failure"},
      %{id: 11, workflow: "ci.yml", status: "queued", conclusion: nil}
    ]

    assert %{pending: ["test"], failed: []} =
             CiEvidence.judge(["test"], %{runs: runs, jobs: [old_fail], statuses: []})
  end

  test "a newest run that ended with no jobs fails a name no job carries" do
    runs = [%{id: 12, workflow: "ci.yml", status: "completed", conclusion: "startup_failure"}]

    assert %{failed: [{"test", "run_startup_failure"}]} =
             CiEvidence.judge(["test"], %{runs: runs, jobs: [], statuses: []})

    # A completed jobless run of ANOTHER workflow does not fail a name some job carries.
    green = job("test", "completed", "success", %{run_id: 13, workflow: "ci.yml"})

    runs = [
      %{id: 13, workflow: "ci.yml", status: "completed", conclusion: "success"},
      %{id: 14, workflow: "lint.yml", status: "completed", conclusion: "startup_failure"}
    ]

    assert %{passed: ["test"]} =
             CiEvidence.judge(["test"], %{runs: runs, jobs: [green], statuses: []})
  end

  # US-26.4.6 review round 1, finding 6: a jobless run that concluded success, skipped or
  # neutral ran nothing and failed nothing (every job's `if:` false, a path filter), so it is
  # no evidence about any name: the name is missing, never failed.
  test "a jobless run that concluded success, skipped or neutral fails nothing" do
    for conclusion <- ["success", "skipped", "neutral"] do
      runs = [%{id: 12, workflow: "ci.yml", status: "completed", conclusion: conclusion}]

      assert %{missing: ["test"], failed: []} =
               CiEvidence.judge(["test"], %{runs: runs, jobs: [], statuses: []}),
             conclusion

      refute CiEvidence.dead_run?(hd(runs)), conclusion
    end

    for conclusion <- ["failure", "cancelled", "timed_out", "action_required", nil] do
      runs = [%{id: 12, workflow: "ci.yml", status: "completed", conclusion: conclusion}]
      expected = "run_" <> (conclusion || "none")

      assert %{failed: [{"test", ^expected}]} =
               CiEvidence.judge(["test"], %{runs: runs, jobs: [], statuses: []})
    end
  end

  test "each required name is judged on its own" do
    jobs = [
      job("test", "completed", "success", %{id: 1}),
      job("lint", "completed", "failure", %{id: 2})
    ]

    assert %{passed: ["test"], failed: [{"lint", "failure"}], missing: ["dialyzer"]} =
             judge(["test", "lint", "dialyzer"], jobs)
  end

  # AC-45.6.2: the local gate is recorded and never satisfies a required check.
  test "local-gate is reported, never looked up as a required check" do
    statuses = [status("local-gate", "success")]

    assert %{local_gate: "success", missing: ["test"], passed: []} = judge(["test"], [], statuses)
    assert %{local_gate: "success", passed: [], missing: []} = judge(["local-gate"], [], statuses)
    assert CiEvidence.lookup_names(["local-gate", "test"]) == ["test"]
  end

  test "statuses that could not be read record local-gate as unread and decide nothing" do
    assert %{local_gate: "unread", passed: ["test"]} =
             judge(["test"], [job("test", "completed", "success")], {:unread, :forbidden})
  end

  test "to_record/5 keeps only what the judgement read, with string keys" do
    evidence = %{
      jobs: [job("test", "completed", "failure"), job("codeql", "completed", "success")],
      statuses: [status("local-gate", "success"), status("other", "success")]
    }

    result = CiEvidence.judge(["test"], evidence)
    record = CiEvidence.to_record("abc", ["test"], evidence, result, ~U[2026-09-27 10:00:00Z])

    assert record["sha"] == "abc"
    # Always six fractional digits, so records order correctly as text.
    assert record["read_at"] == "2026-09-27T10:00:00.000000Z"
    assert record["local_gate"] == "success"
    assert record["failed"] == [%{"name" => "test", "why" => "failure"}]

    assert [%{"name" => "test", "workflow" => "ci.yml", "conclusion" => "failure"}] =
             record["jobs"]
  end
end
