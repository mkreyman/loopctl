# Per-worktree TEST DATABASE partition — the Elixir half of a derivation that already
# exists in shell.
#
# WHY THIS FILE EXISTS. The partition was implemented ONLY inside claude-config's git
# hooks (~/.claude/hooks/lib/worktree-partition.sh, claude-config#574), which export
# MIX_TEST_PARTITION before running the gate. A bare `mix test` runs no git hook, so a
# linked worktree's suite targeted the SHARED `loopctl_test` database exactly as the main
# tree's did. Two suites on one database is not a slow suite, it is a WRONG one: measured
# on minis 2026-09-16, the same code and tree gave 0 failures on separate databases and a
# cross-suite row leaking into `HnswDeadEntryRecallTest`'s `assert ann_read(...) == []` on
# a shared one. Making the database a property of the TREE means every invocation gets it —
# `mix test`, `mix precommit`, an agent's targeted run — not only the two git hooks.
#
# WHY IT IS HERE AND NOT IN lib/. `config/test.exs` is evaluated BEFORE the project is
# compiled, so nothing under `lib/` is loadable at the moment the database name is needed.
# `Code.require_file/2` from the config defines this module in the VM, where the suite then
# sees the same code — one implementation, called by both, never two copies of the rules.
#
# THE NAME MUST BE BYTE-IDENTICAL to what worktree-partition.sh produces. The hooks,
# claude-config's bin/worktree-remove.sh and bin/worktree-db-sweep.sh create, drop and sweep
# the shell's spelling; a divergence of one character means the suite runs on a database
# nothing manages. `config_worktree_partition_test.exs` pins measured outputs of the shell
# implementation for that reason (`@shell_vectors`). Change neither side alone.
defmodule Loopctl.Config.WorktreePartition do
  @moduledoc """
  Derives the `MIX_TEST_PARTITION` suffix for a linked git worktree.

  Main tree: `""` (the database name is unchanged). Linked worktree:
  `_wt_<slug>_<hash6>`, or `_wt_<hash6>` when the slug is empty.

  Every failure degrades to `""` — no git, a git error, an unreadable path — so a tree
  this cannot classify keeps exactly the behaviour it had before this existed.
  """

  @doc """
  The suffix appended to every test database name — the whole derivation in one call.

  `config/test.exs` deliberately does NOT call this. It performs the
  `System.get_env("MIX_TEST_PARTITION")` read itself and hands the value to `choose/2`,
  because claude-config's `bin/worktree-remove.sh` gates the per-worktree database drop on
  `grep -qs MIX_TEST_PARTITION config/test.exs`: with the read hidden behind this function
  the token survived only in a prose comment, and one reflow would have made the sweeper
  orphan every loopctl worktree database. The RULES stay here — this function and the
  config resolve through the same `choose/2` — only the environment read is duplicated, and
  `test/loopctl/config_worktree_partition_test.exs` pins that it stays executable code.

  An explicitly SET `MIX_TEST_PARTITION` always wins, INCLUDING an empty string: CI sets
  it per partition and the git hooks export it, and either would otherwise be overridden
  by a derivation that knows less than the caller does. `nil` (unset) is the only value
  that reaches the derivation, which mirrors the shell's `[ -n "${MIX_TEST_PARTITION+x}" ]`
  (set at all) rather than a truthiness test.

  `cd` runs the git queries in another directory; it exists for the tests.
  """
  def suffix(cd \\ nil) do
    choose(System.get_env("MIX_TEST_PARTITION"), fn -> derive(cd) end)
  end

  @doc """
  Resolves an explicit `MIX_TEST_PARTITION` value against a lazy derivation.

  The pure half of `suffix/1`, split out because this is the one place where the two
  implementations can silently disagree: `""` is falsy in shell and TRUTHY in Elixir, so a
  `||` chain here would let the derivation override an operator's explicit empty string.
  """
  def choose(env_value, derive_fun)
  def choose(nil, derive_fun) when is_function(derive_fun, 0), do: derive_fun.() || ""
  def choose(explicit, _derive_fun) when is_binary(explicit), do: explicit

  @doc """
  The partition for the tree at `cd` (the cwd when nil), or `nil` in the main tree.

  Returns `nil` for every failure too — that is the safe direction, since it leaves the
  shared database name in place rather than inventing one no tooling knows about.

  The question is about `cd` and about nothing else, so the git query runs with the ambient
  git environment cleared — see `cleared_git_env/0`, which is what keeps an inherited
  `GIT_DIR` from answering in this one's place.
  """
  def derive(cd \\ nil) do
    with {:ok, base} <- base_dir(cd),
         {:ok, [git_dir, common_dir, root]} <- rev_parse(cd),
         :linked <-
           linked_worktree_status(Path.expand(git_dir, base), Path.expand(common_dir, base)) do
      partition_for_root(root)
    else
      _ -> nil
    end
  end

  # git resolved the relative spellings against the directory it RAN in, so they must be
  # expanded against that same directory and not against the BEAM's cwd.
  defp base_dir(nil), do: File.cwd()
  defp base_dir(cd) when is_binary(cd), do: {:ok, cd}

  @doc """
  The partition name for a worktree ROOT — pure, and the half that must stay byte-identical
  to the shell.

  ROOT is the VERBATIM `git rev-parse --show-toplevel` output. The slug is its basename,
  ASCII-lowercased, every other byte replaced by `_`, runs of `_` squeezed, `_` stripped
  from both ends, truncated to 20 bytes, then stripped of a trailing `_` the truncation
  may have exposed. The hash is the first 6 hex characters of git's blob id for the root
  PATH — SHA-1 over `"blob " <> byte_size(root) <> <<0>> <> root` — computed here rather
  than by shelling out to `git hash-object`.
  """
  def partition_for_root(root) when is_binary(root) do
    case slug(Path.basename(root)) do
      "" -> "_wt_" <> hash6(root)
      slug -> "_wt_" <> slug <> "_" <> hash6(root)
    end
  end

  defp slug(base) do
    base
    |> mask()
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
    |> truncate(20)
    |> String.trim_trailing("_")
  end

  # Byte-wise, matching `LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' '_'`: a
  # multi-byte character becomes one `_` per BYTE, which the squeeze above then collapses.
  # `String.downcase/1` would differ — it lowercases non-ASCII, which `tr` does not.
  defp mask(base), do: for(<<c <- base>>, into: "", do: <<mask_byte(c)>>)

  defp mask_byte(c) when c in ?A..?Z, do: c + 32
  defp mask_byte(c) when c in ?a..?z or c in ?0..?9, do: c
  defp mask_byte(_), do: ?_

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: binary_part(s, 0, n)

  defp hash6(root) do
    payload = "blob " <> Integer.to_string(byte_size(root)) <> <<0>> <> root

    :sha
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 6)
  end

  @doc """
  `:linked` when the git dir is a LINKED worktree's private dir, `:main` in the main tree,
  `:indeterminate` when either path cannot be read.

  THREE STATES, AND DELIBERATELY NOT A `?` PREDICATE. The house rule is that a `?` function
  answers `true`/`false`, and this one cannot: "I could not read the path" is a third
  answer, not a `false`. Named `linked_worktree?/2` it returned the TRUTHY atom
  `:indeterminate`, so `derive/1` was safe only because it matched `true <-`; a single `if`
  at a future call site would have read "cannot classify" as "linked" and partitioned the
  MAIN tree's database into a name the worktree sweeper treats as disposable.

  Identity is by (inode, device) rather than by string, which is what the shell's
  `cd "$dir" && pwd -P` comparison approximates: either path may come back relative
  (`.git` in the main tree) and either may run through a symlink (/tmp -> /private/tmp on
  macOS). `File.stat/1` follows symlinks, so two spellings of one directory compare equal
  and a plain string comparison would not. Only a linked worktree has a private git dir
  under the common one; a submodule's git dir IS its own common dir, so it reads as a main
  tree, exactly as it does in the shell.

  `:indeterminate` is distinct from `:linked` on purpose: `derive/1` must leave the shared
  database name alone when it cannot classify a tree, never invent a partition no tooling
  knows about.
  """
  def linked_worktree_status(git_dir, common_dir) do
    with {:ok, %File.Stat{inode: ia, major_device: da}} <- File.stat(git_dir),
         {:ok, %File.Stat{inode: ib, major_device: db}} <- File.stat(common_dir) do
      if {ia, da} == {ib, db}, do: :main, else: :linked
    else
      _ -> :indeterminate
    end
  end

  @doc """
  The `:env` overrides that strip the ambient git environment from the query.

  A list of `{name, nil}` pairs for `System.cmd/3`'s `:env`, covering every inherited
  `GIT_*` variable except the `GIT_TRACE*` diagnostics.

  WHY THIS EXISTS. `derive/1` asks ONE question — which worktree does this PATH belong to —
  and an ambient `GIT_DIR` describing some OTHER directory is never an input to it. A git
  hook exports `GIT_DIR` (and `GIT_INDEX_FILE`, `GIT_PREFIX`, ...) into every child process,
  so `mix precommit` run BY the pre-commit hook inherits it, and the derivation then answers
  about the hook's repository instead of the path it was handed. Measured 2026-09-16 with a
  linked worktree's private git dir exported and the query run in a directory that is not a
  repository at all: git exits 0, reports that private dir as `--git-dir` and the common dir
  as `--git-common-dir` (so the tree classifies as `:linked`) and reports the CWD as
  `--show-toplevel` — a partition invented for a non-repository. `GIT_WORK_TREE` is the same
  failure one field over: inside a real linked worktree it moves `--show-toplevel` alone, so
  the tree stays `:linked` and the partition names a path that is not the tree.

  THE FAILURE IS ASYMMETRIC, WHICH IS WHY IT SURVIVED: a main checkout's hook exports a
  RELATIVE `GIT_DIR=.git` that resolves nowhere else, so it fails CLOSED by luck, while a
  linked worktree's is ABSOLUTE and fails OPEN — so every main-tree commit passed the gate
  and every worktree commit was refused. KB `d1f32cc7` has the full account.

  THE PRECEDENT IS ALREADY IN THIS REPOSITORY, and this file was the one git caller that
  could not reach it. `Loopctl.DeliveryGates.GitEnv` (2026-09-14, KB d1f32cc7) clears the
  same discovery variables for the delivery gates, after an inherited GIT_DIR let a
  measurement fixture commit ten times to the working branch and a drift fixture empty
  `config/runtime.exs` and push. Its moduledoc states the rule this one follows: `-C` does
  NOT win against `GIT_DIR`. The list here is a SUPERSET of that module's `@discovery`,
  and the duplication is forced — `config/test.exs` evaluates before the project is
  compiled, so nothing under `lib/` is loadable at the moment this runs. What is NOT
  copied is that module's `GIT_CONFIG_GLOBAL=/dev/null` / `GIT_CONFIG_NOSYSTEM=1` pinning:
  it buys measurement determinism, and here it would only make git refuse repositories a
  developer's real `safe.directory` allows.

  A DENY LIST, NOT AN ALLOW LIST. Anything `GIT_*` is assumed to change what git finds
  unless it is known not to; a variable git adds later is cleared by default rather than
  discovered by a wrong database. `GIT_TRACE*` is the deliberate exception: it changes what
  git PRINTS to stderr, never what it finds, the command's own `2>/dev/null` is the defence
  against it, and that defence is pinned by "still partitions when git writes to stderr on a
  SUCCESSFUL run" — clearing it here would leave that test green and proving nothing, and
  there is no env-free replacement: git ignores `trace2.*` from repository-local config
  (checked on git 2.53.0), so an environment variable is the only way to make a SUCCESSFUL
  rev-parse write to stderr. THE EXCEPTION ITSELF IS NOT FALSIFIABLE by this repo's suite —
  flipping this clause to `true` leaves all 22 tests green (`bin/mutate.sh`, exit 1,
  2026-09-16) — which is tolerable only because clearing GIT_TRACE would change nothing
  the derivation ANSWERS; it would silence one developer's tracing of one command. Do not
  read the green as cover for widening the exception to a variable that steers discovery.
  Clearing `GIT_CONFIG_*` can make git refuse a repository it would otherwise read
  (`safe.directory`); that direction is a non-zero exit and therefore `nil`, which is the
  safe one.
  """
  def cleared_git_env do
    for {name, _value} <- System.get_env(), clear_for_query?(name), do: {name, nil}
  end

  defp clear_for_query?("GIT_TRACE" <> _), do: false
  defp clear_for_query?("GIT_" <> _), do: true
  defp clear_for_query?(_), do: false

  # One git invocation, three answers, in flag order. Anything unexpected — a missing git
  # binary, a non-zero exit, a path containing a newline — falls through to :error and
  # leaves the database name alone.
  #
  # RUN THROUGH `sh` SO STDERR IS DISCARDED AT THE SOURCE, exactly as the shell half does
  # (`git rev-parse --git-dir 2>/dev/null`). It is not decoration: `stderr_to_stdout: true`
  # merged git's stderr INTO the text being parsed, so any benign diagnostic on a
  # SUCCESSFUL run broke the three-line split and degraded a linked worktree back onto the
  # shared database — the exact defect this file exists to end. Measured: `GIT_TRACE=1`,
  # an ordinary developer variable, makes this command exit 0 with FOUR lines. Merely
  # dropping the option would fix the parse but print git's own `fatal: not a git
  # repository` into the suite output for the no-repo case, which `2>/dev/null` also
  # silences. The command is a fixed literal — no interpolation reaches the shell — and
  # `cd` is passed to `System.cmd/3`, not spliced into it.
  #
  # THE ENVIRONMENT IS CLEARED IN THE `:env` OPTION, NOT IN THIS STRING, so that the
  # discovery variables are gone before `sh` starts and nothing has to be quoted into a
  # command line. `cleared_git_env/0` says what is cleared and why.
  @rev_parse_cmd "git rev-parse --git-dir --git-common-dir --show-toplevel 2>/dev/null"

  defp rev_parse(cd) do
    opts = [env: cleared_git_env()] ++ if cd, do: [cd: cd], else: []

    case System.cmd("sh", ["-c", @rev_parse_cmd], opts) do
      {out, 0} ->
        case String.split(out, "\n", trim: true) do
          [_git_dir, _common_dir, _root] = three -> {:ok, three}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
