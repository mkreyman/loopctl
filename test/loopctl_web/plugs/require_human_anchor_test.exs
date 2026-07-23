defmodule LoopctlWeb.Plugs.RequireHumanAnchorTest do
  @moduledoc """
  US-26.7.1 — unit tests for the `RequireHumanAnchor` plug, mirroring the
  direct `assign/3` + `Plug.call/2` style used by `SetTenantTest`.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias Loopctl.Tenants.TierCapabilities
  alias LoopctlWeb.Plugs.RequireHumanAnchor

  describe "call/2" do
    test "passes through for a human_anchored tenant", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      api_key = %ApiKey{tenant_id: tenant.id, role: :user}

      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> assign(:current_tenant, tenant)
        |> RequireHumanAnchor.call([])

      refute conn.halted
    end

    test "halts with 403 custody_tier_required for an agent_rooted tenant", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      api_key = %ApiKey{tenant_id: tenant.id, role: :user}

      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> assign(:current_tenant, tenant)
        |> RequireHumanAnchor.call([])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 403
      assert body["error"]["code"] == "custody_tier_required"
      assert is_binary(body["error"]["message"])
      assert is_map(body["error"]["remediation"])
      assert body["error"]["remediation"]["learn_more"] =~ "chain-of-custody"
    end

    test "superadmin key with no impersonation (current_tenant: nil) passes without crashing",
         %{conn: conn} do
      api_key = %ApiKey{tenant_id: nil, role: :superadmin}

      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> assign(:current_tenant, nil)
        |> RequireHumanAnchor.call([])

      refute conn.halted
    end

    test "superadmin impersonating an agent_rooted tenant is blocked (routes through the impersonated tenant's tier)",
         %{conn: conn} do
      agent_rooted_tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      superadmin_key = %ApiKey{tenant_id: nil, role: :superadmin}
      # Mirrors what LoopctlWeb.Plugs.Impersonate actually does: reassigns
      # current_tenant + current_api_key.tenant_id to the impersonated
      # tenant BEFORE controller plugs run.
      impersonated_key = %{superadmin_key | tenant_id: agent_rooted_tenant.id}

      conn =
        conn
        |> assign(:current_api_key, impersonated_key)
        |> assign(:current_tenant, agent_rooted_tenant)
        |> assign(:impersonating, true)
        |> RequireHumanAnchor.call([])

      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "custody_tier_required"
    end

    test "superadmin impersonating a human_anchored tenant passes", %{conn: conn} do
      human_tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      superadmin_key = %ApiKey{tenant_id: nil, role: :superadmin}
      impersonated_key = %{superadmin_key | tenant_id: human_tenant.id}

      conn =
        conn
        |> assign(:current_api_key, impersonated_key)
        |> assign(:current_tenant, human_tenant)
        |> assign(:impersonating, true)
        |> RequireHumanAnchor.call([])

      refute conn.halted
    end

    test "no current_tenant assign at all fails closed (never permissive)", %{conn: conn} do
      api_key = %ApiKey{tenant_id: Ecto.UUID.generate(), role: :user}

      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> RequireHumanAnchor.call([])

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "call/2 — 403 discoverability (#505)" do
    setup %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})

      conn =
        conn
        |> assign(:current_api_key, %ApiKey{tenant_id: tenant.id, role: :user})
        |> assign(:current_tenant, tenant)

      %{conn: conn, tenant: tenant}
    end

    test "the 403 body embeds the tenant's capability map", %{conn: conn} do
      conn = RequireHumanAnchor.call(conn, [])
      caps = Jason.decode!(conn.resp_body)["error"]["capabilities"]

      assert caps["trust_tier"] == "agent_rooted"
      assert "work_breakdown" in caps["blocked"]
      assert "knowledge_base" in caps["allowed"]
      assert caps["surfaces"]["work_breakdown"] == "requires_human_anchor"
    end

    test "the embedded map matches what GET /tenants/me advertises — one derivation, no drift",
         %{conn: conn, tenant: tenant} do
      conn = RequireHumanAnchor.call(conn, [])
      from_403 = Jason.decode!(conn.resp_body)["error"]["capabilities"]

      # Same derivation, minus the static per-surface descriptions: they never
      # vary per tenant and have no business being re-serialized on every denial.
      advertised =
        tenant
        |> TierCapabilities.for_tenant()
        |> TierCapabilities.compact()
        |> Jason.encode!()
        |> Jason.decode!()

      assert from_403 == advertised
    end

    test "the 403 omits the static descriptions but keeps what a caller branches on",
         %{conn: conn} do
      conn = RequireHumanAnchor.call(conn, [])
      caps = Jason.decode!(conn.resp_body)["error"]["capabilities"]

      refute Map.has_key?(caps, "descriptions")
      assert caps["scope"] == "trust_tier_only"
      assert caps["applies_to"] == "mutating_actions"
      assert is_list(caps["blocked"])
    end

    test "omits agent_native_alternative when the mount names none", %{conn: conn} do
      conn = RequireHumanAnchor.call(conn, [])
      remediation = Jason.decode!(conn.resp_body)["error"]["remediation"]

      refute Map.has_key?(remediation, "agent_native_alternative")
      assert remediation["enrollment_upgrade"]["docs"] =~ "tenant-signup"
      assert "enroll_authenticator" in remediation["enrollment_upgrade"]["tools"]
    end

    test "surfaces the mount's :alternative as remediation.agent_native_alternative",
         %{conn: conn} do
      alternative = %{tool: "create_kb_scope", endpoint: "POST /api/v1/kb-scopes"}

      conn = RequireHumanAnchor.call(conn, alternative: alternative)
      remediation = Jason.decode!(conn.resp_body)["error"]["remediation"]

      assert remediation["agent_native_alternative"]["tool"] == "create_kb_scope"
      assert remediation["agent_native_alternative"]["endpoint"] == "POST /api/v1/kb-scopes"
      # The upgrade path is still offered alongside it.
      assert remediation["learn_more"] =~ "chain-of-custody"
    end

    test "a missing current_tenant still fails closed WITH the most restrictive map",
         %{conn: conn} do
      conn =
        conn
        |> Map.update!(:assigns, &Map.delete(&1, :current_tenant))
        |> RequireHumanAnchor.call([])

      assert conn.halted
      caps = Jason.decode!(conn.resp_body)["error"]["capabilities"]
      assert "work_breakdown" in caps["blocked"]

      # The surface set is the restrictive one, but the tier is NOT self-reported
      # as agent_rooted: the tenant could not be resolved, so the body says so.
      assert caps["unknown_tier"] == true
      assert caps["trust_tier"] == "unknown_tenant"
    end

    test "the gate itself is unchanged — an agent_rooted tenant is still halted", %{conn: conn} do
      conn = RequireHumanAnchor.call(conn, alternative: %{tool: "create_kb_scope"})

      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "custody_tier_required"
    end
  end

  describe "init/1 — opt validation (#505)" do
    @valid_alternative %{
      tool: "create_kb_scope",
      endpoint: "POST /api/v1/kb-scopes",
      description: "Creates a kind: kb project scope."
    }

    test "passes a bare mount and a well-formed alternative through untouched" do
      assert RequireHumanAnchor.init([]) == []

      opts = [alternative: @valid_alternative]
      assert RequireHumanAnchor.init(opts) == opts
    end

    test "a misspelled key raises instead of silently degrading the 403 to a dead end" do
      assert_raise ArgumentError, ~r/unknown option\(s\) \[:alternatve\]/, fn ->
        RequireHumanAnchor.init(alternatve: @valid_alternative)
      end
    end

    test "non-keyword opts raise instead of blowing up inside the 403 path" do
      assert_raise ArgumentError, ~r/expects a keyword list/, fn ->
        RequireHumanAnchor.init(%{alternative: @valid_alternative})
      end
    end

    test "an alternative missing a required string key raises" do
      assert_raise ArgumentError, ~r/:endpoint/, fn ->
        RequireHumanAnchor.init(alternative: Map.delete(@valid_alternative, :endpoint))
      end

      assert_raise ArgumentError, ~r/:description/, fn ->
        RequireHumanAnchor.init(alternative: %{@valid_alternative | description: nil})
      end
    end

    test "a non-map alternative raises" do
      assert_raise ArgumentError, ~r/must be a map/, fn ->
        RequireHumanAnchor.init(alternative: "create_kb_scope")
      end
    end
  end
end
