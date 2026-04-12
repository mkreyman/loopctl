defmodule LoopctlWeb.TenantAuditKeyControllerTest do
  @moduledoc """
  Tests for US-26.0.2 — public key endpoint and key rotation.
  """

  use LoopctlWeb.ConnCase, async: true

  import Loopctl.Fixtures

  setup :verify_on_exit!

  describe "GET /api/v1/tenants/:id/audit_public_key" do
    test "returns PEM format by default", %{conn: conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/audit_public_key")

      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/x-pem-file"
      body = response(conn, 200)
      assert body =~ "-----BEGIN PUBLIC KEY-----"
      assert body =~ "-----END PUBLIC KEY-----"
      assert body =~ Base.encode64(pub_key)
    end

    test "returns JWK format when Accept header requests it", %{conn: conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})

      conn =
        conn
        |> put_req_header("accept", "application/jwk+json")
        |> get(~p"/api/v1/tenants/#{tenant.id}/audit_public_key")

      assert json_response(conn, 200)["kty"] == "OKP"
      assert json_response(conn, 200)["crv"] == "Ed25519"
      assert json_response(conn, 200)["x"] == Base.url_encode64(pub_key, padding: false)
    end

    test "returns 404 when tenant has no key", %{conn: conn} do
      tenant = fixture(:tenant)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/audit_public_key")

      assert json_response(conn, 404)["error"]["message"] =~ "no audit signing key"
    end

    test "returns 404 for unknown tenant", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenants/#{Ecto.UUID.generate()}/audit_public_key")

      assert json_response(conn, 404)["error"]["message"] =~ "Tenant not found"
    end

    test "endpoint is accessible without authentication", %{conn: _conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})

      # Use a bare conn with no auth headers
      conn =
        Phoenix.ConnTest.build_conn()
        |> get(~p"/api/v1/tenants/#{tenant.id}/audit_public_key")

      assert response(conn, 200) =~ "BEGIN PUBLIC KEY"
    end
  end

  describe "POST /api/v1/tenants/:id/rotate-audit-key" do
    test "requires WebAuthn assertion", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, tenant: tenant, role: :user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{})

      assert json_response(conn, 401)["error"]["code"] == "webauthn_required"
    end

    test "rotates key when assertion is provided", %{conn: conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})
      {raw_key, _api_key} = fixture(:api_key, tenant: tenant, role: :user)

      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
          "webauthn_assertion" => Base.encode64(:crypto.strong_rand_bytes(64))
        })

      resp = json_response(conn, 200)
      assert resp["data"]["tenant_id"] == tenant.id
      assert resp["data"]["audit_signing_public_key"] != Base.encode64(pub_key)
      assert resp["data"]["rotated_at"] != nil
    end

    test "no endpoint exposes the private key" do
      conn = Phoenix.ConnTest.build_conn()

      conn1 = get(conn, "/api/v1/tenants/#{Ecto.UUID.generate()}/audit_private_key")
      assert conn1.status in [404, 400]

      conn2 = get(conn, "/api/v1/admin/tenants/#{Ecto.UUID.generate()}/secrets")
      assert conn2.status in [404, 400]
    end
  end
end
