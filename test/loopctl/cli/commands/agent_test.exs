defmodule Loopctl.CLI.Commands.AgentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Agent

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/agents/register"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "agent" => %{"id" => "a-1", "name" => "worker-1", "agent_type" => "implementer"}
          })

        {"GET", "/api/v1/stories/" <> _id} ->
          Req.Test.json(conn, %{
            "story" => %{
              "id" => "s-1",
              "title" => "Build API",
              "acceptance_criteria" => [
                %{"id" => "AC-1", "description" => "Endpoint works"},
                %{"id" => "AC-2", "description" => "Tests pass"}
              ],
              "agent_status" => "pending"
            }
          })

        {"POST", "/api/v1/stories/" <> _rest} ->
          Req.Test.json(conn, %{
            "story" => %{"id" => "s-1", "agent_status" => "contracted"}
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "agent register" do
    test "registers an agent" do
      output =
        capture_io(fn ->
          Agent.run("agent", ["register", "--name", "worker-1", "--type", "implementer"], [])
        end)

      assert output =~ "worker-1"
    end

    test "requires --name and --type" do
      output =
        capture_io(:stderr, fn ->
          Agent.run("agent", ["register", "--name", "only-name"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "contract" do
    test "fetches story, displays info, then contracts" do
      output =
        capture_io(fn ->
          Agent.run("contract", ["s-1"], [])
        end)

      assert output =~ "Story: Build API"
      assert output =~ "Acceptance Criteria: 2"
      assert output =~ "contracted"
    end
  end

  describe "claim" do
    test "claims a story" do
      output =
        capture_io(fn ->
          Agent.run("claim", ["s-1"], [])
        end)

      assert output =~ "s-1"
    end
  end

  describe "start" do
    test "starts a story" do
      output =
        capture_io(fn ->
          Agent.run("start", ["s-1"], [])
        end)

      assert output =~ "s-1"
    end
  end

  describe "report" do
    test "reports a story done" do
      output =
        capture_io(fn ->
          Agent.run("report", ["s-1"], [])
        end)

      assert output =~ "s-1"
    end

    test "reports with artifact JSON" do
      artifact = Jason.encode!(%{"type" => "schema", "path" => "lib/test.ex"})

      output =
        capture_io(fn ->
          Agent.run("report", ["s-1", "--artifact", artifact], [])
        end)

      assert output =~ "s-1"
    end
  end

  describe "unclaim" do
    test "unclaims a story" do
      output =
        capture_io(fn ->
          Agent.run("unclaim", ["s-1"], [])
        end)

      assert output =~ "s-1"
    end
  end
end
