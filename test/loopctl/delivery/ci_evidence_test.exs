defmodule Loopctl.Delivery.CiEvidenceTest do
  @moduledoc """
  `Loopctl.Delivery.CiEvidence` (US-45.6): what CI said about one commit, judged against the
  required checks. Pure, so every case is a table of evidence and an expected judgement.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.CiEvidence

  defp run(name, status, conclusion \\ nil),
    do: %{name: name, status: status, conclusion: conclusion}

  defp status(context, state), do: %{context: context, state: state}

  defp judge(required, runs, statuses \\ []),
    do: CiEvidence.judge(required, %{check_runs: runs, statuses: statuses})

  test "a completed run concluding success, neutral or skipped passes" do
    for conclusion <- ["success", "neutral", "skipped"] do
      assert %{passed: ["test"], failed: [], pending: [], missing: []} =
               judge(["test"], [run("test", "completed", conclusion)]),
             conclusion
    end
  end

  test "any other conclusion fails, naming it" do
    for conclusion <- ["failure", "cancelled", "timed_out", "action_required", "stale"] do
      assert %{failed: [{"test", ^conclusion}], passed: []} =
               judge(["test"], [run("test", "completed", conclusion)])
    end
  end

  test "a run that has not completed is pending, whatever it concluded so far" do
    for state <- ["queued", "in_progress", "waiting"] do
      assert %{pending: ["test"], passed: [], failed: []} = judge(["test"], [run("test", state)])
    end
  end

  test "a commit status satisfies a required name the check runs do not carry" do
    assert %{passed: ["ci/external"]} =
             judge(["ci/external"], [], [status("ci/external", "success")])

    assert %{pending: ["ci/external"]} =
             judge(["ci/external"], [], [status("ci/external", "pending")])

    assert %{failed: [{"ci/external", "error"}]} =
             judge(["ci/external"], [], [status("ci/external", "error")])
  end

  test "a required name nothing reported is missing" do
    assert %{missing: ["test"], passed: [], pending: [], failed: []} =
             judge(["test"], [run("lint", "completed", "success")])
  end

  # Review round 1, finding 5: only the LATEST result under a name counts, as GitHub's own
  # required-check rule judges it.
  test "among runs of one name the highest id decides, whatever it concluded" do
    old_fail = Map.put(run("test", "completed", "failure"), :id, 1)
    new_pass = Map.put(run("test", "completed", "success"), :id, 2)
    assert %{passed: ["test"], failed: []} = judge(["test"], [new_pass, old_fail])

    rerun = Map.put(run("test", "queued"), :id, 3)
    assert %{pending: ["test"], passed: []} = judge(["test"], [new_pass, rerun])
  end

  test "between a run and a status of one name the later one decides" do
    stale_status = %{context: "test", state: "failure", at: "2026-09-27T09:00:00Z"}

    green_run =
      Map.merge(run("test", "completed", "success"), %{completed_at: "2026-09-27T10:00:00Z"})

    assert %{passed: ["test"]} = judge(["test"], [green_run], [stale_status])

    newer_status = %{stale_status | at: "2026-09-27T11:00:00Z"}
    assert %{failed: [{"test", "failure"}]} = judge(["test"], [green_run], [newer_status])

    # A run with no timestamp was just queued: nothing is newer.
    assert %{pending: ["test"]} = judge(["test"], [run("test", "queued")], [newer_status])
  end

  test "each required name is judged on its own" do
    runs = [run("test", "completed", "success"), run("lint", "completed", "failure")]

    assert %{passed: ["test"], failed: [{"lint", "failure"}], missing: ["dialyzer"]} =
             judge(["test", "lint", "dialyzer"], runs)
  end

  # AC-45.6.2: the local gate is recorded and never satisfies a required check, even when a
  # caller lists it.
  test "local-gate is reported, never looked up as a required check" do
    statuses = [status("local-gate", "success")]

    assert %{local_gate: "success", missing: ["test"], passed: []} =
             judge(["test"], [], statuses)

    assert %{local_gate: "success", passed: [], missing: []} =
             judge(["local-gate"], [], statuses)

    assert CiEvidence.lookup_names(["local-gate", "test"]) == ["test"]
  end

  test "to_record/5 keeps the evidence and the judgement with string keys" do
    evidence = %{
      check_runs: [run("test", "completed", "failure")],
      statuses: [status("local-gate", "success")]
    }

    result = CiEvidence.judge(["test"], evidence)
    record = CiEvidence.to_record("abc", ["test"], evidence, result, ~U[2026-09-27 10:00:00Z])

    assert record["sha"] == "abc"
    # Always six fractional digits, so records order correctly as text.
    assert record["read_at"] == "2026-09-27T10:00:00.000000Z"
    assert record["local_gate"] == "success"
    assert record["failed"] == [%{"name" => "test", "why" => "failure"}]
    assert [%{"name" => "test", "conclusion" => "failure"}] = record["check_runs"]
    assert [%{"context" => "local-gate", "state" => "success"}] = record["statuses"]
  end
end
