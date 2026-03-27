defmodule Loopctl.CLI.Commands.StatusTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Status

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/projects/p-1/progress"} ->
          Req.Test.json(conn, %{
            "total_stories" => 25,
            "verified" => 20,
            "progress_percent" => 80
          })

        {"GET", "/api/v1/epics/e-1/progress"} ->
          Req.Test.json(conn, %{
            "total_stories" => 5,
            "verified" => 3,
            "progress_percent" => 60
          })

        {"GET", "/api/v1/stories/s-1"} ->
          Req.Test.json(conn, %{
            "story" => %{
              "id" => "s-1",
              "number" => "1.1",
              "title" => "Foundation",
              "agent_status" => "pending"
            }
          })

        {"GET", "/api/v1/stories/ready"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"id" => "s-2", "number" => "1.2", "title" => "Auth", "agent_status" => "pending"}
            ]
          })

        {"GET", "/api/v1/stories/blocked"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "s-3",
                "number" => "2.1",
                "title" => "Blocked Story",
                "agent_status" => "pending"
              }
            ]
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "status --project" do
    test "shows project progress" do
      output =
        capture_io(fn ->
          Status.run("status", ["--project", "p-1"], [])
        end)

      assert output =~ "80"
    end
  end

  describe "status --epic" do
    test "shows epic progress" do
      output =
        capture_io(fn ->
          Status.run("status", ["--epic", "e-1"], [])
        end)

      assert output =~ "60"
    end
  end

  describe "status <story_id>" do
    test "shows story detail" do
      output =
        capture_io(fn ->
          Status.run("status", ["s-1"], [])
        end)

      assert output =~ "Foundation"
    end
  end

  describe "next" do
    test "lists ready stories" do
      output =
        capture_io(fn ->
          Status.run("next", ["--project", "p-1"], [])
        end)

      assert output =~ "Auth"
    end
  end

  describe "blocked" do
    test "lists blocked stories" do
      output =
        capture_io(fn ->
          Status.run("blocked", ["--project", "p-1"], [])
        end)

      assert output =~ "Blocked Story"
    end
  end

  describe "no arguments" do
    test "shows usage" do
      output =
        capture_io(:stderr, fn ->
          Status.run("status", [], [])
        end)

      assert output =~ "Usage:"
    end
  end
end
