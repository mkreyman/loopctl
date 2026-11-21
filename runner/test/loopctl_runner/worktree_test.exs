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
    File.write!(Path.join(path, "wip.txt"), "a crashed run's work")
    assert {:ok, %{reused: true, start: nil}} = Worktree.create(repo, path, "loop/s1", "master")
    assert {:error, msg} = Worktree.create(repo, path, "loop/other", "master")
    assert msg =~ "exists on branch loop/s1"
  end

  test "on replay, a tree holding no work starts afresh and keeps what it ignores", %{
    repo: repo,
    path: path
  } do
    # Adopting it would start the story from whatever base the crashed run was cut from; removing
    # it and cutting again threw away the ignored build output, a full rebuild.
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    File.write!(Path.join([repo, ".git", "info", "exclude"]), "_build/\n")
    File.mkdir_p!(Path.join(path, "_build"))
    File.write!(Path.join([path, "_build", "app.beam"]), "compiled")
    commit!(repo, "later.txt", "the base moved on")

    assert {:ok, %{reused: false, start: "master"}} =
             Worktree.create(repo, path, "loop/s1", "master")

    assert git!(path, ["rev-parse", "HEAD"]) == git!(repo, ["rev-parse", "master"])
    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "loop/s1"
    assert File.read!(Path.join([path, "_build", "app.beam"])) == "compiled"
  end

  test "on replay, a locked tree holding no work starts afresh instead of failing", %{
    repo: repo,
    path: path
  } do
    # `worktree remove --force` refuses a locked tree, which failed the whole dispatch.
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    git!(repo, ["worktree", "lock", path])

    assert {:ok, %{reused: false, start: "master"}} =
             Worktree.create(repo, path, "loop/s1", "master")

    assert git!(repo, ["worktree", "list", "--porcelain"]) =~ "locked"
  end

  test "a stray directory at the path is never reset as if it were the story's tree", %{
    repo: repo,
    path: path
  } do
    # Git reads a plain directory under `.claude/` as part of the main tree: a checkout there
    # would move the main tree's branch.
    git!(repo, ["branch", "loop/s1"])
    File.write!(Path.join([repo, ".git", "info", "exclude"]), ".claude/\n")
    File.mkdir_p!(path)

    assert {:error, message} = Worktree.create(repo, path, "loop/s1", "master")
    assert message =~ "not the top of a worktree"
    assert git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"]) == "master"
  end

  test "refuses a branch with unshipped commits that exists without a worktree", %{
    repo: repo,
    path: path
  } do
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    commit!(path, "work.txt", "an earlier story's work")
    git!(repo, ["worktree", "remove", "--force", path])

    assert {:error, "branch loop/s1 already exists without a worktree"} =
             Worktree.create(repo, path, "loop/s1", "master")
  end

  test "retires an empty branch left without a worktree, instead of refusing", %{
    repo: repo,
    path: path
  } do
    git!(repo, ["branch", "loop/s1"])

    assert {:ok, %{reused: false}} = Worktree.create(repo, path, "loop/s1", "master")
    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "loop/s1"
  end

  test "refuses a base that does not exist locally", %{repo: repo, path: path} do
    assert {:error, "cannot create worktree from origin/nope" <> _} =
             Worktree.create(repo, path, "loop/s1", "origin/nope")
  end

  test "teardown keeps a tree and branch the session committed to", %{repo: repo, path: path} do
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    commit!(path, "work.txt", "work")

    assert %{worktree: {:kept, "commits beyond master" <> _}, branch: {:kept, _}} =
             Worktree.remove_if_clean(repo, path, "loop/s1", "master")

    assert File.dir?(path)
    assert git!(repo, ["branch", "--list", "loop/s1"]) =~ "loop/s1"
  end

  test "teardown keeps an untracked file that status.showUntrackedFiles hides", %{
    repo: repo,
    path: path
  } do
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    git!(repo, ["config", "status.showUntrackedFiles", "no"])
    File.write!(Path.join(path, "new.txt"), "never added")

    assert %{worktree: {:kept, "uncommitted changes"}} =
             Worktree.remove_if_clean(repo, path, "loop/s1", "master")

    assert File.read!(Path.join(path, "new.txt")) == "never added"
  end

  describe "remove_if_clean/4" do
    test "removes a worktree with no work", %{repo: repo, path: path} do
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a tree whose directory is gone loses its one registration, and nothing else's", %{
      repo: repo,
      path: path
    } do
      # Its registration left behind, git refuses to delete the branch it still names. Dropping it
      # with a repository-wide `worktree prune` also drops every other worktree of the operator's
      # whose directory is missing at that moment — one on an unmounted volume included.
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
      other = Path.join([repo, ".claude/worktrees", "operators-own"])
      git!(repo, ["worktree", "add", "-q", "-b", "operators-own", other, "master"])
      File.rm_rf!(path)
      File.rm_rf!(other)

      assert %{worktree: :absent, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      listed = git!(repo, ["worktree", "list", "--porcelain"])
      refute listed =~ "loop-s1"
      assert listed =~ "operators-own"
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

      assert %{worktree: {:kept, "commits beyond master" <> _}} =
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

  describe "a branch whose content origin's base already carries" do
    # `gh pr merge --squash` lands the branch as ONE new commit on origin's base, so the branch's
    # own commits are in no history the base has and `rev-list base..branch` stays above zero for
    # ever. Without a content test teardown keeps it, and the next dispatch adopts work that
    # shipped.
    setup %{repo: repo, path: path} do
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
      commit!(path, "work.txt", "work")
      origin = Path.join(Path.dirname(repo), "origin.git")
      git!(Path.dirname(repo), ["clone", "-q", "--bare", repo, origin])
      git!(repo, ["remote", "add", "origin", origin])
      {:ok, origin: origin}
    end

    test "teardown removes the worktree and deletes the branch",
         %{repo: repo, path: path} = ctx do
      squash_into_origin!(ctx.origin, "loop/s1")

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      refute File.dir?(path)
      assert git!(repo, ["branch", "--list", "loop/s1"]) == ""
    end

    test "the branch is still recognised once origin's base has moved on past the squash",
         %{repo: repo, path: path} = ctx do
      # The ordinary case: other PRs merge after this one. The branch's tree is no longer origin's
      # tree, so comparing trees directly would keep it; merging it in changes nothing.
      squash_into_origin!(ctx.origin, "loop/s1")
      other = Path.join(Path.dirname(ctx.origin), "other")
      commit!(other, "later.txt", "a later PR")
      git!(other, ["push", "-q", "origin", "master"])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a branch origin does NOT carry is kept, origin or not", %{repo: repo, path: path} do
      # The same repo with an origin that never merged it: the fetch works, the content differs.
      assert %{worktree: {:kept, "commits beyond master"}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert git!(repo, ["branch", "--list", "loop/s1"]) =~ "loop/s1"
    end

    test "commits only a stale remote-tracking ref reaches are asked of origin, and kept",
         %{repo: repo, path: path} do
      # Origin's ref as an earlier fetch left it, carrying the branch's commit, which origin has
      # since dropped: counted against that ref alone the branch held nothing and was deleted.
      tip = git!(repo, ["rev-parse", "loop/s1"])
      stale = git!(repo, ["commit-tree", tip <> "^{tree}", "-p", tip, "-m", "dropped since"])
      git!(repo, ["update-ref", "refs/remotes/origin/master", stale])

      assert %{worktree: {:kept, "commits beyond master"}, branch: {:kept, _}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert git!(repo, ["rev-parse", "loop/s1"]) == tip
    end

    test "a fetch that fails keeps the branch, and the reason names it",
         %{repo: repo, path: path} = ctx do
      squash_into_origin!(ctx.origin, "loop/s1")
      # A remote-tracking ref that already shows the squash, from an earlier fetch: only the
      # failed fetch stands between it and a removal, so the test sees the failure being honoured.
      git!(repo, ["fetch", "-q", "origin"])
      git!(repo, ["remote", "set-url", "origin", Path.join(Path.dirname(repo), "no-such.git")])

      assert %{worktree: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert reason =~ ~r/^commits beyond master; origin's master could not be fetched: .*no-such/
    end

    test "a later commit editing the same lines does not hide the squash",
         %{repo: repo, path: path} = ctx do
      # Merging the branch into origin's base as it is NOW conflicts on those lines; the squash
      # commit's patch-id is still the branch's. Two commits, so neither alone is the squash.
      commit!(path, "more.txt", "more")
      git!(repo, ["push", "-q", "origin", "loop/s1"])
      other = squash_into_origin!(ctx.origin, "loop/s1")
      commit!(other, "work.txt", "rewritten by a later PR")
      git!(other, ["push", "-q", "origin", "master"])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a squash whose conflict was resolved in the branch's favour is recognised",
         %{repo: repo, path: path} = ctx do
      # A concurrent PR wrote the same file first; the squash commit then changes ITS content to
      # the branch's, so its patch-id is not the branch's. Its content is.
      other = clone_origin!(ctx.origin)
      commit!(other, "work.txt", "a concurrent PR's version")
      commit!(other, "work.txt", "work")
      git!(other, ["push", "-q", "origin", "master"])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a rebase merge is recognised, though a later commit edits the same lines",
         %{repo: repo, path: path} = ctx do
      commit!(path, "second.txt", "second")
      git!(repo, ["push", "-q", "origin", "loop/s1"])
      other = clone_origin!(ctx.origin)
      commit!(other, "unrelated.txt", "landed first")
      git!(other, ["cherry-pick", "origin/loop/s1~1", "origin/loop/s1"])
      commit!(other, "second.txt", "rewritten by a later PR")
      git!(other, ["push", "-q", "origin", "master"])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a merge carrying content of its own keeps the branch, though its other commits shipped",
         %{repo: repo, path: path} = ctx do
      # `git cherry` lists no merge commit: with the branch's ordinary commits on origin by
      # cherry-pick, it marked every commit shipped and the merge's own content went with the branch.
      side = Path.join(Path.dirname(repo), "side")
      git!(repo, ["worktree", "add", "-q", "-b", "side", side, "master"])
      commit!(side, "side.txt", "side")
      git!(path, ["merge", "-q", "--no-ff", "--no-commit", "side"])
      File.write!(Path.join(path, "resolution.txt"), "only the merge has this")
      git!(path, ["add", "resolution.txt"])
      git!(path, ["commit", "-q", "-m", "merge side"])
      git!(repo, ["push", "-q", "origin", "loop/s1", "side"])
      other = clone_origin!(ctx.origin)
      git!(other, ["cherry-pick", "origin/loop/s1^1", "origin/side"])
      git!(other, ["push", "-q", "origin", "master"])

      assert %{worktree: {:kept, "commits beyond master"}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a branch origin's base reaches by history is retired on re-dispatch",
         %{repo: repo, path: path} do
      # A fast-forward: origin's base now IS the branch, and a fetched ref shows it, so the branch
      # holds nothing beyond it. Without a worktree it was refused as an earlier story's.
      git!(repo, ["push", "-q", "origin", "loop/s1:master"])
      git!(repo, ["fetch", "-q", "origin"])
      git!(repo, ["worktree", "remove", "--force", path])

      assert {:ok, %{reused: false}} = Worktree.create(repo, path, "loop/s1", "master")
    end

    test "uncommitted changes keep the tree even when the commits shipped",
         %{repo: repo, path: path} = ctx do
      squash_into_origin!(ctx.origin, "loop/s1")
      File.write!(Path.join(path, "scratch.txt"), "uncommitted")

      assert %{worktree: {:kept, "uncommitted changes"}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a re-dispatch retires it and cuts a fresh tree instead of adopting",
         %{repo: repo, path: path} = ctx do
      squash_into_origin!(ctx.origin, "loop/s1")

      assert {:ok, %{reused: false}} = Worktree.create(repo, path, "loop/s1", "master")
      # Cut from origin's base, which carries the squash; the local master never saw it.
      assert git!(path, ["rev-parse", "HEAD"]) == git!(repo, ["rev-parse", "origin/master"])
      refute git!(path, ["rev-parse", "HEAD"]) == git!(repo, ["rev-parse", "master"])
    end

    test "a re-dispatch retires it with no worktree, instead of refusing",
         %{repo: repo, path: path} = ctx do
      squash_into_origin!(ctx.origin, "loop/s1")
      git!(repo, ["worktree", "remove", "--force", path])

      assert {:ok, %{reused: false}} = Worktree.create(repo, path, "loop/s1", "master")
    end
  end

  test "a squashed rename is recognised, though a later commit edits the same lines", %{
    repo: repo,
    path: path
  } do
    # The squash search reads only the paths the branch changed. A rename listed by its new name
    # alone showed the squash as an added file, whose patch-id is not the branch's. Two commits, so
    # neither alone is the squash, and the later edit makes merging the branch in conflict.
    commit!(repo, "doc.txt", Enum.map_join(1..10, &"line #{&1}\n"))
    origin = Path.join(Path.dirname(repo), "origin.git")
    git!(Path.dirname(repo), ["clone", "-q", "--bare", repo, origin])
    git!(repo, ["remote", "add", "origin", origin])
    {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
    git!(path, ["mv", "doc.txt", "guide.txt"])
    git!(path, ["commit", "-q", "-m", "rename"])
    commit!(path, "guide.txt", Enum.map_join(1..10, &"line #{&1}\n") <> "added by the branch\n")
    git!(repo, ["push", "-q", "origin", "loop/s1"])
    other = squash_into_origin!(origin, "loop/s1")
    commit!(other, "guide.txt", Enum.map_join(1..10, &"line #{&1}\n") <> "a later PR's line\n")
    git!(other, ["push", "-q", "origin", "master"])

    assert %{worktree: :removed, branch: :deleted} =
             Worktree.remove_if_clean(repo, path, "loop/s1", "master")
  end

  describe "a new branch, when the local base is behind origin's" do
    # Nothing on a dev machine pulls the local base, so it is usually behind what has shipped: a
    # branch cut from it starts the story on stale code.
    setup %{repo: repo} do
      origin = Path.join(Path.dirname(repo), "origin.git")
      git!(Path.dirname(repo), ["clone", "-q", "--bare", repo, origin])
      git!(repo, ["remote", "add", "origin", origin])
      other = Path.join(Path.dirname(repo), "other")
      git!(Path.dirname(repo), ["clone", "-q", origin, other])
      git!(other, ["config", "user.email", "test@example.com"])
      git!(other, ["config", "user.name", "test"])
      git!(other, ["config", "core.hooksPath", "/dev/null"])
      commit!(other, "shipped.txt", "shipped since the local base was last pulled")
      git!(other, ["push", "-q", "origin", "master"])
      {:ok, shipped: git!(other, ["rev-parse", "HEAD"])}
    end

    test "is cut from origin's base, with no upstream", %{repo: repo, path: path} = ctx do
      assert {:ok,
              %{reused: false, base: "master", start: "refs/remotes/origin/master", fetch: :ok}} =
               Worktree.create(repo, path, "loop/s1", "master")

      assert git!(path, ["rev-parse", "HEAD"]) == ctx.shipped
      # A branch cut from a remote-tracking ref would otherwise track origin's master.
      env = Enum.map(Worktree.repo_locating_env(), &{&1, nil})

      assert {_, 1} =
               System.cmd("git", ["-C", path, "config", "branch.loop/s1.merge"], env: env)
    end

    test "its cut_from is origin's commit, and stays so once adopted with a session's commit",
         %{repo: repo, path: path} = ctx do
      shipped = ctx.shipped
      assert {:ok, %{cut_from: ^shipped}} = Worktree.create(repo, path, "loop/s1", "master")
      commit!(path, "wip.txt", "an earlier session's commit")

      # The local base is behind: a merge base with it alone would name a commit older than the
      # one this tree was cut from, and read a stale `.loopctl/mode`.
      refute git!(repo, ["rev-parse", "master"]) == shipped

      assert {:ok, %{reused: true, cut_from: ^shipped}} =
               Worktree.create(repo, path, "loop/s1", "master")
    end

    test "is cut from the local base when it holds a commit origin's lacks", %{
      repo: repo,
      path: path
    } do
      # Diverged: origin shipped one commit and the local base has one nobody pushed. Cut from
      # origin's, the story started without the local one.
      commit!(repo, "local.txt", "committed here, never pushed")

      assert {:ok, %{reused: false, start: "master", fetch: :ok}} =
               Worktree.create(repo, path, "loop/s1", "master")

      assert git!(path, ["rev-parse", "HEAD"]) == git!(repo, ["rev-parse", "master"])
    end

    test "is cut from the base as given when the fetch fails", %{repo: repo, path: path} do
      # Origin's ref resolves, from an earlier fetch: only the failed fetch keeps it out.
      git!(repo, ["fetch", "-q", "origin"])
      git!(repo, ["remote", "set-url", "origin", Path.join(Path.dirname(repo), "no-such.git")])

      assert {:ok, %{reused: false, start: "master", fetch: {:error, error}}} =
               Worktree.create(repo, path, "loop/s1", "master")

      assert error =~ "no-such.git"
      assert git!(path, ["rev-parse", "HEAD"]) == git!(repo, ["rev-parse", "master"])
    end

    test "the fetch writes no FETCH_HEAD and runs no automatic maintenance", %{repo: repo} do
      # FETCH_HEAD is what a session's own `git pull` in this repository reads, and maintenance is
      # a gc the runner did not ask for. A pack already here and a pack limit of one make the
      # fetch's second pack due for a gc, which runs the pre-auto-gc hook first.
      dir = Path.dirname(repo)
      hooks = Path.join(dir, "hooks")
      File.mkdir_p!(hooks)
      File.write!(Path.join(hooks, "pre-auto-gc"), "#!/bin/sh\ntouch #{dir}/gc-ran\nexit 1\n")
      File.chmod!(Path.join(hooks, "pre-auto-gc"), 0o755)
      git!(repo, ["repack", "-q", "-d"])

      for {key, value} <- [
            {"core.hooksPath", hooks},
            {"maintenance.auto", "true"},
            {"gc.autoPackLimit", "1"},
            {"gc.autoDetach", "false"},
            {"fetch.unpackLimit", "1"}
          ],
          do: git!(repo, ["config", key, value])

      assert :ok = Worktree.fetch_base(repo, "master")
      refute File.exists?(Path.join([repo, ".git", "FETCH_HEAD"]))
      refute File.exists?(Path.join(dir, "gc-ran"))
    end

    test "a ref another git holds locked is fetched once it is released", ctx do
      # Released 200 ms after upload-pack is done, so git finds it held and waits, in the one fetch,
      # past its own 100 ms default; the wait is 1000 ms, so a release late by 800 ms still lands.
      lock = locked_origin_ref!(ctx.repo)
      log = wrapped_upload_pack!(ctx.repo, "", "sleep 0.2; rm -f #{lock}")

      assert :ok = Worktree.fetch_base(ctx.repo, "master")
      assert git!(ctx.repo, ["rev-parse", "refs/remotes/origin/master"]) == ctx.shipped
      # One fetch: git waited, rather than failing and being fetched again.
      assert log |> File.read!() |> String.split() == ["start", "end"]
    end

    test "a ref that stays locked is reported, and not fetched again", %{repo: repo} do
      locked_origin_ref!(repo)
      upload_pack = counting_upload_pack!(repo, "")

      assert {:error, error} = Worktree.fetch_base(repo, "master")
      assert error =~ "git fetch exited 1"
      assert error =~ "refs/remotes/origin/master"
      # Held by a live git, as far as its age says: not called stale. Its refs did not move, so a
      # second fetch would only repeat the refusal.
      refute error =~ "no longer runs"
      assert upload_pack |> File.read!() |> String.trim() == "1"
    end

    test "a ref another git moved while this fetch waited is fetched again, afresh", ctx do
      # The other git releases its lock having written a value this fetch did not read, which git
      # refuses as an old value that no longer holds. (A ref that did not exist yet is written over
      # whatever another git put there, so the race needs one that does.)
      git!(ctx.repo, ["update-ref", "refs/remotes/origin/master", "HEAD"])
      lock = locked_origin_ref!(ctx.repo)
      ref = String.replace_suffix(lock, ".lock", "")
      moved = git!(ctx.repo, ["commit-tree", "HEAD^{tree}", "-m", "moved"])

      log =
        wrapped_upload_pack!(ctx.repo, "", """
        if [ "$(grep -c start $LOG)" -eq 1 ]; then sleep 0.2; echo #{moved} > #{lock}; mv #{lock} #{ref}; fi
        """)

      assert :ok = Worktree.fetch_base(ctx.repo, "master")
      assert git!(ctx.repo, ["rev-parse", "refs/remotes/origin/master"]) == ctx.shipped
      assert log |> File.read!() |> String.split() == ["start", "end", "start", "end"]
    end

    test "a lock older than any live fetch is named, with its age, and not waited on twice",
         %{repo: repo} do
      lock = locked_origin_ref!(repo)
      File.touch!(lock, System.os_time(:second) - 120)
      upload_pack = counting_upload_pack!(repo, "")

      assert {:error, error} = Worktree.fetch_base(repo, "master")
      assert error =~ ~r/#{Regex.escape(lock)} is \d+ s old, left by a git that no longer runs/
      assert upload_pack |> File.read!() |> String.trim() == "1"
    end

    test "a fetch that waited out its bound for another fetches nothing, and says so",
         %{repo: repo} do
      # This test holds the repository's fetch lock, as another fetch would, in a registry of its
      # own. The bound leaves room to fetch at first, so only waiting uses it up.
      locks = start_fetch_locks!()
      :ok = LoopctlRunner.FetchLock.acquire(locks, Worktree.fetch_lock_key(repo), 1_000)
      upload_pack = counting_upload_pack!(repo, "")

      fetch = fn ->
        Worktree.fetch_base(repo, "master", timeout_ms: 3_500, fetch_locks: locks)
      end

      assert {:error, error} = Task.await(Task.async(fetch))
      # Given up once no fetch could start (about 500 ms in), not at the deadline.
      [_, waited] = Regex.run(~r/not fetched: (\d+) ms into its 3500 ms bound/, error)
      assert String.to_integer(waited) < 2_000
      refute File.exists?(upload_pack)
    end

    test "a bound with no room for git's own lock wait fetches nothing", %{repo: repo} do
      upload_pack = counting_upload_pack!(repo, "")

      assert {:error, error} = Worktree.fetch_base(repo, "master", timeout_ms: 500)
      assert error =~ "fewer than 3000 ms were left to start git in"
      refute File.exists?(upload_pack)
    end

    test "without a lock server, a bound with no room still fetches nothing", %{repo: repo} do
      upload_pack = counting_upload_pack!(repo, "")

      assert {:error, error} =
               Worktree.fetch_base(repo, "master", timeout_ms: 500, fetch_locks: :no_lock_server)

      assert error =~ "fewer than 3000 ms were left to start git in"
      refute File.exists?(upload_pack)
    end

    test "every path to one repository takes the same fetch lock", %{repo: repo} do
      link = Path.join(Path.dirname(repo), "repo-link")
      File.ln_s!(repo, link)
      assert Worktree.fetch_lock_key(link) == Worktree.fetch_lock_key(repo)
      assert Worktree.fetch_lock_key(repo) != nil
    end

    test "the runner's own fetches of one repository run one at a time", %{repo: repo} do
      log = wrapped_upload_pack!(repo, "sleep 0.3")

      locks = start_fetch_locks!()

      [
        Task.async(fn -> Worktree.fetch_base(repo, "master", fetch_locks: locks) end),
        Task.async(fn -> Worktree.fetch_base(repo, "master", fetch_locks: locks) end)
      ]
      |> Task.await_many(15_000)
      |> Enum.each(&assert(&1 == :ok))

      assert log |> File.read!() |> String.split() == ["start", "end", "start", "end"]
    end

    test "a fatal fetch is reported as git said it", %{repo: repo} do
      upload_pack = counting_upload_pack!(repo, "")

      assert {:error, error} = Worktree.fetch_base(repo, "no-such-branch")
      assert error =~ "git fetch exited 128"
      assert upload_pack |> File.read!() |> String.trim() == "1"
    end

    test "a base only origin has is counted against origin's", %{repo: repo, path: path} do
      # No local `release`: excluding it made every count fail, and the untouched tree was kept as
      # "could not be counted" for ever.
      git!(repo, ["push", "-q", "origin", "master:refs/heads/release"])
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "release")

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "release")
    end

    test "untouched, it is removed at teardown with no fetch", %{repo: repo, path: path} do
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
      # Offline now: an untouched tree must not need origin to be found clean, though it is ahead
      # of the local master by what shipped.
      git!(repo, ["remote", "set-url", "origin", Path.join(Path.dirname(repo), "no-such.git")])

      refute Worktree.asks_origin?(Worktree.work_in(repo, path, "loop/s1", "master"))

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end
  end

  describe "a worktree holding worktrees of its own" do
    # A session following the delivery loop cuts `.claude/worktrees/<name>` inside its own tree,
    # which is ignored, so the tree reads clean; `worktree remove --force` would take the nested
    # tree's uncommitted work with it.
    setup %{repo: repo, path: path} do
      {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
      File.write!(Path.join(path, ".gitignore"), ".claude/\n")
      git!(path, ["add", ".gitignore"])
      git!(path, ["commit", "-q", "-m", "ignore"])
      git!(repo, ["update-ref", "refs/heads/master", "loop/s1"])
      nested = Path.join([path, ".claude", "worktrees", "inner"])
      git!(path, ["worktree", "add", "-q", "-b", "inner", nested])
      File.write!(Path.join(nested, "wip.txt"), "uncommitted work in the nested tree")
      {:ok, nested: nested}
    end

    test "is kept, with its branch, and the nested work survives",
         %{repo: repo, path: path} = ctx do
      assert %{worktree: {:kept, reason}, branch: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert reason =~ "holds repositories of its own: .claude/worktrees/inner"
      assert File.read!(Path.join(ctx.nested, "wip.txt")) =~ "uncommitted work"
      assert git!(repo, ["branch", "--list", "loop/s1"]) =~ "loop/s1"
    end

    test "a re-dispatch starts its branch afresh in place, and the nested work survives",
         %{repo: repo, path: path} = ctx do
      assert {:ok, %{reused: false, start: "master"}} =
               Worktree.create(repo, path, "loop/s1", "master")

      assert File.read!(Path.join(ctx.nested, "wip.txt")) =~ "uncommitted work"
    end

    test "a nested worktree of the same repository whose commits are on its branch does not keep it",
         %{repo: repo, path: path} = ctx do
      # It shares the story repository's refs, so it always has a branch, and that branch outlives
      # the tree: counting branches kept every such tree for ever.
      git!(ctx.nested, ["add", "wip.txt"])
      git!(ctx.nested, ["commit", "-q", "-m", "nested work"])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert git!(repo, ["show", "inner:wip.txt"]) =~ "uncommitted work"
    end

    test "a nested worktree of the same repository with a commit no branch reaches keeps it",
         %{repo: repo, path: path} = ctx do
      git!(ctx.nested, ["checkout", "-q", "--detach"])
      git!(ctx.nested, ["add", "wip.txt"])
      git!(ctx.nested, ["commit", "-q", "-m", "detached nested work"])

      assert %{worktree: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert reason =~ "holds repositories of its own: .claude/worktrees/inner"
    end

    test "a directory the scan may not enter keeps the tree: a forced removal would stop part-way",
         %{repo: repo, path: path} = ctx do
      private = Path.join([path, ".claude", "private"])
      File.mkdir_p!(private)
      File.chmod!(private, 0o000)
      on_exit(fn -> File.chmod(private, 0o755) end)

      assert %{worktree: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert reason =~ "Permission denied"
      assert File.dir?(private)
      assert File.read!(Path.join(ctx.nested, "wip.txt")) =~ "uncommitted work"
    end

    test "build and dependency directories are not scanned", %{repo: repo, path: path} = ctx do
      # Rebuilt by the next build or `deps.get`, and node_modules alone can take the scan past its
      # bound: a repository in one does not keep the tree, whatever it holds.
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      File.write!(Path.join([repo, ".git", "info", "exclude"]), "node_modules/\n")
      git_repo!(Path.join([path, "assets", "node_modules", "pkg"]))

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "is removed once the nested tree is gone", %{repo: repo, path: path} = ctx do
      git!(repo, ["worktree", "remove", "--force", ctx.nested])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "is removed once the nested tree's directory is deleted, though git still lists it",
         %{repo: repo, path: path} = ctx do
      File.rm_rf!(ctx.nested)
      assert git!(repo, ["worktree", "list", "--porcelain"]) =~ "prunable"

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a repository cloned inside it keeps it while it holds a commit its remotes lack",
         %{repo: repo, path: path} = ctx do
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      clone = Path.join([path, ".claude", "worktrees", "clone"])
      git!(repo, ["clone", "-q", repo, clone])
      git!(clone, ["config", "user.email", "test@example.com"])
      git!(clone, ["config", "user.name", "test"])
      git!(clone, ["config", "core.hooksPath", "/dev/null"])
      commit!(clone, "clone-work.txt", "only this clone has it")

      assert %{worktree: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert reason =~ "holds repositories of its own: .claude/worktrees/clone"
    end

    test "a repository cloned inside it holding nothing its remotes lack does not keep it",
         %{repo: repo, path: path} = ctx do
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      git!(repo, ["clone", "-q", repo, Path.join([path, ".claude", "worktrees", "clone"])])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a pinned dependency checkout does not keep it", %{repo: repo, path: path} = ctx do
      # Mix's git deps: detached, clean, no branch; the next `deps.get` rebuilds it, and `deps/`
      # is not scanned at all.
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      dep = Path.join([path, "deps", "dep"])
      git!(repo, ["clone", "-q", repo, dep])
      git!(dep, ["checkout", "-q", "--detach"])
      git!(dep, ["branch", "-q", "-D", "master"])
      File.write!(Path.join(path, ".gitignore"), ".claude/\ndeps/\n")
      git!(path, ["commit", "-q", "-am", "ignore deps"])
      git!(repo, ["update-ref", "refs/heads/master", "loop/s1"])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "an initialised submodule at its recorded commit does not keep it",
         %{repo: repo, path: path} = ctx do
      # Its clone has a branch, as every clone has, so counting branches kept every such tree.
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      submodule!(repo, path)

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a submodule at a recorded commit no remote-tracking ref of its reaches does not keep it",
         %{repo: repo, path: path} = ctx do
      # A recorded commit `submodule update` fetched by id is on no remote-tracking ref of the
      # clone: only the record says the parent repository has it.
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      sub = submodule!(repo, path)
      git!(sub, ["remote", "remove", "origin"])

      assert %{worktree: :removed, branch: :deleted} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")
    end

    test "a submodule with a commit its recorded commit lacks keeps it",
         %{repo: repo, path: path} = ctx do
      # HEAD back at the recorded commit, so the tree itself reads clean; the commit is on a branch.
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      sub = submodule!(repo, path)
      recorded = git!(sub, ["rev-parse", "HEAD"])
      git!(sub, ["checkout", "-q", "-b", "session-work"])
      commit!(sub, "sub-work.txt", "work only this clone has")
      git!(sub, ["checkout", "-q", "--detach", recorded])

      assert %{worktree: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert reason =~ "holds repositories of its own: lib/sub"
    end

    test "a detached checkout with uncommitted changes keeps it",
         %{repo: repo, path: path} = ctx do
      git!(repo, ["worktree", "remove", "--force", ctx.nested])
      dep = Path.join([path, ".claude", "scratch"])
      git!(repo, ["clone", "-q", repo, dep])
      git!(dep, ["checkout", "-q", "--detach"])
      git!(dep, ["branch", "-q", "-D", "master"])
      File.write!(Path.join(dep, "README.md"), "edited, never committed")

      assert %{worktree: {:kept, reason}} =
               Worktree.remove_if_clean(repo, path, "loop/s1", "master")

      assert reason =~ ".claude/scratch"
    end
  end

  # A submodule at lib/sub, committed on loop/s1 and master alike and initialised in the tree, as
  # `git submodule update --init` leaves it: detached at the recorded commit, its clone on a branch.
  defp submodule!(repo, path) do
    source = git_repo!(Path.join(Path.dirname(repo), "sub-source"))
    file = ["-c", "protocol.file.allow=always"]
    git!(path, file ++ ["submodule", "add", "-q", source, "lib/sub"])
    git!(path, ["commit", "-q", "-m", "add submodule"])
    git!(repo, ["update-ref", "refs/heads/master", "loop/s1"])
    git!(path, ["submodule", "deinit", "-q", "--force", "lib/sub"])
    git!(path, file ++ ["submodule", "update", "-q", "--init"])
    sub = Path.join(path, "lib/sub")
    git!(sub, ["config", "user.email", "test@example.com"])
    git!(sub, ["config", "user.name", "test"])
    git!(sub, ["config", "core.hooksPath", "/dev/null"])
    sub
  end

  defp locked_origin_ref!(repo) do
    lock = Path.join([repo, ".git", "refs", "remotes", "origin", "master.lock"])
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "")
    lock
  end

  # A fetch-lock registry of the test's own, so no test shares the application's.
  defp start_fetch_locks! do
    name = :"fetch_locks_#{System.unique_integer([:positive])}"
    start_supervised!({LoopctlRunner.FetchLock, name: name})
    name
  end

  # An upload-pack that logs each run, runs the real one, then logs its end and runs `detached`
  # cut off from its pipes (git reads upload-pack's output to its end, so anything holding them
  # would hold git too). Returns the log. `before` runs first, with $LOG set.
  defp wrapped_upload_pack!(repo, before, detached \\ "") do
    dir = Path.dirname(repo)
    log = Path.join(dir, "upload-pack.log")
    script = Path.join(dir, "upload-pack")

    File.write!(script, """
    #!/bin/sh
    LOG=#{log}
    echo start >> "$LOG"
    #{before}
    git upload-pack "$@"; status=$?
    echo end >> "$LOG"
    (#{if detached == "", do: ":", else: detached}) </dev/null >/dev/null 2>&1 &
    exit $status
    """)

    File.chmod!(script, 0o755)
    git!(repo, ["config", "remote.origin.uploadpack", script])
    log
  end

  # An upload-pack that counts its runs into the returned file, then runs `then` with $n set.
  defp counting_upload_pack!(repo, then) do
    dir = Path.dirname(repo)
    count = Path.join(dir, "upload-packs")
    script = Path.join(dir, "upload-pack")

    File.write!(script, """
    #!/bin/sh
    n=$(( $(cat #{count} 2>/dev/null || echo 0) + 1 )); echo $n > #{count}
    #{then}
    exec git upload-pack "$@"
    """)

    File.chmod!(script, 0o755)
    git!(repo, ["config", "remote.origin.uploadpack", script])
    count
  end

  defp commit!(dir, file, content) do
    File.write!(Path.join(dir, file), content)
    git!(dir, ["add", file])
    git!(dir, ["commit", "-q", "-m", file])
  end

  # What `gh pr merge --squash` leaves: origin's master gains ONE new commit with the branch's
  # content, and the branch's own commits stay out of its history. Returns the clone that made it.
  defp squash_into_origin!(origin, branch) do
    other = clone_origin!(origin)
    git!(other, ["merge", "-q", "--squash", "origin/" <> branch])
    git!(other, ["commit", "-q", "-m", "squash"])
    git!(other, ["push", "-q", "origin", "master"])
    other
  end

  defp clone_origin!(origin) do
    other = Path.join(Path.dirname(origin), "other")
    git!(Path.dirname(origin), ["clone", "-q", origin, other])
    git!(other, ["config", "user.email", "test@example.com"])
    git!(other, ["config", "user.name", "test"])
    git!(other, ["config", "core.hooksPath", "/dev/null"])
    # An operator's global `merge.ff = false` refuses `--squash`; this clone is the test's own.
    git!(other, ["config", "merge.ff", "true"])
    other
  end

  test "teardown of nothing reports absence", %{repo: repo, path: path} do
    assert %{worktree: :absent, branch: :absent} =
             Worktree.remove_if_clean(repo, path, "loop/s1", "master")
  end

  describe "judged_commit/3, the commit a triage run judges" do
    setup %{repo: repo} do
      origin = Path.join(Path.dirname(repo), "origin.git")
      git!(Path.dirname(repo), ["clone", "-q", "--bare", repo, origin])
      git!(repo, ["remote", "add", "origin", origin])
      {:ok, origin: origin}
    end

    test "is origin's base when the checkout is behind it", %{repo: repo, origin: origin} do
      # The 2026-11-21 sandbox case: a run commits to origin, and the runner's checkout of that
      # repository is never pulled.
      other = clone_origin!(origin)
      commit!(other, "seeded.ex", "the file the report is about")
      git!(other, ["push", "-q", "origin", "master"])
      shipped = git!(other, ["rev-parse", "HEAD"])

      assert {:ok, ^shipped, :origin} = Worktree.judged_commit(repo, "master")
      refute git!(repo, ["rev-parse", "HEAD"]) == shipped
    end

    test "is origin's base when the checkout is at it", %{repo: repo} do
      head = git!(repo, ["rev-parse", "HEAD"])
      assert {:ok, ^head, :origin} = Worktree.judged_commit(repo, "master")
    end

    test "is the checkout's commit when it holds commits origin's base lacks", %{repo: repo} do
      commit!(repo, "local.ex", "the operator's unpushed work")
      head = git!(repo, ["rev-parse", "HEAD"])

      assert {:ok, ^head, :checkout, why} = Worktree.judged_commit(repo, "master")
      assert why =~ "holds commits origin's master lacks"
    end

    test "is the checkout's commit when origin cannot be fetched", %{repo: repo} do
      git!(repo, ["remote", "set-url", "origin", Path.join(Path.dirname(repo), "no-such.git")])
      head = git!(repo, ["rev-parse", "HEAD"])

      assert {:ok, ^head, :checkout, why} = Worktree.judged_commit(repo, "master")
      assert why =~ "origin's master was not fetched"
    end

    test "is the checkout's commit when origin has no such base", %{repo: repo} do
      head = git!(repo, ["rev-parse", "HEAD"])
      assert {:ok, ^head, :checkout, _why} = Worktree.judged_commit(repo, "no-such-branch")
    end
  end

  describe "the triage trees" do
    setup %{repo: repo} do
      {:ok, runs: Path.join(Path.dirname(repo), "runs")}
    end

    test "live under the runner's runs_dir, one per repo, never in the operator's checkout", %{
      repo: repo,
      runs: runs
    } do
      other = git_repo!(Path.join(Path.dirname(repo), "other"))
      shared = Worktree.triage_tree_path(runs, repo)
      own = Worktree.triage_tree_path(runs, repo, "run-1")

      assert Path.dirname(shared) == Path.join(runs, ".triage-trees")
      assert Path.dirname(own) == Path.join(runs, ".triage-trees")
      assert own == shared <> "-run-1"
      refute Worktree.triage_tree_path(runs, other) == shared

      {:ok, sha} = Worktree.create_detached(repo, shared)
      assert git!(shared, ["rev-parse", "HEAD"]) == sha
      # Still a worktree of HIS repository, and his checkout gains nothing for it.
      assert git!(repo, ["worktree", "list", "--porcelain"]) =~ Path.basename(shared)
      refute File.exists?(Path.join(repo, ".claude"))
    end

    test "is never reset where git would find an ENCLOSING repository; it is cut again", %{
      repo: repo
    } do
      # A tree whose `.git` file is gone is a plain directory, so git run there walks UP — here to
      # the operator's checkout, as it would to any repository the runs_dir sits inside — and
      # `checkout --force` plus `clean -ffdx` would discard his edits and his untracked files.
      runs = Path.join(repo, "runs")
      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.create_detached(repo, tree)
      File.rm!(Path.join(tree, ".git"))
      File.write!(Path.join(repo, "README.md"), "his edit\n")
      File.write!(Path.join(repo, "his-notes.txt"), "untracked")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Worktree.refresh_detached(repo, tree)
        end)

      assert log =~ "is not recognisably the runner's triage tree"
      assert File.read!(Path.join(repo, "README.md")) == "his edit\n"
      assert File.read!(Path.join(repo, "his-notes.txt")) == "untracked"
      assert File.regular?(Path.join(tree, ".git"))
    end

    test "a plain directory in the way is moved aside, never a refusal every later run repeats",
         %{
           repo: repo,
           runs: runs
         } do
      tree = Worktree.triage_tree_path(runs, repo)
      File.mkdir_p!(tree)
      File.write!(Path.join(tree, "whose.txt"), "not the runner's")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, sha} = Worktree.refresh_detached(repo, tree)
          assert git!(tree, ["rev-parse", "HEAD"]) == sha
        end)

      assert log =~ "moved it to"
      refute File.exists?(Path.join(tree, "whose.txt"))

      assert [aside] = Path.wildcard(Path.join([runs, ".triage-trees", "set-aside", "*"]))
      assert File.read!(Path.join(aside, "whose.txt")) == "not the runner's"
    end

    test "a worktree of a DIFFERENT repository at the path is moved aside, never reset", %{
      repo: repo,
      runs: runs
    } do
      # Its own `.git` file stops git's discovery, but at someone else's repository: resetting it
      # would be the runner acting on a repo it was never pointed at.
      other = git_repo!(Path.join(Path.dirname(repo), "other"))
      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.create_detached(other, tree)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Worktree.refresh_detached(repo, tree)
      end)

      assert git!(tree, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) ==
               git!(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    end

    test "only a DETACHED tree carrying the runner's marker is reset; any other is cut again", %{
      repo: repo,
      runs: runs
    } do
      # The runner's own tree, put on a branch: detached is how the runner leaves it, so anything
      # else is someone's use of that path and is not reset in place.
      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.create_detached(repo, tree)
      git!(tree, ["checkout", "-q", "-b", "someone"])

      on_branch =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Worktree.refresh_detached(repo, tree)
        end)

      assert on_branch =~ "is not recognisably the runner's triage tree"
      assert git!(tree, ["rev-parse", "--abbrev-ref", "HEAD"]) == "HEAD"

      # A detached worktree of this repo the runner did not cut: no marker, so not the runner's.
      git!(repo, ["worktree", "remove", "--force", tree])
      git!(repo, ["worktree", "add", "-q", "--detach", tree])

      unmarked =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Worktree.refresh_detached(repo, tree)
        end)

      assert unmarked =~ "is not recognisably the runner's triage tree"

      # And the runner's own, detached and marked, is reset in place, with nothing said.
      File.write!(Path.join(tree, "left.txt"), "by a session")

      reset =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Worktree.refresh_detached(repo, tree)
        end)

      # capture_log in an async module also collects what concurrent tests log, so "nothing said"
      # is checked as nothing said about this tree, never as an empty capture.
      refute reset =~ "triage tree"
      refute reset =~ tree
      refute File.exists?(Path.join(tree, "left.txt"))
    end

    test "a cut drops no registration but its own path's: the operator's missing worktree survives",
         %{repo: repo, runs: runs} do
      # A worktree of his whose directory is not there right now — on a volume that is not mounted —
      # keeps its registration and whatever git holds for it. A repository-wide `worktree prune`
      # before a cut deleted it.
      away = Path.join(Path.dirname(repo), "on-a-usb-disk")
      git!(repo, ["worktree", "add", "-q", "--detach", away])
      admin = git!(away, ["rev-parse", "--absolute-git-dir"])
      File.rm_rf!(away)

      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.create_detached(repo, tree)

      # And a tree of the runner's whose directory went missing is still cut again at its path.
      File.rm_rf!(tree)
      assert {:ok, _} = Worktree.refresh_detached(repo, tree)
      assert %{worktree: :removed} = Worktree.remove(repo, tree, "", "HEAD")
      assert %{worktree: :absent} = Worktree.remove(repo, tree, "", "HEAD")

      assert File.dir?(admin)
      assert git!(repo, ["worktree", "list", "--porcelain"]) =~ "on-a-usb-disk"
    end

    test "a worktree of this repo without the marker is moved aside with its edits, never removed",
         %{repo: repo, runs: runs} do
      # Not the runner's, so what is in it may be someone's uncommitted work. Moved, it is still a
      # working worktree at its new place.
      tree = Worktree.triage_tree_path(runs, repo)
      git!(repo, ["worktree", "add", "-q", "--detach", tree])
      File.write!(Path.join(tree, "README.md"), "someone's edit\n")

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Worktree.refresh_detached(repo, tree)
      end)

      assert [aside] = Path.wildcard(Path.join([runs, ".triage-trees", "set-aside", "*"]))
      assert File.read!(Path.join(aside, "README.md")) == "someone's edit\n"
      assert git!(aside, ["status", "--porcelain"]) == "M README.md"
      # Registered where it now is, and the runner's tree at the path is a different worktree.
      refute git!(aside, ["rev-parse", "--absolute-git-dir"]) ==
               git!(tree, ["rev-parse", "--absolute-git-dir"])
    end

    test "the operator's checkout hooks never run in a triage tree", %{repo: repo, runs: runs} do
      # `worktree add` and `checkout` run post-checkout. His hooks are his to run in his checkout;
      # in a scratch tree, unattended, they are unbounded code nobody asked for.
      hooks = Path.join(Path.dirname(repo), "hooks")
      ran = Path.join(Path.dirname(repo), "hook-ran")
      File.mkdir_p!(hooks)
      File.write!(Path.join(hooks, "post-checkout"), "#!/bin/sh\ntouch #{ran}\n")
      File.chmod!(Path.join(hooks, "post-checkout"), 0o755)
      git!(repo, ["config", "core.hooksPath", hooks])

      tree = Worktree.triage_tree_path(runs, repo)
      {:ok, _} = Worktree.refresh_detached(repo, tree)
      {:ok, _} = Worktree.refresh_detached(repo, tree)

      refute File.exists?(ran)
      # The hook itself works: it is the runner's git that does not run it.
      git!(repo, ["checkout", "-q", "--detach"])
      assert File.exists?(ran)
    end
  end

  describe "cut_from" do
    test "a new tree's is its HEAD, the base's commit, read before any session", %{
      repo: repo,
      path: path
    } do
      base = git!(repo, ["rev-parse", "master"])
      assert {:ok, %{cut_from: ^base}} = Worktree.create(repo, path, "loop/s1", "master")
      assert git!(path, ["rev-parse", "HEAD"]) == base
    end

    test "an adopted tree's is its merge base with the base, never an earlier session's commit",
         %{repo: repo, path: path} do
      {:ok, %{cut_from: cut}} = Worktree.create(repo, path, "loop/s1", "master")
      # An earlier session committed a mode of its own choosing on the story's branch.
      File.mkdir_p!(Path.join(path, ".loopctl"))
      File.write!(Path.join([path, ".loopctl", "mode"]), "thread\n")
      git!(path, ["add", ".loopctl/mode"])
      git!(path, ["commit", "-q", "-m", "session"])
      refute git!(path, ["rev-parse", "HEAD"]) == cut

      assert {:ok, %{reused: true, cut_from: ^cut}} =
               Worktree.create(repo, path, "loop/s1", "master")
    end

    test "a tree reset in place is read again: its new HEAD, not the commit it was first cut from",
         %{repo: repo, path: path} do
      {:ok, %{cut_from: first}} = Worktree.create(repo, path, "loop/s1", "master")
      commit!(repo, "later.txt", "the base moved on")
      moved = git!(repo, ["rev-parse", "master"])
      refute moved == first

      assert {:ok, %{reused: false, cut_from: ^moved}} =
               Worktree.create(repo, path, "loop/s1", "master")
    end
  end

  test "a tree whose cut cannot be read is removed with its branch, and the error says so", %{
    repo: repo,
    path: path
  } do
    # A post-checkout hook points the new tree's HEAD at a branch that does not exist, so
    # `worktree add` succeeds and reading the commit it was cut from then fails.
    hooks = Path.join(Path.dirname(repo), "hooks")
    File.mkdir_p!(hooks)
    hook = Path.join(hooks, "post-checkout")

    File.write!(hook, """
    #!/bin/sh
    printf 'ref: refs/heads/unborn-by-hook\\n' > "$(git rev-parse --git-dir)/HEAD"
    """)

    File.chmod!(hook, 0o755)
    git!(repo, ["config", "core.hooksPath", hooks])

    assert {:error, why} = Worktree.create(repo, path, "loop/s1", "master")
    assert why =~ "cannot tell which commit"
    assert why =~ "the new worktree and branch were removed"
    refute File.dir?(path)
    assert git!(repo, ["branch", "--list", "loop/s1"]) == ""
    # The main checkout is the only tree git still knows.
    assert [_main] = Regex.scan(~r/^worktree /m, git!(repo, ["worktree", "list", "--porcelain"]))
  end

  describe "commit_file/4" do
    defp commit_mode!(repo, fun) do
      File.mkdir_p!(Path.join(repo, ".loopctl"))
      fun.(Path.join([repo, ".loopctl", "mode"]))
      git!(repo, ["add", "-A", ".loopctl"])
      git!(repo, ["commit", "-q", "-m", "mode"])
      git!(repo, ["rev-parse", "HEAD"])
    end

    test "reads the commit named, not a later one and not a working tree", %{repo: repo} do
      cut = commit_mode!(repo, &File.write!(&1, "pr\n"))
      commit_mode!(repo, &File.write!(&1, "thread\n"))
      # And a working tree that says something else again, uncommitted.
      File.write!(Path.join([repo, ".loopctl", "mode"]), "yolo\n")

      assert Worktree.commit_file(repo, cut, ".loopctl/mode", 64) == {:ok, "pr\n"}
    end

    test "a path the commit does not have is absent, whatever the working tree holds", %{
      repo: repo
    } do
      File.mkdir_p!(Path.join(repo, ".loopctl"))
      File.write!(Path.join([repo, ".loopctl", "mode"]), "thread\n")
      assert Worktree.commit_file(repo, "master", ".loopctl/mode", 64) == :absent
    end

    test "git's stderr is never read as the answer", %{repo: repo} do
      commit_mode!(repo, &File.write!(&1, "pr\n"))
      # A tag and a branch of one name: git warns that the name is ambiguous, on stderr, and
      # still answers. Merged into stdout, the warning would be parsed as the tree entry.
      git!(repo, ["tag", "master"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Worktree.commit_file(repo, "master", ".loopctl/mode", 64) == {:ok, "pr\n"}
        end)

      assert log =~ "ambiguous"
    end

    test "a file over the bound is refused unread", %{repo: repo} do
      commit_mode!(repo, &File.write!(&1, String.duplicate("thread ", 20)))
      assert {:error, why} = Worktree.commit_file(repo, "master", ".loopctl/mode", 64)
      assert why =~ "larger than 64 bytes"
    end

    test "a symlink or a directory at the path is refused, and nothing on disk is opened", %{
      repo: repo
    } do
      commit_mode!(repo, &File.ln_s!("/dev/zero", &1))
      assert {:error, why} = Worktree.commit_file(repo, "master", ".loopctl/mode", 64)
      assert why =~ "is not a regular file"

      git!(repo, ["rm", "-q", ".loopctl/mode"])

      commit_mode!(repo, fn path ->
        File.mkdir_p!(path)
        File.write!(Path.join(path, "x"), "")
      end)

      assert {:error, why} = Worktree.commit_file(repo, "master", ".loopctl/mode", 64)
      assert why =~ "is not a regular file"
    end

    test "a commit that does not exist is an error carrying git's stderr, never absent", %{
      repo: repo
    } do
      assert {:error, why} = Worktree.commit_file(repo, "nope", ".loopctl/mode", 64)
      assert why =~ "cannot list .loopctl/mode at nope"
      assert why =~ "nope"
      refute why =~ "git exited"
      # The length line the shell appends after stderr is cut off, never shown.
      refute why =~ ~r/\d\z/
    end
  end

  describe "split_git/3" do
    setup %{repo: repo} do
      dir = tmp_dir!("fake-git")

      fake = fn name, body ->
        path = Path.join(dir, name)
        File.write!(path, "#!/bin/sh\n" <> body)
        File.chmod!(path, 0o755)
        path
      end

      {:ok, fake: fake, repo: repo}
    end

    test "a failure's stderr is cut exactly off the stdout written before it", %{
      fake: fake,
      repo: repo
    } do
      git = fake.("fails", "printf 'partial 42'\nprintf 'boom \\303\\251 7\\n' >&2\nexit 3\n")
      assert Worktree.split_git(git, repo, []) == {:error, "boom é 7"}
    end

    test "a success's stderr is logged, never read as the answer", %{fake: fake, repo: repo} do
      git = fake.("warns", "printf 'answer\\n'\necho 'careful' >&2\n")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Worktree.split_git(git, repo, ["rev-parse"]) == {:ok, "answer\n"}
        end)

      assert log =~ "careful"
    end

    test "a failure with no stderr names its exit status", %{fake: fake, repo: repo} do
      git = fake.("silent", "printf 'partial'\nexit 5\n")
      assert Worktree.split_git(git, repo, []) == {:error, "git exited 5"}
    end
  end
end
