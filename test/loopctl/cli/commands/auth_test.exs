defmodule Loopctl.CLI.Commands.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Auth

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/tenants/me"} ->
          Req.Test.json(conn, %{
            "tenant" => %{
              "id" => "t-1",
              "name" => "Test Tenant",
              "slug" => "test-tenant",
              "email" => "test@example.com"
            }
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "auth login" do
    test "saves server and key to config" do
      output =
        capture_io(fn ->
          Auth.run("auth", ["login", "--server", "https://test.local", "--key", "lc_abc"], [])
        end)

      assert output =~ "Credentials saved"
      assert output =~ "https://test.local"
    end

    test "requires --server argument" do
      output =
        capture_io(:stderr, fn ->
          Auth.run("auth", ["login", "--key", "lc_abc"], [])
        end)

      assert output =~ "Missing --server"
    end
  end

  describe "auth whoami" do
    test "shows current tenant info" do
      output =
        capture_io(fn ->
          Auth.run("auth", ["whoami"], [])
        end)

      assert output =~ "Test Tenant"
    end
  end

  describe "invalid subcommand" do
    test "shows usage" do
      output =
        capture_io(:stderr, fn ->
          Auth.run("auth", ["bogus"], [])
        end)

      assert output =~ "Usage: loopctl auth"
    end
  end
end
