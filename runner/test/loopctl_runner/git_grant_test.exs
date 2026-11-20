defmodule LoopctlRunner.GitGrantTest do
  # Global trace patterns on Owner and File, which a concurrent test would trip.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{GitGrant, Owner}

  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  setup do
    {:ok, grants: tmp_dir!("git-grant")}
  end

  # A live os process that is not a BEAM, ended when the test is.
  defp live_non_beam! do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:exit_status, args: ["60"]])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true) end)
    {port, pid}
  end

  test "the grant sweep asks once whether an owner several grants share is alive", ctx do
    # Every grant a daemon arms names the same BEAM, and each liveness question forks `ps`.
    owner = granted(owner!())

    for id <- ~w(a b c),
        do: File.write!(Path.join(ctx.grants, GitGrant.prefix() <> id), GitGrant.line(id, owner))

    parent = self()

    sweeper =
      spawn(fn ->
        receive do
          :go -> send(parent, {:swept, GitGrant.sweep(ctx.grants)})
        end
      end)

    :erlang.trace_pattern({Owner, :alive?, 1}, true, [:global])
    on_exit(fn -> :erlang.trace_pattern({Owner, :alive?, 1}, false, [:global]) end)
    :erlang.trace(sweeper, true, [:call])
    send(sweeper, :go)

    assert_receive {:swept, []}, 5_000
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 5_000
    assert_received {:trace, ^sweeper, :call, {Owner, :alive?, [^owner]}}
    refute_received {:trace, ^sweeper, :call, {Owner, :alive?, _}}
  end

  test "a pending file is judged by the owner it names, and swept past ten minutes whoever",
       ctx do
    # Prepare and arm straddle one Port.open, milliseconds apart. A Session killed between them
    # leaves a pending file naming the daemon, which lives on: judged by its owner alone, it was
    # never swept while the daemon ran.
    pending = &Path.join(ctx.grants, ".loopctl-runner-pending-" <> &1)
    now = System.os_time(:second)
    two_hours_ago = now - 7_200
    live = granted(owner!())
    dead = Owner.of(dead_pid(), live["beam_start_id"])
    {port, launcher} = live_non_beam!()

    File.write!(pending.("live-old"), GitGrant.line("live-old", live))
    File.touch!(pending.("live-old"), now - 11 * 60)
    File.write!(pending.("live-young"), GitGrant.line("live-young", live))
    File.touch!(pending.("live-young"), now - 9 * 60)
    File.write!(pending.("dead-fresh"), GitGrant.line("dead-fresh", dead))
    File.write!(pending.("session-gone"), GitGrant.line("session-gone", live, Owner.of(launcher)))
    File.write!(pending.("unparseable-stale"), "")
    File.touch!(pending.("unparseable-stale"), two_hours_ago)
    File.write!(pending.("unparseable-fresh"), "")

    GitGrant.sweep(ctx.grants)
    assert File.exists?(pending.("session-gone"))

    System.cmd("kill", ["-9", "#{launcher}"])
    assert_receive {^port, {:exit_status, _}}, 5_000
    GitGrant.sweep(ctx.grants)

    refute File.exists?(pending.("live-old"))
    assert File.exists?(pending.("live-young"))
    refute File.exists?(pending.("dead-fresh"))
    refute File.exists?(pending.("session-gone"))
    refute File.exists?(pending.("unparseable-stale"))
    assert File.exists?(pending.("unparseable-fresh"))
  end

  # A pid no process holds: one that just exited.
  defp dead_pid do
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    String.to_integer(String.trim(out))
  end

  test "a session line recorded by pid alone is judged as a process, not as a BEAM", ctx do
    # The launcher is a shell. An owner recorded by pid alone must be a BEAM to count as alive,
    # and judging the SESSION that way would sweep a live session's grant mid-run.
    {port, launcher} = live_non_beam!()
    path = Path.join(ctx.grants, GitGrant.prefix() <> "pid-only-session")
    File.write!(path, GitGrant.line("pid-only-session", owner!(), Owner.of(launcher, nil)))

    assert GitGrant.sweep(ctx.grants) == []

    System.cmd("kill", ["-9", "#{launcher}"])
    assert_receive {^port, {:exit_status, _}}, 5_000
    assert GitGrant.sweep(ctx.grants) == [path]
  end

  test "a grant appears only once, whole, in the one rename that carries both of its lines" do
    # Visible with only its owner line, a Session killed before the launcher's line was added left
    # a grant naming only the daemon's BEAM, which no sweep removes while the daemon lives. Written
    # in place, a reader could see it empty or half-written: the sweep finds no stamp and leaves
    # it, the hook finds no owner.
    root = tmp_dir!("git-grant-atomic")
    git_repo!(Path.join(root, "repo"))
    config = config!(root)
    path = GitGrant.path(config, "atomic")
    launcher = Owner.of(String.to_integer(System.pid()), "utc:Sat Sep 12 15:34:27 2026")

    for mfa <- [{File, :write, 2}, {File, :rename, 2}],
        do: :erlang.trace_pattern(mfa, true, [:global])

    on_exit(fn ->
      for mfa <- [{File, :write, 2}, {File, :rename, 2}],
          do: :erlang.trace_pattern(mfa, false, [:global])
    end)

    parent = self()

    me =
      spawn(fn ->
        send(parent, {:prepared, GitGrant.prepare(config, "atomic")})

        receive do
          :arm -> send(parent, {:armed, GitGrant.arm(path, launcher)})
        end
      end)

    :erlang.trace(me, true, [:call])
    assert_receive {:prepared, {:ok, ^path}}, 5_000
    # Prepared is not armed: between the two, which a Port.open spans, there is no grant at all.
    assert [pending_name] = File.ls!(config.grant_dir)
    refute String.starts_with?(pending_name, GitGrant.prefix())
    send(me, :arm)
    assert_receive {:armed, {:ok, ^path}}, 5_000
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 5_000

    pending = Path.join(config.grant_dir, pending_name)
    # Both writes land on the pending name, never on the grant's.
    assert_received {:trace, ^me, :call, {File, :write, [^pending, _]}}
    assert_received {:trace, ^me, :call, {File, :write, [^pending, _]}}
    refute_received {:trace, ^me, :call, {File, :write, _}}
    assert_received {:trace, ^me, :call, {File, :rename, [^pending, ^path]}}
    refute_received {:trace, ^me, :call, {File, :rename, _}}

    assert GitGrant.holders(path) == {granted(owner!()), launcher}
    # Nothing but the grant is left in the directory.
    assert File.ls!(config.grant_dir) == [Path.basename(path)]
  end

  test "nothing is armed that was not prepared, and disarming takes a pending file too", ctx do
    config = %{config!(tmp_dir!("git-grant-unprepared")) | grant_dir: ctx.grants}
    path = GitGrant.path(config, "unprepared")
    launcher = Owner.of(String.to_integer(System.pid()), "utc:Sat Sep 12 15:34:27 2026")

    # No owner line to arm: a grant naming only its session would be one no sweep can judge.
    assert capture_log(fn -> assert {:error, :enoent} = GitGrant.arm(path, launcher) end) =~
             "could not arm the subagent git grant for session unprepared"

    assert File.ls!(ctx.grants) == []

    # A session that raised between the two steps: its teardown leaves nothing behind.
    assert {:ok, ^path} = GitGrant.prepare(config, "unprepared")
    assert [_pending] = File.ls!(ctx.grants)
    GitGrant.disarm(path)
    assert File.ls!(ctx.grants) == []
  end

  test "a config with no grant directory arms nothing, sweeps nothing and raises nowhere" do
    # `Config.load/1` always fills one in, but a Config built any other way can carry nil, and a
    # crash here would take the session — or the reap before every run — down with it.
    config = %{config!(tmp_dir!("git-grant-nil")) | grant_dir: nil}

    assert GitGrant.path(config, "none") == nil
    # Said out loud: the session goes ahead, and its agent's commit will be refused.
    assert capture_log(fn ->
             assert {:error, :no_grant_dir} = GitGrant.prepare(config, "none")
           end) =~ "the config names no grant_dir"

    assert GitGrant.sweep(nil) == []
    assert GitGrant.list(nil) == []
  end

  test "a sweep lists the directory once for the pending files and the grants alike", ctx do
    File.write!(Path.join(ctx.grants, ".loopctl-runner-pending-x"), "x")
    File.write!(Path.join(ctx.grants, GitGrant.prefix() <> "y"), "armed by hand\n")
    parent = self()

    sweeper =
      spawn(fn ->
        receive do
          :go -> send(parent, {:swept, GitGrant.sweep(ctx.grants)})
        end
      end)

    :erlang.trace_pattern({File, :ls, 1}, true, [:global])
    on_exit(fn -> :erlang.trace_pattern({File, :ls, 1}, false, [:global]) end)
    :erlang.trace(sweeper, true, [:call])
    send(sweeper, :go)

    assert_receive {:swept, []}, 5_000
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 5_000
    assert_received {:trace, ^sweeper, :call, {File, :ls, [_]}}
    refute_received {:trace, ^sweeper, :call, {File, :ls, _}}
  end

  test "a start is read back in either of Owner's forms, and no other parses", ctx do
    path = Path.join(ctx.grants, GitGrant.prefix() <> "forms")
    utc = Owner.of(41, "utc:Sat Sep 12 15:34:27 2026")
    boot = Owner.of(42, "boot:6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d:123456")
    File.write!(path, GitGrant.line("forms", utc, boot))
    assert GitGrant.holders(path) == {utc, boot}
    File.write!(path, GitGrant.line("forms", boot, utc))
    assert GitGrant.holders(path) == {boot, utc}

    # No runner ever wrote a grant with a date string: one that carries it names no owner here,
    # and is left for whoever wrote it.
    File.write!(path, GitGrant.line("forms", Owner.of(41, "Thu Jan 1 00:00:00 1970")))
    assert GitGrant.holders(path) == nil
    # Nor, now, epoch seconds: no start is computed from the clock any more.
    File.write!(path, GitGrant.line("forms", Owner.of(41, "1790000000")))
    assert GitGrant.holders(path) == nil
  end

  test "list/1 is every grant-named file in the directory, dotfiles included", ctx do
    grant = Path.join(ctx.grants, GitGrant.prefix() <> "x")
    File.write!(grant, "armed by hand\n")
    File.write!(Path.join(ctx.grants, "unrelated"), "")

    assert GitGrant.list(ctx.grants) == [grant]
    assert GitGrant.list(Path.join(ctx.grants, "missing")) == []
  end
end
