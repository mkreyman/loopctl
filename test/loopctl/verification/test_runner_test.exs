defmodule Loopctl.Verification.TestRunnerTest do
  @moduledoc """
  Input hardening for the L3 verification runner — advisories ie-04
  (GHSA-pv74-gwwh-g92x) and ie-03 (GHSA-38cj-97f6-r82q).

  These tests exercise the validation helpers directly and assert that
  `run_tests/3` refuses hostile input BEFORE it can spawn `git`/`mix` or run
  `File.rm_rf/1`. US-26.4.6 adds the scrubbed environment and the per-command
  budgets, asserted on the step plan `run_tests/3` executes (`steps/5`) and on
  `exec/1` running a real command.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.TestRunner

  @anonymous %Credential{kind: :operator_token, token: nil}

  describe "safe_repo_url?/1" do
    test "accepts http(s) URLs with a real host" do
      assert TestRunner.safe_repo_url?("https://github.com/acme/app.git")
      assert TestRunner.safe_repo_url?("http://example.com/repo.git")
      assert TestRunner.safe_repo_url?("HTTPS://github.com/acme/app.git")
    end

    test "rejects remote-helper / file / ssh / local-path / flag-shaped forms" do
      refute TestRunner.safe_repo_url?("ext::sh -c 'touch /tmp/pwned'")
      refute TestRunner.safe_repo_url?("file:///etc/passwd")
      refute TestRunner.safe_repo_url?("ssh://git@github.com/acme/app.git")
      refute TestRunner.safe_repo_url?("git@github.com:acme/app.git")
      refute TestRunner.safe_repo_url?("/etc/passwd")
      refute TestRunner.safe_repo_url?("-oProxyCommand=evil")
      refute TestRunner.safe_repo_url?("https://")
      refute TestRunner.safe_repo_url?(nil)
      refute TestRunner.safe_repo_url?(123)
    end
  end

  describe "build_work_dir/0 and within_tmp?/1 (path fencing)" do
    test "build_work_dir is unique and always inside the system temp dir" do
      dir1 = TestRunner.build_work_dir()
      dir2 = TestRunner.build_work_dir()

      assert dir1 != dir2
      assert TestRunner.within_tmp?(dir1)
      assert TestRunner.within_tmp?(dir2)
      assert String.starts_with?(Path.basename(dir1), "loopctl_verify_")
    end

    test "within_tmp? rejects traversal and outside-tmp paths" do
      tmp = System.tmp_dir!()

      refute TestRunner.within_tmp?(Path.join(tmp, "../../etc"))
      refute TestRunner.within_tmp?("/etc")
      refute TestRunner.within_tmp?("/")
      # the temp dir itself must never be a deletion target
      refute TestRunner.within_tmp?(tmp)
      refute TestRunner.within_tmp?(nil)
    end

    test "build_work_dir/0 takes no input, so no SHA can ever reach the path" do
      # This documents the design, it does NOT feed a SHA into build_work_dir/0
      # (which is zero-arity): the path is derived from random bytes alone, so a
      # hostile commit_sha value has no channel to influence it. Every build
      # lands strictly inside the system temp dir.
      Enum.each(1..50, fn _ ->
        assert TestRunner.within_tmp?(TestRunner.build_work_dir())
      end)
    end
  end

  describe "enabled?/0 (runner gate, default off — advisory ie-03)" do
    test "is disabled in the test environment" do
      # config/test.exs keeps :enable_local_test_runner false; the runner
      # executes untrusted code and must be opt-in per environment.
      refute TestRunner.enabled?()
    end
  end

  describe "run_tests/3 refuses invalid input before spawning a subprocess" do
    @valid_sha String.duplicate("a", 40)
    @valid_url "https://github.com/acme/app.git"

    test "returns :invalid_commit_sha for a traversal SHA (before the enable gate)" do
      assert {:error, :invalid_commit_sha} =
               TestRunner.run_tests(@valid_url, "../../etc", @anonymous)
    end

    test "returns :invalid_commit_sha for a flag-shaped SHA" do
      assert {:error, :invalid_commit_sha} = TestRunner.run_tests(@valid_url, "-o=x", @anonymous)

      assert {:error, :invalid_commit_sha} =
               TestRunner.run_tests(@valid_url, "--upload-pack=x", @anonymous)
    end

    test "returns :invalid_commit_sha for a blank SHA" do
      assert {:error, :invalid_commit_sha} = TestRunner.run_tests(@valid_url, "", @anonymous)
    end

    test "returns :invalid_repo_url for an ext:: remote-helper URL" do
      assert {:error, :invalid_repo_url} =
               TestRunner.run_tests("ext::sh -c 'id'", @valid_sha, @anonymous)
    end

    test "returns :invalid_repo_url for a file:// URL" do
      assert {:error, :invalid_repo_url} =
               TestRunner.run_tests("file:///etc/passwd", @valid_sha, @anonymous)
    end

    test "returns :invalid_repo_url for a bare local path" do
      assert {:error, :invalid_repo_url} =
               TestRunner.run_tests("/tmp/evil", @valid_sha, @anonymous)
    end

    test "returns :runner_disabled for valid input when the runner is off (no clone)" do
      # Valid SHA + URL pass validation, then hit the default-off gate: the
      # runner never clones or executes anything.
      assert {:error, :runner_disabled} =
               TestRunner.run_tests(
                 @valid_url,
                 @valid_sha,
                 %Credential{kind: :operator_token, token: "ghp_never_used"}
               )
    end
  end

  # US-26.4.6 review round 1, finding 1: the fallback runs tenant code, so loopctl's own
  # environment must not reach it, and the credential must reach git's process only.
  describe "command_env/2 and steps/5: loopctl's environment never reaches tenant code" do
    @token "ghp_the_operator_token"
    @parent %{
      "PATH" => "/usr/bin:/bin",
      "HOME" => "/home/loopctl",
      "LANG" => "C.UTF-8",
      "GITHUB_TOKEN" => @token,
      "DATABASE_URL" => "ecto://loopctl:pw@db/loopctl",
      "SECRET_KEY_BASE" => "skb",
      "CLOAK_KEY" => "cloak",
      "LOOPCTL_ORCH_KEY" => "lc_orch",
      "RELEASE_COOKIE" => "cookie",
      "GIT_CONFIG_COUNT" => "7"
    }
    @secrets ~w(GITHUB_TOKEN DATABASE_URL SECRET_KEY_BASE CLOAK_KEY LOOPCTL_ORCH_KEY RELEASE_COOKIE)
    @credential %Credential{kind: :operator_token, token: @token}
    @work_dir "/tmp/loopctl_verify_x"

    defp plan,
      do: TestRunner.steps(@valid_url, @valid_sha, @work_dir, @credential, @parent)

    defp step(args_head), do: Enum.find(plan(), &(hd(&1.args) == args_head))

    defp carries_token?(env),
      do: Enum.any?(env, fn {_name, value} -> is_binary(value) and value =~ "AUTHORIZATION" end)

    test "every step unsets every secret and keeps only the allowlist" do
      for %{opts: opts} = step <- plan() do
        env = Map.new(opts[:env])

        for secret <- @secrets,
            do: assert(Map.fetch(env, secret) == {:ok, nil}, "#{secret} in #{inspect(step.args)}")

        # Allowlisted names are inherited, i.e. not named at all.
        for kept <- ["PATH", "HOME", "LANG"], do: refute(Map.has_key?(env, kept))
        assert env["MIX_ENV"] == "test"
        refute Enum.any?(Map.values(env), &(&1 == @token))
      end
    end

    test "the credential reaches git clone and git fetch, and nothing else" do
      for head <- ["clone", "fetch"] do
        assert carries_token?(step(head).opts[:env]), head
        assert step(head).command == "git"
      end

      for head <- ["checkout", "deps.get", "test"] do
        env = step(head).opts[:env]
        refute carries_token?(env), head

        refute Enum.any?(env, &match?({"GIT_CONFIG_" <> _, value} when is_binary(value), &1)),
               head
      end

      assert Enum.map(plan(), &{&1.command, hd(&1.args)}) == [
               {"git", "clone"},
               {"git", "fetch"},
               {"git", "checkout"},
               {"mix", "deps.get"},
               {"mix", "test"}
             ]
    end

    test "an inherited GIT_CONFIG_COUNT is replaced by the credential's, never duplicated" do
      env = step("clone").opts[:env]
      assert [{"GIT_CONFIG_COUNT", "2"}] = Enum.filter(env, &(elem(&1, 0) == "GIT_CONFIG_COUNT"))
    end

    test "every step is bounded, and the bounds sum to max_run_seconds/0" do
      budgets = Enum.map(plan(), & &1.budget)
      assert Enum.all?(budgets, &(is_integer(&1) and &1 > 0))
      assert TestRunner.max_run_seconds() == Enum.sum(budgets) + 30 * length(budgets)
    end

    # The WIRING: `exec/1` hands a step's env to the real process. `env` prints what the
    # child actually received; with the scrub dropped it prints loopctl's whole environment.
    test "a real command sees only the allowlist, MIX_ENV and nothing of the parent's" do
      allowed = ~w(PATH HOME LANG LC_ALL TMPDIR MIX_HOME HEX_HOME ASDF_DIR ASDF_DATA_DIR MIX_ENV)

      # Non-vacuous: this process has variables the scrub must remove.
      assert Enum.any?(Map.keys(System.get_env()), &(&1 not in allowed))

      step = %{command: "env", args: [], opts: [env: TestRunner.command_env(:plain)], budget: 10}
      assert {:ok, output, 0} = TestRunner.exec(step)

      names =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))

      assert "MIX_ENV" in names
      assert names -- allowed == []
    end
  end

  describe "exec/1: a command past its budget" do
    test "is killed and answers local_timeout" do
      started = System.monotonic_time(:millisecond)

      assert TestRunner.exec(%{command: "sleep", args: ["30"], opts: [], budget: 1}) ==
               {:error, :local_timeout}

      assert System.monotonic_time(:millisecond) - started < 10_000
    end

    test "one inside its budget answers its output and exit status" do
      assert {:ok, "hi\n", 0} =
               TestRunner.exec(%{command: "echo", args: ["hi"], opts: [], budget: 5})

      assert {:ok, _output, 1} =
               TestRunner.exec(%{command: "false", args: [], opts: [], budget: 5})
    end
  end
end
