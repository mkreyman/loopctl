defmodule Loopctl.Progress.BackfillLifecycleHistoryTest do
  @moduledoc """
  Backfill (and its bulk sibling, mark-complete) certifies a story as verified with no
  report, no review record and no independent verifier. The only thing keeping that
  from being a shortcut past the whole custody chain is "this story never entered the
  dispatch lifecycle".

  The dispatch markers alone cannot carry that claim, because one of them is erasable:
  `force_unclaim_story/3` clears `assigned_agent_id`, and a story claimed with a key no
  dispatch minted never gets an `implementer_dispatch_id` either. Two sources remember
  what the story row no longer does: the DURABLE `stories.lifecycle_entered_at` column,
  stamped where the erasure happens, and — only inside the audit retention window — the
  `audit_log` lifecycle entries.

  The marker is a COLUMN and not a `metadata` key because `metadata` is cast by
  `Story.update_changeset/2` and replaced wholesale by `PATCH /api/v1/stories/:id`: one
  ordinary request erased it and handed the launder path back. See
  `LoopctlWeb.StoryLifecycleMarkerTest` for the request-level proof.
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

    test "force-unclaim stamps a DURABLE marker on the story row itself" do
      agent = fixture(:agent, %{agent_type: :implementer})
      story = fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})

      {:ok, _} = Progress.claim_story(story.tenant_id, story.id, agent_id: agent.id)
      {:ok, unclaimed} = Progress.force_unclaim_story(story.tenant_id, story.id)

      assert %DateTime{} = unclaimed.lifecycle_entered_at
    end

    test "agent self-unclaim stamps it too" do
      agent = fixture(:agent, %{agent_type: :implementer})
      story = fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})

      {:ok, _} = Progress.claim_story(story.tenant_id, story.id, agent_id: agent.id)
      {:ok, unclaimed} = Progress.unclaim_story(story.tenant_id, story.id, agent_id: agent.id)

      assert %DateTime{} = unclaimed.lifecycle_entered_at
      assert {:error, :story_entered_lifecycle} = backfill(unclaimed)
    end

    test "the marker alone refuses, with no audit history at all" do
      # `audit_log` is RANGE-partitioned and AuditPartitionWorker DROPs partitions past
      # `:audit_retention_days` (default 90), so the audit arm of the guard EXPIRES: a
      # story force-unclaimed long enough ago reads as never-dispatched again. This is
      # that story — the marker set, not one audit row — and it must still be refused.
      story =
        fixture(:story, %{agent_status: :pending})
        |> Ecto.Changeset.change(lifecycle_entered_at: ~U[2020-01-01 00:00:00.000000Z])
        |> Loopctl.AdminRepo.update!()

      assert {:error, :story_entered_lifecycle} = backfill(story)
    end

    test "the legacy metadata stamp is still honoured" do
      # Stories stamped while the marker lived in `metadata` (and whose metadata was
      # replaced before the migration's backfill ran) must keep being refused. This
      # clause can only make the guard refuse MORE, never less.
      story =
        fixture(:story, %{agent_status: :pending})
        |> Ecto.Changeset.change(metadata: %{"lifecycle_entered_at" => "2020-01-01T00:00:00Z"})
        |> Loopctl.AdminRepo.update!()

      assert is_nil(story.lifecycle_entered_at)
      assert {:error, :story_entered_lifecycle} = backfill(story)
    end

    test "the BULK reject auto-reset stamps it too" do
      # The fourth site that clears assigned_agent_id on a worked story. Without the
      # stamp the guard here rests on `verified_status: :rejected` alone.
      story = fixture(:story, %{agent_status: :reported_done})
      orch = fixture(:agent, %{tenant_id: story.tenant_id, agent_type: :orchestrator})

      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_reject(
          story.tenant_id,
          [%{"story_id" => story.id, "reason" => "not done"}],
          orch.id
        )

      reset = reload(story)
      assert is_nil(reset.assigned_agent_id)
      assert %DateTime{} = reset.lifecycle_entered_at
    end

    test "re-running force-unclaim retro-stamps a worked story already at pending" do
      # The remedy for a story reset before the column existed: its only remaining
      # evidence is an audit entry that expires with its partition, and the idempotent
      # early return made the remedy a no-op. Now it makes that evidence permanent.
      story = fixture(:story, %{agent_status: :pending})
      lifecycle_entry(story, "status_changed")

      {:ok, unclaimed} = Progress.force_unclaim_story(story.tenant_id, story.id)

      assert %DateTime{} = unclaimed.lifecycle_entered_at
    end

    test "re-running force-unclaim does NOT stamp never-dispatched work" do
      # Force-unclaiming a pending story writes its own audit entry; reading that back
      # would let the remedy permanently refuse the backfill it exists to permit.
      story = fixture(:story, %{agent_status: :pending})

      {:ok, _} = Progress.force_unclaim_story(story.tenant_id, story.id)
      {:ok, twice} = Progress.force_unclaim_story(story.tenant_id, story.id)

      # Still refused while the audit entry lives, but NOT stamped — so the refusal
      # expires with the partition instead of becoming permanent.
      assert is_nil(twice.lifecycle_entered_at)
    end

    test "the marker records the FIRST entry, not the latest erasure" do
      agent = fixture(:agent, %{agent_type: :implementer})
      original = ~U[2020-01-01 00:00:00.000000Z]

      story =
        fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})
        |> Ecto.Changeset.change(lifecycle_entered_at: original)
        |> Loopctl.AdminRepo.update!()

      {:ok, _} = Progress.claim_story(story.tenant_id, story.id, agent_id: agent.id)
      {:ok, unclaimed} = Progress.force_unclaim_story(story.tenant_id, story.id)

      assert unclaimed.lifecycle_entered_at == original
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

  describe "ensure_mark_complete_allowed/2 parity" do
    test "the bulk path refuses the same laundered story" do
      story = fixture(:story, %{agent_status: :pending})
      lifecycle_entry(story, "status_changed")

      assert {:error, :story_entered_lifecycle} =
               Progress.ensure_mark_complete_allowed(reload(story), lifecycle_set(story))
    end

    test "the bulk path still allows never-dispatched work" do
      story = imported_reported_done_story()

      assert :ok = Progress.ensure_mark_complete_allowed(reload(story), lifecycle_set(story))
    end

    test "the batch set is one query for the whole batch, not one per story" do
      worked = fixture(:story, %{agent_status: :pending})
      lifecycle_entry(worked, "force_unclaimed")
      untouched = fixture(:story, %{tenant_id: worked.tenant_id, agent_status: :pending})

      set =
        Progress.stories_with_lifecycle_history(worked.tenant_id, [worked.id, untouched.id])

      assert MapSet.member?(set, worked.id)
      refute MapSet.member?(set, untouched.id)
    end
  end

  defp lifecycle_set(story),
    do: Progress.stories_with_lifecycle_history(story.tenant_id, [story.id])

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
