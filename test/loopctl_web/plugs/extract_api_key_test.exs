defmodule LoopctlWeb.Plugs.ExtractApiKeyTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias LoopctlWeb.Plugs.ExtractApiKey

  describe "call/2" do
    test "extracts Bearer token from Authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer lc_test_key_123")
        |> ExtractApiKey.call([])

      assert conn.assigns.raw_api_key == "lc_test_key_123"
      refute conn.halted
    end

    test "assigns nil when no Authorization header present", %{conn: conn} do
      conn = ExtractApiKey.call(conn, [])

      assert conn.assigns.raw_api_key == nil
      refute conn.halted
    end

    test "assigns nil for non-Bearer authorization", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> ExtractApiKey.call([])

      assert conn.assigns.raw_api_key == nil
      refute conn.halted
    end

    test "trims whitespace from token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer   lc_trimmed_key  ")
        |> ExtractApiKey.call([])

      assert conn.assigns.raw_api_key == "lc_trimmed_key"
    end
  end
end
