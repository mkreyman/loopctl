defmodule LoopctlRunner.WorktreeSubmodulesTest do
  # Sets GIT_CONFIG_PARAMETERS in the OS environment, which every git the runner starts inherits:
  # file transport is refused for submodules by default. Not async for that reason.
  use ExUnit.Case, async: false

  alias LoopctlRunner.Worktree
  import LoopctlRunner.TestSupport

  setup do
    repo = git_repo!(Path.join(tmp_dir!("worktree-submodules"), "repo"))
    {:ok, repo: repo}
  end

  describe "sync_submodules/3" do
    setup %{repo: repo} do
      {:ok, runs: Path.join(Path.dirname(repo), "runs")}
    end

    # A superproject with one submodule, initialised in the operator's checkout. File transport is
    # refused for submodules by default, so every git this test and the runner start is allowed it.
    defp with_submodule(repo) do
      sub = git_repo!(Path.join(Path.dirname(repo), "sub"))
      git!(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendored"])
      git!(repo, ["commit", "-q", "-m", "vendor"])
      System.put_env("GIT_CONFIG_PARAMETERS", "'protocol.file.allow'='always'")
      on_exit(fn -> System.delete_env("GIT_CONFIG_PARAMETERS") end)
      sub
    end

    test "a submodule that will not initialise is logged, named, and the tree still used", %{
      repo: repo,
      runs: runs
    } do
      File.write!(Path.join(repo, ".gitmodules"), """
      [submodule "gone"]
      \tpath = gone
      \turl = #{Path.join(repo, "no-such-remote")}
      """)

      sha = git!(repo, ["rev-parse", "HEAD"])
      git!(repo, ["update-index", "--add", "--cacheinfo", "160000,#{sha},gone"])
      git!(repo, ["add", ".gitmodules"])
      git!(repo, ["commit", "-q", "-m", "a submodule nothing can fetch"])
      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.create_detached(repo, tree)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:missing, ["gone"], detail} = Worktree.sync_submodules(repo, tree)
          assert detail =~ "exited"
        end)

      assert log =~ "submodules of #{tree} were not initialised"
      assert File.dir?(tree)
    end

    test "a tree with no submodules pays for nothing", %{repo: repo, runs: runs} do
      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.create_detached(repo, tree)
      assert :ok = Worktree.sync_submodules(repo, tree)
    end

    test "inside every submodule too, what a session left is gone before the next run", %{
      repo: repo,
      runs: runs
    } do
      # The superproject's `clean -ffdx` stops at a submodule's boundary, so without a reset INSIDE
      # it the next session would judge the last one's edits and leftovers as the code.
      with_submodule(repo)
      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.refresh_detached(repo, tree)
      assert :ok = Worktree.sync_submodules(repo, tree)

      vendored = Path.join(tree, "vendored")
      File.write!(Path.join(vendored, "README.md"), "a session's edit\n")
      File.write!(Path.join(vendored, "left.txt"), "untracked")

      {:ok, _} = Worktree.refresh_detached(repo, tree)
      assert :ok = Worktree.sync_submodules(repo, tree)

      assert File.read!(Path.join(vendored, "README.md")) == "fixture\n"
      refute File.exists?(Path.join(vendored, "left.txt"))
    end

    test "a submodule whose remote is out of reach is cloned from the checkout's own clone", %{
      repo: repo,
      runs: runs
    } do
      # The runner's git has the operator's credentials scrubbed, so a private submodule's remote is
      # as unreachable as this deleted one. The clone his checkout already has is not: it is on his
      # disk, and it holds the commit the superproject records. No GIT_CONFIG_PARAMETERS here — the
      # local transport is the runner's own to allow.
      sub = git_repo!(Path.join(Path.dirname(repo), "sub"))
      git!(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendored"])
      git!(repo, ["commit", "-q", "-m", "vendor"])
      File.rm_rf!(sub)

      for tree <- [
            Worktree.triage_tree_path(runs, repo),
            Worktree.triage_tree_path(runs, repo, "r")
          ] do
        {:ok, _} = Worktree.create_detached(repo, tree)
        assert :ok = Worktree.sync_submodules(repo, tree)
        vendored = Path.join(tree, "vendored")
        assert File.read!(Path.join(vendored, "README.md")) == "fixture\n"
        # Copied, not borrowed: a tree that outlives the operator's `gc` loses nothing.
        gitdir = git!(vendored, ["rev-parse", "--absolute-git-dir"])
        refute File.exists?(Path.join(gitdir, "objects/info/alternates"))
      end

      # His config is not rewritten to name his own clone.
      assert git!(repo, ["config", "submodule.vendored.url"]) == sub

      # Teardown removes a tree holding an initialised submodule.
      tree = Worktree.triage_tree_path(runs, repo, "r")
      assert %{worktree: :removed} = Worktree.remove(repo, tree, "", "HEAD")
      refute File.dir?(tree)
    end

    test "a checkout that is itself a LINKED worktree lends the clones git keeps for it", %{
      repo: repo,
      runs: runs
    } do
      # A linked worktree's submodule clones live under `<common>/worktrees/<id>/modules`, not
      # `<common>/modules`, which is why they are found with `--git-path` rather than assumed.
      sub = git_repo!(Path.join(Path.dirname(repo), "sub"))
      git!(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendored"])
      git!(repo, ["commit", "-q", "-m", "vendor"])
      git!(repo, ["submodule", "deinit", "-q", "-f", "vendored"])
      File.rm_rf!(Path.join([repo, ".git", "modules"]))
      linked = Path.join(Path.dirname(repo), "linked")
      git!(repo, ["worktree", "add", "-q", "--detach", linked])
      git!(linked, ["-c", "protocol.file.allow=always", "submodule", "update", "-q", "--init"])
      File.rm_rf!(sub)

      tree = Worktree.triage_tree_path(runs, linked)
      {:ok, _} = Worktree.create_detached(linked, tree)
      assert :ok = Worktree.sync_submodules(linked, tree)
      assert File.read!(Path.join([tree, "vendored", "README.md"])) == "fixture\n"
    end
  end
end
