defmodule Loopctl.Verification.CiTargetTest do
  @moduledoc """
  US-26.4.6, AC-26.4.6.1/.2: the repository comes from the intake source and the branch from
  the story's placement — never from `projects.repo_url`. `resolve/5` is the pure half; the
  reads are exercised end to end in `Loopctl.Workers.VerificationRunnerWorkerIntegrationTest`.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Verification.CiTarget
  alias Loopctl.WorkBreakdown.Story

  @story %Story{id: "abcd1234-0000-4000-8000-000000000000", number: 7}
  @source %{repo_full_name: "acme/widgets", base_branch: "main"}
  @required ["test"]

  defp stage(branch), do: %{branch: branch, merge_gate_allowed_sha: nil}

  test "the repository is the intake source's and the base is the placed one" do
    route = %{mode: :pr, branch: "loop/x", base_branch: "release"}

    assert {:ok, target} = CiTarget.resolve(@story, @source, @required, route, nil)

    assert target == %{
             repo: "acme/widgets",
             branch: "loop/x",
             base_branch: "release",
             required_checks: ["test"],
             mode: :pr,
             merge_gate_allowed_sha: nil
           }
  end

  # Round 3: the merge gate's allow comes from the stage row, and `mode` says whether the gate
  # compared the change itself (a thread placement) or not.
  test "the stage row's allow is the commit to judge, and the mode is the placement's" do
    allowed = String.duplicate("c", 40)
    stage = %{branch: "loop/stage", merge_gate_allowed_sha: allowed}

    assert {:ok, %{merge_gate_allowed_sha: ^allowed, mode: :pr}} =
             CiTarget.resolve(
               @story,
               @source,
               @required,
               %{mode: :pr, branch: nil, base_branch: nil},
               stage
             )

    assert {:ok, %{merge_gate_allowed_sha: ^allowed, mode: :thread}} =
             CiTarget.resolve(
               @story,
               @source,
               @required,
               %{mode: :thread, branch: "loop/wire", base_branch: nil},
               stage
             )

    # A claim with no accepted dispatch (mode nil) is judged as a pull request.
    assert {:ok, %{mode: :pr}} =
             CiTarget.resolve(
               @story,
               @source,
               @required,
               %{mode: nil, branch: "b", base_branch: nil},
               nil
             )
  end

  test "a route that recorded no base falls back to the source's base branch" do
    assert {:ok, %{base_branch: "main"}} =
             CiTarget.resolve(
               @story,
               @source,
               @required,
               %{mode: :pr, branch: "b", base_branch: nil},
               nil
             )
  end

  test "pr mode: the dispatched branch first, then the stage row's branch" do
    assert {:ok, %{branch: "wire"}} =
             CiTarget.resolve(
               @story,
               @source,
               @required,
               %{mode: :pr, branch: "wire", base_branch: nil},
               stage("stage")
             )

    assert {:ok, %{branch: "stage"}} =
             CiTarget.resolve(
               @story,
               @source,
               @required,
               %{mode: :pr, branch: nil, base_branch: nil},
               stage("stage")
             )
  end

  test "a story nothing placed on a branch is no_story_branch" do
    for route <- [
          %{mode: nil, branch: nil, base_branch: nil},
          %{mode: :pr, branch: "", base_branch: nil}
        ] do
      assert CiTarget.resolve(@story, @source, @required, route, nil) ==
               {:unconfigured, "no_story_branch"}
    end
  end

  test "thread mode: exactly DispatchPayload.thread_branch/3" do
    for {route, stage} <- [
          {%{mode: :thread, branch: "loop/wire", base_branch: nil}, "loop/stage"},
          {%{mode: :thread, branch: nil, base_branch: nil}, "loop/stage"},
          {%{mode: :thread, branch: nil, base_branch: nil}, nil}
        ] do
      {:ok, expected} = DispatchPayload.thread_branch(route, @story, stage)

      assert {:ok, %{branch: ^expected}} =
               CiTarget.resolve(@story, @source, @required, route, stage && stage(stage))
    end
  end
end
