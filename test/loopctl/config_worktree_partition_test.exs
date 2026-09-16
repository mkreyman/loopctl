defmodule Loopctl.ConfigWorktreePartitionTest do
  @moduledoc """
  The per-worktree test-database partition (`config/worktree_partition.exs`).

  TWO IMPLEMENTATIONS, ONE NAME. claude-config's git hooks
  (`~/.claude/hooks/lib/worktree-partition.sh`) derive the same partition in shell, and
  `bin/worktree-remove.sh` / `bin/worktree-db-sweep.sh` create, drop and sweep the database
  THAT name points at. A one-character divergence leaves the suite running on a database no
  tooling manages — silently, and only in a worktree. Every vector below is MEASURED output
  of the shell implementation, by feeding roots to `worktree_partition_for/1` itself from
  inside a real linked worktree (beelink and minis, 2026-09-16); the first two name
  databases that exist on minis. Do not "fix" one side alone.

  WHY THE SUITE CAN SEE THIS MODULE AT ALL: `config/test.exs` requires the file at boot,
  before compilation, which is also why the derivation cannot live under `lib/`.
  """
  # async: false — two tests set MIX_TEST_PARTITION, which is VM-global.
  use ExUnit.Case, async: false

  @config_dir Path.expand("../../config", __DIR__)
  @config_file Path.join(@config_dir, "test.exs")

  # Idempotent: `config/test.exs` already required this at boot. Guarded so the file is
  # never evaluated TWICE, which would redefine the module and warn — and `mix precommit`
  # runs `test --warnings-as-errors`.
  unless Code.ensure_loaded?(Loopctl.Config.WorktreePartition) do
    Code.require_file(Path.join(@config_dir, "worktree_partition.exs"))
  end

  alias Loopctl.Config.WorktreePartition

  @wt "/home/mkreyman/workspace/x/.claude/worktrees"

  @shell_vectors [
    {"/home/mkreyman/workspace/loopctl/.claude/worktrees/dispatch-key-revocation",
     "_wt_dispatch_key_revocat_a45df8"},
    {"/home/mkreyman/workspace/home_care_billing/.claude/worktrees/fee-schedule-fetch",
     "_wt_fee_schedule_fetch_9e050d"},
    {"#{@wt}/A_Weird--Name__x", "_wt_a_weird_name_x_0b8f7f"},
    {"#{@wt}/a-very-long-worktree-name-that-exceeds-twenty", "_wt_a_very_long_worktree_c20f4c"},
    {"#{@wt}/----", "_wt_cf2be3"},
    # The three that bind the BYTE-WISE masking. `LC_ALL=C tr -c 'a-z0-9' '_'` replaces
    # each non-ASCII BYTE, so a multi-byte character becomes one `_` per byte, which the
    # squeeze then collapses. `String.downcase/1` lowercases non-ASCII instead, and the
    # first two are where that DIVERGES: U+212A KELVIN SIGN downcases to an ASCII `k`
    # (giving `kelvin_k_k_name`), and U+0130 downcases to `i` plus a combining dot
    # (giving `dotted_i_name`). Without these, `mask/1` could be rewritten with
    # `String.downcase/1` and every assertion in this file would stay green — measured.
    {"#{@wt}/KELVIN-K-\u212A-name", "_wt_kelvin_k_name_2e3b0e"},
    {"#{@wt}/dotted-\u0130-name", "_wt_dotted_name_52d740"},
    {"#{@wt}/emoji-\u{1F642}-name", "_wt_emoji_name_dbbcf3"}
  ]

  describe "partition_for_root/1" do
    test "reproduces the shell implementation byte for byte" do
      for {root, expected} <- @shell_vectors do
        assert WorktreePartition.partition_for_root(root) == expected,
               "#{root} must derive #{expected}, the name the git hooks and the worktree " <>
                 "sweepers use; got #{WorktreePartition.partition_for_root(root)}"
      end
    end

    test "hashes the FULL root path, not the basename" do
      a = WorktreePartition.partition_for_root("/home/one/.claude/worktrees/probe")
      b = WorktreePartition.partition_for_root("/home/two/.claude/worktrees/probe")

      assert String.starts_with?(a, "_wt_probe_")
      assert String.starts_with?(b, "_wt_probe_")
      refute a == b
    end
  end

  describe "linked_worktree?/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "wt_partition_#{System.unique_integer([:positive])}")
      common = Path.join(dir, "common")
      private = Path.join(dir, "common/worktrees/probe")
      link = Path.join(dir, "link-to-common")
      File.mkdir_p!(private)
      File.ln_s!(common, link)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, common: common, private: private, link: link}
    end

    test "false for one directory reached by two spellings", ctx do
      refute WorktreePartition.linked_worktree?(ctx.common, ctx.common)

      assert WorktreePartition.linked_worktree?(ctx.common, ctx.link) == false,
             "a symlinked spelling of the SAME directory is the main tree; comparing the " <>
               "path strings would call it a worktree and partition the main tree's database"
    end

    test "true for a private git dir under the common one", ctx do
      assert WorktreePartition.linked_worktree?(ctx.private, ctx.common) == true
    end

    test "indeterminate when a path cannot be read", ctx do
      assert WorktreePartition.linked_worktree?(Path.join(ctx.dir, "gone"), ctx.common) ==
               :indeterminate
    end
  end

  describe "derive/1" do
    test "yields nothing outside a git repository" do
      dir =
        Path.join(System.tmp_dir!(), "wt_partition_nogit_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert WorktreePartition.derive(dir) == nil
    end

    test "agrees with git's own answer for the tree the suite is running in" do
      # Runs in the main tree AND in a linked worktree — the suite is expected in both —
      # and degrades with the derivation itself when there is no git answer at all.
      case System.cmd("git", ~w(rev-parse --git-dir --git-common-dir --show-toplevel),
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          [git_dir, common_dir, root] = String.split(out, "\n", trim: true)

          expected =
            case WorktreePartition.linked_worktree?(
                   Path.expand(git_dir),
                   Path.expand(common_dir)
                 ) do
              true -> WorktreePartition.partition_for_root(root)
              _ -> nil
            end

          assert WorktreePartition.derive() == expected

        _ ->
          assert WorktreePartition.derive() == nil
      end
    end
  end

  describe "choose/2 — an explicit MIX_TEST_PARTITION wins" do
    test "including an EMPTY string" do
      assert WorktreePartition.choose("", fn -> "_wt_derived" end) == "",
             "the shell tests `[ -n \"${MIX_TEST_PARTITION+x}\" ]` (set at all), so an " <>
               "explicit empty value must NOT fall through to the derivation"
    end

    test "for a non-empty value" do
      assert WorktreePartition.choose("_ci_3", fn -> "_wt_derived" end) == "_ci_3"
    end

    test "without even consulting the derivation" do
      assert WorktreePartition.choose("_ci_3", fn -> raise "derivation must not run" end) ==
               "_ci_3"
    end

    test "unset falls through to the derivation, and to an empty suffix in the main tree" do
      assert WorktreePartition.choose(nil, fn -> "_wt_derived" end) == "_wt_derived"
      assert WorktreePartition.choose(nil, fn -> nil end) == ""
    end
  end

  describe "suffix/1" do
    setup do
      previous = System.get_env("MIX_TEST_PARTITION")

      on_exit(fn ->
        if previous, do: System.put_env("MIX_TEST_PARTITION", previous)
        unless previous, do: System.delete_env("MIX_TEST_PARTITION")
      end)

      :ok
    end

    test "reads the environment variable" do
      System.put_env("MIX_TEST_PARTITION", "_ci_7")
      assert WorktreePartition.suffix() == "_ci_7"
    end

    test "is a string when unset, so it is safe to interpolate" do
      System.delete_env("MIX_TEST_PARTITION")
      assert is_binary(WorktreePartition.suffix())
    end
  end

  describe "config/test.exs wiring" do
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
      # `derive/1` above, and pinning the value here makes the assertion independent of
      # whether the suite itself is running in a worktree.
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
end
