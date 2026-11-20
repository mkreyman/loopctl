defmodule LoopctlE2e.CiGreenTest do
  @moduledoc """
  The `ci_green` stage judges the PR branch's push runs the way loopctl's merge gate does
  (`Loopctl.Delivery.CiEvidence`): only each workflow's newest run counts, and a completed run
  passes only with `success`, `skipped` or `neutral`.
  """
  use ExUnit.Case, async: true

  alias LoopctlE2e.{Stages, StubClient}

  @repo "mkreyman/loopctl-e2e-sandbox"
  @ctx %{repo: @repo, pr: 3}
  @pr %{"number" => 3, "head" => %{"ref" => "loop/story-7-abcdef12", "sha" => "h1"}}

  defp ci_green(runs) do
    client =
      StubClient.start(%{
        {:github, :get, "/repos/#{@repo}/pulls/3"} => [{:ok, 200, @pr}],
        {:github, :get, "/repos/#{@repo}/actions/runs"} => [
          {:ok, 200, %{"workflow_runs" => runs}}
        ]
      })

    check = Enum.find(Stages.all(), &(&1.name == :ci_green)).check
    check.(client, @ctx)
  end

  defp run(id, workflow, status, conclusion \\ nil),
    do: %{
      "id" => id,
      "workflow_id" => workflow,
      "name" => "W#{workflow}",
      "status" => status,
      "conclusion" => conclusion
    }

  test "every workflow's newest run succeeding is green" do
    assert {:done, @ctx} =
             ci_green([run(1, 10, "completed", "success"), run(2, 20, "completed", "skipped")])
  end

  test "a run that died at startup fails the stage, as the gate's dead_run? does" do
    assert {:fail, "push runs failed: W10"} =
             ci_green([run(1, 10, "completed", "startup_failure")])
  end

  test "an older failed run a newer run of the same workflow superseded does not count" do
    assert {:done, @ctx} =
             ci_green([run(1, 10, "completed", "failure"), run(2, 10, "completed", "success")])
  end

  test "a newer run still in progress waits even when an older one passed" do
    assert {:wait, "push runs running: W10"} =
             ci_green([run(1, 10, "completed", "success"), run(2, 10, "in_progress")])
  end
end
