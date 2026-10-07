defmodule Loopctl.ConfigTestExsPartitionWiringTest do
  @moduledoc """
  `config/test.exs` gives every repo AND the local secrets file the per-worktree partition
  (`config/worktree_partition.exs`; the derivation itself is
  `Loopctl.ConfigWorktreePartitionTest`).

  `async: false` because the subject is config/test.exs's OWN read of the OS environment
  variable `MIX_TEST_PARTITION`: `Config.Reader` evaluates the file, which calls
  `System.get_env/1` directly, so the only way to hand it a value is to set the variable in
  the BEAM's environment, which every concurrent test shares. That read stays in the file on
  purpose — `Loopctl.ConfigWorktreePartitionTest` pins it as executable code for
  claude-config's worktree sweeper.
  """
  use ExUnit.Case, async: false

  @config_file Path.expand("../../config/test.exs", __DIR__)

  setup do
    previous = System.get_env("MIX_TEST_PARTITION")

    on_exit(fn ->
      if previous, do: System.put_env("MIX_TEST_PARTITION", previous)
      unless previous, do: System.delete_env("MIX_TEST_PARTITION")
    end)

    :ok
  end

  test "every repo AND the local secrets file carry the partition" do
    # A sentinel through the real config file: the derivation is exercised in
    # `Loopctl.ConfigWorktreePartitionTest`, and pinning the value here makes the assertion
    # independent of whether the suite itself is running in a worktree.
    System.put_env("MIX_TEST_PARTITION", "_wt_wiring_probe")

    config = Config.Reader.read!(@config_file, env: :test)[:loopctl]

    for repo <- [Loopctl.Repo, Loopctl.AdminRepo, Loopctl.HeavyReadRepo] do
      assert config[repo][:database] == "loopctl_test_wt_wiring_probe",
             "#{inspect(repo)} must use the partitioned database — all three share one " <>
               "database and must move together"
    end

    assert Path.basename(config[:secrets_file]) ==
             "loopctl_local_secrets_test_wt_wiring_probe.json"
  end
end
