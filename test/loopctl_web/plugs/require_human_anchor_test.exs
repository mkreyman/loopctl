defmodule LoopctlWeb.Plugs.RequireHumanAnchorTest do
  @moduledoc """
  US-26.7.1 — unit tests for the `RequireHumanAnchor` plug, mirroring the
  direct `assign/3` + `Plug.call/2` style used by `SetTenantTest`.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
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
end
