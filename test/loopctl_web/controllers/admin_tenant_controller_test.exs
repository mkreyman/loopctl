defmodule LoopctlWeb.AdminTenantControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Audit
  alias Loopctl.AuditChain
  alias Loopctl.Tenants
  alias Loopctl.WebAuthn.Reauth

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Builds the assertion request object with SEPARATE base64url fields — the
  # crypto-01 shape consumed by Reauth.verify_and_consume/3 (never one blob
  # reused for all four values, which was the placeholder bug).
  defp assertion_body(challenge_id, credential_id) do
    %{
      "challenge_id" => challenge_id,
      "credential_id" => Base.url_encode64(credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(:crypto.strong_rand_bytes(37), padding: false),
      "signature" => Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
      "client_data_json" => Base.url_encode64(~s({"type":"webauthn.get"}), padding: false)
    }
  end

  describe "GET /api/v1/admin/tenants" do
    test "lists tenants with stats for superadmin", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant_a = fixture(:tenant, %{name: "Alpha Tenant", status: :active})
      _tenant_b = fixture(:tenant, %{name: "Beta Tenant", status: :suspended})

      # Create resources for tenant_a
      fixture(:project, %{tenant_id: tenant_a.id})
      fixture(:agent, %{tenant_id: tenant_a.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants")

      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["meta"]["total_count"] >= 2

      alpha = Enum.find(body["data"], &(&1["name"] == "Alpha Tenant"))
      beta = Enum.find(body["data"], &(&1["name"] == "Beta Tenant"))

      assert alpha["project_count"] == 1
      assert alpha["agent_count"] == 1
      assert alpha["status"] == "active"

      assert beta["project_count"] == 0
      assert beta["agent_count"] == 0
      assert beta["status"] == "suspended"

      # Verify expected fields
      for field <-
            ~w(id name slug email status project_count story_count agent_count api_key_count inserted_at) do
        assert Map.has_key?(alpha, field), "Missing field: #{field}"
      end
    end

    test "filters tenants by status", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      fixture(:tenant, %{name: "Active One", status: :active})
      fixture(:tenant, %{name: "Suspended One", status: :suspended})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants?status=suspended")

      body = json_response(conn, 200)

      names = Enum.map(body["data"], & &1["name"])
      assert "Suspended One" in names
      refute "Active One" in names
    end

    test "searches tenants by name or slug", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      fixture(:tenant, %{name: "Findme Corp"})
      fixture(:tenant, %{name: "Other Corp"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants?search=findme")

      body = json_response(conn, 200)
      assert body["data"] != []

      assert Enum.all?(body["data"], fn t ->
               String.contains?(String.downcase(t["name"]), "findme")
             end)
    end

    test "paginates results", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      for i <- 1..5 do
        fixture(:tenant, %{name: "Paginated Tenant #{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["page"] == 1
      assert body["meta"]["page_size"] == 2
      assert body["meta"]["total_count"] >= 5
    end

    test "non-superadmin gets 403", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants")

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/admin/tenants/:id" do
    test "returns tenant detail with full stats", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{name: "Detail Tenant"})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants/#{tenant.id}")

      body = json_response(conn, 200)
      t = body["tenant"]

      assert t["id"] == tenant.id
      assert t["name"] == "Detail Tenant"
      assert t["project_count"] == 1
      assert t["epic_count"] == 1
      assert t["story_count"] == 1
      assert Map.has_key?(t, "settings")
      assert Map.has_key?(t, "updated_at")
    end

    test "returns 404 for non-existent tenant", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/admin/tenants/:id" do
    test "updates tenant with partial settings merge", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{settings: %{"max_webhooks" => 10, "max_projects" => 50}})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{
          "settings" => %{"max_webhooks" => 20}
        })

      body = json_response(conn, 200)
      t = body["tenant"]

      assert t["settings"]["max_webhooks"] == 20
      assert t["settings"]["max_projects"] == 50
    end

    test "updates tenant name", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{name: "Old Name"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{"name" => "New Name"})

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "New Name"
    end

    # rls-02: the superadmin update path shares Tenant.update_changeset via
    # update_tenant_admin/2, so slug must be immutable here too. Guards the
    # security-critical admin route against a future regression.
    test "ignores attempts to change slug (rls-02)", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{slug: "keep-slug", name: "Old Name"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{
          "slug" => "hijacked-slug",
          "name" => "New Name"
        })

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "New Name"
      assert body["tenant"]["slug"] == "keep-slug"
    end

    # rls-03: colliding with another tenant's email must return 422, not 500
    # (a 500 would be a cross-tenant email-enumeration oracle).
    test "returns 422 (not 500) on duplicate email (rls-03)", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      _other = fixture(:tenant, %{email: "taken@example.com"})
      tenant = fixture(:tenant, %{email: "mine@example.com"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{"email" => "taken@example.com"})

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert body["error"]["details"] == %{"email" => ["has already been taken"]}
    end

    test "creates audit log entry on update", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{name: "Audit Target"})

      conn
      |> auth_conn(raw_key)
      |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{"name" => "Updated Name"})

      {:ok, result} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_updated")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.actor_type == "superadmin"
      assert entry.actor_id == api_key.id
    end
  end

  describe "POST /api/v1/admin/tenants/:id/suspend" do
    test "suspends an active tenant", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      body = json_response(conn, 200)
      assert body["tenant"]["status"] == "suspended"
    end

    test "suspending already-suspended tenant returns 422", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      body = json_response(conn, 422)
      assert body["error"]["message"] == "Tenant is already suspended"
    end

    test "suspended tenant's API key gets 403", %{conn: conn} do
      {sa_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})
      {tenant_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Suspend
      conn
      |> auth_conn(sa_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      # Tenant's own API call should return 403
      conn2 =
        build_conn()
        |> auth_conn(tenant_key)
        |> get(~p"/api/v1/tenants/me")

      body = json_response(conn2, 403)
      assert body["error"]["message"] == "Access denied"
    end

    test "creates audit log entry for suspension", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      {:ok, result} = Audit.list_entries(tenant.id, action: "tenant_suspended")
      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.actor_type == "superadmin"
      assert entry.actor_id == api_key.id
      assert entry.entity_type == "tenant"
    end
  end

  describe "POST /api/v1/admin/tenants/:id/activate" do
    test "activates a suspended tenant", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      body = json_response(conn, 200)
      assert body["tenant"]["status"] == "active"
    end

    test "activating already-active tenant returns 422", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      body = json_response(conn, 422)
      assert body["error"]["message"] == "Tenant is already active"
    end

    test "activated tenant regains API access", %{conn: conn} do
      {sa_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})
      {tenant_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Activate
      conn
      |> auth_conn(sa_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      # Tenant's own API call should succeed
      conn2 =
        build_conn()
        |> auth_conn(tenant_key)
        |> get(~p"/api/v1/tenants/me")

      assert json_response(conn2, 200)
    end

    test "creates audit log entry for activation", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      {:ok, result} = Audit.list_entries(tenant.id, action: "tenant_activated")
      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.actor_type == "superadmin"
      assert entry.actor_id == api_key.id
    end
  end

  describe "authorization" do
    test "non-superadmin cannot access any admin tenant endpoint", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      for {method, path} <- [
            {:get, ~p"/api/v1/admin/tenants"},
            {:get, ~p"/api/v1/admin/tenants/#{tenant.id}"},
            {:patch, ~p"/api/v1/admin/tenants/#{tenant.id}"},
            {:post, ~p"/api/v1/admin/tenants/#{tenant.id}/suspend"},
            {:post, ~p"/api/v1/admin/tenants/#{tenant.id}/activate"}
          ] do
        resp =
          conn
          |> auth_conn(raw_key)
          |> dispatch(LoopctlWeb.Endpoint, method, path)

        assert resp.status == 403, "Expected 403 for #{method} #{path}, got #{resp.status}"
      end
    end
  end

  describe "POST /api/v1/admin/tenants/:id/clear-halt/challenge" do
    test "issues a challenge bound to the target tenant's authenticators", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt/challenge", %{})

      data = json_response(conn, 200)["data"]
      assert data["challenge_id"]
      assert data["challenge"] != ""
      assert Base.url_encode64(auth.credential_id, padding: false) in data["allowed_credentials"]
    end

    test "returns 422 when the tenant has no enrolled authenticator", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt/challenge", %{})

      assert json_response(conn, 422)["error"]["code"] == "no_authenticators"
    end

    test "rejects a non-superadmin key", %{conn: conn} do
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      _auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt/challenge", %{})

      assert conn.status == 403
    end

    test "returns 404 (not 500) for a malformed non-UUID tenant id", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/not-a-uuid/clear-halt/challenge", %{})

      assert json_response(conn, 404)["error"]["status"] == 404
    end
  end

  describe "POST /api/v1/admin/tenants/:id/clear-halt" do
    setup do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 0)
      {:ok, _halted} = Tenants.halt_custody(tenant.id)

      %{raw_key: raw_key, api_key: api_key, tenant: tenant, auth: auth}
    end

    defp issue_challenge(conn, raw_key, tenant_id) do
      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant_id}/clear-halt/challenge", %{})
      |> json_response(200)
      |> Map.fetch!("data")
    end

    test "clears the halt via the two-step challenge-bound ceremony", ctx do
      %{conn: conn, raw_key: raw_key, api_key: api_key, tenant: tenant, auth: auth} = ctx

      # Default MockWebAuthn stub verifies successfully (sign_count: 1).
      challenge_data = issue_challenge(conn, raw_key, tenant.id)

      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth.credential_id)
        })

      resp = json_response(clear_conn, 200)
      assert resp["data"]["id"] == tenant.id
      assert resp["data"]["custody_halted_at"] == nil
      assert resp["data"]["status"] == "halt_cleared"

      # Halt is actually cleared in the DB.
      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      assert reloaded.custody_halted_at == nil

      # The halt_cleared audit event was appended to the hash chain, and it
      # records WHICH verified authenticator (credential + advanced counter)
      # authorized the break-glass clear — not only the superadmin key.
      %{data: entries} = AuditChain.list_entries(tenant.id, action: "halt_cleared")
      assert length(entries) == 1
      entry = hd(entries)
      assert entry.payload["cleared_by"] == api_key.id

      assert entry.payload["credential_id"] ==
               Base.url_encode64(auth.credential_id, padding: false)

      assert entry.payload["sign_count"] == 1
    end

    test "AC3: a rotate-audit-key challenge cannot clear a custody halt (cross-purpose)", ctx do
      %{conn: conn, raw_key: raw_key, tenant: tenant, auth: auth} = ctx

      # Mint a challenge for the DIFFERENT ceremony purpose (audit-key rotation)
      # for the SAME tenant + enrolled authenticator. The default MockWebAuthn
      # stub verifies any assertion successfully, so the ONLY thing standing
      # between this cross-purpose challenge and a cleared halt is the purpose
      # scoping in Reauth.consume_challenge (`c.purpose == ^purpose`).
      {:ok, issued} = Reauth.issue_challenge(tenant.id, "rotate_audit_key")

      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" => assertion_body(issued.challenge_id, auth.credential_id)
        })

      assert json_response(clear_conn, 401)["error"]["code"] == "webauthn_failed"

      # The halt remains set — a rotate-audit-key challenge cleared nothing.
      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      refute is_nil(reloaded.custody_halted_at)
    end

    test "a rejected break-glass attempt is recorded in the audit chain", ctx do
      %{conn: conn, raw_key: raw_key, api_key: api_key, tenant: tenant, auth: auth} = ctx

      Mox.stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:error, :invalid_assertion}
      end)

      challenge_data = issue_challenge(conn, raw_key, tenant.id)

      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth.credential_id)
        })

      assert json_response(clear_conn, 401)["error"]["code"] == "webauthn_failed"

      # The rejection is forensically recorded (L6): a compromised superadmin
      # key attempting break-glass without the hardware factor leaves a trace.
      %{data: entries} = AuditChain.list_entries(tenant.id, action: "halt_clear_rejected")
      assert length(entries) == 1
      assert hd(entries).payload["rejected_by"] == api_key.id

      # No successful clear was recorded.
      %{data: cleared} = AuditChain.list_entries(tenant.id, action: "halt_cleared")
      assert cleared == []
    end

    test "rejects a garbage assertion that fails verification and does NOT clear the halt", ctx do
      %{conn: conn, raw_key: raw_key, tenant: tenant, auth: auth} = ctx

      Mox.stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:error, :invalid_assertion}
      end)

      challenge_data = issue_challenge(conn, raw_key, tenant.id)

      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" =>
            assertion_body(challenge_data["challenge_id"], auth.credential_id)
        })

      assert json_response(clear_conn, 401)["error"]["code"] == "webauthn_failed"

      # Halt remains set.
      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      refute is_nil(reloaded.custody_halted_at)
    end

    test "rejects an assertion referencing a non-existent challenge and keeps the halt", ctx do
      %{conn: conn, raw_key: raw_key, tenant: tenant, auth: auth} = ctx

      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" => assertion_body(Ecto.UUID.generate(), auth.credential_id)
        })

      assert json_response(clear_conn, 401)["error"]["code"] == "webauthn_failed"

      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      refute is_nil(reloaded.custody_halted_at)
    end

    test "a challenge is single-use — replaying the consumed assertion is rejected", ctx do
      %{conn: conn, raw_key: raw_key, tenant: tenant, auth: auth} = ctx

      challenge_data = issue_challenge(conn, raw_key, tenant.id)
      body = assertion_body(challenge_data["challenge_id"], auth.credential_id)

      # First use clears the halt.
      assert conn
             |> auth_conn(raw_key)
             |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
               "webauthn_assertion" => body
             })
             |> json_response(200)

      # Re-halt, then replay the SAME (already-consumed) challenge.
      {:ok, _} = Tenants.halt_custody(tenant.id)

      replay_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" => body
        })

      assert json_response(replay_conn, 401)["error"]["code"] == "webauthn_failed"

      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      refute is_nil(reloaded.custody_halted_at)
    end

    test "a missing webauthn_assertion is rejected (webauthn_required) and keeps the halt", ctx do
      %{conn: conn, raw_key: raw_key, tenant: tenant} = ctx

      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{})

      assert json_response(clear_conn, 401)["error"]["code"] == "webauthn_required"

      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      refute is_nil(reloaded.custody_halted_at)
    end

    test "a non-map webauthn_assertion is rejected (webauthn_required)", ctx do
      %{conn: conn, raw_key: raw_key, tenant: tenant} = ctx

      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" => Base.encode64(:crypto.strong_rand_bytes(64))
        })

      assert json_response(clear_conn, 401)["error"]["code"] == "webauthn_required"

      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      refute is_nil(reloaded.custody_halted_at)
    end

    test "returns 404 (not 500) for a malformed non-UUID id even with a well-formed body", ctx do
      %{conn: conn, raw_key: raw_key, auth: auth} = ctx

      # A well-formed assertion body but a garbage path id must be caught by the
      # up-front UUID guard (404), NOT raise Ecto.Query.CastError deep in
      # consume_challenge's tenant_id predicate (which would 500).
      clear_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/not-a-uuid/clear-halt", %{
          "webauthn_assertion" => assertion_body(Ecto.UUID.generate(), auth.credential_id)
        })

      assert json_response(clear_conn, 404)["error"]["status"] == 404
    end

    test "a non-superadmin key is rejected on clear-halt (role gate unchanged)", ctx do
      %{conn: conn, tenant: tenant, auth: auth} = ctx
      # User key from a SEPARATE, non-halted tenant so the role gate (403) is
      # exercised in isolation from any custody-halt request guard.
      other = fixture(:tenant, %{slug: "role-gate-other"})
      {user_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :user})

      clear_conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/clear-halt", %{
          "webauthn_assertion" => assertion_body(Ecto.UUID.generate(), auth.credential_id)
        })

      assert clear_conn.status == 403

      {:ok, reloaded} = Tenants.get_tenant(tenant.id)
      refute is_nil(reloaded.custody_halted_at)
    end

    test "tenant isolation: a challenge for tenant A cannot clear tenant B's halt", ctx do
      %{conn: conn, raw_key: raw_key, tenant: tenant_a, auth: auth_a} = ctx

      # Tenant B is independently halted with its own enrolled authenticator.
      tenant_b =
        fixture(:tenant, %{
          slug: "halt-b",
          audit_signing_public_key: :crypto.strong_rand_bytes(32)
        })

      _auth_b = fixture(:root_authenticator, tenant_id: tenant_b.id, sign_count: 0)
      {:ok, _} = Tenants.halt_custody(tenant_b.id)

      # Mint a challenge for tenant A, then try to spend it against tenant B.
      challenge_a = issue_challenge(conn, raw_key, tenant_a.id)

      cross_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant_b.id}/clear-halt", %{
          "webauthn_assertion" =>
            assertion_body(challenge_a["challenge_id"], auth_a.credential_id)
        })

      assert json_response(cross_conn, 401)["error"]["code"] == "webauthn_failed"

      # Tenant B is still halted.
      {:ok, reloaded_b} = Tenants.get_tenant(tenant_b.id)
      refute is_nil(reloaded_b.custody_halted_at)
    end
  end
end
