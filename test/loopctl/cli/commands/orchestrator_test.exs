defmodule Loopctl.CLI.Commands.OrchestratorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Orchestrator

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/stories/" <> _rest} ->
          Req.Test.json(conn, %{
            "story" => %{"id" => "s-1", "verified_status" => "verified"}
          })

        {"GET", "/api/v1/stories/ready"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "s-2",
                "number" => "1.2",
                "title" => "Pending Story",
                "agent_status" => "reported_done"
              }
            ]
          })

        {"PUT", "/api/v1/orchestrator/state/" <> _id} ->
          Req.Test.json(conn, %{
            "state_key" => "main",
            "version" => 1,
            "state_data" => %{"progress" => 50}
          })

        {"GET", "/api/v1/orchestrator/state/" <> _id} ->
          Req.Test.json(conn, %{
            "state_key" => "main",
            "version" => 1,
            "state_data" => %{"progress" => 50}
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "verify" do
    test "verifies a story" do
      output =
        capture_io(fn ->
          Orchestrator.run("verify", ["s-1", "--result", "pass", "--summary", "All good"], [])
        end)

      assert output =~ "verified"
    end
  end

  describe "reject" do
    test "rejects a story" do
      output =
        capture_io(fn ->
          Orchestrator.run("reject", ["s-1", "--reason", "Tests fail"], [])
        end)

      assert output =~ "s-1"
    end
  end

  describe "pending" do
    test "lists pending stories" do
      output =
        capture_io(fn ->
          Orchestrator.run("pending", ["--project", "p-1"], [])
        end)

      assert output =~ "Pending Story"
    end
  end

  describe "state save" do
    test "saves orchestrator state" do
      data = Jason.encode!(%{"progress" => 50})

      output =
        capture_io(fn ->
          Orchestrator.run("state", ["save", "--project", "p-1", "--data", data], [])
        end)

      assert output =~ "main"
    end

    test "requires --project and --data" do
      output =
        capture_io(:stderr, fn ->
          Orchestrator.run("state", ["save", "--project", "p-1"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "state load" do
    test "loads orchestrator state" do
      output =
        capture_io(fn ->
          Orchestrator.run("state", ["load", "--project", "p-1"], [])
        end)

      assert output =~ "main"
    end

    test "requires --project" do
      output =
        capture_io(:stderr, fn ->
          Orchestrator.run("state", ["load"], [])
        end)

      assert output =~ "Usage:"
    end
  end
end
