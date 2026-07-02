defmodule LoopctlWeb.TenantAuditKeyControllerTest do
  @moduledoc """
  Tests for US-26.0.2 — public key endpoint and key rotation.
  """

  use LoopctlWeb.ConnCase, async: true

  import Loopctl.Fixtures

  setup :verify_on_exit!

  # Builds the assertion request object with SEPARATE base64url fields
  # (never one blob reused for all four values — that was the placeholder bug).
  defp assertion_body(challenge_id, credential_id) do
    %{
      "challenge_id" => challenge_id,
      "credential_id" => Base.url_encode64(credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(:crypto.strong_rand_bytes(37), padding: false),
      "signature" => Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
      "client_data_json" => Base.url_encode64(~s({"type":"webauthn.get"}), padding: false)
    }
  end

  describe "GET /api/v1/tenants/:id/audit_public_key" do
    test "returns PEM format by default", %{conn: conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/audit_public_key")

      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/x-pem-file"
      body = response(conn, 200)
      assert body =~ "-----BEGIN PUBLIC KEY-----"
      assert body =~ "-----END PUBLIC KEY-----"
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

    test "returns uniform 404 when tenant has no key", %{conn: conn} do
      tenant = fixture(:tenant)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/audit_public_key")

      assert json_response(conn, 404)["error"]["message"] == "Not found"
    end

    test "returns uniform 404 for unknown tenant", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenants/#{Ecto.UUID.generate()}/audit_public_key")

      # Same message as above — prevents tenant enumeration
      assert json_response(conn, 404)["error"]["message"] == "Not found"
    end

    test "endpoint is accessible without authentication", %{conn: _conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})

      conn =
        Phoenix.ConnTest.build_conn()
        |> get(~p"/api/v1/tenants/#{tenant.id}/audit_public_key")

      assert response(conn, 200) =~ "BEGIN PUBLIC KEY"
    end
  end

  describe "POST /api/v1/tenants/:id/rotate-audit-key" do
    test "requires WebAuthn assertion", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{})

      assert json_response(conn, 401)["error"]["code"] == "webauthn_required"
    end

    test "rejects when caller doesn't own the target tenant", %{conn: conn} do
      tenant_a = fixture(:tenant, %{slug: "owner-a"})

      tenant_b =
        fixture(:tenant, %{
          slug: "owner-b",
          audit_signing_public_key: :crypto.strong_rand_bytes(32)
        })

      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant_a.id, role: :user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant_b.id}/rotate-audit-key", %{
          "webauthn_assertion" => Base.encode64(:crypto.strong_rand_bytes(64))
        })

      assert json_response(conn, 403)["error"]["message"] == "Forbidden"
    end

    test "rotates key via the two-step challenge-bound ceremony", %{conn: conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 0)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)

      Mox.expect(Loopctl.MockWebAuthn, :verify_authentication, fn _payload, _challenge, opts ->
        # Real enrolled credential threaded in — NOT an empty allow list.
        assert [{cred_id, _pub}] = Keyword.fetch!(opts, :allow_credentials)
        assert cred_id == auth.credential_id
        {:ok, %{sign_count: 9}}
      end)

      authed = put_req_header(conn, "authorization", "Bearer #{raw_key}")

      # Step 1: issue a challenge.
      challenge_conn =
        post(authed, ~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})

      challenge_data = json_response(challenge_conn, 200)["data"]
      assert challenge_data["challenge_id"]

      assert Base.url_encode64(auth.credential_id, padding: false) in challenge_data[
               "allowed_credentials"
             ]

      # Step 2: assert against the stored challenge.
      rotate_conn =
        authed
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth.credential_id)
        })

      resp = json_response(rotate_conn, 200)
      assert resp["data"]["tenant_id"] == tenant.id
      assert resp["data"]["audit_signing_public_key"] != Base.encode64(pub_key)
      assert resp["data"]["rotated_at"] != nil
    end

    test "rejects an assertion with no prior stored challenge", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
          "webauthn_assertion" => assertion_body(Ecto.UUID.generate(), auth.credential_id)
        })

      assert json_response(conn, 401)["error"]["code"] == "webauthn_failed"
    end

    test "a challenge is single-use — the second attempt fails", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 0)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      Mox.stub(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)

      Mox.stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 2}}
      end)

      authed = put_req_header(conn, "authorization", "Bearer #{raw_key}")

      challenge_data =
        authed
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      body = assertion_body(challenge_data["challenge_id"], auth.credential_id)

      assert authed
             |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
               "webauthn_assertion" => body
             })
             |> json_response(200)

      # Replaying the same challenge is refused.
      assert authed
             |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
               "webauthn_assertion" => body
             })
             |> json_response(401)
    end

    test "rejects a foreign tenant's credential (tenant isolation)", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      _auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      other = fixture(:tenant, %{slug: "other-ct"})
      foreign_auth = fixture(:root_authenticator, tenant_id: other.id)

      authed = put_req_header(conn, "authorization", "Bearer #{raw_key}")

      challenge_data =
        authed
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      conn =
        post(authed, ~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], foreign_auth.credential_id)
        })

      assert json_response(conn, 401)["error"]["code"] == "webauthn_failed"
    end

    test "rejects sign-counter regression and does NOT rotate", %{conn: conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 20)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      Mox.stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 5}}
      end)

      authed = put_req_header(conn, "authorization", "Bearer #{raw_key}")

      challenge_data =
        authed
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      conn =
        post(authed, ~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth.credential_id)
        })

      assert json_response(conn, 401)["error"]["code"] == "webauthn_failed"

      # Key unchanged.
      {:ok, reloaded} = Loopctl.Tenants.get_tenant(tenant.id)
      assert reloaded.audit_signing_public_key == pub_key
    end

    test "rejects an invalid signature and does NOT rotate", %{conn: conn} do
      pub_key = :crypto.strong_rand_bytes(32)
      tenant = fixture(:tenant, %{audit_signing_public_key: pub_key})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      Mox.stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:error, :invalid_assertion}
      end)

      authed = put_req_header(conn, "authorization", "Bearer #{raw_key}")

      challenge_data =
        authed
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      conn =
        post(authed, ~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth.credential_id)
        })

      assert json_response(conn, 401)["error"]["code"] == "webauthn_failed"

      {:ok, reloaded} = Loopctl.Tenants.get_tenant(tenant.id)
      assert reloaded.audit_signing_public_key == pub_key
    end

    test "rejects agent-role keys", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      agent = fixture(:agent, tenant_id: tenant.id)

      {raw_key, _api_key} =
        fixture(:api_key, tenant_id: tenant.id, agent_id: agent.id, role: :agent)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key", %{
          "webauthn_assertion" => Base.encode64(:crypto.strong_rand_bytes(64))
        })

      assert json_response(conn, 403)
    end

    test "no endpoint exposes the private key" do
      conn = Phoenix.ConnTest.build_conn()

      conn1 = get(conn, "/api/v1/tenants/#{Ecto.UUID.generate()}/audit_private_key")
      assert conn1.status in [404, 400]

      conn2 = get(conn, "/api/v1/admin/tenants/#{Ecto.UUID.generate()}/secrets")
      assert conn2.status in [404, 400]
    end
  end

  describe "POST /api/v1/tenants/:id/rotate-audit-key/challenge" do
    test "issues a challenge for the tenant owner", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})

      data = json_response(conn, 200)["data"]
      assert data["challenge_id"]
      assert data["challenge"] != ""

      assert Base.url_encode64(auth.credential_id, padding: false) in data["allowed_credentials"]
    end

    test "returns 422 when the tenant has no enrolled authenticator", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant.id, role: :user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})

      assert json_response(conn, 422)["error"]["code"] == "no_authenticators"
    end

    test "rejects a caller who does not own the target tenant", %{conn: conn} do
      tenant_a = fixture(:tenant, %{slug: "chal-a"})
      tenant_b = fixture(:tenant, %{slug: "chal-b"})
      _auth = fixture(:root_authenticator, tenant_id: tenant_b.id)
      {raw_key, _api_key} = fixture(:api_key, tenant_id: tenant_a.id, role: :user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant_b.id}/rotate-audit-key/challenge", %{})

      assert json_response(conn, 403)["error"]["message"] == "Forbidden"
    end

    test "rejects agent-role keys", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      agent = fixture(:agent, tenant_id: tenant.id)

      {raw_key, _api_key} =
        fixture(:api_key, tenant_id: tenant.id, agent_id: agent.id, role: :agent)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/tenants/#{tenant.id}/rotate-audit-key/challenge", %{})

      assert json_response(conn, 403)
    end
  end
end
