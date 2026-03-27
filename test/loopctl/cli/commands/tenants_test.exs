defmodule Loopctl.CLI.Commands.TenantsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Tenants

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/tenants/register"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "tenant" => %{"id" => "t-1", "name" => "New Tenant", "slug" => "new-tenant"},
            "api_key" => "lc_newkey123"
          })

        {"GET", "/api/v1/tenants/me"} ->
          Req.Test.json(conn, %{
            "tenant" => %{
              "id" => "t-1",
              "name" => "Test Tenant",
              "slug" => "test-tenant",
              "settings" => %{}
            }
          })

        {"PATCH", "/api/v1/tenants/me"} ->
          Req.Test.json(conn, %{
            "tenant" => %{
              "id" => "t-1",
              "name" => "Test Tenant",
              "settings" => %{"max_projects" => 100}
            }
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "tenant register" do
    test "registers a tenant with name and email" do
      output =
        capture_io(fn ->
          Tenants.run(
            "tenant",
            ["register", "--name", "New Tenant", "--email", "new@example.com"],
            []
          )
        end)

      assert output =~ "New Tenant"
    end

    test "requires --name and --email" do
      output =
        capture_io(:stderr, fn ->
          Tenants.run("tenant", ["register", "--name", "Only Name"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "tenant info" do
    test "shows current tenant info" do
      output =
        capture_io(fn ->
          Tenants.run("tenant", ["info"], [])
        end)

      assert output =~ "Test Tenant"
    end
  end

  describe "tenant update" do
    test "updates tenant settings" do
      output =
        capture_io(fn ->
          Tenants.run("tenant", ["update", "--setting", "max_projects=100"], [])
        end)

      assert output =~ "max_projects"
    end

    test "requires at least one --setting" do
      output =
        capture_io(:stderr, fn ->
          Tenants.run("tenant", ["update"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "invalid subcommand" do
    test "shows usage" do
      output =
        capture_io(:stderr, fn ->
          Tenants.run("tenant", ["bogus"], [])
        end)

      assert output =~ "Usage: loopctl tenant"
    end
  end
end
