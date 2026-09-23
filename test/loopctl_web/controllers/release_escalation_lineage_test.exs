defmodule LoopctlWeb.ReleaseEscalationLineageTest do
  @moduledoc """
  US-44.4: a claim release that reaches the retry ceiling escalates the story, and entering
  `escalated` writes an entry on the tenant's hash chain. That entry names the principal whose
  release caused it — and the lineage it names must be the caller's, resolved SERVER-SIDE from
  the authenticating key by the controller, never a default.

  Two controllers feed that lineage in: `unclaim` (the agent giving a story back) passes
  `:actor_lineage`, and `reject` passes `:verifier_lineage`, which the auto-reset forwards. These
  tests drive the real endpoints with dispatch-minted keys, so they bind to what the controller
  actually resolves: a dropped lineage would record `[]`, the shape the tenant's own operator key
  writes, on a custody entry that cannot be corrected afterwards.

  `config/test.exs` sets the ceiling to 2 and each story starts with one `runner_lost` on its
  stage row, so the release under test is the one that reaches it.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    # The implementer's OWN dispatch-minted key: the credential whose lineage `unclaim`
    # resolves server-side.
    {:ok, %{dispatch: impl, raw_key: impl_key}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: impl_agent.id})

    # An independently-rooted orchestrator: allowed to reject the implementer's work, and the
    # lineage `reject` must resolve.
    {:ok, %{dispatch: verifier, raw_key: verifier_key}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :orchestrator,
        agent_id: fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator}).id
      })

    %{
      tenant: tenant,
      impl_agent: impl_agent,
      impl: impl,
      impl_key: impl_key,
      verifier: verifier,
      verifier_key: verifier_key
    }
  end

  # A delivery story held by the implementer under its dispatch, its stage row in flight with
  # one counted release already spent — so the next counted release reaches the ceiling of 2.
  defp delivery_story(ctx, agent_status, stage) do
    story =
      fixture(:story, %{tenant_id: ctx.tenant.id, agent_status: agent_status})
      |> Ecto.Changeset.change(%{
        assigned_agent_id: ctx.impl_agent.id,
        implementer_dispatch_id: ctx.impl.id,
        assigned_at: DateTime.utc_now()
      })
      |> AdminRepo.update!()

    fixture(:story_stage, %{
      repo: AdminRepo,
      tenant_id: ctx.tenant.id,
      story_id: story.id,
      stage: stage,
      claim_epoch: story.claim_epoch,
      attempts: %{"runner_lost" => 1}
    })

    story
  end

  defp escalation_entry(ctx, story) do
    AdminRepo.one!(
      from e in Entry,
        where:
          e.tenant_id == ^ctx.tenant.id and e.entity_id == ^story.id and
            e.action == "story_stage_escalated"
    )
  end

  defp stage_of(story), do: AdminRepo.one!(from s in StoryStage, where: s.story_id == ^story.id)

  defp as(raw_key), do: build_conn() |> put_req_header("authorization", "Bearer #{raw_key}")

  test "an agent's unclaim that reaches the ceiling chains the AGENT'S server-resolved lineage",
       ctx do
    story = delivery_story(ctx, :implementing, :implementing)

    as(ctx.impl_key)
    |> post(~p"/api/v1/stories/#{story.id}/unclaim")
    |> json_response(200)

    row = stage_of(story)
    assert row.stage == :escalated
    assert row.escalation_reason =~ "attempts_exhausted: 2 counted releases"

    entry = escalation_entry(ctx, story)
    assert entry.payload["edge"] == "attempts_exhausted"
    assert entry.actor_lineage == ctx.impl.lineage_path
    refute entry.actor_lineage == []
  end

  test "a reject that reaches the ceiling chains the VERIFIER'S server-resolved lineage", ctx do
    story = delivery_story(ctx, :reported_done, :ci)

    as(ctx.verifier_key)
    |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "needs work"})
    |> json_response(200)

    assert AdminRepo.get!(Story, story.id).verified_status == :rejected
    assert stage_of(story).stage == :escalated

    entry = escalation_entry(ctx, story)
    assert entry.payload["edge"] == "attempts_exhausted"
    assert entry.actor_lineage == ctx.verifier.lineage_path
    refute entry.actor_lineage == []
  end

  # The BULK reject path: `BulkOperationsController` resolves `:verifier_lineage`, and
  # `BulkOperations`' own auto-reset hands it to `follow_release/5` — a second, separate
  # forwarding chain from the single-story reject above.
  test "a bulk reject that reaches the ceiling chains the VERIFIER'S server-resolved lineage",
       ctx do
    story = delivery_story(ctx, :reported_done, :ci)

    body =
      as(ctx.verifier_key)
      |> post(~p"/api/v1/stories/bulk/reject", %{
        "stories" => [%{"story_id" => story.id, "reason" => "needs work"}]
      })
      |> json_response(200)

    assert [%{"status" => "success"}] = body["results"]
    assert stage_of(story).stage == :escalated

    entry = escalation_entry(ctx, story)
    assert entry.payload["edge"] == "attempts_exhausted"
    assert entry.actor_lineage == ctx.verifier.lineage_path
    refute entry.actor_lineage == []
  end

  test "tenant isolation: another tenant's key cannot release this tenant's story", ctx do
    story = delivery_story(ctx, :implementing, :implementing)

    other = fixture(:tenant, %{trust_tier: :human_anchored})
    other_agent = fixture(:agent, %{tenant_id: other.id, agent_type: :implementer})

    {:ok, %{raw_key: foreign_key}} =
      Dispatches.create_dispatch(other.id, %{role: :agent, agent_id: other_agent.id})

    conn = as(foreign_key) |> post(~p"/api/v1/stories/#{story.id}/unclaim")
    assert conn.status == 404

    assert stage_of(story).stage == :implementing
    assert AdminRepo.all(from e in Entry, where: e.entity_id == ^story.id) == []
  end
end
