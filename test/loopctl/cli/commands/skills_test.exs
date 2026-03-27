defmodule Loopctl.CLI.Commands.SkillsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Skills

  setup do
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/skills"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "sk-1",
                "name" => "loopctl:review",
                "current_version" => 2,
                "status" => "active"
              }
            ],
            "meta" => %{"total_count" => 1}
          })

        {"GET", "/api/v1/skills/sk-1"} ->
          Req.Test.json(conn, %{
            "skill" => %{
              "id" => "sk-1",
              "name" => "loopctl:review",
              "current_version" => 2
            },
            "current_prompt" => "Review all code..."
          })

        {"POST", "/api/v1/skills"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "skill" => %{"id" => "sk-new", "name" => "new-skill"},
            "version" => %{"version" => 1}
          })

        {"POST", "/api/v1/skills/sk-1/versions"} ->
          conn = Plug.Conn.put_status(conn, 201)

          Req.Test.json(conn, %{
            "skill" => %{"id" => "sk-1", "current_version" => 3},
            "version" => %{"version" => 3}
          })

        {"GET", "/api/v1/skills/sk-1/versions"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"version" => 1, "changelog" => "Initial", "created_by" => "user"},
              %{"version" => 2, "changelog" => "Updated", "created_by" => "user"}
            ]
          })

        {"GET", "/api/v1/skills/sk-1/versions/1"} ->
          Req.Test.json(conn, %{
            "version" => %{"version" => 1, "prompt_text" => "V1 prompt"}
          })

        {"GET", "/api/v1/skills/sk-1/stats"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{"version" => 1, "total_results" => 5, "pass_count" => 4, "fail_count" => 1}
            ]
          })

        {"DELETE", "/api/v1/skills/" <> _id} ->
          Req.Test.json(conn, %{
            "skill" => %{"id" => "sk-1", "status" => "archived"}
          })

        {"POST", "/api/v1/skills/import"} ->
          Req.Test.json(conn, %{
            "total" => 2,
            "created" => 2,
            "updated" => 0,
            "errored" => 0
          })

        _ ->
          conn = Plug.Conn.put_status(conn, 404)
          Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    :ok
  end

  describe "skill list" do
    test "lists skills" do
      output = capture_io(fn -> Skills.run("skill", ["list"], []) end)
      assert output =~ "loopctl:review"
    end
  end

  describe "skill get" do
    test "gets a skill by name" do
      output = capture_io(fn -> Skills.run("skill", ["get", "loopctl:review"], []) end)
      assert output =~ "Review all code"
    end

    test "gets a specific version" do
      output =
        capture_io(fn ->
          Skills.run("skill", ["get", "loopctl:review", "--version", "1"], [])
        end)

      assert output =~ "V1 prompt"
    end
  end

  describe "skill create" do
    test "requires --name and --file" do
      output =
        capture_io(:stderr, fn ->
          Skills.run("skill", ["create", "--name", "my-skill"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "skill update" do
    test "requires --file" do
      output =
        capture_io(:stderr, fn ->
          Skills.run("skill", ["update", "my-skill"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "skill stats" do
    test "shows performance stats" do
      output = capture_io(fn -> Skills.run("skill", ["stats", "loopctl:review"], []) end)
      assert output =~ "pass_count"
    end
  end

  describe "skill history" do
    test "shows version history" do
      output = capture_io(fn -> Skills.run("skill", ["history", "loopctl:review"], []) end)
      assert output =~ "Updated"
    end
  end

  describe "skill archive" do
    test "archives a skill" do
      output = capture_io(fn -> Skills.run("skill", ["archive", "loopctl:review"], []) end)
      assert output =~ "archived"
    end
  end

  describe "skill import" do
    test "requires directory argument" do
      output =
        capture_io(:stderr, fn ->
          Skills.run("skill", ["import"], [])
        end)

      assert output =~ "Usage:"
    end
  end

  describe "invalid subcommand" do
    test "shows usage" do
      output =
        capture_io(:stderr, fn ->
          Skills.run("skill", ["bogus"], [])
        end)

      assert output =~ "Usage:"
    end
  end
end
