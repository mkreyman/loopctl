defmodule LoopctlWeb.Plugs.UpdateLastSeenTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Agents
  alias Loopctl.TouchBuffer

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "UpdateLastSeen plug" do
    test "records last_seen_at into the buffer with no synchronous DB write (US-33.4)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, name: "seen-agent"})
      initial_last_seen = agent.last_seen_at

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      # last_seen_at is set during registration
      assert %DateTime{} = initial_last_seen

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      # Make an authenticated request (agent can access change feed)
      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}")

      assert json_response(conn, 200)

      # AC-33.4.2: the request path performs NO synchronous last_seen_at UPDATE —
      # the DB row is unchanged from registration until a flush.
      {:ok, unchanged} = Agents.get_agent(tenant.id, agent.id)
      assert DateTime.compare(unchanged.last_seen_at, initial_last_seen) == :eq

      # AC-33.4.1: the touch was recorded into the in-memory buffer (a pending ts
      # >= registration time) instead.
      assert {:ok, %DateTime{} = pending} =
               TouchBuffer.peek(TouchBuffer.table_name(), {:agent, agent.id})

      assert DateTime.compare(pending, initial_last_seen) in [:gt, :eq]
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
