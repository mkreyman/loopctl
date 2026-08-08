defmodule LoopctlWeb.TenantControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  # NOTE: Prior to US-26.0.1 this module also covered
  # `POST /api/v1/tenants/register`. That endpoint is removed for Chain
  # of Custody v2 — `/signup` (WebAuthn-gated LiveView) is the only
  # path to create a tenant. Coverage for the new flow lives in
  # `test/loopctl_web/live/signup_live_test.exs`.

  describe "GET /api/v1/tenants/me" do
    test "returns current tenant profile", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "My Tenant"})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/tenants/me")

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "My Tenant"
      assert body["tenant"]["id"] == tenant.id
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenants/me")
      assert json_response(conn, 401)
    end

    # #505 — an agent could previously only map its tier's boundary by taking a
    # 403 per endpoint. get_tenant now advertises it up front.
    test "advertises the tier's capabilities for an agent_rooted tenant", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/tenants/me")

      caps = json_response(conn, 200)["tenant"]["capabilities"]

      assert caps["trust_tier"] == "agent_rooted"
      assert "work_breakdown" in caps["blocked"]
      assert "chain_of_custody" in caps["blocked"]
      # ...and the surface it CAN use to establish a project row for its repo.
      assert "kb_project_scopes" in caps["allowed"]
      assert "knowledge_base" in caps["allowed"]
      assert caps["remediation"]["enrollment_upgrade"]["docs"] =~ "tenant-signup"
      assert is_binary(caps["descriptions"]["work_breakdown"])
    end

    test "advertises an unblocked capability set for a human_anchored tenant", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/tenants/me")

      caps = json_response(conn, 200)["tenant"]["capabilities"]

      assert caps["trust_tier"] == "human_anchored"
      assert caps["blocked"] == []
      assert "work_breakdown" in caps["allowed"]
      refute Map.has_key?(caps, "remediation")
    end
  end

  describe "PATCH /api/v1/tenants/me" do
    test "updates tenant name", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Old Name"})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/tenants/me", %{"name" => "New Name"})

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "New Name"
    end

    test "updates tenant settings", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/tenants/me", %{
          "settings" => %{"rate_limit_requests_per_minute" => 500}
        })

      body = json_response(conn, 200)
      assert body["tenant"]["settings"]["rate_limit_requests_per_minute"] == 500
    end

    # rls-02: slug is immutable on update. A PATCH attempting to rename it
    # succeeds (other fields apply) but leaves the slug — and therefore the
    # audit-key secret name — unchanged.
    test "ignores attempts to change slug (rls-02)", %{conn: conn} do
      tenant = fixture(:tenant, %{slug: "keep-slug", name: "Old Name"})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/tenants/me", %{"slug" => "hijacked-slug", "name" => "New Name"})

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "New Name"
      assert body["tenant"]["slug"] == "keep-slug"
    end

    # rls-03: colliding with another tenant's email must return 422, not 500.
    # A 500 here would be a cross-tenant email-enumeration oracle.
    test "returns 422 (not 500) when email is already used by another tenant (rls-03)",
         %{conn: conn} do
      _other = fixture(:tenant, %{email: "taken@example.com"})
      tenant = fixture(:tenant, %{email: "mine@example.com"})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/tenants/me", %{"email" => "taken@example.com"})

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      # The details map leaks nothing about the other tenant beyond the
      # standard uniqueness message on :email (JSON keys are strings).
      assert body["error"]["details"] == %{"email" => ["has already been taken"]}
    end

    test "allows updating to a unique email (rls-03)", %{conn: conn} do
      tenant = fixture(:tenant, %{email: "mine@example.com"})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/tenants/me", %{"email" => "fresh@example.com"})

      body = json_response(conn, 200)
      assert body["tenant"]["email"] == "fresh@example.com"
    end
  end

  # #624 item 4 — the custody OWNER key is the root of the attestation chain, and
  # registering one runs an Ed25519 verify plus a chained audit append. Its
  # sibling ceremony (WebAuthn enroll) has had a per-tenant hourly limiter all
  # along; this one had none. Mirrors that limiter, including its FAIL-CLOSED
  # posture.
  describe "POST /api/v1/tenants/me/custody-owner-key — per-tenant rate limit" do
    # Scoped to the owner-key bucket so the pipeline's own per-key RPM limiter
    # (which fails OPEN) is untouched and cannot be what produced the 429.
    defp stub_owner_key_limiter(outcome) do
      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        "custody_owner_key:rotate:" <> _tenant_id, _window, _limit -> outcome
        _bucket, _window, _limit -> {:allow, 1}
      end)
    end

    defp register_owner_key(conn, raw_key) do
      {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)

      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> post(~p"/api/v1/tenants/me/custody-owner-key", %{
        "owner_pubkey" => Base.encode16(pub),
        "alg" => "ed25519"
      })
    end

    setup do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      %{tenant: tenant, raw_key: raw_key}
    end

    test "over the budget the registration is refused with 429", ctx do
      stub_owner_key_limiter({:deny, 10})

      body =
        build_conn()
        |> register_owner_key(ctx.raw_key)
        |> json_response(429)

      assert body["error"]["code"] == "rate_limited"

      # Refused BEFORE the expensive verification path: nothing was registered.
      {:ok, tenant} = Loopctl.Tenants.get_tenant(ctx.tenant.id)
      assert is_nil(tenant.custody_owner_pubkey)
    end

    test "the gate FAILS CLOSED — a limiter fault denies rather than unlocks", ctx do
      # Unlocking an anti-abuse gate when its counter store is down is the one
      # outcome that defeats the gate entirely.
      stub_owner_key_limiter({:error, :counter_store_down})

      body =
        build_conn()
        |> register_owner_key(ctx.raw_key)
        |> json_response(429)

      assert body["error"]["code"] == "rate_limited"
    end

    test "a structurally impossible key is refused BEFORE the budget is charged", ctx do
      # `gate_ok?/3` post-increments, so anything that reaches the limiter spends
      # the budget. Hex-decoding alone let any even-length string through, which
      # made the "only real attempts spend it" ordering buy nothing.
      test_pid = self()

      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        "custody_owner_key:rotate:" <> _tenant_id, _window, _limit ->
          send(test_pid, :owner_key_budget_charged)
          {:allow, 1}

        _bucket, _window, _limit ->
          {:allow, 1}
      end)

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.raw_key}")
        |> post(~p"/api/v1/tenants/me/custody-owner-key", %{
          "owner_pubkey" => String.duplicate("00", 16),
          "alg" => "ed25519"
        })
        |> json_response(422)

      assert body["error"]["message"] =~ "32-byte"
      refute_receive :owner_key_budget_charged
    end

    test "within the budget the registration proceeds", ctx do
      stub_owner_key_limiter({:allow, 1})

      body =
        build_conn()
        |> register_owner_key(ctx.raw_key)
        |> json_response(200)

      assert body["tenant"]["id"] == ctx.tenant.id

      {:ok, tenant} = Loopctl.Tenants.get_tenant(ctx.tenant.id)
      refute is_nil(tenant.custody_owner_pubkey)
    end
  end
end
