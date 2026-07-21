defmodule LoopctlWeb.AdminViolatorControllerTest do
  @moduledoc """
  #461 item 2 — AdminViolatorController now gates on `exact_role: :superadmin`
  (aligned with the other admin controllers) instead of `role: :superadmin`.
  superadmin is the top role, so this is a convention TIGHTENING, not a behavior
  change: superadmin is still allowed and every lower role is still forbidden.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/admin/violators authorization" do
    test "superadmin is allowed", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/violators")

      assert %{"data" => _, "meta" => _} = json_response(conn, 200)
    end

    test "a user (below superadmin) is forbidden", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/violators")

      assert json_response(conn, 403)
    end

    test "an orchestrator is forbidden", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/violators")

      assert json_response(conn, 403)
    end
  end
end
