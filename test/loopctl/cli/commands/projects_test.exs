defmodule Loopctl.CLI.Commands.ProjectsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Projects

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/projects"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "project" => %{"id" => "p-1", "name" => "My Project", "slug" => "my-project"}
          })

        {"GET", "/api/v1/projects"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "p-1",
                "name" => "My Project",
                "slug" => "my-project",
                "status" => "active"
              }
            ]
          })

        {"GET", "/api/v1/projects/p-1"} ->
          Req.Test.json(conn, %{
            "project" => %{"id" => "p-1", "name" => "My Project"}
          })

        {"DELETE", "/api/v1/projects/" <> _id} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/api/v1/projects/" <> _rest} ->
          Req.Test.json(conn, %{
            "epics_created" => 2,
            "stories_created" => 10
          })

        {"GET", "/api/v1/projects/" <> _rest} ->
          Req.Test.json(conn, %{
            "epics" => [%{"number" => 1, "title" => "Foundation"}]
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "project create" do
    test "creates a project with name" do
      output =
        capture_io(fn ->
          Projects.run(
            "project",
            ["create", "My Project", "--repo", "https://github.com/x/y"],
            []
          )
        end)

      assert output =~ "My Project"
    end

    test "requires a name" do
      output =
        capture_io(:stderr, fn ->
          Projects.run("project", ["create"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "project list" do
    test "lists projects" do
      output =
        capture_io(fn ->
          Projects.run("project", ["list"], [])
        end)

      assert output =~ "My Project"
    end
  end

  describe "project info" do
    test "shows project info" do
      output =
        capture_io(fn ->
          Projects.run("project", ["info", "p-1"], [])
        end)

      assert output =~ "My Project"
    end
  end

  describe "project archive" do
    test "archives a project" do
      output =
        capture_io(fn ->
          Projects.run("project", ["archive", "p-1"], [])
        end)

      assert output =~ "archived"
    end
  end

  describe "import" do
    test "requires --project" do
      output =
        capture_io(:stderr, fn ->
          Projects.run("import", ["some/path"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "export" do
    test "exports a project" do
      output =
        capture_io(fn ->
          Projects.run("export", ["--project", "p-1"], [])
        end)

      assert output =~ "Foundation"
    end

    test "requires --project" do
      output =
        capture_io(:stderr, fn ->
          Projects.run("export", [], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "invalid subcommand" do
    test "shows usage" do
      output =
        capture_io(:stderr, fn ->
          Projects.run("project", ["bogus"], [])
        end)

      assert output =~ "Usage:"
    end
  end
end
