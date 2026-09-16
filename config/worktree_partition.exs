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
# nothing manages. `config_worktree_partition_test.exs` pins five measured outputs of the
# shell implementation for that reason. Change neither side alone.
defmodule Loopctl.Config.WorktreePartition do
  @moduledoc """
  Derives the `MIX_TEST_PARTITION` suffix for a linked git worktree.

  Main tree: `""` (the database name is unchanged). Linked worktree:
  `_wt_<slug>_<hash6>`, or `_wt_<hash6>` when the slug is empty.

  Every failure degrades to `""` — no git, a git error, an unreadable path — so a tree
  this cannot classify keeps exactly the behaviour it had before this existed.
  """

  @doc """
  The suffix `config/test.exs` appends to every test database name.

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
  """
  def derive(cd \\ nil) do
    with {:ok, base} <- base_dir(cd),
         {:ok, [git_dir, common_dir, root]} <- rev_parse(cd),
         true <-
           linked_worktree?(Path.expand(git_dir, base), Path.expand(common_dir, base)) do
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
  `true` when the git dir is a LINKED worktree's private dir, `false` in the main tree,
  `:indeterminate` when either path cannot be read.

  Identity is by (inode, device) rather than by string, which is what the shell's
  `cd "$dir" && pwd -P` comparison approximates: either path may come back relative
  (`.git` in the main tree) and either may run through a symlink (/tmp -> /private/tmp on
  macOS). `File.stat/1` follows symlinks, so two spellings of one directory compare equal
  and a plain string comparison would not. Only a linked worktree has a private git dir
  under the common one; a submodule's git dir IS its own common dir, so it reads as a main
  tree, exactly as it does in the shell.

  `:indeterminate` is distinct from `true` on purpose: `derive/1` must leave the shared
  database name alone when it cannot classify a tree, never invent a partition no tooling
  knows about.
  """
  def linked_worktree?(git_dir, common_dir) do
    with {:ok, %File.Stat{inode: ia, major_device: da}} <- File.stat(git_dir),
         {:ok, %File.Stat{inode: ib, major_device: db}} <- File.stat(common_dir) do
      {ia, da} != {ib, db}
    else
      _ -> :indeterminate
    end
  end

  # One git invocation, three answers, in flag order. Anything unexpected — a missing git
  # binary, a non-zero exit, a stderr line joined to the output, a path containing a
  # newline — falls through to :error and leaves the database name alone.
  defp rev_parse(cd) do
    opts = [stderr_to_stdout: true] ++ if(cd, do: [cd: cd], else: [])

    case System.cmd("git", ~w(rev-parse --git-dir --git-common-dir --show-toplevel), opts) do
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
