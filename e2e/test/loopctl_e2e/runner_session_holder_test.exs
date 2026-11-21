defmodule LoopctlE2e.RunnerSessionHolderTest do
  @moduledoc "TC-52.20.5's judgement: the placed story's holder is its runner's session."
  use ExUnit.Case, async: true

  alias LoopctlE2e.Stages

  @row %{"stage" => "implementing", "runner_name" => "x1"}
  @uuid "0b7c3f9e-2a41-4c8d-9e57-1f2a3b4c5d6e"

  defp holder(overrides),
    do: Map.merge(%{"kind" => "runner_session", "host" => "x1", "session_id" => @uuid}, overrides)

  test "a runner_session holder on the placed runner with a launched uuid passes" do
    assert Stages.judge_holder(holder(%{}), @row) == :done
  end

  test "before the runner accepts, the session id is the placement's and the stage waits" do
    assert {:wait, _} = Stages.judge_holder(holder(%{"session_id" => "dispatch:abc"}), @row)
    assert {:wait, _} = Stages.judge_holder(nil, @row)
  end

  test "another kind of holder, or another host, fails" do
    assert {:fail, "the placed story is held by a interactive holder"} =
             Stages.judge_holder(holder(%{"kind" => "interactive"}), @row)

    assert {:fail, _} = Stages.judge_holder(holder(%{"host" => "minis"}), @row)
  end
end
