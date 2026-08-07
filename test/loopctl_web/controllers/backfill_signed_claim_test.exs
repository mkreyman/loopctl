defmodule LoopctlWeb.BackfillSignedClaimTest do
  @moduledoc """
  `POST /stories/:id/backfill` reaches the same terminal `verified_status: :verified`
  as `POST /stories/:id/verify`, on a single named work item. Leaving it off the
  §9.3 signed-claim plug left an unsigned route to the outcome the signed profile
  exists to attribute.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Test.CustodyEnrollment
  alias Loopctl.Test.CustodyProfileStub

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    %{raw_key: raw_key} =
      CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id, role: :orchestrator})

    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :pending})

    %{tenant: tenant, raw_key: raw_key, story: story}
  end

  defp backfill(conn, raw_key, story) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> post(~p"/api/v1/stories/#{story.id}/backfill", %{"reason" => "pre-loopctl work"})
  end

  test "under the bearer default the backfill path is unchanged", ctx do
    conn = backfill(build_conn(), ctx.raw_key, ctx.story)

    assert json_response(conn, 200)["story"]["verified_status"] == "verified"
  end

  test "under the signed profile an enrolled caller must sign the backfill claim", ctx do
    CustodyProfileStub.set_profile(:signed)
    on_exit(fn -> CustodyProfileStub.set_profile(:bearer) end)

    conn = backfill(build_conn(), ctx.raw_key, ctx.story)

    assert json_response(conn, 401)["error"]["code"] == "claim_signature_required"
  end
end
