defmodule LoopctlWeb.AdminStatsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/admin/stats" do
    test "returns correct aggregate counts", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant_a = fixture(:tenant, %{name: "Stats Tenant A", status: :active})
      tenant_b = fixture(:tenant, %{name: "Stats Tenant B", status: :active})
      _tenant_c = fixture(:tenant, %{name: "Stats Tenant C", status: :suspended})

      # Create resources across tenants
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      fixture(:project, %{tenant_id: tenant_b.id})

      epic_a = fixture(:epic, %{tenant_id: tenant_a.id, project_id: project_a.id})
      fixture(:story, %{tenant_id: tenant_a.id, epic_id: epic_a.id, agent_status: :pending})

      fixture(:story, %{
        tenant_id: tenant_a.id,
        epic_id: epic_a.id,
        agent_status: :implementing
      })

      fixture(:agent, %{tenant_id: tenant_a.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/stats")

      body = json_response(conn, 200)
      stats = body["stats"]

      # Tenant counts (3 created in this test, but may include others from superadmin fixture)
      assert stats["total_tenants"] >= 3
      assert stats["tenants_active"] >= 2
      assert stats["tenants_suspended"] >= 1

      # Resource counts
      assert stats["total_projects"] >= 2
      assert stats["total_stories"] >= 2
      assert stats["total_epics"] >= 1
      assert stats["total_agents"] >= 1

      # Story status breakdown
      assert is_map(stats["stories_by_agent_status"])
      assert Map.get(stats["stories_by_agent_status"], "pending", 0) >= 1
      assert Map.get(stats["stories_by_agent_status"], "implementing", 0) >= 1

      # Active stories (implementing)
      assert stats["active_stories"] >= 1

      # Verified status breakdown present
      assert is_map(stats["stories_by_verified_status"])
    end

    test "stories_by_verified_status breakdown is correct", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)
      epic = fixture(:epic, %{tenant_id: tenant.id})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, verified_status: :unverified})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, verified_status: :verified})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, verified_status: :verified})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, verified_status: :rejected})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/stats")

      body = json_response(conn, 200)
      verified = body["stats"]["stories_by_verified_status"]

      assert Map.get(verified, "unverified", 0) >= 1
      assert Map.get(verified, "verified", 0) >= 2
      assert Map.get(verified, "rejected", 0) >= 1
    end

    test "active_agents counts only recently seen agents", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)

      # Recent agent
      recent_agent = fixture(:agent, %{tenant_id: tenant.id})

      Loopctl.AdminRepo.update!(
        Ecto.Changeset.change(recent_agent, %{
          status: :active,
          last_seen_at: DateTime.utc_now()
        })
      )

      # Stale agent (seen 48 hours ago)
      stale_agent = fixture(:agent, %{tenant_id: tenant.id})

      Loopctl.AdminRepo.update!(
        Ecto.Changeset.change(stale_agent, %{
          status: :active,
          last_seen_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
        })
      )

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/stats")

      body = json_response(conn, 200)
      stats = body["stats"]

      assert stats["total_agents"] >= 2
      # Only the recent one should be counted as active
      assert stats["active_agents"] >= 1
      # stale one should not be counted -- active_agents < total_agents
      assert stats["active_agents"] < stats["total_agents"]
    end

    test "returns zero counts with empty system", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/stats")

      body = json_response(conn, 200)
      stats = body["stats"]

      # All required fields present
      for field <-
            ~w(total_tenants tenants_active tenants_suspended tenants_deactivated
               total_projects total_epics total_stories total_agents total_api_keys
               stories_by_agent_status stories_by_verified_status
               active_stories active_agents) do
        assert Map.has_key?(stats, field), "Missing field: #{field}"
      end
    end

    test "non-superadmin cannot access stats", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/stats")

      assert json_response(conn, 403)
    end
  end
end
