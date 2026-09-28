defmodule LoopctlRunner.ConfigTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Config
  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  setup do
    {:ok, root: tmp_dir!("config")}
  end

  test "a grant_dir the hook cannot see is warned about; the same directory by any path is not",
       %{root: root} do
    # block-subagent-git.sh reads $HOME/.claude alone: grants armed anywhere else leave every
    # dispatched agent's commit refused while the runner looks healthy.
    home_claude = Path.join(root, "home/.claude")
    File.mkdir_p!(home_claude)
    config = config!(root)

    assert capture_log(fn -> Config.warn_if_hook_cannot_see_grants(config, home_claude) end) =~
             "invisible to it"

    # A HOME reached through a symlink names the directory the hook reads, by another path.
    File.ln_s!(Path.join(root, "home"), Path.join(root, "linked-home"))
    linked = %{config | grant_dir: Path.join(root, "linked-home/.claude")}

    refute capture_log(fn -> Config.warn_if_hook_cannot_see_grants(linked, home_claude) end) =~
             "grant_dir"

    same = %{config | grant_dir: home_claude}

    refute capture_log(fn -> Config.warn_if_hook_cannot_see_grants(same, home_claude) end) =~
             "grant_dir"
  end

  test "loading a config warns nothing about its grant_dir", %{root: root} do
    # Every test config points grant_dir at a directory of its own and goes through load/1: the
    # warning belongs to the entry points that arm grants for real (control_config_test).
    moved = Path.join(root, "moved.json")
    File.write!(moved, JSON.encode!(config_map(root)))
    refute capture_log(fn -> {:ok, _} = Config.load(moved) end) =~ "grant_dir"
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

    test "on a prefix loopctl's join schema would refuse, since every join declares them", %{
      root: root
    } do
      # A dot is not in the contract's prefix pattern, so this config would fail EVERY join.
      assert {:error, "config branch_prefixes cannot be declared to loopctl: " <> _} =
               Config.from_map(config_map(root, %{"branch_prefixes" => ["feat.x/"]}))

      nine = for n <- 1..9, do: "p#{n}/"

      assert {:error, "config branch_prefixes cannot be declared to loopctl: " <> _} =
               Config.from_map(config_map(root, %{"branch_prefixes" => nine}))
    end

    test "on a non-positive budget", %{root: root} do
      assert {:error, "config max_turns must be a positive integer"} =
               Config.from_map(config_map(root, %{"max_turns" => 0}))
    end

    test "when no grant_dir is configured and HOME is not set", %{root: root} do
      # The BEAM reads its home once, at boot, so only a VM started without HOME can show this:
      # one is started here on the suite's own compiled code, with the same Erlang and Elixir.
      path = Path.join(root, "runner.json")
      File.write!(path, JSON.encode!(Map.delete(config_map(root), "grant_dir")))
      elixir = Path.expand("../../bin/elixir", :code.lib_dir(:elixir))
      ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      {out, _status} =
        System.cmd(
          elixir,
          Enum.flat_map(ebins, &["-pa", &1]) ++
            ["-e", "IO.inspect(LoopctlRunner.Config.load(#{inspect(path)}))"],
          env: [
            {"HOME", nil},
            {"PATH", Path.join(:code.root_dir(), "bin") <> ":" <> System.get_env("PATH")}
          ],
          stderr_to_stdout: true
        )

      assert out =~ ~s({:error, "cannot resolve grant_dir: HOME is not set"})
    end
  end

  describe "an obsolete key" do
    test "allowed_tools loads, with one warning naming it obsolete and ignored", %{root: root} do
      # Configs already on the dev machines carry it: refusing them would stop those daemons over
      # a key that grants nothing now that no --allowedTools is composed.
      path = Path.join(root, "runner.json")

      File.write!(
        path,
        JSON.encode!(config_map(root, %{"allowed_tools" => ["Bash(mix test:*)"]}))
      )

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %Config{}} = Config.load(path) end)

      assert [_one] =
               Regex.scan(~r/#{Regex.escape(path)}: allowed_tools is obsolete and ignored/, log)
    end

    test "is not warned about when absent", %{root: root} do
      path = Path.join(root, "runner.json")
      File.write!(path, JSON.encode!(config_map(root)))

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %Config{}} = Config.load(path) end)

      refute log =~ path
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

  describe "session_env" do
    defp with_env(root, env), do: Map.put(config_map(root), "session_env", env)

    test "is per repo, and refuses names the runner owns, unknown repos, and non-string values" do
      root = tmp_dir!("session-env")
      repo = config_map(root)["repos"] |> Map.keys() |> hd()

      env = %{repo => %{"TEST_DB_BASE" => "x_{story}", "RUN_PROBE" => "r_{run}"}}
      assert {:ok, config} = Config.from_map(with_env(root, env))

      [{"RUN_PROBE", "r_01234567"}, {"TEST_DB_BASE", "x_" <> story}] =
        Config.session_env_for(config, repo, "story-a", "0123456789abcdef")

      # {story} is stable across a story's runs, and differs between stories.
      assert [_, {"TEST_DB_BASE", "x_" <> ^story}] =
               Config.session_env_for(config, repo, "story-a", "fedcba9876543210")

      assert [_, {"TEST_DB_BASE", other}] =
               Config.session_env_for(config, repo, "story-b", "0123456789abcdef")

      assert other != "x_" <> story
      assert byte_size(story) == 8
      assert Config.session_env_for(config, "other", "story-a", "0123456789abcdef") == []

      for bad <- [
            %{repo => %{"LOOP_MODE" => "0"}},
            %{repo => %{"LOOPCTL_LAUNCHER_SETSID" => "1"}},
            %{repo => %{"ANTHROPIC_API_KEY" => "x"}},
            %{repo => %{"GIT_DIR" => "/tmp"}},
            %{repo => %{"RELEASE_COOKIE" => "x"}},
            %{repo => %{"ERL_CRASH_DUMP_SECONDS" => "0"}},
            %{repo => %{"ROOTDIR" => "/tmp"}},
            %{repo => %{"lower" => "x"}},
            %{repo => %{"OK" => 1}},
            %{"not_a_repo" => %{"OK" => "x"}},
            %{repo => "x"}
          ] do
        assert {:error, _} = Config.from_map(with_env(root, bad)), inspect(bad)
      end
    end

    test "a config carrying session_env is refused when other users can read it" do
      # The hatch is only as good as the file it lives in: we now tell operators to put a
      # credential here, and under a default umask runner.json is 0644. The same 0o077 test the
      # channel token already gets, and only when session_env carries something — a config
      # without it holds no secret of its own.
      root = tmp_dir!("session-env-mode")
      repo = config_map(root)["repos"] |> Map.keys() |> hd()
      path = Path.join(root, "runner.json")

      File.write!(path, JSON.encode!(with_env(root, %{repo => %{"SECRET_KEY_BASE" => "x"}})))
      File.chmod!(path, 0o644)

      assert {:error, message} = Config.load(path)
      assert message =~ "session_env"
      assert message =~ "chmod 600"

      File.chmod!(path, 0o600)
      assert {:ok, _} = Config.load(path)

      # A config with no session_env is not refused: that property was never relied on there.
      plain = Path.join(root, "plain.json")
      File.write!(plain, JSON.encode!(config_map(root)))
      File.chmod!(plain, 0o644)
      assert {:ok, _} = Config.load(plain)
    end

    test "a credential is accepted, since a session keeps it; the refusals name their rule" do
      # A session inherits every credential an attended one has (only ANTHROPIC_API_KEY is unset,
      # and ANTHROPIC_* is runner-managed), so a value here reaches the session and is allowed.
      root = tmp_dir!("session-env-message")
      repo = config_map(root)["repos"] |> Map.keys() |> hd()

      for name <- ~w(GH_TOKEN SSH_AUTH_SOCK NPM_TOKEN) do
        assert {:ok, _} = Config.from_map(with_env(root, %{repo => %{name => "x"}})), name
      end

      # The causes keep their own wording, so an operator is sent to the name or to the value.
      assert {:error, managed} =
               Config.from_map(with_env(root, %{repo => %{"GIT_DIR" => "/tmp"}}))

      assert managed =~ "the runner manages itself"

      assert {:error, value} = Config.from_map(with_env(root, %{repo => %{"OK" => 1}}))
      assert value =~ "is not a string value"
      refute value =~ "the runner manages itself"
    end
  end
end
