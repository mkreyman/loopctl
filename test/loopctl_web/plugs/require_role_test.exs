defmodule LoopctlWeb.Plugs.RequireRoleTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias LoopctlWeb.Plugs.RequireRole

  defp conn_with_role(conn, role) do
    assign(conn, :current_api_key, %ApiKey{id: Ecto.UUID.generate(), role: role})
  end

  describe "minimum role check" do
    test "superadmin can access user-level endpoint", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:superadmin)
        |> RequireRole.call(%{role: :user})

      refute conn.halted
    end

    test "user can access user-level endpoint", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:user)
        |> RequireRole.call(%{role: :user})

      refute conn.halted
    end

    test "orchestrator can access agent-level endpoint", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:orchestrator)
        |> RequireRole.call(%{role: :agent})

      refute conn.halted
    end

    test "agent can access agent-level endpoint", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:agent)
        |> RequireRole.call(%{role: :agent})

      refute conn.halted
    end

    test "agent cannot access user-level endpoint", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:agent)
        |> RequireRole.call(%{role: :user})

      assert conn.halted
      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 403
    end

    test "orchestrator cannot access user-level endpoint", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:orchestrator)
        |> RequireRole.call(%{role: :user})

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "exact role check" do
    test "exact role match passes", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:agent)
        |> RequireRole.call(%{exact_role: :agent})

      refute conn.halted
    end

    test "higher role rejected by exact check", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:user)
        |> RequireRole.call(%{exact_role: :agent})

      assert conn.halted
      assert conn.status == 403
    end

    test "lower role rejected by exact check", %{conn: conn} do
      conn =
        conn
        |> conn_with_role(:agent)
        |> RequireRole.call(%{exact_role: :orchestrator})

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "fail-closed catch-all (#461 item 1)" do
    test "no current_api_key assign → clean 401 JSON, halted, does not raise", %{conn: conn} do
      # A route that mounts RequireRole with NO authentication plug ahead of it must
      # fail CLOSED (401), not raise FunctionClauseError (500 + stacktrace leak).
      conn = RequireRole.call(conn, %{role: :agent})

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 401
      assert body["error"]["message"] == "Authentication required"
    end

    test "missing key fails closed for exact_role gates too", %{conn: conn} do
      conn = RequireRole.call(conn, %{exact_role: :superadmin})

      assert conn.halted
      assert conn.status == 401
    end
  end
end
