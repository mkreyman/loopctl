defmodule Loopctl.CLI.ClientTest do
  use ExUnit.Case, async: true

  alias Loopctl.CLI.Client

  setup do
    # Stub the Req.Test plug for CLI client
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/tenants/me"} ->
          Req.Test.json(conn, %{
            "id" => "tenant-1",
            "name" => "Test Tenant",
            "slug" => "test-tenant"
          })

        {"POST", "/api/v1/projects"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "id" => "project-1",
            "name" => "Test Project"
          })

        {"PATCH", "/api/v1/projects/project-1"} ->
          Req.Test.json(conn, %{
            "id" => "project-1",
            "name" => "Updated Project"
          })

        {"DELETE", "/api/v1/projects/project-1"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"PUT", "/api/v1/orchestrator/state/project-1"} ->
          Req.Test.json(conn, %{"ok" => true})

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "get/2" do
    test "makes a GET request and returns parsed body" do
      assert {:ok, body} =
               Client.get("/api/v1/tenants/me",
                 server: "http://localhost:4000",
                 api_key: "lc_testkey"
               )

      assert body["name"] == "Test Tenant"
    end

    test "returns error when no server configured" do
      assert {:error, :no_server_configured} =
               Client.get("/api/v1/tenants/me", server: nil, api_key: "lc_testkey")
    end
  end

  describe "post/3" do
    test "makes a POST request with JSON body" do
      assert {:ok, body} =
               Client.post(
                 "/api/v1/projects",
                 %{"name" => "Test Project"},
                 server: "http://localhost:4000",
                 api_key: "lc_testkey"
               )

      assert body["name"] == "Test Project"
    end
  end

  describe "patch/3" do
    test "makes a PATCH request with JSON body" do
      assert {:ok, body} =
               Client.patch(
                 "/api/v1/projects/project-1",
                 %{"name" => "Updated Project"},
                 server: "http://localhost:4000",
                 api_key: "lc_testkey"
               )

      assert body["name"] == "Updated Project"
    end
  end

  describe "delete/2" do
    test "makes a DELETE request" do
      assert {:ok, _body} =
               Client.delete("/api/v1/projects/project-1",
                 server: "http://localhost:4000",
                 api_key: "lc_testkey"
               )
    end
  end

  describe "put/3" do
    test "makes a PUT request with JSON body" do
      assert {:ok, body} =
               Client.put(
                 "/api/v1/orchestrator/state/project-1",
                 %{"state" => "data"},
                 server: "http://localhost:4000",
                 api_key: "lc_testkey"
               )

      assert body["ok"] == true
    end
  end

  describe "error handling" do
    test "returns error tuple for non-2xx responses" do
      assert {:error, {404, _body}} =
               Client.get("/api/v1/nonexistent",
                 server: "http://localhost:4000",
                 api_key: "lc_testkey"
               )
    end
  end
end
