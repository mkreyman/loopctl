defmodule ChgAdapter.SnapshotTest do
  use ExUnit.Case, async: false

  import Mix.Tasks.Chg.Snapshot, only: [check_cwd_off?: 1, project_config: 2]

  defmodule PerEnvProject do
    def project, do: [elixirc_options: if(Mix.env() == :dev, do: [check_cwd: false], else: [])]
  end

  test "the cwd check is off through elixirc_options or a compile alias" do
    assert check_cwd_off?(elixirc_options: [debug_info: true, check_cwd: false])
    assert check_cwd_off?(aliases: [compile: ["compile --no-check-cwd"]])
    assert check_cwd_off?(aliases: [compile: "compile --no-check-cwd"])
  end

  test "a project that keeps the cwd check is refused" do
    refute check_cwd_off?([])
    refute check_cwd_off?(elixirc_options: [check_cwd: true])
    refute check_cwd_off?(aliases: [compile: ["compile --warnings-as-errors"]])
    refute check_cwd_off?(aliases: [compile: [&IO.inspect/1]])
  end

  test "each env's config is read under that env, and the current env is restored" do
    env = Mix.env()
    assert check_cwd_off?(project_config(PerEnvProject, :dev))
    refute check_cwd_off?(project_config(PerEnvProject, :test))
    assert Mix.env() == env
  end
end
