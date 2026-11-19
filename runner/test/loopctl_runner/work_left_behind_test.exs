defmodule LoopctlRunner.WorkLeftBehindTest do
  # Each test builds its own repositories under its own directory.
  use ExUnit.Case, async: true

  alias LoopctlRunner.Worktree
  import LoopctlRunner.TestSupport

  # A checkout with an `origin` that holds master, and the branch `loop/x` cut from it.
  defp with_origin! do
    root = tmp_dir!("left-behind")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(origin)
    git!(origin, ["init", "-q", "--bare", "-b", "master"])
    repo = git_repo!(Path.join(root, "repo"))
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "-q", "origin", "master"])
    git!(repo, ["fetch", "-q", "origin"])
    git!(repo, ["checkout", "-q", "-b", "loop/x"])
    repo
  end

  defp commit!(repo, file) do
    File.write!(Path.join(repo, file), file)
    git!(repo, ["add", file])
    git!(repo, ["commit", "-q", "-m", file])
  end

  test "a branch holding a commit no origin ref reaches left work behind" do
    repo = with_origin!()
    commit!(repo, "a.txt")
    assert Worktree.work_left_behind(repo, "loop/x") == true
  end

  test "a branch whose commits origin's refs all reach left none" do
    repo = with_origin!()
    # Cut and never committed to: its tip is master's, which origin holds.
    assert Worktree.work_left_behind(repo, "loop/x") == false

    commit!(repo, "a.txt")
    git!(repo, ["push", "-q", "origin", "loop/x"])
    assert Worktree.work_left_behind(repo, "loop/x") == false
  end

  test "the remote-tracking refs are read as they are: nothing is fetched" do
    repo = with_origin!()
    commit!(repo, "a.txt")
    # Pushed by another route, so this checkout's refs do not know: still left behind as far as
    # it can tell, because it reads only what it holds. The route is a second clone fetching the
    # branch from this one: git 2.56 updates `refs/remotes/origin/*` even on a push to origin's
    # bare URL, so pushing from this checkout no longer leaves its refs unaware.
    origin = git!(repo, ["remote", "get-url", "origin"])
    other = Path.join(Path.dirname(repo), "other")
    git!(Path.dirname(repo), ["clone", "-q", origin, other])
    git!(other, ["fetch", "-q", repo, "loop/x:loop/x"])
    git!(other, ["push", "-q", "origin", "loop/x"])
    refute git!(repo, ["for-each-ref", "refs/remotes/origin/loop/x"]) =~ "loop/x"
    assert Worktree.work_left_behind(repo, "loop/x") == true
  end

  test "no origin to compare against, no branch, or no checkout cannot tell" do
    lone = git_repo!(Path.join(tmp_dir!("left-behind-lone"), "repo"))
    assert Worktree.work_left_behind(lone, "master") == nil

    repo = with_origin!()
    assert Worktree.work_left_behind(repo, "loop/never-cut") == nil

    assert Worktree.work_left_behind(Path.join(tmp_dir!("left-behind-none"), "gone"), "loop/x") ==
             nil
  end
end
