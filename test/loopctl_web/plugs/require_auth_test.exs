defmodule LoopctlWeb.Plugs.RequireAuthTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias LoopctlWeb.Plugs.RequireAuth

  describe "call/2" do
    test "passes through when current_api_key is assigned", %{conn: conn} do
      api_key = %ApiKey{id: Ecto.UUID.generate(), role: :user}

      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> RequireAuth.call([])

      refute conn.halted
    end

    test "halts with 401 when no current_api_key", %{conn: conn} do
      conn = RequireAuth.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 401
      assert body["error"]["message"] == "Unauthorized"
    end
  end
end
