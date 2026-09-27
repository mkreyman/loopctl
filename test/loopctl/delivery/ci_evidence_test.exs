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

  test "a failure anywhere under a name decides it, then anything still running" do
    runs = [run("test", "completed", "success"), run("test", "completed", "failure")]
    assert %{failed: [{"test", "failure"}], passed: []} = judge(["test"], runs)

    runs = [run("test", "completed", "success"), run("test", "in_progress")]
    assert %{pending: ["test"], passed: []} = judge(["test"], runs)
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
    assert record["read_at"] == "2026-09-27T10:00:00Z"
    assert record["local_gate"] == "success"
    assert record["failed"] == [%{"name" => "test", "why" => "failure"}]
    assert [%{"name" => "test", "conclusion" => "failure"}] = record["check_runs"]
    assert [%{"context" => "local-gate", "state" => "success"}] = record["statuses"]
  end
end
