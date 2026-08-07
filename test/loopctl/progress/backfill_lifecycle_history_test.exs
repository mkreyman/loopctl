defmodule Loopctl.Progress.BackfillLifecycleHistoryTest do
  @moduledoc """
  Backfill (and its bulk sibling, mark-complete) certifies a story as verified with no
  report, no review record and no independent verifier. The only thing keeping that
  from being a shortcut past the whole custody chain is "this story never entered the
  dispatch lifecycle".

  The dispatch markers alone cannot carry that claim, because one of them is erasable:
  `force_unclaim_story/3` clears `assigned_agent_id`, and a story claimed with a key no
  dispatch minted never gets an `implementer_dispatch_id` either. The append-only audit
  log remembers what the story row no longer does.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Progress

  setup :verify_on_exit!

  defp backfill(story) do
    Progress.backfill_story(story.tenant_id, story.id, %{"reason" => "pre-loopctl work"})
  end

  defp lifecycle_entry(story, action) do
    fixture(:audit_log, %{
      tenant_id: story.tenant_id,
      entity_type: "story",
      entity_id: story.id,
      action: action
    })
  end

  describe "backfill_story/4 with lifecycle history" do
    test "refuses a story with a status_changed entry even when every marker is clear" do
      story = fixture(:story, %{agent_status: :pending})
      lifecycle_entry(story, "status_changed")

      assert {:error, :story_entered_lifecycle} = backfill(story)
    end

    test "refuses a story that was force-unclaimed back to pending" do
      story = fixture(:story, %{agent_status: :pending})
      lifecycle_entry(story, "force_unclaimed")

      assert {:error, :story_entered_lifecycle} = backfill(story)
    end

    test "the claim -> force-unclaim -> backfill route is closed end to end" do
      agent = fixture(:agent, %{agent_type: :implementer})
      story = fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})

      {:ok, _} = Progress.claim_story(story.tenant_id, story.id, agent_id: agent.id)
      {:ok, unclaimed} = Progress.force_unclaim_story(story.tenant_id, story.id)

      # Every dispatch marker is clear again — state alone can no longer tell this
      # apart from work that predates loopctl.
      assert unclaimed.agent_status == :pending
      assert is_nil(unclaimed.assigned_agent_id)
      assert is_nil(unclaimed.implementer_dispatch_id)
      assert is_nil(unclaimed.verifier_dispatch_id)

      assert {:error, :story_entered_lifecycle} = backfill(unclaimed)
    end

    test "still allows never-dispatched imported work at reported_done" do
      story = imported_reported_done_story()
      # Creation/import actions are not lifecycle actions — this is the case backfill
      # exists for and it must keep working.
      lifecycle_entry(story, "created")
      lifecycle_entry(story, "imported")

      assert {:ok, backfilled} = backfill(story)
      assert backfilled.verified_status == :verified
    end

    test "still allows a plain pending story with no history at all" do
      story = fixture(:story, %{agent_status: :pending})

      assert {:ok, backfilled} = backfill(story)
      assert backfilled.verified_status == :verified
    end

    test "tenant isolation: another tenant's lifecycle entry does not block this story" do
      story = fixture(:story, %{agent_status: :pending})
      other_tenant = fixture(:tenant)

      # Same entity_id, different tenant. A guard that forgot to scope by tenant would
      # refuse this backfill.
      fixture(:audit_log, %{
        tenant_id: other_tenant.id,
        entity_type: "story",
        entity_id: story.id,
        action: "status_changed"
      })

      assert {:ok, backfilled} = backfill(story)
      assert backfilled.verified_status == :verified
    end
  end

  describe "ensure_mark_complete_allowed/1 parity" do
    test "the bulk path refuses the same laundered story" do
      story = fixture(:story, %{agent_status: :pending})
      lifecycle_entry(story, "status_changed")

      assert {:error, :story_entered_lifecycle} =
               Progress.ensure_mark_complete_allowed(reload(story))
    end

    test "the bulk path still allows never-dispatched work" do
      story = imported_reported_done_story()

      assert :ok = Progress.ensure_mark_complete_allowed(reload(story))
    end
  end

  # Work imported with `initial_agent_status: "reported_done"` and no agent: the shape
  # backfill/mark-complete exists to remediate. The story fixture auto-assigns an agent
  # for :reported_done, which is the ever-dispatched shape, so build it directly (the
  # DB CHECK is satisfied because `implementer_dispatch_id` is NULL).
  defp imported_reported_done_story do
    fixture(:story, %{agent_status: :pending})
    |> Ecto.Changeset.change(agent_status: :reported_done)
    |> Loopctl.AdminRepo.update!()
  end

  defp reload(story), do: Loopctl.AdminRepo.get!(Loopctl.WorkBreakdown.Story, story.id)
end
