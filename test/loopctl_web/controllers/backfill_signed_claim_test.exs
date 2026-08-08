defmodule LoopctlWeb.BackfillSignedClaimTest do
  @moduledoc """
  `POST /stories/:id/backfill` reaches the same terminal `verified_status: :verified`
  as `POST /stories/:id/verify`, on a single named work item. Leaving it off the
  §9.3 signed-claim plug left an unsigned route to the outcome the signed profile
  exists to attribute.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Test.CustodyEnrollment
  alias Loopctl.Test.CustodyProfileStub

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    %{raw_key: raw_key, agent_pub: agent_pub, agent_priv: agent_priv} =
      CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id, role: :orchestrator})

    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :pending})

    %{
      tenant: tenant,
      raw_key: raw_key,
      agent_pub: agent_pub,
      agent_priv: agent_priv,
      story: story
    }
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

  test "a VALID signed claim is recorded in the hash-chained audit log (§9.4)", ctx do
    CustodyProfileStub.set_profile(:signed)
    on_exit(fn -> CustodyProfileStub.set_profile(:bearer) end)

    claimed_at = System.system_time(:second)

    claim_sig =
      SignedProfile.sign(
        "ed25519",
        SignedProfile.claim_preimage(
          "ed25519",
          ctx.tenant.id,
          "verify",
          ctx.story.id,
          %{},
          nil,
          claimed_at
        ),
        ctx.agent_priv
      )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{ctx.raw_key}")
      |> post(~p"/api/v1/stories/#{ctx.story.id}/backfill", %{
        "reason" => "pre-loopctl work",
        "claim" => %{
          "alg" => "ed25519",
          "claim_sig" => Base.encode16(claim_sig, case: :lower),
          "claimed_at" => claimed_at
        }
      })

    assert json_response(conn, 200)["story"]["verified_status"] == "verified"

    # Verifying the signature and then dropping it is half a control: the signature
    # evaporates at request end and the resulting `verified` record becomes
    # indistinguishable from one an operator fabricated.
    entry =
      Loopctl.AuditChain.list_entries(ctx.tenant.id, action: "signed_custody_claim").data
      |> Enum.find(&(&1.entity_id == ctx.story.id))

    assert entry, "expected a signed_custody_claim audit-chain entry for backfill"
    assert entry.payload["gate"] == "verify"
    assert entry.payload["agent_pubkey"] == Base.encode16(ctx.agent_pub, case: :lower)
    assert entry.payload["claim_sig"] == Base.encode16(claim_sig, case: :lower)
  end
end
