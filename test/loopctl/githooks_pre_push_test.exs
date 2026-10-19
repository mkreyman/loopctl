defmodule Loopctl.GithooksPrePushTest do
  @moduledoc """
  Canary for `.githooks/` (#985): the repo-local hooks that put chg's shadow
  phase beside the fleet's gate.

  Runs the real hooks in throwaway git repositories, under a throwaway HOME
  holding fakes of the fleet's `~/.git-hooks`, claude-config's `local-gate.sh`
  and gate-lock lib, and a fake `chg` first on PATH. Each fake logs what it was
  asked. Proves the fleet's pre-push still decides the push, that chg is asked
  only once the push goes ahead, that the gate row is recorded only from a
  `mix precommit` attestation of exactly the pushed tree, that the shadow check
  starts in a gap between gates and runs holding no lock, that each commit is
  recorded and checked once however often it is pushed, that every call into
  chg is bounded, and that `git push` reaches the hook at all once
  `.githooks/install.sh` has pointed `core.hooksPath` at its dispatcher, even
  while the main worktree is on a commit older than `.githooks/`.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv

  @zero String.duplicate("0", 40)
  @flock System.find_executable("flock")
  @real_lock_lib Path.expand("~/.claude/hooks/lib/gate-lock-fd.sh")
  @real_gate_run Path.expand("~/workspace/claude-config/bin/gate-run.sh")
  @url "git@example:r.git"
  @fleet_hooks Path.expand("~/workspace/claude-config/git-hooks")

  setup do
    # Physical, because the hook prints the paths git resolves; random, because a
    # new VM's unique_integer/1 starts again where an earlier run's did.
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(Loopctl.RealTmpDir.path!(), "loopctl-githooks-#{suffix}")
    repo = Path.join(root, "repo")
    home = Path.join(root, "home")
    bin = Path.join(root, "bin")
    log = Path.join(root, "calls.log")
    lock = Path.join([repo, ".claude", "gate.lock"])
    Enum.each([repo, home, bin], &File.mkdir_p!/1)
    on_exit(fn -> remove_when_settled!(root, log, Path.join(home, ".chg/shadow/claims")) end)

    git!(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = rev!(repo, "HEAD")
    # The remote's default branch, which nearest-base.sh measures from.
    git!(repo, ["update-ref", "refs/remotes/origin/master", base])
    git!(repo, ["remote", "add", "origin", @url])
    git!(repo, ["checkout", "-q", "-b", "feature"])
    # gate-run.sh gates only a Mix project; untracked, as a build's files are.
    File.write!(Path.join(repo, "mix.exs"), "")

    # The repository has adopted the gate lock, as `touch` in the main worktree does.
    File.mkdir_p!(Path.dirname(lock))
    File.touch!(lock)

    # The fleet's hooks: each logs its name, its arguments and its stdin.
    for name <- ["pre-push", "pre-commit", "commit-msg"] do
      write_exec!(Path.join([home, ".git-hooks", name]), """
      #!/bin/bash
      echo "fleet #{name} $0 $*" >> "#{log}"
      if [ "#{name}" = pre-push ]; then
        while IFS= read -r l; do [ -n "$l" ] && echo "fleet stdin $l" >> "#{log}"; done
      fi
      exit "${FAKE_FLEET_EXIT:-0}"
      """)
    end

    # claude-config's local-gate.sh: `check` attests unless FAKE_CHECK_EXIT says not.
    write_exec!(Path.join([home, "workspace/claude-config/bin", "local-gate.sh"]), """
    #!/bin/bash
    [ "$1" = check ] || exit 2
    echo "check $2" >> "#{log}"
    [ "${FAKE_CHECK_EXIT:-0}" = 0 ] || { echo "unattested: repo root"; exit 1; }
    [ -z "${FAKE_CHECK_SLEEP:-}" ] || sleep "$FAKE_CHECK_SLEEP"
    printf 'fingerprint=abc\\nproject=.\\ngate=mix precommit\\nduration_s=%s\\n' "${FAKE_DURATION:-7}"
    """)

    # claude-config's gate-run.sh: logs how it was asked, then runs the command.
    write_exec!(Path.join([home, "workspace/claude-config/bin", "gate-run.sh"]), """
    #!/bin/bash
    echo "gate-run $*" >> "#{log}"
    while [ "$1" != -- ]; do shift; done
    shift
    exec "$@"
    """)

    # claude-config's gate-lock lib, reduced to the one function the hook calls.
    write_exec!(Path.join([home, ".claude/hooks/lib", "gate-lock-fd.sh"]), """
    gate_lock_path() { echo "$1/.claude/gate.lock"; }
    """)

    # chg: answers `chg gate` as chg does from CHG_GATE, logs every other call,
    # and whether a check runs while the gate lock is held. FAKE_*_SLEEP hang it.
    write_exec!(Path.join(bin, "chg"), """
    #!/bin/bash
    if [ "$1" = gate ]; then
      [ -z "${FAKE_GATE_SLEEP:-}" ] || sleep "$FAKE_GATE_SLEEP"
      echo "${CHG_GATE:-shadow}"; exit 0
    fi
    echo "chg $*" >> "#{log}"
    if [ "$1" = shadow ] && [ -n "${FAKE_RECORD_SLEEP:-}" ]; then sleep "$FAKE_RECORD_SLEEP"; fi
    if [ "$1" = check ]; then
      if flock -n "#{lock}" true; then echo "chg lock free" >> "#{log}"
      else echo "chg lock held" >> "#{log}"; fi
      echo "chg check output $*"
      echo "chg check done" >> "#{log}"
    fi
    exit 0
    """)

    %{repo: repo, home: home, bin: bin, log: log, root: root, base: base, lock: lock}
  end

  describe "pre-push, chg in shadow" do
    @describetag skip: @flock == nil && "flock is not on this machine's PATH"

    test "the fleet hook decides first; an attested tip records the gate's pass and queues chg's check through gate-run",
         ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} = push(ctx, [line(tip)])

      assert status == 0, out

      assert out =~
               "chg shadow check of #{String.slice(tip, 0, 12)} queued for a gap between gates"

      shadow = await_call!(ctx, "chg check --shadow --foreground")
      assert shadow =~ ~r/ --sha #{tip} --base #{ctx.base}$/
      await_call!(ctx, "chg lock free")

      calls = calls(ctx)
      assert "gate-run -w 1800 --heavy -- true" in calls
      fleet = Enum.find(calls, &String.starts_with?(&1, "fleet pre-push"))
      assert fleet =~ ~r{/\.git-hooks/pre-push origin git@example:r\.git$}
      assert "fleet stdin #{line(tip)}" in calls
      assert "check #{tip}" in calls

      [record] = Enum.filter(calls, &String.starts_with?(&1, "chg shadow record"))

      assert record ==
               "chg shadow record --sha #{tip} --verdict pass --ms 7000 --gate mix precommit"

      assert index_of(calls, fleet) < index_of(calls, record)
    end

    test "an unattested tip queues chg's check and records no verdict", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} = push(ctx, [line(tip)], [{"FAKE_CHECK_EXIT", "1"}])

      assert status == 0, out
      await_call!(ctx, "chg check --shadow --foreground")
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg shadow record"))
    end

    test "a push the fleet hook stops asks chg nothing and keeps the fleet hook's status",
         ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} = push(ctx, [line(tip)], [{"FAKE_FLEET_EXIT", "3"}])

      assert status == 3, out
      refute out =~ "chg shadow"
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg "))
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "check "))
    end

    test "a deletion, and a commit already on the remote, are not shadowed", ctx do
      old = commit!(ctx.repo, "lib/old.ex", "defmodule Old do end\n")
      git!(ctx.repo, ["update-ref", "refs/remotes/origin/feature", old])

      {out, status} =
        push(ctx, [
          "(delete) #{@zero} refs/heads/gone #{old}",
          "refs/heads/again #{old} refs/heads/again #{@zero}"
        ])

      assert status == 0, out
      refute out =~ "chg shadow"
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg "))
    end

    test "one commit pushed to two refs is recorded and shadowed once", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} =
        push(ctx, [line(tip), "refs/heads/other #{tip} refs/heads/other #{@zero}"])

      assert status == 0, out
      await_call!(ctx, "chg check --shadow --foreground")
      calls = calls(ctx)
      assert Enum.count(calls, &String.starts_with?(&1, "chg shadow record")) == 1
      assert Enum.count(calls, &String.starts_with?(&1, "chg check --shadow")) == 1
    end

    test "with no base to measure from, chg's check picks its own", ctx do
      git!(ctx.repo, ["update-ref", "-d", "refs/remotes/origin/master"])
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, _status} = push(ctx, [line(tip)])

      shadow = await_call!(ctx, "chg check --shadow --foreground")
      assert shadow =~ ~r/ --sha #{tip}$/, out
    end

    test "a story cut from an epic branch is measured from the epic, not master", ctx do
      epic = commit!(ctx.repo, "lib/epic.ex", "defmodule Epic do end\n")
      git!(ctx.repo, ["update-ref", "refs/remotes/origin/epic/e", epic])
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, _status} = push(ctx, [line(tip)])

      shadow = await_call!(ctx, "chg check --shadow --foreground")
      assert shadow =~ ~r/ --sha #{tip} --base #{epic}$/, out
    end

    test "without the gate lock adopted, the check is not started but the pass is recorded",
         ctx do
      File.rm!(ctx.lock)
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} = push(ctx, [line(tip)])

      assert status == 0, out
      assert out =~ "chg shadow not started: this repo has no gate lock to queue it behind"
      assert out =~ "touch #{ctx.lock}"
      calls = calls(ctx)
      refute Enum.any?(calls, &String.starts_with?(&1, "chg check"))
      assert Enum.any?(calls, &String.starts_with?(&1, "chg shadow record --sha #{tip}"))
    end

    test "without claude-config's lock lib, the check is not started and says why", ctx do
      File.rm!(Path.join([ctx.home, ".claude/hooks/lib", "gate-lock-fd.sh"]))
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} = push(ctx, [line(tip)])

      assert status == 0, out

      assert out =~
               "chg shadow not started: claude-config's gate-lock-fd.sh is not on this machine"

      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg check"))
    end

    @tag skip:
           (not File.regular?(@real_lock_lib) && "claude-config's gate-lock-fd.sh is absent") ||
             (not File.regular?(@real_gate_run) && "claude-config's gate-run.sh is absent") ||
             (@flock == nil && "flock is not on this machine's PATH")
    test "with claude-config's real gate-run.sh, the check waits for a gate to finish and then holds no lock",
         ctx do
      # gate-run.sh finds its lib beside itself, as in claude-config.
      cc = Path.join(ctx.home, "workspace/claude-config")
      File.cp!(@real_gate_run, Path.join(cc, "bin/gate-run.sh"))
      File.mkdir_p!(Path.join(cc, "hooks/lib"))
      File.cp!(@real_lock_lib, Path.join(cc, "hooks/lib/gate-lock-fd.sh"))
      File.cp!(@real_lock_lib, Path.join([ctx.home, ".claude/hooks/lib", "gate-lock-fd.sh"]))
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")
      gate = hold_lock!(ctx)

      {out, status} = push(ctx, [line(tip)])

      assert status == 0, out
      assert out =~ "queued for a gap between gates"
      # A gate holds the lock: the check has not started.
      Process.sleep(500)
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg check"))

      release_lock!(gate)
      await_call!(ctx, "chg check --shadow --foreground")
      # Running, it holds nothing a commit gate's exclusive take would wait on.
      await_call!(ctx, "chg lock free")
      refute "chg lock held" in calls(ctx)
    end

    test "every commit the push carries is recorded; only the tip is checked", ctx do
      first = commit!(ctx.repo, "lib/a.ex", "defmodule A do end\n")
      tip = commit!(ctx.repo, "lib/b.ex", "defmodule B do end\n")

      {out, status} = push(ctx, [line(tip)])

      assert status == 0, out
      await_call!(ctx, "chg check done")
      calls = calls(ctx)
      records = Enum.filter(calls, &String.starts_with?(&1, "chg shadow record"))
      assert Enum.sort(records) == Enum.sort([record(tip), record(first)])
      refute Enum.any?(calls, &(&1 == "check #{ctx.base}"))
      assert [check] = Enum.filter(calls, &String.starts_with?(&1, "chg check --shadow"))
      assert check =~ " --sha #{tip} "
    end

    test "an update records only what it adds to the remote ref", ctx do
      old = commit!(ctx.repo, "lib/a.ex", "defmodule A do end\n")
      tip = commit!(ctx.repo, "lib/b.ex", "defmodule B do end\n")

      {out, 0} = push(ctx, ["refs/heads/feature #{tip} refs/heads/feature #{old}"])

      await_call!(ctx, "chg check done")
      records = Enum.filter(calls(ctx), &String.starts_with?(&1, "chg shadow record"))
      assert records == [record(tip)], out
    end

    test "a retried push of the same commit records nothing again and leaves its check's log alone",
         ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, 0} = push(ctx, [line(tip)])
      await_call!(ctx, "chg check done")
      [_, log] = Regex.run(~r/\(log (\S+)\)/, out)
      first = File.read!(log)
      assert first =~ "chg check output"

      {again, status} = push(ctx, [line(tip)])

      assert status == 0, again
      assert again =~ "already queued, running or done on this machine: not queued again"
      calls = calls(ctx)
      assert Enum.count(calls, &String.starts_with?(&1, "chg shadow record")) == 1
      assert Enum.count(calls, &String.starts_with?(&1, "chg check --shadow")) == 1
      assert File.read!(log) == first
    end

    test "a duration local-gate.sh did not know sends no --ms", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, 0} = push(ctx, [line(tip)], [{"FAKE_DURATION", "?"}])

      assert [record] = Enum.filter(calls(ctx), &String.starts_with?(&1, "chg shadow record"))
      assert record == "chg shadow record --sha #{tip} --verdict pass --gate mix precommit", out
    end

    test "a hung chg gate is cut off and the push goes ahead with chg off", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")
      started = System.monotonic_time(:millisecond)

      {out, status} =
        push(ctx, [line(tip)], [{"FAKE_GATE_SLEEP", "20"}, {"CHG_HOOK_TIMEOUT_S", "1"}])

      assert status == 0, out
      assert System.monotonic_time(:millisecond) - started < 15_000
      assert out =~ "chg gate timed out after 1s: chg is off for this push"
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg "))
    end

    test "a hung local-gate.sh check records nothing, and the tip is still checked", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} =
        push(ctx, [line(tip)], [{"FAKE_CHECK_SLEEP", "20"}, {"CHG_HOOK_TIMEOUT_S", "1"}])

      assert status == 0, out
      assert out =~ "local-gate.sh check #{String.slice(tip, 0, 12)} timed out after 1s"
      await_call!(ctx, "chg check done")
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg shadow record"))
    end

    test "a hung chg shadow record is cut off and says so", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} =
        push(ctx, [line(tip)], [{"FAKE_RECORD_SLEEP", "20"}, {"CHG_HOOK_TIMEOUT_S", "1"}])

      assert status == 0, out
      assert out =~ "chg shadow record #{String.slice(tip, 0, 12)} timed out after 1s"
      await_call!(ctx, "chg check done")
    end

    test "without timeout(1) on PATH, perl bounds the call", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")
      path = ctx.bin <> ":" <> path_without!(ctx, ["timeout", "gtimeout"])
      started = System.monotonic_time(:millisecond)

      {out, status} =
        push(ctx, [line(tip)], [
          {"PATH", path},
          {"FAKE_GATE_SLEEP", "20"},
          {"CHG_HOOK_TIMEOUT_S", "1"}
        ])

      assert status == 0, out
      assert System.monotonic_time(:millisecond) - started < 15_000
      assert out =~ "chg gate timed out after 1s"
    end

    test "a push to a URL of a configured remote uses that remote", ctx do
      old = commit!(ctx.repo, "lib/old.ex", "defmodule Old do end\n")
      git!(ctx.repo, ["update-ref", "refs/remotes/origin/feature", old])

      {out, status} =
        push(ctx, ["refs/heads/again #{old} refs/heads/again #{@zero}"], [], [@url, @url])

      assert status == 0, out
      # The check is queued detached, so its synchronous line is the witness.
      refute out =~ "chg shadow"
      refute Enum.any?(calls(ctx), &String.starts_with?(&1, "chg "))
    end

    test "a push to an unknown URL judges the remote by the ref's old value, and measures from origin",
         ctx do
      url = "git@elsewhere:x.git"
      old = commit!(ctx.repo, "lib/old.ex", "defmodule Old do end\n")
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} =
        push(
          ctx,
          [
            "refs/heads/back #{old} refs/heads/back #{tip}",
            "refs/heads/feature #{tip} refs/heads/feature #{old}"
          ],
          [],
          [url, url]
        )

      assert status == 0, out
      shadow = await_call!(ctx, "chg check --shadow --foreground")
      assert shadow =~ ~r/ --sha #{tip} --base #{ctx.base}$/
      records = Enum.filter(calls(ctx), &String.starts_with?(&1, "chg shadow record"))
      assert records == [record(tip)]
    end

    test "CHG_GATE=off leaves the push exactly the fleet hook's", ctx do
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} = push(ctx, [line(tip)], [{"CHG_GATE", "off"}])

      assert status == 0, out
      refute out =~ "chg shadow"
      calls = calls(ctx)
      assert Enum.any?(calls, &String.starts_with?(&1, "fleet pre-push"))
      refute Enum.any?(calls, &String.starts_with?(&1, "chg "))
      refute Enum.any?(calls, &String.starts_with?(&1, "check "))
    end
  end

  test "without chg installed the push is exactly the fleet hook's", ctx do
    File.rm!(Path.join(ctx.bin, "chg"))
    tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

    {out, status} = push(ctx, [line(tip)], [{"PATH", ctx.bin <> ":" <> path_without_chg()}])

    assert status == 0, out
    refute out =~ "chg shadow"
    calls = calls(ctx)
    assert Enum.any?(calls, &String.starts_with?(&1, "fleet pre-push"))
    refute Enum.any?(calls, &String.starts_with?(&1, "chg "))
  end

  test "without the fleet's pre-push the push goes ahead and says what did not run", ctx do
    File.rm!(Path.join([ctx.home, ".git-hooks", "pre-push"]))
    tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

    {out, status} = push(ctx, [line(tip)], [{"CHG_GATE", "off"}])

    assert status == 0, out
    assert out =~ "the fleet's pre-push (mix test.e2e) did not run"
  end

  describe "the hooks that hand back to the fleet" do
    for name <- ["pre-commit", "commit-msg"] do
      test "#{name} runs the fleet's #{name} with its arguments and keeps its status", ctx do
        {out, status} = run_hook(ctx, unquote(name), ["a b", "c"], [{"FAKE_FLEET_EXIT", "3"}])

        assert status == 3, out

        assert [call] =
                 Enum.filter(calls(ctx), &String.starts_with?(&1, "fleet #{unquote(name)}"))

        # $0 is the fleet hook's own path, which it resolves its lib directory from.
        assert call == "fleet #{unquote(name)} #{ctx.home}/.git-hooks/#{unquote(name)} a b c"
      end

      test "#{name} without the fleet's lets git go on and says so", ctx do
        File.rm!(Path.join([ctx.home, ".git-hooks", unquote(name)]))

        {out, status} = run_hook(ctx, unquote(name), [])

        assert status == 0, out
        assert out =~ "the fleet's #{unquote(name)} did not run"
      end
    end

    test "every hook git looks for in .githooks is executable" do
      for path <- Path.wildcard(Path.join(githooks(), "*")), File.regular?(path) do
        assert Bitwise.band(File.stat!(path).mode, 0o111) != 0, "#{path} is not executable"
      end
    end

    @tag skip: not File.dir?(@fleet_hooks) && "claude-config's git-hooks/ is not on this machine"
    test "every fleet hook has a .githooks counterpart, or git would stop running it here" do
      fleet = @fleet_hooks |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "."))
      assert fleet != []
      missing = Enum.reject(fleet, &File.regular?(Path.join(githooks(), &1)))

      assert missing == [],
             "add a .githooks/<name> that hands back to the fleet's: #{inspect(missing)}"
    end
  end

  describe "install.sh, and git reaching the hook" do
    test "points core.hooksPath at a dispatcher in the git common dir, from a linked worktree",
         ctx do
      main = with_githooks!(ctx.repo)
      wt = Path.join(ctx.root, "wt")
      git!(ctx.repo, ["worktree", "add", "-q", wt, "-b", "wt"])

      {out, 0} = install(ctx, wt)

      hooks = Path.join([main, ".git", "githooks-dispatch"])
      assert out =~ "core.hooksPath -> #{hooks}"
      assert config(wt, "core.hooksPath") == hooks
      assert config(ctx.repo, "core.hooksPath") == hooks
      assert hooks |> File.ls!() |> Enum.sort() == ["commit-msg", "pre-commit", "pre-push"]
      assert {"core.hooksPath already " <> _, 0} = install(ctx, ctx.repo)
    end

    test "hooks never vanish while the main worktree is on a commit older than .githooks", ctx do
      main = with_githooks!(ctx.repo)
      wt = Path.join(ctx.root, "wt")
      git!(ctx.repo, ["worktree", "add", "-q", wt, "-b", "wt"])
      {_, 0} = install(ctx, wt)
      dispatch = Path.join([main, ".git", "githooks-dispatch"])

      # Present: the dispatcher runs .githooks/pre-push, which shadows. (The
      # fake lock lib finds the lock beside the worktree it is asked about.)
      File.mkdir_p!(Path.join(wt, ".claude"))
      File.touch!(Path.join(wt, ".claude/gate.lock"))
      tip = commit!(wt, "lib/thing.ex", "defmodule Thing do end\n")
      {out, 0} = run_dispatch(ctx, dispatch, "pre-push", wt, line(tip))
      assert out =~ "queued for a gap between gates"
      await_call!(ctx, "chg check done")

      # The main worktree checks out a commit predating .githooks/.
      File.rm_rf!(Path.join(main, ".githooks"))
      File.rm!(ctx.log)

      {out, status} =
        System.cmd(
          "git",
          [
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "x"
          ],
          cd: wt,
          env: hook_env(ctx),
          stderr_to_stdout: true
        )

      assert status == 0, out
      calls = calls(ctx)

      assert Enum.any?(
               calls,
               &String.starts_with?(&1, "fleet pre-commit #{ctx.home}/.git-hooks/pre-commit")
             )

      assert Enum.any?(
               calls,
               &String.starts_with?(&1, "fleet commit-msg #{ctx.home}/.git-hooks/commit-msg")
             )

      {out, 0} = run_dispatch(ctx, dispatch, "pre-push", wt, line(tip))
      assert Enum.any?(calls(ctx), &String.starts_with?(&1, "fleet pre-push")), out
      refute out =~ "chg shadow"

      # Neither side has the hook: git's no-hook behaviour.
      File.rm_rf!(Path.join(ctx.home, ".git-hooks"))
      assert {_, 0} = run_dispatch(ctx, dispatch, "pre-push", wt, line(tip))
    end

    test "leaves core.hooksPath alone on a machine without the fleet's hooks", ctx do
      with_githooks!(ctx.repo)
      File.rm_rf!(Path.join(ctx.home, ".git-hooks"))

      {out, 0} = install(ctx, ctx.repo)

      assert out =~ "core.hooksPath unchanged: no fleet hooks"
      assert config(ctx.repo, "core.hooksPath") == ""
    end

    @tag skip: @flock == nil && "flock is not on this machine's PATH"
    test "once installed, a real git push runs .githooks/pre-push, and it runs the fleet's",
         ctx do
      with_githooks!(ctx.repo)
      {_, 0} = install(ctx, ctx.repo)
      remote = Path.join(ctx.root, "remote.git")
      git!(ctx.root, ["init", "-q", "--bare", remote])
      git!(ctx.repo, ["remote", "set-url", "origin", remote])
      tip = commit!(ctx.repo, "lib/thing.ex", "defmodule Thing do end\n")

      {out, status} =
        System.cmd("git", ["push", "-q", "origin", "feature"],
          cd: ctx.repo,
          env: hook_env(ctx),
          stderr_to_stdout: true
        )

      assert status == 0, out
      shadow = await_call!(ctx, "chg check --shadow --foreground")
      assert shadow =~ ~r/ --sha #{tip} --base #{ctx.base}$/
      calls = calls(ctx)
      assert Enum.any?(calls, &(&1 =~ ~r{^fleet pre-push \S+/\.git-hooks/pre-push origin }))
      assert "fleet stdin refs/heads/feature #{tip} refs/heads/feature #{@zero}" in calls
    end
  end

  # The detached check runs after the hook has returned: wait for the first
  # call it logs that starts with `prefix`, and return it.
  defp await_call!(ctx, prefix, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    case Enum.find(calls(ctx), &String.starts_with?(&1, prefix)) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("no call starting #{inspect(prefix)} in #{inspect(calls(ctx))}")

        Process.sleep(20)
        await_call!(ctx, prefix, deadline)

      call ->
        call
    end
  end

  # A queued check writes into the root until it exits: removing the root under
  # it fails, or leaves a file behind. So the root goes once every check the
  # hook claimed has logged that it is done (at once where none was queued).
  defp remove_when_settled!(root, log, claims, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000
    claimed = Enum.count(Path.wildcard(Path.join(claims, "*.check")))
    busy? = claimed > Enum.count(calls(%{log: log}), &(&1 == "chg check done"))

    if busy? and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      remove_when_settled!(root, log, claims, deadline)
    else
      File.rm_rf!(root)
    end
  end

  # A gate holding the lock EXCLUSIVE, as the fleet's pre-commit does, until
  # release_lock!/1.
  defp hold_lock!(ctx) do
    held = Path.join(ctx.root, "held")
    release = Path.join(ctx.root, "release")
    script = ~s(: > "$1"; while [ -e "$1" ] && [ ! -e "$2" ]; do sleep 0.05; done)

    task =
      Task.async(fn ->
        System.cmd(@flock, ["-x", ctx.lock, "sh", "-c", script, "sh", held, release])
      end)

    # A failed assertion must not leave the holder behind: it also lets go once
    # the root is removed.
    wait_until!(fn -> File.exists?(held) end)
    %{task: task, release: release}
  end

  defp release_lock!(%{task: task, release: release}) do
    File.touch!(release)
    {_, 0} = Task.await(task)
  end

  defp wait_until!(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("timed out waiting")
      true -> Process.sleep(20) && wait_until!(fun, deadline)
    end
  end

  defp record(sha),
    do: "chg shadow record --sha #{sha} --verdict pass --ms 7000 --gate mix precommit"

  # This machine's PATH as one directory of links, minus `names`.
  defp path_without!(ctx, names) do
    farm = Path.join(ctx.root, "path-farm")
    File.mkdir_p!(farm)

    for dir <- String.split(System.get_env("PATH", ""), ":", trim: true),
        File.dir?(dir),
        name <- File.ls!(dir),
        name not in names,
        not File.exists?(Path.join(farm, name)) do
      File.ln_s!(Path.join(dir, name), Path.join(farm, name))
    end

    farm
  end

  defp run_dispatch(ctx, dispatch, hook, dir, stdin_line) do
    stdin = Path.join(ctx.root, "stdin")
    File.write!(stdin, stdin_line <> "\n")

    System.cmd("sh", ["-c", ~s("$0" origin #{@url} < "$1"), Path.join(dispatch, hook), stdin],
      cd: dir,
      env: hook_env(ctx),
      stderr_to_stdout: true
    )
  end

  defp githooks, do: Path.join(File.cwd!(), ".githooks")

  defp line(sha), do: "refs/heads/feature #{sha} refs/heads/feature #{@zero}"

  defp push(ctx, lines, extra_env \\ [], args \\ ["origin", @url]) do
    stdin = Path.join(ctx.root, "stdin")
    File.write!(stdin, Enum.join(lines, "\n") <> "\n")
    hook = Path.join(githooks(), "pre-push")

    System.cmd("bash", ["-c", ~s(bash "$0" "$2" "$3" < "$1"), hook, stdin | args],
      cd: ctx.repo,
      env: hook_env(ctx) ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp run_hook(ctx, name, args, extra_env \\ []) do
    System.cmd("bash", [Path.join(githooks(), name) | args],
      cd: ctx.repo,
      env: hook_env(ctx) ++ extra_env,
      stderr_to_stdout: true
    )
  end

  # The hooks' own git calls must not follow a GIT_DIR exported by a gate this
  # suite may be running inside, nor the machine's global hooksPath.
  defp hook_env(ctx) do
    GitEnv.spawn_env() ++
      [
        {"HOME", ctx.home},
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH", "")},
        {"CHG_GATE", nil},
        {"CHG_HOME", nil},
        {"GATE_FLOCK_DIR", Path.join(ctx.root, "no-brew")}
      ]
  end

  # Copies this checkout's .githooks into `repo`, untracked as a main worktree's
  # checkout of them would be; returns the repo's physical path.
  defp with_githooks!(repo) do
    {_, 0} = System.cmd("cp", ["-R", githooks(), Path.join(repo, ".githooks")])
    {main, 0} = System.cmd("pwd", ["-P"], cd: repo)
    String.trim(main)
  end

  defp install(ctx, dir) do
    System.cmd("bash", [Path.join(githooks(), "install.sh")],
      cd: dir,
      env: GitEnv.spawn_env() ++ [{"HOME", ctx.home}],
      stderr_to_stdout: true
    )
  end

  # What the repository's own config holds: without git/2's `-c` overrides,
  # which would answer for themselves.
  defp config(dir, key) do
    {out, _} = System.cmd("git", ["config", "--get", key], cd: dir, env: GitEnv.spawn_env())
    String.trim(out)
  end

  # This machine's PATH, minus any directory holding a real chg.
  defp path_without_chg do
    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.reject(&File.exists?(Path.join(&1, "chg")))
    |> Enum.join(":")
  end

  defp calls(ctx) do
    case File.read(ctx.log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp index_of(list, item), do: Enum.find_index(list, &(&1 == item))

  defp commit!(repo, path, body) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
    git!(repo, ["add", path])
    git!(repo, ["commit", "-q", "-m", "add #{path}"])
    rev!(repo, "HEAD")
  end

  defp rev!(repo, ref) do
    {sha, 0} = git(repo, ["rev-parse", ref])
    String.trim(sha)
  end

  defp write_exec!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp git!(dir, args) do
    {out, status} = git(dir, args)
    assert status == 0, "git #{Enum.join(args, " ")} in #{dir}: #{out}"
    out
  end

  # The fixture's git: no hooks, no signing, no machine config.
  defp git(dir, args) do
    System.cmd(
      "git",
      GitEnv.config_args() ++
        ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false" | args],
      cd: dir,
      env: GitEnv.spawn_env(),
      stderr_to_stdout: true
    )
  end
end
