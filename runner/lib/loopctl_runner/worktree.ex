defmodule LoopctlRunner.Worktree do
  @moduledoc """
  Creating and removing the git worktree a session runs in.

  The session's cwd must BE the worktree (design §8): `block-foreign-repo-write.sh`
  keys on `git rev-parse --git-common-dir`, so a session started elsewhere with the
  target passed through `--add-dir` has every write refused.

  No network: the worktree is cut from a ref that already exists locally. Nothing here
  commits, pushes or merges. Teardown deletes the branch only when it carries no commit
  beyond its base, so work a session committed is kept and reported, never discarded.
  """

  @worktrees_subdir ".claude/worktrees"

  # Variables that make git operate on a DIFFERENT repository, index or tree than the
  # directory it runs in. Git exports some of them to hooks, so a runner started from a
  # hook or another git process inherits them: an inherited GIT_INDEX_FILE made
  # `git worktree add` fail (measured, under the pre-commit gate), and an inherited GIT_DIR
  # would point a session's commits at another repo. Every git call here, and the session
  # environment, clears them.
  @repo_locating_env ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX)

  @doc "The git variables to unset in any process that should find its repository by cwd."
  @spec repo_locating_env() :: [String.t()]
  def repo_locating_env, do: @repo_locating_env

  @type created :: %{path: String.t(), branch: String.t(), base: String.t(), reused: boolean()}
  @type removal :: %{
          worktree: :removed | :absent | {:kept, String.t()} | {:error, String.t()},
          branch:
            :deleted | :absent | {:kept, non_neg_integer() | String.t()} | {:error, String.t()}
        }

  @spec path_for(String.t(), String.t()) :: String.t()
  def path_for(repo_path, story_id),
    do: Path.join([repo_path, @worktrees_subdir, "loop-" <> story_id])

  @doc """
  Creates the worktree, or adopts one already on disk for the same branch.

  Adoption is what makes the stage idempotent on replay (design §3): a crashed run's
  worktree is recognised rather than duplicated. A branch that exists WITHOUT the
  worktree is refused — it may hold commits from an earlier story.
  """
  @spec create(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, created()} | {:error, String.t()}
  def create(repo_path, path, branch, base) do
    cond do
      File.dir?(path) ->
        adopt(path, branch, base)

      branch_exists?(repo_path, branch) ->
        {:error, "branch #{branch} already exists without a worktree"}

      true ->
        add(repo_path, path, branch, base)
    end
  end

  defp adopt(path, branch, base) do
    case git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, ^branch} -> {:ok, %{path: path, branch: branch, base: base, reused: true}}
      {:ok, other} -> {:error, "#{path} exists on branch #{other}, not #{branch}"}
      {:error, out} -> {:error, "#{path} exists but is not a worktree: #{out}"}
    end
  end

  defp add(repo_path, path, branch, base) do
    with {:ok, _} <- git(repo_path, ["rev-parse", "--verify", "--quiet", base <> "^{commit}"]),
         {:ok, _} <- git(repo_path, ["worktree", "add", "-b", branch, path, base]) do
      {:ok, %{path: path, branch: branch, base: base, reused: false}}
    else
      {:error, out} -> {:error, "cannot create worktree from #{base}: #{out}"}
    end
  end

  defp branch_exists?(repo_path, branch) do
    match?(
      {:ok, _},
      git(repo_path, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])
    )
  end

  @doc """
  Removes the worktree only when it holds no work: no uncommitted changes in it and no
  commits on its branch beyond the base. Otherwise both are kept, so a re-run of the same
  story adopts the worktree (`create/4`) instead of being refused or discarding the work.

  Every removal the runner performs goes through here, teardown included: a worktree a
  re-run adopted may hold the crashed run's work, and a session that started nothing has
  no business discarding it.
  """
  @spec remove_if_clean(String.t(), String.t(), String.t(), String.t()) :: removal()
  def remove_if_clean(repo_path, path, branch, base) do
    case work_in(repo_path, path, branch, base) do
      nil -> remove(repo_path, path, branch, base)
      reason -> %{worktree: {:kept, reason}, branch: {:kept, reason}}
    end
  end

  defp work_in(repo_path, path, branch, base) do
    cond do
      not File.dir?(path) -> commits_reason(commits_ahead(repo_path, branch, base), base)
      dirty?(path) -> "uncommitted changes"
      true -> head_or_branch_reason(repo_path, path, branch, base)
    end
  end

  # Commits can sit where HEAD points without being on the recorded branch: a detached
  # checkout, or a rebase the wall clock stopped. Both must be empty to count as clean.
  defp head_or_branch_reason(repo_path, path, branch, base) do
    head =
      case git(path, ["rev-list", "--count", base <> "..HEAD"]) do
        {:ok, count} -> {:ok, String.to_integer(count)}
        {:error, _} -> :unknown
      end

    commits_reason(head, base) || commits_reason(commits_ahead(repo_path, branch, base), base)
  end

  defp commits_reason({:ok, 0}, _base), do: nil
  defp commits_reason({:ok, _}, base), do: "commits beyond #{base}"
  # A base that no longer resolves says nothing about the branch: keep it.
  defp commits_reason(:unknown, base), do: "commits beyond #{base} could not be counted"

  # An unreadable status counts as dirty: the reaper must never guess work away.
  defp dirty?(path) do
    case git(path, ["status", "--porcelain"]) do
      {:ok, ""} -> false
      _ -> true
    end
  end

  defp commits_ahead(repo_path, branch, base) do
    if branch_exists?(repo_path, branch) do
      case git(repo_path, ["rev-list", "--count", base <> ".." <> branch]) do
        {:ok, count} -> {:ok, String.to_integer(count)}
        {:error, _} -> :unknown
      end
    else
      {:ok, 0}
    end
  end

  @doc "The registry status a removal outcome leaves the worktree in."
  @spec status_after(removal()) :: String.t()
  def status_after(%{worktree: worktree}) when worktree in [:removed, :absent], do: "removed"
  def status_after(%{worktree: {:kept, _}}), do: "kept"
  def status_after(_), do: "remove_failed"

  @doc """
  Removes the worktree and, when it holds no commits of its own, its branch.

  Returns what happened to each, for the trace.
  """
  @spec remove(String.t(), String.t(), String.t(), String.t()) :: removal()
  def remove(repo_path, path, branch, base) do
    worktree = remove_worktree(repo_path, path)
    git(repo_path, ["worktree", "prune"])
    %{worktree: worktree, branch: remove_branch(repo_path, branch, base)}
  end

  defp remove_worktree(repo_path, path) do
    if File.dir?(path) do
      case git(repo_path, ["worktree", "remove", "--force", path]) do
        {:ok, _} -> :removed
        {:error, out} -> {:error, out}
      end
    else
      :absent
    end
  end

  defp remove_branch(repo_path, branch, base) do
    with true <- branch_exists?(repo_path, branch),
         {:ok, count} <- git(repo_path, ["rev-list", "--count", base <> ".." <> branch]) do
      delete_if_empty(repo_path, branch, String.to_integer(count))
    else
      false -> :absent
      {:error, out} -> {:error, out}
    end
  end

  defp delete_if_empty(repo_path, branch, 0) do
    case git(repo_path, ["branch", "-D", branch]) do
      {:ok, _} -> :deleted
      {:error, out} -> {:error, out}
    end
  end

  defp delete_if_empty(_repo_path, _branch, commits), do: {:kept, commits}

  defp git(dir, args) do
    env = Enum.map(@repo_locating_env, &{&1, nil})

    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
