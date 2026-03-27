defmodule Loopctl.CLI.Commands.KeysTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Keys

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/api_keys"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "api_key" => %{
              "id" => "key-1",
              "name" => "my-key",
              "role" => "user",
              "key_prefix" => "lc_abc12"
            },
            "raw_key" => "lc_abc123456789"
          })

        {"GET", "/api/v1/api_keys"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "key-1",
                "name" => "my-key",
                "role" => "user",
                "key_prefix" => "lc_abc12"
              }
            ]
          })

        {"DELETE", "/api/v1/api_keys/" <> _id} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/api/v1/api_keys/" <> _rest} ->
          Req.Test.json(conn, %{
            "api_key" => %{
              "id" => "key-2",
              "name" => "my-key",
              "role" => "user",
              "key_prefix" => "lc_new12"
            },
            "raw_key" => "lc_new123456789"
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "keys create" do
    test "creates an API key with name and role" do
      output =
        capture_io(fn ->
          Keys.run("keys", ["create", "--name", "my-key", "--role", "user"], [])
        end)

      assert output =~ "my-key"
    end

    test "requires --name and --role" do
      output =
        capture_io(:stderr, fn ->
          Keys.run("keys", ["create", "--name", "only-name"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "keys list" do
    test "lists API keys" do
      output =
        capture_io(fn ->
          Keys.run("keys", ["list"], [])
        end)

      assert output =~ "my-key"
    end
  end

  describe "keys revoke" do
    test "revokes an API key" do
      output =
        capture_io(fn ->
          Keys.run("keys", ["revoke", "key-1"], [])
        end)

      assert output =~ "revoked"
    end
  end

  describe "keys rotate" do
    test "rotates an API key" do
      output =
        capture_io(fn ->
          Keys.run("keys", ["rotate", "key-1"], [])
        end)

      assert output =~ "lc_new"
    end
  end

  describe "invalid subcommand" do
    test "shows usage" do
      output =
        capture_io(:stderr, fn ->
          Keys.run("keys", ["bogus"], [])
        end)

      assert output =~ "Usage:"
    end
  end
end
