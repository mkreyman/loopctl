defmodule LoopctlWeb.BulkVerifyCallerLineageTest do
  @moduledoc """
  Bulk verify/reject reach the same terminal `verified`/`rejected` states single-story
  verify does, so they must run the L4 caller comparison against the SAME principal.

  `Loopctl.BulkOperations` falls back to `opts[:actor_id]` when no `:verifier_lineage`
  is supplied, and `LoopctlWeb.AuditContext.from_conn/1` fills that with the
  authenticating key's id — so the two agreed by coincidence, not by construction.
  `:actor_id` is an audit-ATTRIBUTION field: a change to what gets attributed would
  have moved the custody gate with it, silently. The controller now resolves the
  lineage from `conn.assigns.current_api_key.id`, the expression
  `LoopctlWeb.StoryVerificationController` uses.

  These tests drive the real endpoint, so they bind to whatever the controller actually
  resolves rather than to the context function's fallback.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: impl_agent.id})

    # A sub-orchestrator INSIDE the implementer's chain: the shape that must be refused.
    # `create_dispatch/2` mints the dispatch's own api_key and returns it once — that
    # key IS the credential whose lineage the controller resolves server-side.
    {:ok, %{raw_key: sub_key}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :orchestrator,
        agent_id: fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator}).id,
        parent_dispatch_id: impl.id
      })

    # An independently-rooted orchestrator: the shape that IS allowed to certify.
    {:ok, %{raw_key: independent_key}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :orchestrator,
        agent_id: fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator}).id
      })

    story =
      fixture(:story, %{tenant_id: tenant.id, agent_status: :reported_done})
      |> Ecto.Changeset.change(%{
        assigned_agent_id: impl_agent.id,
        implementer_dispatch_id: impl.id
      })
      |> AdminRepo.update!()

    %{tenant: tenant, story: story, sub_key: sub_key, independent_key: independent_key}
  end

  defp bulk(ctx, raw_key, path, story_params) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> post(path, %{"stories" => [Map.put(story_params, "story_id", ctx.story.id)]})
    |> json_response(422)
    |> Map.fetch!("results")
    |> hd()
  end

  defp verify(ctx, raw_key) do
    bulk(ctx, raw_key, ~p"/api/v1/stories/bulk/verify", %{
      "result" => "pass",
      "summary" => "ok"
    })
  end

  defp reject(ctx, raw_key),
    do: bulk(ctx, raw_key, ~p"/api/v1/stories/bulk/reject", %{"reason" => "needs work"})

  test "an orchestrator dispatched under the implementer cannot bulk-verify its work", ctx do
    result = verify(ctx, ctx.sub_key)

    assert result["status"] == "error"
    assert result["reason"] =~ "cannot verify your own implemented work"
  end

  test "an independently-rooted orchestrator clears the custody gate", ctx do
    # The DISCRIMINATING half: if the lineage never reached the gate, BOTH callers
    # would be refused the same way (an unlineaged caller cannot certify
    # dispatch-minted work). Only this case shows the caller's REAL lineage arrived —
    # it clears custody and stops at the NEXT gate, the missing review record.
    result = verify(ctx, ctx.independent_key)

    assert result["status"] == "error"
    assert result["reason"] =~ "no independent review record"
  end

  test "bulk reject takes the caller's lineage too", ctx do
    result = reject(ctx, ctx.sub_key)

    assert result["status"] == "error"
    assert result["reason"] =~ "cannot verify your own implemented work"
  end

  test "tenant isolation: a foreign tenant's story is not verifiable", ctx do
    other = fixture(:tenant, %{trust_tier: :human_anchored})
    foreign = fixture(:story, %{tenant_id: other.id, agent_status: :reported_done})

    result = verify(%{ctx | story: foreign}, ctx.independent_key)

    assert result["status"] == "error"
  end
end
