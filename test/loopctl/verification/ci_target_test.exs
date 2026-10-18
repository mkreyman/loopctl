defmodule Loopctl.Verification.CiTargetTest do
  @moduledoc """
  US-26.4.6, AC-26.4.6.1/.2: the repository comes from the intake source and the branch from
  the story's placement — never from `projects.repo_url`. `resolve/4` is the pure half; the
  reads are exercised end to end in `Loopctl.Workers.VerificationRunnerWorkerIntegrationTest`.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Verification.CiTarget

  @source %{repo_full_name: "acme/widgets", base_branch: "main"}
  @required ["test"]

  test "the repository is the intake source's and the base is the placed one" do
    route = %{branch: "loop/x", base_branch: "release"}

    assert {:ok, target} = CiTarget.resolve(@source, @required, route, nil)

    assert target == %{
             repo: "acme/widgets",
             branch: "loop/x",
             base_branch: "release",
             required_checks: ["test"]
           }
  end

  test "a route that recorded no base falls back to the source's base branch" do
    assert {:ok, %{base_branch: "main"}} =
             CiTarget.resolve(
               @source,
               @required,
               %{branch: "b", base_branch: nil},
               nil
             )
  end

  test "the dispatched branch first, then the stage row's branch" do
    assert {:ok, %{branch: "wire"}} =
             CiTarget.resolve(
               @source,
               @required,
               %{branch: "wire", base_branch: nil},
               "stage"
             )

    assert {:ok, %{branch: "stage"}} =
             CiTarget.resolve(
               @source,
               @required,
               %{branch: nil, base_branch: nil},
               "stage"
             )
  end

  test "a story nothing placed on a branch is no_story_branch" do
    for route <- [
          %{branch: nil, base_branch: nil},
          %{branch: "", base_branch: nil}
        ] do
      assert CiTarget.resolve(@source, @required, route, nil) ==
               {:unconfigured, "no_story_branch"}
    end
  end
end
