defmodule LoopctlRunner.WorktreeTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Worktree
  import LoopctlRunner.TestSupport

  setup do
    repo = git_repo!(Path.join(tmp_dir!("worktree"), "repo"))
    {:ok, repo: repo, path: Worktree.path_for(repo, "s1")}
  end

  test "creates a worktree on a new branch cut from the base", %{repo: repo, path: path} do
    assert {:ok, %{reused: false}} = Worktree.create(repo, path, "loop/s1", "master")
    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "loop/s1"
    assert path == Path.join([repo, ".claude/worktrees/loop-s1"])
  end

  test "adopts its own worktree on replay instead of creating a second", %{repo: repo, path: path} do
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    assert {:ok, %{reused: true}} = Worktree.create(repo, path, "loop/s1", "master")
    assert {:error, msg} = Worktree.create(repo, path, "loop/other", "master")
    assert msg =~ "exists on branch loop/s1"
  end

  test "refuses a branch that already exists without a worktree", %{repo: repo, path: path} do
    git!(repo, ["branch", "loop/s1"])

    assert {:error, "branch loop/s1 already exists without a worktree"} =
             Worktree.create(repo, path, "loop/s1", "master")
  end

  test "refuses a base that does not exist locally", %{repo: repo, path: path} do
    assert {:error, "cannot create worktree from origin/nope" <> _} =
             Worktree.create(repo, path, "loop/s1", "origin/nope")
  end

  test "teardown removes the worktree and its empty branch, even with dirty files", %{
    repo: repo,
    path: path
  } do
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    File.write!(Path.join(path, "scratch.txt"), "uncommitted")

    assert %{worktree: :removed, branch: :deleted} =
             Worktree.remove(repo, path, "loop/s1", "master")

    refute File.dir?(path)
    assert git!(repo, ["branch", "--list", "loop/s1"]) == ""
  end

  test "teardown keeps a branch the session committed to", %{repo: repo, path: path} do
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    File.write!(Path.join(path, "work.txt"), "work")
    git!(path, ["add", "work.txt"])
    git!(path, ["commit", "-q", "-m", "work"])

    assert %{worktree: :removed, branch: {:kept, 1}} =
             Worktree.remove(repo, path, "loop/s1", "master")

    assert git!(repo, ["branch", "--list", "loop/s1"]) =~ "loop/s1"
  end

  describe "remove_if_clean/4" do
    test "removes a worktree with no work", %{repo: repo, path: path} do
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "keeps one with commits on a detached HEAD that are not on the branch", %{
      repo: repo,
      path: path
    } do
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
      git!(path, ["checkout", "-q", "--detach"])
      File.write!(Path.join(path, "detached.txt"), "work")
      git!(path, ["add", "detached.txt"])
      git!(path, ["commit", "-q", "-m", "detached work"])

      assert %{worktree: {:kept, "commits beyond master"}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "keeps one whose commits cannot be counted because the base is gone", %{
      repo: repo,
      path: path
    } do
      git!(repo, ["branch", "base-to-delete"])
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "base-to-delete")
      git!(repo, ["branch", "-D", "base-to-delete"])

      assert %{worktree: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "base-to-delete")

      assert reason =~ "could not be counted"
      assert File.dir?(path)
    end
  end

  test "teardown of nothing reports absence", %{repo: repo, path: path} do
    assert %{worktree: :absent, branch: :absent} =
             Worktree.remove(repo, path, "loop/s1", "master")
  end
end
