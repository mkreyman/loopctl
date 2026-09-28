defmodule LoopctlRunner.PushedCommitsTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.PushedCommits

  @moduletag :tmp_dir

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit!(dir, name) do
    File.write!(Path.join(dir, name), name)
    git!(dir, ["add", name])
    git!(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", name])

    %{
      commit_sha: git!(dir, ["rev-parse", "HEAD"]),
      tree_sha: git!(dir, ["rev-parse", "HEAD^{tree}"])
    }
  end

  # A clone of a bare origin, on a story branch cut from master: the shape a run's repo has.
  setup %{tmp_dir: tmp} do
    origin = Path.join(tmp, "origin.git")
    repo = Path.join(tmp, "repo")
    git!(tmp, ["init", "-q", "--bare", "-b", "master", origin])
    git!(tmp, ["clone", "-q", origin, repo])
    commit!(repo, "base")
    git!(repo, ["push", "-q", "origin", "HEAD:master"])
    git!(repo, ["checkout", "-q", "-b", "loop/story"])
    {:ok, repo: repo}
  end

  test "nothing pushed yet is an empty list, not an error", %{repo: repo} do
    commit!(repo, "local-only")
    assert PushedCommits.since(repo, "origin/master", "loop/story") == {:ok, []}
  end

  test "reports only PUSHED commits beyond the base, oldest first, each with its tree", %{
    repo: repo
  } do
    one = commit!(repo, "one")
    two = commit!(repo, "two")
    git!(repo, ["push", "-q", "-u", "origin", "loop/story"])
    # Committed, never pushed: not on the change thread, so not reported.
    commit!(repo, "three")

    assert PushedCommits.since(repo, "origin/master", "loop/story") == {:ok, [one, two]}
  end

  test "a base that does not resolve is an error, never an empty list", %{repo: repo} do
    commit!(repo, "one")
    git!(repo, ["push", "-q", "-u", "origin", "loop/story"])

    assert {:error, _} = PushedCommits.since(repo, "origin/no-such-base", "loop/story")
  end
end
