defmodule LoopctlRunner.LoopPushTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../priv/bin/loop-push", __DIR__)

  # EVERY git call, the script's included, drops the variables that point git at a repository:
  # under the pre-commit hook they name THIS repository, and `-C` does not override them. A test
  # in this repo once committed into the real branch and pushed to GitHub master that way.
  @no_repo_env Enum.map(LoopctlRunner.Worktree.repo_locating_env(), &{&1, nil})

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: @no_repo_env)
    String.trim(out)
  end

  defp commit!(dir, name, content \\ nil) do
    File.write!(Path.join(dir, name), content || name)
    git!(dir, ["add", name])
    git!(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", name])
    git!(dir, ["rev-parse", "HEAD"])
  end

  defp loop_push(dir, env \\ []) do
    # A run directory of the test's own: a test run inside a loop session must never record in
    # ITS run directory, and loop-push refuses to push with none.
    default_run = Path.join(Path.dirname(dir), "default-run")
    File.mkdir_p!(default_run)

    System.cmd(@script, [],
      cd: dir,
      stderr_to_stdout: true,
      env:
        @no_repo_env ++
          [{"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@t"}] ++
          [{"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@t"}] ++
          Enum.to_list(
            Map.merge(
              %{"LOOP_BRANCH" => "loop/story", "LOOP_RUN_DIR" => default_run},
              Map.new(env)
            )
          )
    )
  end

  # A bare origin with master, the session's clone on loop/story, and a second clone standing in
  # for loopctl's merge executor, which moves the thread branch without telling the session.
  setup %{tmp_dir: tmp} do
    origin = Path.join(tmp, "origin.git")
    session = Path.join(tmp, "session")
    other = Path.join(tmp, "other")
    git!(tmp, ["init", "-q", "--bare", "-b", "master", origin])
    git!(tmp, ["clone", "-q", origin, session])
    commit!(session, "base")
    git!(session, ["push", "-q", "origin", "HEAD:master"])
    git!(session, ["checkout", "-q", "-b", "loop/story"])
    {:ok, origin: origin, session: session, other: other, tmp: tmp}
  end

  defp remote_head(ctx), do: git!(ctx.origin, ["rev-parse", "refs/heads/loop/story"])

  defp move_remote(ctx, file, content \\ nil) do
    git!(ctx.tmp, ["clone", "-q", "-b", "loop/story", ctx.origin, ctx.other])
    sha = commit!(ctx.other, file, content)
    git!(ctx.other, ["push", "-q", "origin", "loop/story"])
    sha
  end

  test "a first push creates the branch on origin", ctx do
    mine = commit!(ctx.session, "one")
    assert {out, 0} = loop_push(ctx.session)
    assert out =~ "pushed #{mine}"
    assert remote_head(ctx) == mine
  end

  test "after origin moved, it merges origin's commits and pushes without force", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)
    theirs = move_remote(ctx, "base-update")
    mine = commit!(ctx.session, "two")

    assert {_, 0} = loop_push(ctx.session)
    head = remote_head(ctx)
    # Nothing on origin was lost: both the base update and the session's commit are in history.
    git!(ctx.origin, ["merge-base", "--is-ancestor", theirs, head])
    git!(ctx.origin, ["merge-base", "--is-ancestor", mine, head])
  end

  test "no push it makes can force: no --force form, no + refspec", ctx do
    # Merging first makes a forced push a fast-forward too, so only the ARGUMENTS can show it.
    bin = Path.join(ctx.tmp, "bin")
    File.mkdir_p!(bin)
    log = Path.join(ctx.tmp, "git.log")
    real = System.find_executable("git")
    File.write!(Path.join(bin, "git"), "#!/bin/sh\necho \"$*\" >> #{log}\nexec #{real} \"$@\"\n")
    File.chmod!(Path.join(bin, "git"), 0o755)
    path = [{"PATH", bin <> ":" <> System.get_env("PATH")}]

    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session, path)
    move_remote(ctx, "base-update")
    commit!(ctx.session, "two")
    {_, 0} = loop_push(ctx.session, path)

    pushes = log |> File.read!() |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/(^| )push /))
    assert length(pushes) == 2

    for push <- pushes do
      refute push =~ ~r/(^| )(-f|--force|--force-with-lease|--force-if-includes)( |=|$)/
      refute push =~ ~r/ \+/
    end
  end

  test "a conflict aborts the merge, pushes nothing and says what to do", ctx do
    commit!(ctx.session, "shared", "mine")
    {_, 0} = loop_push(ctx.session)
    theirs = move_remote(ctx, "shared", "theirs")
    commit!(ctx.session, "shared", "mine again")

    assert {out, 3} = loop_push(ctx.session)
    assert out =~ "conflict"
    assert remote_head(ctx) == theirs
    # The merge was aborted: the session's tree is clean, not mid-merge.
    assert git!(ctx.session, ["status", "--porcelain"]) == ""
  end

  test "it refuses a detached HEAD and a branch that is not the session's", ctx do
    commit!(ctx.session, "one")
    assert {_, 2} = loop_push(ctx.session, [{"LOOP_BRANCH", "loop/other"}])
    git!(ctx.session, ["checkout", "-q", "--detach"])
    assert {_, 2} = loop_push(ctx.session)
  end

  test "without LOOP_BRANCH it refuses and pushes nothing", ctx do
    commit!(ctx.session, "one")
    assert {out, 2} = loop_push(ctx.session, [{"LOOP_BRANCH", nil}])
    assert out =~ "LOOP_BRANCH is not set"
    assert git!(ctx.origin, ["branch", "--list", "loop/story"]) == ""
  end

  test "a merge git will not start (uncommitted changes in its way) says git's words, exit 5",
       ctx do
    commit!(ctx.session, "shared", "mine")
    {_, 0} = loop_push(ctx.session)
    move_remote(ctx, "shared", "theirs")
    File.write!(Path.join(ctx.session, "shared"), "uncommitted")

    assert {out, 5} = loop_push(ctx.session)
    assert out =~ "git would not merge origin/loop/story"
    refute File.exists?(Path.join(ctx.session, ".git/MERGE_HEAD"))
  end

  test "origin moving between its fetch and its push sends it round again: fetch, merge, push",
       ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)

    # The merge executor's commit, ready in another clone, lands on origin just before this
    # push reaches it: git, on the script's PATH, pushes it first, once.
    git!(ctx.tmp, ["clone", "-q", "-b", "loop/story", ctx.origin, ctx.other])
    theirs = commit!(ctx.other, "base-update")
    bin = Path.join(ctx.tmp, "racing-bin")
    File.mkdir_p!(bin)
    real = System.find_executable("git")
    once = Path.join(ctx.tmp, "raced")

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    case " $* " in *" push "*) is_push=1 ;; *) is_push= ;; esac
    if [ -n "$is_push" ] && [ ! -e "#{once}" ]; then
        touch "#{once}"
        "#{real}" -C "#{ctx.other}" push -q origin loop/story
    fi
    exec "#{real}" "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    mine = commit!(ctx.session, "two")

    assert {_, 0} = loop_push(ctx.session, [{"PATH", bin <> ":" <> System.get_env("PATH")}])
    assert File.exists?(once)
    head = remote_head(ctx)

    {_, 0} =
      System.cmd("git", ["-C", ctx.origin, "merge-base", "--is-ancestor", theirs, head],
        env: @no_repo_env
      )

    {_, 0} =
      System.cmd("git", ["-C", ctx.origin, "merge-base", "--is-ancestor", mine, head],
        env: @no_repo_env
      )
  end

  defp ancestor?(repo, commit, of) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", repo, "merge-base", "--is-ancestor", commit, of],
        env: @no_repo_env,
        stderr_to_stdout: true
      )
    )
  end

  test "a branch origin deleted is pushed fresh, never merged from its stale tracking ref", ctx do
    old = commit!(ctx.session, "shipped")
    {_, 0} = loop_push(ctx.session)
    # Squash-merged and deleted on origin; the re-dispatch resets the branch to the base.
    git!(ctx.origin, ["update-ref", "-d", "refs/heads/loop/story"])
    git!(ctx.session, ["reset", "-q", "--hard", "master"])
    mine = commit!(ctx.session, "fresh")

    assert {_, 0} = loop_push(ctx.session)
    assert remote_head(ctx) == mine
    refute ancestor?(ctx.origin, old, mine)
  end

  test "a push that fails for another reason exits 4 with what git said", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)
    File.rm_rf!(ctx.origin)
    commit!(ctx.session, "two")

    assert {out, 4} = loop_push(ctx.session)
    assert out =~ "loop-push: could not ask origin where loop/story is"
    assert out =~ "does not appear to be a git repository"
  end

  test "a tag sharing the branch's name does not stop it pushing its own branch", ctx do
    mine = commit!(ctx.session, "one")
    git!(ctx.session, ["tag", "loop/story"])
    assert {_, 0} = loop_push(ctx.session)
    assert remote_head(ctx) == mine
  end

  test "a fetch that fails never merges the tracking ref it left behind", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)
    move_remote(ctx, "theirs")
    # The session's tracking ref learns origin's commit, then origin becomes unreachable.
    git!(ctx.session, [
      "fetch",
      "-q",
      "origin",
      "+refs/heads/loop/story:refs/remotes/origin/loop/story"
    ])

    File.rename!(ctx.origin, ctx.origin <> ".away")
    mine = commit!(ctx.session, "two")

    assert {_, 4} = loop_push(ctx.session)
    assert git!(ctx.session, ["rev-parse", "HEAD"]) == mine
  end

  # A git whose pushes run `on_push` and fail, printing `said` on stdout, as git's porcelain status
  # and a pre-push hook's own output both come. Returns the environment that puts it first on
  # PATH, and a file counting its pushes.
  defp failing_push_git!(ctx, said, on_push \\ ":") do
    bin = Path.join(ctx.tmp, "failing-bin")
    File.mkdir_p!(bin)
    real = System.find_executable("git")
    count = Path.join(ctx.tmp, "pushes")

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    case " $* " in *" push "*)
        echo x >> "#{count}"
        #{on_push}
        printf '%b\\n' "#{said}"
        exit 1 ;;
    esac
    exec "#{real}" "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    {[{"PATH", bin <> ":" <> System.get_env("PATH")}], count}
  end

  # An update hook on origin that moves the branch after origin advertised it and before it
  # updates it, so receive-pack itself refuses the push: once, or every time.
  defp moving_origin!(ctx, times) do
    hooks = Path.join(ctx.tmp, "origin-hooks")
    File.mkdir_p!(hooks)
    moves = Path.join(ctx.tmp, "origin-moves")

    File.write!(Path.join(hooks, "update"), """
    #!/bin/sh
    n=$(cat "#{moves}" 2>/dev/null || echo 0)
    if [ "$n" -lt #{times} ]; then
        echo $((n + 1)) > "#{moves}"
        head=$(git rev-parse refs/heads/loop/story)
        moved=$(git commit-tree "$head^{tree}" -p "$head" -m "moved by origin $n")
        git update-ref refs/heads/loop/story "$moved"
    fi
    exit 0
    """)

    File.chmod!(Path.join(hooks, "update"), 0o755)
    git!(ctx.origin, ["config", "core.hooksPath", hooks])
    moves
  end

  test "origin's own refusal of a branch moved under it is fetched, merged and pushed past",
       ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)
    moves = moving_origin!(ctx, 1)
    mine = commit!(ctx.session, "two")

    assert {_, 0} = loop_push(ctx.session)
    assert File.read!(moves) == "1\n"
    assert git!(ctx.origin, ["merge-base", "--is-ancestor", mine, remote_head(ctx)]) == ""
  end

  test "a branch origin keeps moving gives up after three pushes, saying what origin answered",
       ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)
    moving_origin!(ctx, 9)
    commit!(ctx.session, "two")

    assert {out, 4} = loop_push(ctx.session)
    assert out =~ "kept moving across 3 attempts"
    assert out =~ "remote rejected"
  end

  test "a refusal with origin unmoved exits at once with git's words", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)

    {env, count} =
      failing_push_git!(ctx, "!\\tHEAD:refs/heads/loop/story\\t[rejected] (needs force)")

    commit!(ctx.session, "two")

    assert {out, 4} = loop_push(ctx.session, env)
    assert out =~ "origin's loop/story did not move"
    assert out =~ "[rejected] (needs force)"
    assert File.read!(count) == "x\n"
  end

  test "a failing hook's output decides nothing, whatever it prints, and is shown", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)

    # A pre-push hook fails having printed, on stdout, its reason and a line shaped like git's.
    {env, count} =
      failing_push_git!(
        ctx,
        "e2e checks FAILED\\n!\\tHEAD:refs/heads/loop/story\\t[rejected] (non-fast-forward)"
      )

    commit!(ctx.session, "two")

    assert {out, 4} = loop_push(ctx.session, env)
    assert out =~ "e2e checks FAILED"
    assert File.read!(count) == "x\n"
  end

  test "a branch deleted after origin moved it is not pushed back on the next round", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)

    # The first push is refused as origin moves the branch; the second, after the merge, as loopctl
    # merges the thread and deletes it.
    {env, count} =
      failing_push_git!(ctx, "!\\tHEAD:refs/heads/loop/story\\t[remote rejected] (refused)", """
      n=$(wc -l < "#{Path.join(ctx.tmp, "pushes")}")
      if [ "$n" -eq 1 ]; then
          head=$(git -C "#{ctx.origin}" rev-parse refs/heads/loop/story)
          moved=$(git -C "#{ctx.origin}" commit-tree "$head^{tree}" -p "$head" -m moved)
          git -C "#{ctx.origin}" update-ref refs/heads/loop/story "$moved"
      else
          git -C "#{ctx.origin}" update-ref -d refs/heads/loop/story
      fi
      """)

    commit!(ctx.session, "two")

    assert {out, 4} = loop_push(ctx.session, env)
    assert out =~ "origin deleted loop/story after a push was refused"
    assert File.read!(count) == "x\nx\n"

    assert {_, 128} =
             System.cmd(
               "git",
               ["-C", ctx.origin, "rev-parse", "--verify", "refs/heads/loop/story"],
               stderr_to_stdout: true
             )
  end

  test "a long refusal keeps the reason at its top and git's words at its bottom", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)
    filler = Enum.map_join(1..40, "\\n", &"trace line #{&1}")

    {env, _count} =
      failing_push_git!(
        ctx,
        "e2e checks FAILED: invoice_test\\n#{filler}\\nerror: failed to push"
      )

    commit!(ctx.session, "two")

    assert {out, 4} = loop_push(ctx.session, env)
    assert out =~ "e2e checks FAILED: invoice_test"
    assert out =~ "error: failed to push"
    refute out =~ "trace line 20\n"
  end

  test "a branch origin deleted during the push is not pushed back", ctx do
    commit!(ctx.session, "one")
    {_, 0} = loop_push(ctx.session)

    {env, count} =
      failing_push_git!(
        ctx,
        "!\\tHEAD:refs/heads/loop/story\\t[remote rejected] (reference does not exist)",
        ~s(git -C "#{ctx.origin}" update-ref -d refs/heads/loop/story)
      )

    commit!(ctx.session, "two")

    assert {out, 4} = loop_push(ctx.session, env)
    assert out =~ "origin deleted loop/story after a push was refused"
    assert File.read!(count) == "x\n"

    assert {_, 128} =
             System.cmd(
               "git",
               ["-C", ctx.origin, "rev-parse", "--verify", "refs/heads/loop/story"],
               stderr_to_stdout: true
             )
  end

  describe "recording each push for the runner" do
    test "each push appends its commit and tree to the run's checkpoints.log", ctx do
      run_dir = Path.join(ctx.tmp, "run")
      File.mkdir_p!(run_dir)
      log = Path.join(run_dir, "checkpoints.log")

      one = commit!(ctx.session, "one")
      assert {_, 0} = loop_push(ctx.session, %{"LOOP_RUN_DIR" => run_dir})
      tree_one = git!(ctx.session, ["rev-parse", "#{one}^{tree}"])
      assert File.read!(log) == "#{one} #{tree_one}\n"

      # After origin moved, what is recorded is the head that was PUSHED: the merge.
      move_remote(ctx, "base-update")
      commit!(ctx.session, "two")
      assert {_, 0} = loop_push(ctx.session, %{"LOOP_RUN_DIR" => run_dir})
      pushed = remote_head(ctx)
      tree = git!(ctx.session, ["rev-parse", "#{pushed}^{tree}"])
      assert File.read!(log) == "#{one} #{tree_one}\n#{pushed} #{tree}\n"
    end

    test "a push it cannot record exits 6, says so, and running it again records it", ctx do
      run_dir = Path.join(ctx.tmp, "run")
      mine = commit!(ctx.session, "one")

      assert {out, 6} = loop_push(ctx.session, %{"LOOP_RUN_DIR" => run_dir})
      assert out =~ "pushed #{mine}"
      assert out =~ "could not record it"
      assert remote_head(ctx) == mine

      File.mkdir_p!(run_dir)
      assert {_, 0} = loop_push(ctx.session, %{"LOOP_RUN_DIR" => run_dir})
      assert File.read!(Path.join(run_dir, "checkpoints.log")) =~ ~r/\A#{mine} [0-9a-f]{40}\n\z/
    end

    test "a line an earlier append left unfinished is ended before the next is written", ctx do
      run_dir = Path.join(ctx.tmp, "run")
      File.mkdir_p!(run_dir)
      log = Path.join(run_dir, "checkpoints.log")
      File.write!(log, "abc123")
      mine = commit!(ctx.session, "one")

      assert {_, 0} = loop_push(ctx.session, %{"LOOP_RUN_DIR" => run_dir})
      assert File.read!(log) =~ ~r/\Aabc123\n#{mine} [0-9a-f]{40}\n\z/
    end

    test "with no run directory to record in, nothing is pushed", ctx do
      commit!(ctx.session, "one")

      assert {out, 2} = loop_push(ctx.session, %{"LOOP_RUN_DIR" => nil})
      assert out =~ "LOOP_RUN_DIR is not set"

      assert {_, status} =
               System.cmd("git", [
                 "-C",
                 ctx.origin,
                 "rev-parse",
                 "--verify",
                 "-q",
                 "refs/heads/loop/story"
               ])

      assert status != 0
    end
  end
end
