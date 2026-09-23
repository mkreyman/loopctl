defmodule Loopctl.Delivery.GateAInputTest do
  @moduledoc """
  What Gate A is judged on, resolved from the database (epic 44, US-44.1). Transitions are
  written as `story_stage_events` rows directly, in the order and shape `Loopctl.Delivery.Stages`
  writes them, because the reader's whole job is to interpret that history.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Delivery.GateAInput
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Repo

  defp story do
    story = fixture(:stage_story, %{})
    row = fixture(:story_stage, %{tenant_id: story.tenant_id, story_id: story.id, stage: :ci})
    %{story: story, row: row}
  end

  defp lens(outcome) do
    %{
      "outcome" => outcome,
      "confidence" => "high",
      "escalation_reasons" => [],
      "contradicts" => []
    }
  end

  defp lenses(a, b, c), do: %{"analyst" => lens(a), "architect" => lens(b), "engineer" => lens(c)}

  # One `transitioned` event, `lock_version` rising with each so the reader's order is the
  # order written here.
  defp events(%{story: story, row: row}, transitions) do
    rows =
      transitions
      |> Enum.with_index(1)
      |> Enum.map(fn {{from, to, edge, data}, n} ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: story.tenant_id,
          story_stage_id: row.id,
          story_id: story.id,
          event: "transitioned",
          from_stage: from,
          to_stage: to,
          edge: edge,
          claim_epoch: 0,
          lock_version: n,
          actor_label: "test",
          data: data,
          inserted_at: DateTime.add(~U[2026-09-23 00:00:00.000000Z], n, :second)
        }
      end)

    {:ok, _} = Repo.with_tenant(story.tenant_id, fn -> Repo.insert_all(StageEvent, rows) end)
  end

  describe "persisted lens verdicts" do
    test "the most recent triage verdict's lenses are the input, in lens order" do
      ctx = story()

      fixture(:triage_verdict, %{
        tenant_id: ctx.story.tenant_id,
        story_id: ctx.story.id,
        lens_verdicts: lenses("story", "story", "escalate")
      })

      assert {:persisted_triage, [first, second, third]} =
               GateAInput.for_story(ctx.story.tenant_id, ctx.story.id)

      assert {first["verdict"], second["verdict"], third["verdict"]} ==
               {"story", "story", "escalate"}

      assert first["confidence"] == 0.9
    end

    test "a verdict recorded without lens verdicts is missing" do
      ctx = story()

      fixture(:triage_verdict, %{
        tenant_id: ctx.story.tenant_id,
        story_id: ctx.story.id,
        lens_verdicts: nil
      })

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :missing
    end

    test "a newer verdict supersedes an older one" do
      ctx = story()

      fixture(:triage_verdict, %{
        tenant_id: ctx.story.tenant_id,
        story_id: ctx.story.id,
        lens_verdicts: lenses("story", "story", "story"),
        inserted_at: ~U[2026-09-23 00:00:01.000000Z]
      })

      fixture(:triage_verdict, %{
        tenant_id: ctx.story.tenant_id,
        story_id: ctx.story.id,
        lens_verdicts: lenses("reject", "reject", "reject"),
        inserted_at: ~U[2026-09-23 00:00:02.000000Z]
      })

      assert {:persisted_triage, [%{"verdict" => "reject"} | _]} =
               GateAInput.for_story(ctx.story.tenant_id, ctx.story.id)
    end

    test "a newer INCOMPLETE triage supersedes an older verdict, and is missing" do
      ctx = story()

      fixture(:triage_verdict, %{
        tenant_id: ctx.story.tenant_id,
        story_id: ctx.story.id,
        inserted_at: ~U[2026-09-23 00:00:01.000000Z]
      })

      fixture(:triage_verdict, %{
        tenant_id: ctx.story.tenant_id,
        story_id: ctx.story.id,
        incomplete_reason: "session_crashed",
        inserted_at: ~U[2026-09-23 00:00:02.000000Z]
      })

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :missing
    end

    test "a lens entry that is not an object is missing, never a crash" do
      assert GateAInput.outputs(%{
               "analyst" => "x",
               "architect" => [],
               "engineer" => lens("story")
             }) ==
               nil
    end

    test "a lens map that does not name each lens once is missing, not a partial trio" do
      assert GateAInput.outputs(%{"analyst" => lens("story"), "architect" => lens("story")}) ==
               nil
    end

    test "another tenant's verdict is never read" do
      ctx = story()
      other = story()

      fixture(:triage_verdict, %{
        tenant_id: other.story.tenant_id,
        story_id: ctx.story.id,
        lens_verdicts: lenses("story", "story", "story")
      })

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :missing
    end
  end

  describe "a human resolution" do
    test "of a triage escalation satisfies Gate A" do
      ctx = story()

      events(ctx, [
        {"detected", "triaged", "forward", %{}},
        {"triaged", "escalated", "triage_escalate", %{}},
        {"escalated", "queued", "human_resolution", %{}}
      ])

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :human_resolution
    end

    test "of a merge-gate escalation that named Gate A satisfies it" do
      ctx = story()

      events(ctx, [
        {"triaged", "queued", "forward", %{}},
        {"ci", "escalated", "merge_gate", %{"payload" => %{"gate_a" => true}}},
        {"escalated", "queued", "human_resolution", %{}}
      ])

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :human_resolution
    end

    test "of a merge-gate escalation that did NOT name Gate A does not" do
      ctx = story()

      events(ctx, [
        {"triaged", "queued", "forward", %{}},
        {"ci", "escalated", "merge_gate", %{"payload" => %{"gate_a" => false}}},
        {"escalated", "queued", "human_resolution", %{}}
      ])

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :missing
    end

    test "of an unrelated escalation does not" do
      ctx = story()

      events(ctx, [
        {"triaged", "queued", "forward", %{}},
        {"queued", "escalated", "attempts_exhausted", %{}},
        {"escalated", "queued", "human_resolution", %{}}
      ])

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :missing
    end

    test "of a Gate A escalation still counts after a later unrelated re-queue" do
      ctx = story()

      events(ctx, [
        {"triaged", "escalated", "triage_escalate", %{}},
        {"escalated", "queued", "human_resolution", %{}},
        {"queued", "escalated", "attempts_exhausted", %{}},
        {"escalated", "queued", "human_resolution", %{}}
      ])

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :human_resolution
    end

    test "is superseded by a later triage" do
      ctx = story()

      events(ctx, [
        {"triaged", "escalated", "triage_escalate", %{}},
        {"escalated", "queued", "human_resolution", %{}},
        {"triaged", "queued", "forward", %{}}
      ])

      assert GateAInput.for_story(ctx.story.tenant_id, ctx.story.id) == :missing
    end
  end
end
