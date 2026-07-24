defmodule LoopctlWeb.Plugs.RequireSignedClaimTest do
  @moduledoc """
  LCP-1 §9.3 pre-gate plug: verifies the conn → policy wiring and the 401 halt.
  Uses the process-dictionary profile stub (async-safe) to force `signed`.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Test.CustodyEnrollment
  alias Loopctl.Test.CustodyProfileStub
  alias LoopctlWeb.Plugs.RequireSignedClaim

  @work "99999999-9999-9999-9999-999999999999"

  setup do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    %{dispatch: dispatch, agent_priv: priv} =
      CustodyEnrollment.enroll_root(tenant.id, %{agent_id: agent.id})

    %{tenant: tenant, dispatch: dispatch, priv: priv}
  end

  defp conn_with(%{tenant: tenant, dispatch: dispatch}, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.assign(:current_api_key, %{id: dispatch.api_key_id, tenant_id: tenant.id})
    |> Map.put(:params, Map.merge(%{"id" => @work, "capability" => "cap-1"}, params))
  end

  defp signed_claim(tenant_id, priv) do
    # `claimed_at` is enforced against a bounded freshness window (§9.3), so sign a
    # CURRENT timestamp rather than a fixed epoch — the same value goes into both the
    # preimage and the wire claim.
    claimed_at = System.os_time(:second)

    preimage =
      SignedProfile.claim_preimage(
        "ed25519",
        tenant_id,
        "verify",
        @work,
        %{},
        "cap-1",
        claimed_at
      )

    sig = SignedProfile.sign("ed25519", preimage, priv)

    %{
      "alg" => "ed25519",
      "claim_sig" => Base.encode16(sig, case: :lower),
      "claimed_at" => claimed_at
    }
  end

  test "under bearer (default), the plug is a no-op even for an enrolled caller", ctx do
    conn = RequireSignedClaim.call(conn_with(ctx, %{}), RequireSignedClaim.init(gate: "verify"))
    refute conn.halted
  end

  test "under signed, an enrolled caller with no signature is halted 401", ctx do
    CustodyProfileStub.set_profile(:signed)
    conn = RequireSignedClaim.call(conn_with(ctx, %{}), RequireSignedClaim.init(gate: "verify"))

    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "claim_signature_required"
  end

  test "under signed, an enrolled caller with a valid signature passes", ctx do
    CustodyProfileStub.set_profile(:signed)
    claim = signed_claim(ctx.tenant.id, ctx.priv)

    conn =
      RequireSignedClaim.call(
        conn_with(ctx, %{"claim" => claim}),
        RequireSignedClaim.init(gate: "verify")
      )

    refute conn.halted
  end

  test "under signed, a valid signature for the WRONG gate is halted 401", ctx do
    CustodyProfileStub.set_profile(:signed)
    # signed_claim binds gate "verify"; present it at a plug mounted for "report"
    claim = signed_claim(ctx.tenant.id, ctx.priv)

    conn =
      RequireSignedClaim.call(
        conn_with(ctx, %{"claim" => claim}),
        RequireSignedClaim.init(gate: "report")
      )

    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "invalid_claim_signature"
  end

  test "init/1 rejects an unknown gate" do
    assert_raise RuntimeError, fn -> RequireSignedClaim.init(gate: "bogus") end
  end
end
