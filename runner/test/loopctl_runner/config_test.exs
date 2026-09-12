defmodule LoopctlRunner.ConfigTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Config
  import LoopctlRunner.TestSupport

  setup do
    {:ok, root: tmp_dir!("config")}
  end

  test "a complete config loads, expanding paths and keeping explicit integers", %{root: root} do
    path = Path.join(root, "runner.json")
    File.write!(path, JSON.encode!(config_map(root, %{"park_after_s" => 42})))

    assert {:ok, %Config{} = config} = Config.load(path)
    assert config.repos == %{"fixture" => Path.join(root, "repo")}
    assert config.park_after_s == 42
    assert config.claude_launcher == headless_launcher()
  end

  describe "fails closed" do
    test "on a missing file", %{root: root} do
      assert {:error, "cannot read config " <> _} = Config.load(Path.join(root, "absent.json"))
    end

    test "on an empty file", %{root: root} do
      path = Path.join(root, "runner.json")
      File.write!(path, "  \n")
      assert {:error, "config " <> rest} = Config.load(path)
      assert rest =~ "is empty"
    end

    test "on invalid JSON", %{root: root} do
      path = Path.join(root, "runner.json")
      File.write!(path, "{\"repos\": ")
      assert {:error, "config is not valid JSON" <> _} = Config.load(path)
    end

    test "on a JSON value that is not an object", %{root: root} do
      path = Path.join(root, "runner.json")
      File.write!(path, "[]")
      assert {:error, "config must be a JSON object"} = Config.load(path)
    end

    test "on an empty repo allow-list", %{root: root} do
      assert {:error, "config repos " <> _} = Config.from_map(config_map(root, %{"repos" => %{}}))
    end

    test "on an empty branch prefix list", %{root: root} do
      assert {:error, "config branch_prefixes " <> _} =
               Config.from_map(config_map(root, %{"branch_prefixes" => []}))
    end

    test "on a non-positive budget", %{root: root} do
      assert {:error, "config max_turns must be a positive integer"} =
               Config.from_map(config_map(root, %{"max_turns" => 0}))
    end
  end

  describe "the claude launcher" do
    test "is refused when it is the bare CLI", %{root: root} do
      assert {:error, "config claude_launcher must be claude-headless.sh" <> _} =
               Config.from_map(
                 config_map(root, %{
                   "claude_launcher" => System.find_executable("claude") || "/usr/bin/claude"
                 })
               )
    end

    test "is refused when named right but not stripping the API key", %{root: root} do
      impostor = Path.join(root, "claude-headless.sh")
      File.write!(impostor, "#!/bin/sh\nexec claude \"$@\"\n")
      File.chmod!(impostor, 0o755)

      assert {:error, "config claude_launcher " <> rest} =
               Config.from_map(config_map(root, %{"claude_launcher" => impostor}))

      assert rest =~ "does not strip ANTHROPIC_API_KEY"
    end

    test "is refused when not executable", %{root: root} do
      copy = Path.join(root, "claude-headless.sh")
      File.write!(copy, "unset ANTHROPIC_API_KEY\n")
      File.chmod!(copy, 0o644)

      assert {:error, "config claude_launcher " <> rest} =
               Config.from_map(config_map(root, %{"claude_launcher" => copy}))

      assert rest =~ "not an executable file"
    end
  end
end
