defmodule Loopctl.Progress.StateMachineTest do
  @moduledoc """
  Tests for US-26.3.2 — HATEOAS state machine.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Progress.StateMachine

  defp story(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        agent_status: :pending,
        verified_status: :unverified,
        title: "Test Story",
        acceptance_criteria: [%{"id" => "AC-1", "description" => "test"}]
      },
      overrides
    )
  end

  test "pending story shows contract action" do
    actions = StateMachine.next_actions(story(), :agent)
    assert length(actions) == 1
    assert hd(actions).action == "contract"
  end

  test "contracted story shows claim action" do
    actions = StateMachine.next_actions(story(%{agent_status: :contracted}), :agent)
    assert length(actions) == 1
    assert hd(actions).action == "claim"
  end

  test "assigned story shows start action for agents" do
    actions = StateMachine.next_actions(story(%{agent_status: :assigned}), :agent)
    assert length(actions) == 1
    assert hd(actions).action == "start"
  end

  test "implementing story shows request_review for agents" do
    actions = StateMachine.next_actions(story(%{agent_status: :implementing}), :agent)
    assert length(actions) == 1
    assert hd(actions).action == "request_review"
  end

  test "reported_done story shows verify+reject for orchestrator" do
    actions =
      StateMachine.next_actions(
        story(%{agent_status: :reported_done}),
        :orchestrator
      )

    action_names = Enum.map(actions, & &1.action)
    assert "verify" in action_names
    assert "reject" in action_names
  end

  test "verified story returns empty actions" do
    actions =
      StateMachine.next_actions(
        story(%{agent_status: :reported_done, verified_status: :verified}),
        :orchestrator
      )

    assert actions == []
  end
end
