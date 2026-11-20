defmodule LoopctlWeb.Plugs.ClientVersionTest do
  @moduledoc """
  TC-52.8.5 (US-52.8): `LoopctlWeb.Plugs.ClientVersion` refuses an old factory client with
  426 before any key is read, and passes every other request unchanged. The release set is
  injected through `conn.private`, so no case depends on the committed manifest's numbers.
  """
  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.Plugs.ClientVersion

  @components %{
    "runner" => %{minimum: "unreported", version: "0.2.0"},
    "chg" => %{minimum: "0.2.0", version: "0.3.0"},
    "mcp" => %{minimum: "3.0.0", version: "3.19.1"}
  }

  defp client(conn, value) do
    conn
    |> Plug.Conn.put_private(:release_set_components, @components)
    |> put_req_header(ClientVersion.header(), value)
  end

  defp keyed(conn) do
    tenant = fixture(:tenant)
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    put_req_header(conn, "authorization", "Bearer #{raw}")
  end

  test "an old MCP package gets 426, not the 401 its missing key would earn", %{conn: conn} do
    body = conn |> client("mcp/0.0.1") |> get(~p"/api/v1/projects") |> json_response(426)

    assert body["error"]["code"] == "incompatible_client_version"
    assert body["error"]["component"] == "mcp"
    assert body["error"]["sent"] == "0.0.1"
    assert body["error"]["minimum"] == "3.0.0"
  end

  test "a current client, no header, and another component all pass", %{conn: conn} do
    assert conn
           |> keyed()
           |> client("mcp/3.19.1")
           |> get(~p"/api/v1/projects")
           |> json_response(200)

    assert conn |> keyed() |> get(~p"/api/v1/projects") |> json_response(200)

    assert conn
           |> keyed()
           |> client("fleet_dash/1.0")
           |> get(~p"/api/v1/projects")
           |> json_response(200)
  end

  test "an old chg is refused on a change-event route before the signature is read",
       %{conn: conn} do
    body =
      conn
      |> client("chg/0.0.1")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/change_events/#{Ecto.UUID.generate()}", "{}")
      |> json_response(426)

    assert body["error"]["component"] == "chg"
    assert body["error"]["minimum"] == "0.2.0"
  end

  test "a factory client with no version after the slash is refused" do
    assert {:ok, "chg", ""} = ClientVersion.parse("chg/")
    assert :other = ClientVersion.parse("chg")
    assert :other = ClientVersion.parse("other/1.0.0")
  end
end
