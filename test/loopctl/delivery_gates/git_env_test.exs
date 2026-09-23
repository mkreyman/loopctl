defmodule Loopctl.DeliveryGates.GitEnvTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv
  alias Loopctl.DeliveryGates.Measurement.RepoHistory
  alias Mix.Tasks.Loopctl.Gates.CheckDrift

  # Pure. No tenant appears anywhere — this is about how a process spawns git.

  describe "one answer, and the two named entry points are it" do
    test "RepoHistory and CheckDrift spawn git with the identical environment" do
      # The defect this module exists to close: three lists, no one a superset of the others,
      # and the weakest the one a future caller copies. Asserted as EQUALITY rather than as
      # "both contain X", because a superset is exactly what the old arrangement looked like
      # from either side.
      assert RepoHistory.scrubbed_git_env() == GitEnv.spawn_env()
      assert CheckDrift.git_env() == GitEnv.spawn_env()
      assert CheckDrift.git_config_args() == GitEnv.config_args()
    end
  end

  describe "what the environment must contain" do
    test "every variable that redirects repository discovery is CLEARED" do
      env = Map.new(GitEnv.spawn_env())

      # Named literally, never read from discovery_overrides/0: a test that derives its
      # expectation from the list it checks moves with any change to that list and can never go
      # red when a name is dropped.
      for name <- ~w(GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
                     GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX
                     GIT_CEILING_DIRECTORIES) do
        assert Map.fetch(env, name) == {:ok, nil}, "#{name} is not cleared before spawning git"
      end
    end

    test "the user's global and system config are taken out of the picture" do
      env = Map.new(GitEnv.spawn_env())

      assert Map.fetch(env, "GIT_CONFIG_GLOBAL") == {:ok, "/dev/null"}
      assert Map.fetch(env, "GIT_CONFIG_NOSYSTEM") == {:ok, "1"}
    end

    test "hooks are neutralised on the command line for anything that may write" do
      assert GitEnv.config_args() == ["-c", "core.hooksPath=/dev/null"]
    end
  end

  describe "it actually works, not merely looks right" do
    test "a global core.hooksPath does not reach a repository spawned with this environment" do
      dir = Path.join(Loopctl.RealTmpDir.path!(), "gitenv_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      run = fn args ->
        {out, 0} =
          System.cmd("git", GitEnv.config_args() ++ ["-C", dir] ++ args,
            stderr_to_stdout: true,
            env: GitEnv.spawn_env()
          )

        String.trim(out)
      end

      run.(["init", "--quiet"])
      hook = run.(["rev-parse", "--git-path", "hooks/pre-commit"])

      # The fleet sets core.hooksPath globally. Under this environment it resolves inside the
      # throwaway repository, and to nothing executable.
      refute File.exists?(Path.expand(hook, dir))
      refute String.contains?(hook, ".git-hooks")
    end
  end
end
