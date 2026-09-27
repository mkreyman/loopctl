defmodule Loopctl.Delivery.CiEvidenceTest do
  @moduledoc """
  `Loopctl.Delivery.CiEvidence` (US-45.6): what CI said about one commit, judged against the
  required checks. Pure, so every case is a table of evidence and an expected judgement.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.CiEvidence

  defp run(name, status, conclusion \\ nil),
    do: %{name: name, status: status, conclusion: conclusion, app: "github-actions"}

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

  # Review round 2, finding 1: a status can be posted by the implementer, so it never
  # satisfies a required check; nor does a run some other App created.
  test "a commit status never satisfies a required check, however green or new" do
    statuses = [status("test", "success")]
    assert %{missing: ["test"], passed: []} = judge(["test"], [], statuses)

    failing = Map.put(run("test", "completed", "failure"), :id, 1)
    assert %{failed: [{"test", "failure"}]} = judge(["test"], [failing], statuses)
  end

  test "only a GitHub Actions check run counts" do
    other_app = %{run("test", "completed", "success") | app: "some-other-app"}
    assert %{missing: ["test"], passed: []} = judge(["test"], [other_app])
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
