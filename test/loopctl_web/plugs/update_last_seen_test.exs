defmodule LoopctlWeb.Plugs.UpdateLastSeenTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Agents

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "UpdateLastSeen plug" do
    test "updates last_seen_at for agent-role API key with agent_id", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, name: "seen-agent"})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      assert is_nil(agent.last_seen_at)

      # Make an authenticated request (agent can register)
      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "another-agent",
          "agent_type" => "implementer"
        })

      assert json_response(conn, 201)

      # Verify last_seen_at was updated
      {:ok, updated} = Agents.get_agent(tenant.id, agent.id)
      assert updated.last_seen_at != nil
    end

    test "does not update for API key without agent_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # Make an authenticated request
      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/agents")

      # Should succeed without errors even though no agent_id
      assert json_response(conn, 200)
    end
  end
end
