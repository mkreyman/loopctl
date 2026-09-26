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
  alias Loopctl.DeliveryGates.GitEnv

  @wt "/home/mkreyman/workspace/x/.claude/worktrees"

  # The ORACLE's own copy of the command, hand-written and deliberately NOT read from the
  # module: an oracle derived from the code under test cannot contradict it. The copy is
  # safe to keep because drift between the two is LOUD, not silent — a flag added to the
  # module makes `rev_parse/1` see four lines, return `:error` and degrade to nil while this
  # oracle still resolves, which fails "agrees with git's own answer" — and because
  # "the command rev_parse/1 actually runs" below pins the module's own value directly.
  @rev_parse_sh "git rev-parse --git-dir --git-common-dir --show-toplevel 2>/dev/null"

  @rev_parse_flags ~w(--git-dir --git-common-dir --show-toplevel)

  # Every git variable that steers DISCOVERY, which is what a git hook exports into every
  # child process it runs. The blocks below fabricate repositories and ask git questions
  # about them, so an inherited value has to be OUT OF THE WAY before a test deliberately
  # sets one: this file's own reproduction is `GIT_DIR=... mix test <this file>`, and an
  # inherited GIT_DIR otherwise reaches the fixtures' `git init` — which re-initialises
  # whatever repository GIT_DIR names, not the one being fabricated — and silently moves
  # every hand-written oracle here off the tree it is meant to describe.
  #
  # Hand-written and deliberately NOT read from the module, on the same principle as
  # @rev_parse_sh: a fixture steered by the code under test cannot contradict it.
  @ambient_git_vars ~w(GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_PREFIX
                       GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
                       GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
                       GIT_NAMESPACE)

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
      # System.tmp_dir!/0 on purpose: nothing here compares with git's output, and on macOS its
      # unresolved /var spelling is exactly what linked_worktree_status/2's inode comparison
      # exists to see through.
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
    setup do
      stash_ambient_git_env!()
    end

    test "yields nothing outside a git repository" do
      dir =
        Path.join(
          Loopctl.RealTmpDir.path!(),
          "wt_partition_nogit_#{System.unique_integer([:positive])}"
        )

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
        Path.join(
          Loopctl.RealTmpDir.path!(),
          "wt_partition_noisy_#{System.unique_integer([:positive])}"
        )

      repo = Path.join(dir, "repo")
      wt = Path.join(dir, "wt")
      private = Path.join(repo, ".git/worktrees/probe")

      stash_ambient_git_env!()

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

    setup do
      stash_ambient_git_env!()
    end

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
        Path.join(
          Loopctl.RealTmpDir.path!(),
          "wt_partition_silent_#{System.unique_integer([:positive])}"
        )

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

  describe "derive/1 with a leaked git environment" do
    # THE DEFECT THIS BLOCK EXISTS FOR. A git hook exports GIT_DIR into every child process,
    # so `mix precommit` run BY the pre-commit hook inherits it and the derivation answered
    # about the hook's repository instead of the path it was handed — which is the test
    # DATABASE the suite then runs on. KB `d1f32cc7` has the cause and the asymmetry that
    # hid it.
    #
    # THE SHAPE HERE IS DELIBERATE: leak a variable naming a REAL repository, then ask
    # `derive/1` about a path outside it and assert the answer is about the path. Naming the
    # repository to git instead — an explicit `--git-dir` — would make the query echo what
    # was passed in, and neither the code nor these tests could then fail. Each test also
    # ASSERTS ITS PRECONDITION against raw git first, so a future git that ignored the
    # variable makes them go red rather than green-and-vacuous.
    setup do
      # The same fabricated linked worktree the NOISY block builds: three plain files under
      # the common git dir plus a `.git` file in the tree, which is a worktree's whole
      # identity, so `git worktree add`'s commit requirement does not apply.
      dir =
        Path.join(
          Loopctl.RealTmpDir.path!(),
          "wt_partition_env_#{System.unique_integer([:positive])}"
        )

      repo = Path.join(dir, "repo")
      wt = Path.join(dir, "wt")
      elsewhere = Path.join(dir, "elsewhere")
      nogit = Path.join(dir, "nogit")
      private = Path.join(repo, ".git/worktrees/probe")

      stash_ambient_git_env!()

      {_, 0} = System.cmd("git", ["init", "-q", repo])
      File.mkdir_p!(private)
      File.mkdir_p!(wt)
      File.mkdir_p!(elsewhere)
      File.mkdir_p!(nogit)
      File.write!(Path.join(private, "gitdir"), Path.join(wt, ".git") <> "\n")
      File.write!(Path.join(private, "commondir"), "../..\n")
      File.write!(Path.join(private, "HEAD"), "ref: refs/heads/probe\n")
      File.write!(Path.join(wt, ".git"), "gitdir: " <> private <> "\n")

      # git's OWN spelling of the root, taken before anything is leaked and without going
      # through the module: /tmp is a symlink on macOS, so the string `wt` is not
      # necessarily what `--show-toplevel` prints, and `partition_for_root/1` hashes the
      # verbatim output.
      {root, 0} = System.cmd("sh", ["-c", "git rev-parse --show-toplevel 2>/dev/null"], cd: wt)
      root = String.trim_trailing(root, "\n")

      on_exit(fn -> File.rm_rf!(dir) end)

      %{
        repo_git: Path.join(repo, ".git"),
        private: private,
        wt: wt,
        root: root,
        elsewhere: elsewhere,
        nogit: nogit
      }
    end

    test "an inherited GIT_DIR does not turn a non-repository into a worktree", ctx do
      System.put_env("GIT_DIR", ctx.private)

      assert [ctx.private, ctx.repo_git, ctx.nogit] == raw_rev_parse(ctx.nogit),
             "precondition: an absolute GIT_DIR must still make git answer in a directory " <>
               "that is not a repository, reporting the CWD as --show-toplevel. If it no " <>
               "longer does, this test proves nothing"

      assert WorktreePartition.derive(ctx.nogit) == nil,
             "a directory that is no repository at all has no partition. With a worktree's " <>
               "GIT_DIR leaked in by a git hook, git exits 0, the private-vs-common dirs " <>
               "classify as :linked and --show-toplevel is the CWD — so the derivation " <>
               "invents a database name for a path git never placed in a repository"
    end

    test "an inherited GIT_DIR does not reclassify a real linked worktree", ctx do
      System.put_env("GIT_DIR", ctx.repo_git)

      assert [ctx.repo_git, ctx.repo_git, ctx.root] == raw_rev_parse(ctx.wt),
             "precondition: GIT_DIR must still override discovery INSIDE a linked worktree, " <>
               "making --git-dir and --git-common-dir the same main-tree path"

      assert WorktreePartition.derive(ctx.wt) == WorktreePartition.partition_for_root(ctx.root),
             "the tree at this path is a linked worktree whatever the environment says. " <>
               "With the MAIN tree's GIT_DIR leaked in, --git-dir equals --git-common-dir, " <>
               "the worktree reads as :main and its suite falls back onto the SHARED " <>
               "loopctl_test database"
    end

    test "an inherited GIT_WORK_TREE does not move the tree derive/1 answers about", ctx do
      System.put_env("GIT_WORK_TREE", ctx.elsewhere)

      assert [ctx.private, ctx.repo_git, ctx.elsewhere] == raw_rev_parse(ctx.wt),
             "precondition: GIT_WORK_TREE must still move --show-toplevel alone, leaving the " <>
               "git dirs — and therefore the :linked classification — untouched"

      assert WorktreePartition.derive(ctx.wt) == WorktreePartition.partition_for_root(ctx.root),
             "GIT_WORK_TREE is the same failure one field over: the tree still classifies as " <>
               ":linked, so the derivation returns a partition — for a path that is not the " <>
               "tree it was asked about. Clearing GIT_DIR alone does not cover this"
    end
  end

  # 846.2 REVIEW ROUND 2, FINDING 8. The moduledoc said this file deliberately does NOT copy
  # `GitEnv`'s `GIT_CONFIG_GLOBAL=/dev/null` pinning, while the `GIT_*` deny list cleared every
  # `GIT_CONFIG*` variable anyway — so on a box whose global git config is supplied only
  # through them (Nix and home-manager point `GIT_CONFIG_GLOBAL` at a store path; some CI
  # images use the `GIT_CONFIG_COUNT`/`KEY`/`VALUE` trio) the pinning WAS effectively applied,
  # `safe.directory` went with it, `rev-parse` refused the tree as dubiously owned, and the
  # suite fell back to the shared `loopctl_test` database. That is the collision this file
  # exists to prevent, so the two sentences were resolved in favour of NOT clearing.
  describe "cleared_git_env/0 and the GIT_CONFIG exception" do
    setup do
      stash_ambient_git_env!(
        @ambient_git_vars ++
          ~w(GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
             GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_WOBBLE_NEW)
      )
    end

    test "config variables are NOT cleared, so a machine keeps its own safe.directory" do
      names =
        ~w(GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
           GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)

      for name <- names, do: System.put_env(name, "set")
      cleared = MapSet.new(WorktreePartition.cleared_git_env(), fn {name, nil} -> name end)

      for name <- names do
        refute MapSet.member?(cleared, name),
               "#{name} selects or supplies CONFIG; it cannot move what rev-parse answers " <>
                 "(pinned by the test below). Clearing it strips the global config on a box " <>
                 "configured through it, git then refuses a dubiously-owned tree, derive/1 " <>
                 "returns nil, and the worktree suite silently shares loopctl_test"
      end
    end

    # THE DENY-LIST DEFAULT IS STILL THE DEFAULT. Without this, the exception above could be
    # widened to `GIT_` and nothing would notice.
    test "an unknown GIT_ variable is still cleared by default" do
      System.put_env("GIT_WOBBLE_NEW", "set")
      cleared = MapSet.new(WorktreePartition.cleared_git_env(), fn {name, nil} -> name end)

      assert MapSet.member?(cleared, "GIT_WOBBLE_NEW")
    end

    # THE PREMISE OF THE EXCEPTION, ASSERTED AGAINST GIT ITSELF rather than assumed — the shape
    # the leaked-environment block uses, so a future git that started honouring `core.worktree`
    # from these sources turns this red instead of silently partitioning on another tree.
    # `core.worktree` is the only setting that could move the answer, and git honours it from
    # repository-LOCAL config alone.
    test "a global config that tries to move the worktree does not move derive/1" do
      dir =
        Path.join(
          Loopctl.RealTmpDir.path!(),
          "wt_partition_cfg_#{System.unique_integer([:positive])}"
        )

      repo = Path.join(dir, "repo")
      elsewhere = Path.join(dir, "elsewhere")
      cfg = Path.join(dir, "global.cfg")

      File.mkdir_p!(repo)
      File.mkdir_p!(elsewhere)
      {_, 0} = System.cmd("git", ["init", "-q", repo])
      File.write!(cfg, "[core]\n\tworktree = #{elsewhere}\n\tbare = false\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      {plain, 0} =
        System.cmd("sh", ["-c", "git rev-parse --show-toplevel 2>/dev/null"], cd: repo)

      {steered, 0} =
        System.cmd("sh", ["-c", "git rev-parse --show-toplevel 2>/dev/null"],
          cd: repo,
          env: [{"GIT_CONFIG_GLOBAL", cfg}]
        )

      assert String.trim(steered) == String.trim(plain),
             "git now honours core.worktree from a GIT_CONFIG_GLOBAL file, so config DOES " <>
               "steer discovery and GIT_CONFIG* must go back on the deny list — read the " <>
               "cleared_git_env/0 doc before changing this"

      {injected, 0} =
        System.cmd("sh", ["-c", "git rev-parse --show-toplevel 2>/dev/null"],
          cd: repo,
          env: [
            {"GIT_CONFIG_COUNT", "1"},
            {"GIT_CONFIG_KEY_0", "core.worktree"},
            {"GIT_CONFIG_VALUE_0", elsewhere}
          ]
        )

      assert String.trim(injected) == String.trim(plain),
             "git now honours core.worktree injected through GIT_CONFIG_COUNT/KEY/VALUE, " <>
               "which is `-c` and the highest precedence there is"
    end
  end

  describe "cleared_git_env/0 against the delivery gates' own list" do
    # ONE RULE, TWO SITES. `Loopctl.DeliveryGates.GitEnv` clears the same discovery variables
    # for the delivery gates — written 2026-09-14 after an inherited GIT_DIR let a fixture
    # commit to the working branch and another empty `config/runtime.exs` and push — and its
    # moduledoc says why two lists are one list and one bug: the weaker one is what a future
    # caller copies. This derivation CANNOT call it (`config/test.exs` evaluates before the
    # project is compiled, so nothing under `lib/` is loadable), so the duplication is forced
    # and only a test can hold the two together.
    setup do
      stash_ambient_git_env!(Enum.uniq(@ambient_git_vars ++ GitEnv.discovery_overrides()))
    end

    test "clears every discovery variable the delivery gates clear" do
      for name <- GitEnv.discovery_overrides(), do: System.put_env(name, "leaked")

      cleared = MapSet.new(WorktreePartition.cleared_git_env(), fn {name, nil} -> name end)

      for name <- GitEnv.discovery_overrides() do
        assert MapSet.member?(cleared, name),
               "#{name} steers git's repository discovery — GitEnv clears it for exactly that " <>
                 "reason — so the partition derivation, which asks git which worktree a PATH " <>
                 "belongs to, must not inherit it either. This list is meant to be a SUPERSET " <>
                 "of GitEnv's, never a narrower second opinion"
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

  # Removes @ambient_git_vars from the BEAM's environment for the duration of one test and
  # puts them back afterwards. `derive/1` reads the environment of the process it runs in, so
  # a test that leaks a variable on purpose does it with `System.put_env/2` after this — and
  # then the ONLY leaked variable is the one that test names.
  defp stash_ambient_git_env!(names \\ @ambient_git_vars) do
    saved = Map.new(names, fn name -> {name, System.get_env(name)} end)
    Enum.each(names, &System.delete_env/1)

    on_exit(fn -> restore_git_env(saved) end)

    :ok
  end

  defp restore_git_env(saved) do
    for {name, value} <- saved do
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end
  end

  # The derivation's git query run WITHOUT the module's environment clearing — how the tests
  # above show that a leaked variable really does move git's answer on this machine. The
  # module's own invocation is this command plus `cleared_git_env/0`.
  defp raw_rev_parse(cd) do
    {out, 0} = System.cmd("sh", ["-c", @rev_parse_sh], cd: cd)
    String.split(out, "\n", trim: true)
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
