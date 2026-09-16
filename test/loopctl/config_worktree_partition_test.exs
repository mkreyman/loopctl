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
  @module_file Path.join(@config_dir, "worktree_partition.exs")

  # Idempotent: `config/test.exs` already required this at boot. Guarded so the file is
  # never evaluated TWICE, which would redefine the module and warn — and `mix precommit`
  # runs `test --warnings-as-errors`.
  unless Code.ensure_loaded?(Loopctl.Config.WorktreePartition) do
    Code.require_file(Path.join(@config_dir, "worktree_partition.exs"))
  end

  alias Loopctl.Config.WorktreePartition

  @wt "/home/mkreyman/workspace/x/.claude/worktrees"

  # The ORACLE's own copy of the command, hand-written and deliberately NOT read from the
  # module: an oracle derived from the code under test cannot contradict it. The copy is
  # safe to keep because drift between the two is LOUD, not silent — a flag added to the
  # module makes `rev_parse/1` see four lines, return `:error` and degrade to nil while this
  # oracle still resolves, which fails "agrees with git's own answer" — and because
  # "the command rev_parse/1 actually runs" below pins the module's own value directly.
  @rev_parse_sh "git rev-parse --git-dir --git-common-dir --show-toplevel 2>/dev/null"

  @rev_parse_flags ~w(--git-dir --git-common-dir --show-toplevel)

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

  describe "linked_worktree_status/2" do
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

    test "main for one directory reached by two spellings", ctx do
      assert WorktreePartition.linked_worktree_status(ctx.common, ctx.common) == :main

      assert WorktreePartition.linked_worktree_status(ctx.common, ctx.link) == :main,
             "a symlinked spelling of the SAME directory is the main tree; comparing the " <>
               "path strings would call it a worktree and partition the main tree's database"
    end

    test "linked for a private git dir under the common one", ctx do
      assert WorktreePartition.linked_worktree_status(ctx.private, ctx.common) == :linked
    end

    test "indeterminate when a path cannot be read", ctx do
      assert WorktreePartition.linked_worktree_status(Path.join(ctx.dir, "gone"), ctx.common) ==
               :indeterminate
    end

    test "answers with three distinct atoms and never a bare boolean", ctx do
      # The function is NOT named with a `?` precisely because it has three answers. When it
      # was `linked_worktree?/2` it returned the TRUTHY atom `:indeterminate`, and `derive/1`
      # was safe only because it matched `true <-`: one `if` at a future call site would have
      # read "cannot classify this tree" as "linked" and partitioned the MAIN tree's database
      # into a name the worktree sweeper treats as disposable.
      answers = [
        WorktreePartition.linked_worktree_status(ctx.common, ctx.common),
        WorktreePartition.linked_worktree_status(ctx.private, ctx.common),
        WorktreePartition.linked_worktree_status(Path.join(ctx.dir, "gone"), ctx.common)
      ]

      assert answers == [:main, :linked, :indeterminate]

      for answer <- answers do
        refute is_boolean(answer),
               "a boolean answer means the three-way status collapsed back into a predicate, " <>
                 "and the unreadable-path case becomes indistinguishable from one of the " <>
                 "other two; got #{inspect(answers)}"
      end
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
      #
      # The oracle discards git's stderr (`2>/dev/null`) for the same reason the derivation
      # does: merged into stdout, one benign diagnostic line — `GIT_TRACE=1` is enough —
      # breaks the three-line split and the ORACLE silently becomes `nil`.
      case System.cmd("sh", ["-c", @rev_parse_sh]) do
        {out, 0} ->
          [git_dir, common_dir, root] = String.split(out, "\n", trim: true)

          expected =
            case WorktreePartition.linked_worktree_status(
                   Path.expand(git_dir),
                   Path.expand(common_dir)
                 ) do
              :linked -> WorktreePartition.partition_for_root(root)
              _ -> nil
            end

          assert WorktreePartition.derive() == expected

        _ ->
          assert WorktreePartition.derive() == nil
      end
    end
  end

  describe "derive/1 in a linked worktree with a NOISY git" do
    setup do
      # A real linked worktree, fabricated WITHOUT a commit. `git worktree add` needs one,
      # but a worktree's identity is three plain files under the common git dir plus a
      # `.git` file in the tree, so git answers `rev-parse` here exactly as it does in a
      # worktree the porcelain cut — which is what this test needs, since the suite itself
      # may be running in the MAIN tree, where derive/1 is nil whatever stderr does.
      dir =
        Path.join(System.tmp_dir!(), "wt_partition_noisy_#{System.unique_integer([:positive])}")

      repo = Path.join(dir, "repo")
      wt = Path.join(dir, "wt")
      private = Path.join(repo, ".git/worktrees/probe")

      {_, 0} = System.cmd("git", ["init", "-q", repo])
      File.mkdir_p!(private)
      File.mkdir_p!(wt)
      File.write!(Path.join(private, "gitdir"), Path.join(wt, ".git") <> "\n")
      File.write!(Path.join(private, "commondir"), "../..\n")
      File.write!(Path.join(private, "HEAD"), "ref: refs/heads/probe\n")
      File.write!(Path.join(wt, ".git"), "gitdir: " <> private <> "\n")

      previous = System.get_env("GIT_TRACE")

      on_exit(fn ->
        if previous, do: System.put_env("GIT_TRACE", previous)
        unless previous, do: System.delete_env("GIT_TRACE")
        File.rm_rf!(dir)
      end)

      %{wt: wt}
    end

    test "still partitions when git writes to stderr on a SUCCESSFUL run", ctx do
      {root, 0} =
        System.cmd("sh", ["-c", "git rev-parse --show-toplevel 2>/dev/null"], cd: ctx.wt)

      root = String.trim_trailing(root, "\n")
      expected = WorktreePartition.partition_for_root(root)

      assert String.starts_with?(expected, "_wt_")
      assert WorktreePartition.derive(ctx.wt) == expected

      # The precondition is ASSERTED, not assumed: if GIT_TRACE ever stops making a
      # successful rev-parse write to stderr, this test would keep passing while proving
      # nothing, so it must go red and send the next reader for another noisy knob.
      {noisy, 0} =
        System.cmd("git", ~w(rev-parse --git-dir --git-common-dir --show-toplevel),
          cd: ctx.wt,
          stderr_to_stdout: true,
          env: [{"GIT_TRACE", "1"}]
        )

      assert length(String.split(noisy, "\n", trim: true)) > 3,
             "GIT_TRACE=1 no longer contaminates a successful rev-parse on this machine, so " <>
               "this test proves nothing; find another variable that makes git write to " <>
               "stderr and exit 0 (got: #{inspect(noisy)})"

      System.put_env("GIT_TRACE", "1")

      assert WorktreePartition.derive(ctx.wt) == expected,
             "a benign stderr line on a SUCCESSFUL git run must not reach the parse. Merged " <>
               "into stdout it breaks the three-line split, derive/1 degrades to nil, and a " <>
               "linked worktree silently runs the suite on the SHARED loopctl_test database " <>
               "— the exact defect this file exists to end, reintroduced by one common " <>
               "developer environment variable"
    end
  end

  describe "the command rev_parse/1 actually runs" do
    # Pinned against the MODULE's own `@rev_parse_cmd`, read out of the source AST, never
    # against a copy in this file: a copy proves only that the copy is well-formed. The two
    # halves are both load-bearing. (a) alone is satisfied by any quiet command, so it could
    # not tell `2>/dev/null` from a derivation that stopped calling git; (b) alone says
    # nothing about stderr.

    test "is still the three-flag git rev-parse" do
      cmd = module_attribute!(:rev_parse_cmd)

      assert cmd =~ ~r/\bgit rev-parse\b/,
             "the silence assertion below is satisfied by ANY quiet command, so it is only " <>
               "meaningful while this is still the git query the derivation needs; got " <>
               inspect(cmd)

      for flag <- @rev_parse_flags do
        assert String.contains?(cmd, flag),
               "#{flag} is one of the three answers `rev_parse/1` splits out, in flag order; " <>
                 "got #{inspect(cmd)}"
      end
    end

    test "writes NOTHING at all when git fails" do
      cmd = module_attribute!(:rev_parse_cmd)

      dir =
        Path.join(System.tmp_dir!(), "wt_partition_silent_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # stderr_to_stdout here is the INSTRUMENT, not the derivation's option: it is how the
      # test sees anything the command lets escape. Whatever `2>/dev/null` swallows inside
      # the shell can never reach this.
      {out, status} = System.cmd("sh", ["-c", cmd], cd: dir, stderr_to_stdout: true)

      refute status == 0,
             "git must FAIL outside a repository, or this proves silence for the wrong reason"

      assert out == "",
             "the derivation's own command must discard git's stderr (`2>/dev/null`), not " <>
               "merely keep it out of the parse. Without it, every suite run outside a " <>
               "repository — the `yields nothing outside a git repository` test does exactly " <>
               "that — prints git's `fatal: not a git repository` into the output, and a " <>
               "developer with GIT_TRACE=1 set gets a trace line per git call. Got: " <>
               inspect(out)
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

    test "reads MIX_TEST_PARTITION in EXECUTABLE code, not only in a comment" do
      # Parsed, not grepped: the parser drops comments by construction, so a mention in
      # prose cannot satisfy this and no hand-rolled comment stripper has to be trusted.
      reads_env? =
        @config_file
        |> File.read!()
        |> Code.string_to_quoted!()
        |> Macro.prewalk(false, fn
          {{:., _, [{:__aliases__, _, [:System]}, :get_env]}, _, ["MIX_TEST_PARTITION" | _]} =
              node,
          _ ->
            {node, true}

          node, found ->
            {node, found}
        end)
        |> elem(1)

      assert reads_env?,
             """
             config/test.exs must contain an EXECUTABLE System.get_env("MIX_TEST_PARTITION") \
             read — this assertion parses the file, so a mention in a comment does not count.

             The reason is outside this repository. claude-config's bin/worktree-remove.sh \
             gates the ENTIRE per-worktree database drop on
                 grep -qs MIX_TEST_PARTITION "$proj/config/test.exs"
             With no match it prints "skip: config/test.exs does not read MIX_TEST_PARTITION" \
             and drops NOTHING, so every removed loopctl worktree orphans its database and a \
             worktree later cut at the same path inherits a stale schema.

             Do NOT "clean this up" by folding the read back into \
             WorktreePartition.suffix/0: that is exactly what left the token surviving only \
             in a comment, one reflow away from a silent sweeper.\
             """
    end
  end

  # The literal value of a module attribute in `config/worktree_partition.exs`, read out of
  # the SOURCE rather than copied here — the same parse-and-walk shape the config pin above
  # uses. The module is already loaded, but a compiled attribute leaves no runtime trace, so
  # the source is the only place its value can be read back from.
  defp module_attribute!(name) do
    value =
      @module_file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(nil, fn
        {:@, _, [{^name, _, [literal]}]} = node, _ when is_binary(literal) -> {node, literal}
        node, found -> {node, found}
      end)
      |> elem(1)

    assert is_binary(value),
           "config/worktree_partition.exs no longer defines a string @#{name}. It is what the " <>
             "assertions in this describe block are pinned against, so they cannot be " <>
             "silently satisfied by a copy living in the test file; re-point them at " <>
             "whatever replaced it rather than deleting them."

    value
  end
end
