defmodule Loopctl.Delivery.ItemEventLogTest do
  @moduledoc """
  US-52.16: `story_stage_events` is the work item's whole event log. Every event names its
  holder and carries a reason; `claimed`, `released` and `note_written` sit beside the stage
  events on any story, with or without a stage row.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.EscalationInbox
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Holders
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  defp holder(tenant_id, agent_id, session_id) do
    attrs = %{"kind" => "interactive", "session_id" => session_id, "host" => "minis"}
    {:ok, %{holder: holder}} = Holders.register(tenant_id, agent_id, attrs)
    holder.id
  end

  defp raw_event(attrs) do
    base = %{
      id: Ecto.UUID.generate(),
      event: "transitioned",
      reason: "r",
      data: %{},
      inserted_at: DateTime.utc_now()
    }

    AdminRepo.insert_all(StageEvent, [Map.merge(base, attrs)])
  end

  defp events(tenant_id, story_id),
    do:
      Enum.map(
        Stages.list_events(tenant_id, story_id),
        &{&1.event, &1.actor_holder_id, &1.reason}
      )

  describe "the table's CHECKs (TC-52.16.1)" do
    setup do
      story = fixture(:story, %{})
      %{story: story}
    end

    test "a stage event needs its stage fields, an item event does not", %{story: story} do
      assert_raise Postgrex.Error, ~r/story_stage_events_stage_fields/, fn ->
        raw_event(%{tenant_id: story.tenant_id, story_id: story.id, claim_epoch: 0})
      end

      assert {1, _} =
               raw_event(%{
                 tenant_id: story.tenant_id,
                 story_id: story.id,
                 event: "claimed",
                 claim_epoch: 0
               })
    end

    test "the reason is required, 1..2000 characters", %{story: story} do
      base = %{tenant_id: story.tenant_id, story_id: story.id, event: "claimed", claim_epoch: 0}

      assert_raise Postgrex.Error, ~r/story_stage_events_reason_length/, fn ->
        raw_event(Map.put(base, :reason, ""))
      end

      assert_raise Postgrex.Error, ~r/story_stage_events_reason_length/, fn ->
        raw_event(Map.put(base, :reason, String.duplicate("x", 2001)))
      end

      assert_raise Postgrex.Error, ~r/not_null_violation|null value/, fn ->
        raw_event(Map.put(base, :reason, nil))
      end
    end

    test "the event allow-list takes the item events and nothing unknown", %{story: story} do
      base = %{tenant_id: story.tenant_id, story_id: story.id, claim_epoch: 0}

      for event <- StageEvent.item_events() do
        assert {1, _} = raw_event(Map.put(base, :event, event))
      end

      assert_raise Postgrex.Error, ~r/story_stage_events_event/, fn ->
        raw_event(Map.put(base, :event, "unknown"))
      end
    end
  end

  describe "stage writes carry a reason (TC-52.16.2)" do
    test "the edge's sentence without a reason, the caller's words with one" do
      story = fixture(:stage_story, %{claim_epoch: 1, agent_status: :assigned})

      fixture(:story_stage, %{
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: :queued,
        claim_epoch: 1
      })

      opts = [claim_epoch: 1, actor_label: "t", actor_role: :user, actor_lineage: []]

      assert {:ok, _} = Stages.advance(story.tenant_id, story.id, {:queued, :claimed}, opts)

      assert {:ok, _} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {:claimed, :worktree},
                 Keyword.put(opts, :reason, "placed on x1")
               )

      [first, second] =
        for %StageEvent{event: "transitioned", reason: reason} <-
              Stages.list_events(story.tenant_id, story.id),
            do: reason

      assert first == StageMachine.edge_reason(:forward)
      assert second == "placed on x1"
    end

    test "every edge has a sentence, and the events' fixed reasons cover every event" do
      edges = StageMachine.transitions() |> Enum.map(fn {_, _, edge} -> edge end) |> Enum.uniq()
      assert MapSet.subset?(MapSet.new(edges), MapSet.new(StageMachine.reasoned_edges()))

      assert Map.keys(StageEvent.reasons()) |> Enum.sort() ==
               Enum.sort(StageEvent.stage_events() ++ StageEvent.item_events())
    end

    test "event_reason/3 trims, falls back, and bounds to the column" do
      assert Stages.event_reason("  why  ", "transitioned", :forward) == "why"
      assert Stages.event_reason("   ", "transitioned", :ci_red) == "CI went red"
      assert Stages.event_reason(nil, "opened", nil) == "the stage row was opened"
      long = Stages.event_reason(String.duplicate("é", 2500), "claimed", nil)
      assert String.length(long) == StageEvent.max_reason_length()
    end
  end

  describe "record_item_event/4 (TC-52.16.3)" do
    setup do
      agent = fixture(:agent, %{agent_type: :implementer})
      story = fixture(:story, %{tenant_id: agent.tenant_id})
      %{story: story, h: holder(agent.tenant_id, agent.id, "s1")}
    end

    test "writes on a story with no stage row, replays once, refuses a blank reason", ctx do
      %{story: story, h: h} = ctx
      opts = [reason: "plan set", actor_holder_id: h, idempotency_key: "k1"]

      assert {:ok, %StageEvent{event: "note_written", story_stage_id: nil} = event} =
               Stages.record_item_event(story.tenant_id, story.id, "note_written", opts)

      assert event.actor_holder_id == h
      assert event.claim_epoch == story.claim_epoch

      assert {:ok, :replayed} =
               Stages.record_item_event(story.tenant_id, story.id, "note_written", opts)

      assert [{"note_written", ^h, "plan set"}] = events(story.tenant_id, story.id)

      for blank <- ["", "   ", nil] do
        assert {:error, :reason_required} =
                 Stages.record_item_event(story.tenant_id, story.id, "note_written",
                   reason: blank
                 )
      end
    end

    test "refuses a stage event name and another tenant's holder", %{story: story} do
      assert {:error, :invalid_event} =
               Stages.record_item_event(story.tenant_id, story.id, "transitioned", reason: "x")

      other = fixture(:agent, %{agent_type: :implementer})
      foreign = holder(other.tenant_id, other.id, "s9")

      # On BOTH repos: AdminRepo bypasses RLS, so only the explicit tenant predicate refuses
      # there (a foreign key does not scope a row to its tenant).
      for repo <- [Loopctl.Repo, AdminRepo] do
        assert {:error, :invalid_holder} =
                 Stages.record_item_event(story.tenant_id, story.id, "note_written",
                   reason: "x",
                   actor_holder_id: foreign,
                   repo: repo
                 )
      end

      assert events(story.tenant_id, story.id) == []
    end
  end

  describe "claim and release paths (TC-52.16.4)" do
    setup do
      agent = fixture(:agent, %{agent_type: :implementer})
      orch = fixture(:agent, %{tenant_id: agent.tenant_id, agent_type: :orchestrator})
      story = fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})
      h = holder(agent.tenant_id, agent.id, "s1")
      %{agent: agent, orch: orch, story: story, h: h, tenant_id: agent.tenant_id}
    end

    test "each writes its event in order, naming the holder that acted", ctx do
      %{tenant_id: t, story: story, h: h} = ctx
      as = [agent_id: ctx.agent.id, holder_id: h]

      {:ok, _} = Progress.claim_story(t, story.id, as)
      {:ok, _} = Progress.unclaim_story(t, story.id, as)
      recontract(story)
      {:ok, _} = Progress.claim_story(t, story.id, as)

      {:ok, _} =
        Progress.force_unclaim_story(t, story.id,
          orchestrator_agent_id: ctx.orch.id,
          release_reason: "runner wedged"
        )

      recontract(story)
      {:ok, claimed} = Progress.claim_story(t, story.id, as)
      expire(story)
      {:ok, _} = Progress.reclaim_expired_claim(t, story.id, claimed.claim_epoch)

      assert events(t, story.id) == [
               {"claimed", h, "claimed"},
               {"released", h, "released by holder"},
               {"claimed", h, "claimed"},
               {"released", nil, "force-unclaimed: runner wedged"},
               {"claimed", h, "claimed"},
               {"released", nil, "lease expired"}
             ]

      [_, released | _] =
        for %StageEvent{event: "released"} = e <- Stages.list_events(t, story.id), do: e

      assert released.data["released_holder_id"] == h
    end

    test "force-unclaim without a reason names its cause", ctx do
      %{tenant_id: t, story: story, h: h} = ctx
      {:ok, _} = Progress.claim_story(t, story.id, agent_id: ctx.agent.id, holder_id: h)
      {:ok, _} = Progress.force_unclaim_story(t, story.id, orchestrator_agent_id: ctx.orch.id)

      assert {"released", nil, "force-unclaimed: operator"} = List.last(events(t, story.id))
    end

    test "bulk claim writes one claimed event per story", ctx do
      %{tenant_id: t, story: story, h: h} = ctx
      second = fixture(:story, %{tenant_id: t, agent_status: :contracted})

      {:ok, results} =
        Loopctl.BulkOperations.bulk_claim(t, [story.id, second.id], ctx.agent.id, holder_id: h)

      assert Enum.all?(results, &(&1.status == "success"))

      for s <- [story, second] do
        assert [{"claimed", ^h, "claimed"}] = events(t, s.id)
      end
    end
  end

  describe "transition readers (TC-52.16.5)" do
    test "list_transitions and the inbox see only transitioned rows" do
      %{story: story} = fixture(:escalated_story, %{edge: :runner_lost})

      for {event, reason} <- [{"released", "lease expired"}, {"note_written", "looked at it"}] do
        {:ok, _} = Stages.record_item_event(story.tenant_id, story.id, event, reason: reason)
      end

      assert [%{to: "escalated"}] = Stages.list_transitions(story.tenant_id, story.id)

      {:ok, %{data: [entry]}} = EscalationInbox.list(story.tenant_id)
      assert entry.edge == "runner_lost"
      assert length(Stages.list_events(story.tenant_id, story.id)) == 3
    end
  end

  describe "tenant isolation (TC-52.16.6)" do
    test "another tenant's log is never read or written" do
      a = fixture(:story, %{})
      b = fixture(:story, %{})
      {:ok, _} = Stages.record_item_event(b.tenant_id, b.id, "note_written", reason: "b's")

      assert Stages.list_events(a.tenant_id, b.id) == []

      assert {:error, :not_found} =
               Stages.record_item_event(a.tenant_id, b.id, "note_written", reason: "x")

      assert {:error, :not_found} =
               Stages.record_item_event(a.tenant_id, b.id, "note_written",
                 reason: "x",
                 repo: AdminRepo
               )

      assert [{"note_written", nil, "b's"}] = events(b.tenant_id, b.id)
    end
  end

  defp recontract(story) do
    from(s in Story, where: s.id == ^story.id)
    |> AdminRepo.update_all(set: [agent_status: :contracted])
  end

  defp expire(story) do
    from(s in Story, where: s.id == ^story.id)
    |> AdminRepo.update_all(set: [claimed_until: DateTime.add(DateTime.utc_now(), -60, :second)])
  end
end
