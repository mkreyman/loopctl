defmodule Loopctl.DeliveryGates.GitEnv do
  @moduledoc """
  How every delivery-gates process spawns `git`: one environment, one set of `-c` overrides.

  This module exists because there were three answers to that question in this repository and
  none of them was a superset of the others — `Measurement.RepoHistory`'s, the drift task's, and
  a third inside `diff_names_test`. Two lists are one list and one bug, and the bug is silent:
  the weaker one is the one a future caller copies.

  ## Discovery, and why `-C` is not enough

  `git -C <repo>` does NOT win against `GIT_DIR`. `-C` changes the directory git starts from;
  `GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` name the repository outright and take
  precedence over discovery. Git EXPORTS those to hook processes, and this project's `pre-commit`
  hook runs the test suite — so anything spawning git from a test, a `git rebase -x`, a
  `git bisect run` or a `git filter-branch` inherits an environment already pointing at the
  repository that invoked it. Reads silently target the wrong repository; writes land in it.

  Measured twice on 2026-09-14, both with `-C` correctly passed: a measurement fixture committed
  to the working branch ten times with the suite green, and a drift fixture emptied
  `config/runtime.exs` and pushed. KB `d1f32cc7-0d0d-4b5c-b0e6-7785256c4d53`.

  ## Config, and why it is not merely hygiene

  `RepoHistory` originally left `GIT_CONFIG_*` alone, on the stated grounds that "the pins at the
  call sites already neutralise the config that could change a measurement". Those pins did not
  exist — there was no `-c` anywhere in the measurement modules — so the narrower list rested on
  a premise that was not true, which is why this consolidation is a correction rather than a
  reversal of someone's judgement.

  Two globals change behaviour here. `core.quotePath` changes the SHAPE of the paths git prints,
  and an anchored trigger pattern never matches a quoted one — `GateB` refuses such a path, so
  the effect is fail-closed rather than wrong, but the measurement still moves. And
  `core.hooksPath`, which is set globally on this fleet, means a freshly `git init`-ed throwaway
  repository still resolves the machine's real pre-commit hook and runs the whole quality gate on
  every fixture commit.
  """

  @discovery ~w(
    GIT_DIR
    GIT_WORK_TREE
    GIT_COMMON_DIR
    GIT_INDEX_FILE
    GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_NAMESPACE
    GIT_PREFIX
    GIT_CEILING_DIRECTORIES
  )

  @doc """
  The environment to spawn git with: discovery overrides cleared, global and system config out
  of the picture.
  """
  @spec spawn_env() :: [{String.t(), String.t() | nil}]
  def spawn_env do
    for(name <- @discovery, do: {name, nil}) ++
      [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
  end

  @doc """
  The discovery variables alone, for a caller that wants to name them.
  """
  @spec discovery_overrides() :: [String.t()]
  def discovery_overrides, do: @discovery

  @doc """
  Command-line `-c` overrides for an invocation that may WRITE.

  Belt and braces over `spawn_env/0`: `GIT_CONFIG_GLOBAL=/dev/null` already hides a global
  `core.hooksPath`, and this says so on the command line, where it is visible in a failure.
  """
  @spec config_args() :: [String.t()]
  def config_args, do: ["-c", "core.hooksPath=/dev/null"]
end
