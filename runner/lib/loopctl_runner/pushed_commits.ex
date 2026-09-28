defmodule LoopctlRunner.PushedCommits do
  @moduledoc """
  The commits a session has PUSHED on its story branch, read from the repository's remote-tracking
  ref, oldest first, each with its tree: what a `checkpoint` (contract 1.20.0) reports.

  Read from the REPOSITORY, not the worktree. Remote-tracking refs live in the common git dir that
  every worktree of a repo shares, so a push from the session's worktree moves
  `refs/remotes/origin/<branch>` here too — and the read still works after teardown has removed
  the worktree, which is when a run's last commits are collected.

  PUSHED, not committed: a commit that never left the machine is not on the change thread, and
  reporting it would name a sha loopctl cannot fetch. What moves the tracking ref is the session's
  own `git push` (or a fetch); a push made from somewhere else is seen once something here
  fetches. A branch with no tracking ref yet has pushed nothing, which is `{:ok, []}`, not an
  error.
  """

  @type commit :: %{commit_sha: String.t(), tree_sha: String.t()}

  @doc """
  Commits on `origin/<branch>` that `base` does not have, oldest first. `base` is the ref the
  worktree was cut from, exactly as the story carries it.
  """
  @spec since(String.t(), String.t(), String.t()) :: {:ok, [commit()]} | {:error, String.t()}
  def since(repo_path, base, branch) do
    tracking = "refs/remotes/origin/" <> branch

    case git(repo_path, ["rev-parse", "--verify", "--quiet", tracking <> "^{commit}"]) do
      {:ok, _} -> log(repo_path, base, tracking)
      # --quiet with a missing ref exits 1 and prints nothing: nothing has been pushed yet.
      {:error, {1, ""}} -> {:ok, []}
      {:error, {status, out}} -> {:error, "rev-parse #{tracking} exited #{status}: #{out}"}
    end
  end

  defp log(repo_path, base, tracking) do
    case git(repo_path, ["log", "--reverse", "--format=%H %T", "#{base}..#{tracking}", "--"]) do
      {:ok, out} ->
        commits =
          for line <- String.split(out, "\n", trim: true),
              [commit, tree] = String.split(line, " "),
              do: %{commit_sha: commit, tree_sha: tree}

        {:ok, commits}

      {:error, {status, out}} ->
        {:error, "log #{base}..#{tracking} exited #{status}: #{out}"}
    end
  end

  defp git(repo_path, args) do
    case System.cmd("git", ["-C", repo_path | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, status} -> {:error, {status, String.trim(out)}}
    end
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  end
end
