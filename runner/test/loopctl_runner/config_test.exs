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
            # A credential port_env/4 unsets: configured here it would be dropped silently,
            # and only under the daemon.
            %{repo => %{"SSH_AUTH_SOCK" => "/tmp/agent"}},
            %{repo => %{"GH_TOKEN" => "x"}},
            %{repo => %{"GPG_AGENT_INFO" => "/tmp/agent:0:1"}},
            %{repo => %{"SSH_ASKPASS" => "/tmp/askpass"}},
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

    test "a SHAPE-matched name is allowed here: this is the escape hatch for the heuristic" do
      # The shape deny is a heuristic over an environment nobody enumerated, and it over-matches
      # real cases — SECRET_KEY_BASE for a test env, a key that is publishable by design. Naming
      # one here is the operator making the judgement the shape cannot, for ONE repo, in a file
      # only they write. Refusing it left them no way to keep it at all.
      root = tmp_dir!("session-env-shaped")
      repo = config_map(root)["repos"] |> Map.keys() |> hd()

      env = %{repo => %{"SECRET_KEY_BASE" => "x", "STRIPE_PUBLISHABLE_KEY" => "y"}}
      assert {:ok, config} = Config.from_map(with_env(root, env))

      assert [{"SECRET_KEY_BASE", "x"}, {"STRIPE_PUBLISHABLE_KEY", "y"}] =
               Config.session_env_for(config, repo, "story-a", "0123456789abcdef")

      # ...and they really are names the shape deny matches, or this proves nothing.
      assert LoopctlRunner.Session.credential_shaped?("SECRET_KEY_BASE")
      assert LoopctlRunner.Session.credential_shaped?("STRIPE_PUBLISHABLE_KEY")
    end

    test "the refusal says WHICH rule refused, because one of them is a breaking change" do
      # A repo that set GH_TOKEN here loaded yesterday and does not today, and the failure is not
      # local: Config.load/1 refuses the WHOLE config, which aborts rel/install.sh's preflight. A
      # message identical to a mistyped value sends the operator to look at the value.
      root = tmp_dir!("session-env-message")
      repo = config_map(root)["repos"] |> Map.keys() |> hd()

      assert {:error, credential} =
               Config.from_map(with_env(root, %{repo => %{"GH_TOKEN" => "x"}}))

      assert credential =~ "session_env.#{repo}.GH_TOKEN"
      # The reason must be TRUE for this name: GH_TOKEN is unset whatever the environment holds.
      # The message used to claim that certainty for SHAPE-matched names too, where it is false —
      # port_env/4 unsets a shaped name only when the daemon's environment carries it — and it
      # sent the operator to change LoopctlRunner.Session, where no mechanism to help them exists.
      assert credential =~ "UNCONDITIONALLY"
      refute credential =~ "LoopctlRunner.Session"

      # A shaped name is no longer refused at all: naming it here is how it is kept.
      assert {:ok, _} = Config.from_map(with_env(root, %{repo => %{"NPM_TOKEN" => "x"}}))

      # The other causes keep their own wording, so the three are told apart.
      assert {:error, managed} =
               Config.from_map(with_env(root, %{repo => %{"GIT_DIR" => "/tmp"}}))

      assert managed =~ "the runner manages itself"
      refute managed =~ "UNCONDITIONALLY"

      assert {:error, value} = Config.from_map(with_env(root, %{repo => %{"OK" => 1}}))
      assert value =~ "is not a string value"
      refute value =~ "UNCONDITIONALLY"
    end
  end

  test "an allowed_tools rule for a tool sessions cannot have is refused at load" do
    root = tmp_dir!("tools-rule")

    for ok <- [["Bash(mix test:*)", "Read(./**)", "Edit(./lib/**)", "Bash(git status)"], []] do
      assert {:ok, _} = Config.from_map(Map.put(config_map(root), "allowed_tools", ok))
    end

    for bad <- ["WebFetch", "Skill", "Agent", "mcp__loopctl__get_story", "WebSearch(x)"] do
      assert {:error, msg} = Config.from_map(Map.put(config_map(root), "allowed_tools", [bad]))
      assert msg =~ "names a tool sessions do not have"
    end
  end

  test "a rule wider than it reads is refused at load: unscoped file tools, shells, bare Bash" do
    root = tmp_dir!("tools-scope")

    for {bad, why} <- [
          {"Write", "not scoped to the worktree"},
          {"Edit(~/**)", "not scoped to the worktree"},
          {"Read(/etc/**)", "not scoped to the worktree"},
          {"Write(./../outside/**)", "not scoped to the worktree"},
          {"Grep(./)", "not scoped to the worktree"},
          {"Bash", "does not name one command"},
          {"Bash(*)", "does not name one command"},
          {"Bash(bash:*)", "does not name one command"},
          {"Bash(sh -c:*)", "does not name one command"},
          {"Bash(/usr/bin/env:*)", "does not name one command"},
          {"Bash(python3:*)", "does not name one command"}
        ] do
      assert {:error, msg} = Config.from_map(Map.put(config_map(root), "allowed_tools", [bad]))
      assert msg =~ why, inspect(bad)
    end
  end
end
