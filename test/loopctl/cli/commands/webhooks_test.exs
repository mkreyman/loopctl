defmodule Loopctl.CLI.Commands.WebhooksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Webhooks

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/webhooks"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "webhook" => %{"id" => "w-1", "url" => "https://example.com/hooks", "active" => true}
          })

        {"GET", "/api/v1/webhooks"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"id" => "w-1", "url" => "https://example.com/hooks", "active" => true}
            ]
          })

        {"DELETE", "/api/v1/webhooks/" <> _id} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/api/v1/webhooks/" <> _rest} ->
          Req.Test.json(conn, %{
            "webhook_event_id" => "ev-1",
            "status" => "pending"
          })

        {"GET", "/api/v1/stories/" <> _rest} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"action" => "status_changed", "entity_type" => "story"}
            ]
          })

        {"GET", "/api/v1/audit"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"action" => "created", "entity_type" => "project"}
            ]
          })

        {"GET", "/api/v1/changes"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"action" => "status_changed", "entity_type" => "story"}
            ]
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "webhook create" do
    test "creates a webhook" do
      output =
        capture_io(fn ->
          Webhooks.run(
            "webhook",
            ["create", "--url", "https://example.com/hooks", "--events", "story.status_changed"],
            []
          )
        end)

      assert output =~ "example.com"
    end

    test "requires --url and --events" do
      output =
        capture_io(:stderr, fn ->
          Webhooks.run("webhook", ["create", "--url", "https://example.com/hooks"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "webhook list" do
    test "lists webhooks" do
      output = capture_io(fn -> Webhooks.run("webhook", ["list"], []) end)
      assert output =~ "example.com"
    end
  end

  describe "webhook delete" do
    test "deletes a webhook" do
      output = capture_io(fn -> Webhooks.run("webhook", ["delete", "w-1"], []) end)
      assert output =~ "deleted"
    end
  end

  describe "webhook test" do
    test "sends a test event" do
      output = capture_io(fn -> Webhooks.run("webhook", ["test", "w-1"], []) end)
      assert output =~ "pending"
    end
  end

  describe "history" do
    test "shows story history" do
      output = capture_io(fn -> Webhooks.run("history", ["s-1"], []) end)
      assert output =~ "status_changed"
    end
  end

  describe "audit" do
    test "queries audit log" do
      output = capture_io(fn -> Webhooks.run("audit", ["--project", "p-1"], []) end)
      assert output =~ "created"
    end
  end

  describe "changes" do
    test "queries change feed" do
      output =
        capture_io(fn ->
          Webhooks.run("changes", ["--project", "p-1", "--since", "2024-01-01T00:00:00Z"], [])
        end)

      assert output =~ "status_changed"
    end
  end
end
