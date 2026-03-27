defmodule Loopctl.CLI.Commands.AdminTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Admin

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/admin/tenants"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"id" => "t-1", "name" => "Tenant A", "slug" => "tenant-a", "status" => "active"}
            ]
          })

        {"GET", "/api/v1/admin/tenants/" <> _id} ->
          Req.Test.json(conn, %{
            "tenant" => %{"id" => "t-1", "name" => "Tenant A", "status" => "active"}
          })

        {"POST", "/api/v1/admin/tenants/" <> _rest} ->
          Req.Test.json(conn, %{
            "tenant" => %{"id" => "t-1", "status" => "suspended"}
          })

        {"GET", "/api/v1/admin/stats"} ->
          Req.Test.json(conn, %{
            "tenants" => 5,
            "projects" => 12,
            "stories" => 185,
            "agents" => 8
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "admin tenants" do
    test "lists all tenants" do
      output = capture_io(fn -> Admin.run("admin", ["tenants"], []) end)
      assert output =~ "Tenant A"
    end
  end

  describe "admin tenant" do
    test "shows tenant detail" do
      output = capture_io(fn -> Admin.run("admin", ["tenant", "t-1"], []) end)
      assert output =~ "Tenant A"
    end
  end

  describe "admin suspend" do
    test "suspends a tenant" do
      output = capture_io(fn -> Admin.run("admin", ["suspend", "t-1"], []) end)
      assert output =~ "suspended"
    end
  end

  describe "admin activate" do
    test "activates a tenant" do
      output = capture_io(fn -> Admin.run("admin", ["activate", "t-1"], []) end)
      assert output =~ "t-1"
    end
  end

  describe "admin stats" do
    test "shows system stats" do
      output = capture_io(fn -> Admin.run("admin", ["stats"], []) end)
      assert output =~ "185"
    end
  end

  describe "invalid subcommand" do
    test "shows usage" do
      output = capture_io(:stderr, fn -> Admin.run("admin", ["bogus"], []) end)
      assert output =~ "Usage:"
    end
  end
end
