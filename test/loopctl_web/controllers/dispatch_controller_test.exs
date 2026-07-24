defmodule LoopctlWeb.DispatchControllerTest do
  @moduledoc """
  LCP-1 §9.2 enrollment-attestation error mapping: each distinct failure gets its
  own status + stable code so a client's recovery differs (register an owner key
  vs fix the attestation vs supply one), never one opaque 422.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Test.CustodyEnrollment

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # The :create action is orchestrator-role + human-anchored.
  defp orchestrator_ctx do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    %{tenant: tenant, raw_key: raw_key, agent: agent}
  end

  describe "POST /api/v1/dispatches — attestation errors" do
    test "enrolling an agent key with no owner key registered is 409 owner_key_not_registered",
         %{conn: conn} do
      %{raw_key: raw_key, agent: agent} = orchestrator_ctx()
      {pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => agent.id,
          "agent_pubkey" => Base.encode16(pub, case: :lower),
          "alg" => "ed25519",
          "attestation" => Base.encode16(:crypto.strong_rand_bytes(64), case: :lower)
        })

      assert json_response(conn, 409)["error"]["code"] == "owner_key_not_registered"
    end

    test "enrolling an agent key with no attestation is 422 attestation_required", %{conn: conn} do
      %{tenant: tenant, raw_key: raw_key, agent: agent} = orchestrator_ctx()
      CustodyEnrollment.ensure_owner_key(tenant.id)
      {pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => agent.id,
          "agent_pubkey" => Base.encode16(pub, case: :lower),
          "alg" => "ed25519"
        })

      assert json_response(conn, 422)["error"]["code"] == "attestation_required"
    end

    test "an undecodable attestation is 422 malformed_attestation_encoding", %{conn: conn} do
      %{tenant: tenant, raw_key: raw_key, agent: agent} = orchestrator_ctx()
      CustodyEnrollment.ensure_owner_key(tenant.id)
      {pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => agent.id,
          "agent_pubkey" => Base.encode16(pub, case: :lower),
          "alg" => "ed25519",
          "attestation" => "nothex!!"
        })

      assert json_response(conn, 422)["error"]["code"] == "malformed_attestation_encoding"
    end

    test "an attestation that does not verify is 422 attestation_invalid", %{conn: conn} do
      %{tenant: tenant, raw_key: raw_key, agent: agent} = orchestrator_ctx()
      CustodyEnrollment.ensure_owner_key(tenant.id)
      {pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => agent.id,
          "agent_pubkey" => Base.encode16(pub, case: :lower),
          "alg" => "ed25519",
          # 64 valid hex bytes, but not a real attestation signature.
          "attestation" => Base.encode16(:crypto.strong_rand_bytes(64), case: :lower)
        })

      assert json_response(conn, 422)["error"]["code"] == "attestation_invalid"
    end

    test "a bearer dispatch (no agent key) still enrolls with 201", %{conn: conn} do
      %{raw_key: raw_key, agent: agent} = orchestrator_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/dispatches", %{"role" => "agent", "agent_id" => agent.id})

      assert json_response(conn, 201)["data"]["dispatch"]["role"] == "agent"
    end
  end
end
