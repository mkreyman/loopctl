defmodule LoopctlWeb.StoryLifecycleMarkerTest do
  @moduledoc """
  The backfill anti-launder marker must survive an ordinary story update.

  It first shipped as `metadata["lifecycle_entered_at"]`, and `PATCH
  /api/v1/stories/:id` casts `:metadata` and REPLACES the whole map — so a single
  orchestrator-role request erased the marker and restored the exact launder the
  guard closes: claim -> force-unclaim -> PATCH the marker away -> backfill straight
  to `verified`, with no report, no review record and no independent verifier.

  `stories.lifecycle_entered_at` is a column that appears in no changeset `cast`
  list. These tests walk the whole HTTP path, ending on the backfill refusal —
  asserting the field alone would pass even if the guard stopped reading it.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

    # A story carrying the marker and NOTHING else: no dispatch markers, and no
    # `audit_log` lifecycle rows. `audit_log` is RANGE-partitioned and
    # AuditPartitionWorker DROPs partitions past `:audit_retention_days`, so the audit
    # arm of the backfill guard EXPIRES — this is the shape a long-ago force-unclaim
    # leaves behind, and it is the shape that binds these assertions to the COLUMN.
    # Running an actual force-unclaim here would let the audit rows carry the refusal
    # even if the guard stopped reading the marker entirely. That the three unclaim
    # paths write the column is covered by
    # `Loopctl.Progress.BackfillLifecycleHistoryTest`.
    story =
      fixture(:story, %{tenant_id: tenant.id, agent_status: :pending})
      |> Ecto.Changeset.change(lifecycle_entered_at: ~U[2020-01-01 00:00:00.000000Z])
      |> AdminRepo.update!()

    assert lifecycle_audit_count(story) == 0

    %{tenant: tenant, agent: agent, raw_key: raw_key, story: story}
  end

  defp lifecycle_audit_count(story) do
    from(a in AuditLog,
      where:
        a.tenant_id == ^story.tenant_id and a.entity_id == ^story.id and
          a.action in ["status_changed", "force_unclaimed", "auto_reset"],
      select: count()
    )
    |> AdminRepo.one()
  end

  defp patch_story(raw_key, story, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> patch(~p"/api/v1/stories/#{story.id}", params)
  end

  defp reload(story), do: AdminRepo.get!(Story, story.id)

  test "the marker alone is what refuses the backfill here", ctx do
    assert %DateTime{} = ctx.story.lifecycle_entered_at
    assert {:error, :story_entered_lifecycle} = backfill(ctx.story)
  end

  test "replacing metadata wholesale does not clear the marker", ctx do
    conn = patch_story(ctx.raw_key, ctx.story, %{"metadata" => %{"note" => "clean slate"}})

    assert json_response(conn, 200)["story"]["metadata"] == %{"note" => "clean slate"}

    reloaded = reload(ctx.story)
    assert reloaded.lifecycle_entered_at == ctx.story.lifecycle_entered_at
    assert {:error, :story_entered_lifecycle} = backfill(reloaded)
  end

  test "naming the column directly in the request body does not clear it either", ctx do
    conn =
      patch_story(ctx.raw_key, ctx.story, %{
        "title" => "renamed",
        "lifecycle_entered_at" => nil,
        "metadata" => %{}
      })

    assert json_response(conn, 200)["story"]["title"] == "renamed"

    reloaded = reload(ctx.story)
    assert reloaded.lifecycle_entered_at == ctx.story.lifecycle_entered_at
    assert {:error, :story_entered_lifecycle} = backfill(reloaded)
  end

  test "the update changeset refuses the field even when handed it directly", ctx do
    changeset = Story.update_changeset(ctx.story, %{lifecycle_entered_at: nil, metadata: %{}})

    refute Map.has_key?(changeset.changes, :lifecycle_entered_at)
  end

  test "the create changeset refuses it too, so a story cannot be born pre-marked", _ctx do
    changeset =
      Story.create_changeset(%Story{}, %{
        number: "9.1",
        title: "smuggled",
        lifecycle_entered_at: ~U[2020-01-01 00:00:00.000000Z]
      })

    refute Map.has_key?(changeset.changes, :lifecycle_entered_at)
  end

  defp backfill(story),
    do: Progress.backfill_story(story.tenant_id, story.id, %{"reason" => "pre-loopctl work"})
end
