defmodule Loopctl.DeliveryGates.Measurement.GateAReplayTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates.Measurement.GateAReplay
  alias Loopctl.DeliveryGates.Measurement.Ticket

  # No tenant: the harness is pure and reads no database.

  defp ticket(attrs) do
    {:ok, ticket} = attrs |> then(&build(:measurement_ticket, &1)) |> Ticket.parse()
    ticket
  end

  describe "the reconstructed trio" do
    test "is three IDENTICAL outputs, because disagreement is unobservable in a replay" do
      replay = GateAReplay.replay(ticket([]))

      assert [one, two, three] = replay.trio
      assert one == two and two == three
    end

    test "carries an empty contradicts by construction" do
      replay = GateAReplay.replay(ticket([]))

      assert Enum.all?(replay.trio, &(&1["contradicts"] == []))
    end

    test "carries confidence as a 0.0 placeholder the gate never reads" do
      replay = GateAReplay.replay(ticket([]))

      assert Enum.all?(replay.trio, &(&1["confidence"] == 0.0))
      assert replay.result.confidences == [0.0, 0.0, 0.0]
    end
  end

  describe "escalation" do
    test "an intake [Bug] ticket with no inversion phrase proceeds" do
      replay = GateAReplay.replay(ticket([]))

      refute GateAReplay.escalated?(replay)
      assert replay.result.decision == :proceed
      assert replay.result.verdict == :story
    end

    test "an intake [Feature] ticket escalates as a workflow change" do
      replay =
        GateAReplay.replay(
          ticket(%{"title" => "[Feature] Acme Homecare: add a diagnosis column"})
        )

      assert GateAReplay.escalated?(replay)
      assert {:workflow_change, _index} = hd(replay.result.reasons)
    end

    test "an inversion phrase escalates" do
      replay =
        GateAReplay.replay(
          ticket(%{"body" => "We no longer want the date stamp on printed documents."})
        )

      assert GateAReplay.escalated?(replay)
      assert Enum.any?(replay.result.reasons, &match?({:inverts_deliberate_behaviour, _}, &1))
    end

    test "an enhancement LABEL escalates a non-intake ticket" do
      replay =
        GateAReplay.replay(
          ticket(%{"title" => "Report builder for caregivers", labels: ["enhancement"]})
        )

      assert GateAReplay.escalated?(replay)
    end

    test "a bug label alongside enhancement is a defect fix, not a workflow change" do
      replay =
        GateAReplay.replay(
          ticket(%{"title" => "Report builder is broken", labels: ["enhancement", "bug"]})
        )

      refute GateAReplay.escalated?(replay)
    end

    test "an intake [Bug] ticket is a defect report whatever labels were applied later" do
      # The prefix is stamped at FILING time; a label often is not. The intake stratum exists
      # precisely so the classification carries no hindsight.
      replay = GateAReplay.replay(ticket(%{labels: ["enhancement"]}))

      refute GateAReplay.escalated?(replay)
    end
  end

  describe "not_story?/1" do
    test "a ticket closed as not-planned reconstructs to a unanimous reject, which PROCEEDS" do
      replay = GateAReplay.replay(ticket(%{"stateReason" => "NOT_PLANNED"}))

      refute GateAReplay.escalated?(replay)
      assert GateAReplay.not_story?(replay)
      assert replay.result.verdict == :reject
    end

    test "a completed ticket is a story" do
      refute GateAReplay.not_story?(GateAReplay.replay(ticket([])))
    end
  end

  describe "suppress: the one judgement call, run both ways" do
    test "suppressing request_shaped? removes the workflow-change escalation" do
      feature = ticket(%{"title" => "[Feature] Acme Homecare: add a diagnosis column"})

      assert GateAReplay.escalated?(GateAReplay.replay(feature))
      refute GateAReplay.escalated?(GateAReplay.replay(feature, suppress: [:request_shaped?]))
    end

    test "suppressing it leaves the inversion trigger alone" do
      inverting =
        ticket(%{
          "title" => "[Feature] Acme Homecare: remove the option to print",
          "body" => "We no longer want it."
        })

      replay = GateAReplay.replay(inverting, suppress: [:request_shaped?])

      assert GateAReplay.escalated?(replay)
      assert Enum.all?(replay.result.reasons, &match?({:inverts_deliberate_behaviour, _}, &1))
    end

    test "suppressing an unknown signal raises rather than silently doing nothing" do
      assert_raise KeyError, fn ->
        GateAReplay.replay(ticket([]), suppress: [:no_such_signal])
      end
    end
  end
end
