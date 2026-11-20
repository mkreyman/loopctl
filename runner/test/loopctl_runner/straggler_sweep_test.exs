defmodule LoopctlRunner.StragglerSweepTest do
  # Spawns real detached processes and signals them by discriminator, so it must not run
  # beside another test doing the same.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{ProcessGroup, TestStragglers}
  import ExUnit.CaptureIO
  import LoopctlRunner.TestSupport

  @moduletag timeout: 60_000

  @probe_var "LOOPCTL_TEST_SWEEP_PROBE"

  setup do
    probe = "sweep-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"

    {:ok,
     ledger: Path.join(tmp_dir!("sweep"), "stragglers"),
     probe: probe,
     marker: @probe_var <> "=" <> probe}
  end

  # A setsid'd process reparented to init, the shape every fixture straggler has: neither a
  # group signal nor a parent walk reaches it. Its cleanup is armed in the same breath as
  # its spawn — a test ABOUT leaked processes is the last place allowed to leak one — and
  # it is recorded in the suite's own ledger too, so the sweep at the end catches whatever
  # a half-run of this file leaves behind.
  defp straggler!(opts) do
    env = if opts[:marked], do: [{@probe_var, opts[:marked]}], else: []

    # Three shapes: dies on TERM at once, ignores TERM, or takes 600ms to shut down. The
    # last one stays perl rather than exec'ing `sleep`, because an exec resets a handler
    # while it preserves an ignore — which is the same asymmetry the stubborn fixture
    # relies on.
    body =
      cond do
        opts[:stubborn] ->
          ~S|$SIG{TERM} = "IGNORE"; POSIX::setsid(); exec "sleep", "300"|

        opts[:slow_term] ->
          ~S|$SIG{TERM} = sub { select(undef, undef, undef, 0.6); exit 0 }; POSIX::setsid(); sleep 300|

        true ->
          ~S|POSIX::setsid(); exec "sleep", "300"|
      end

    {out, 0} =
      System.cmd("/bin/sh", ["-c", ~s|perl -MPOSIX -e '#{body}' >/dev/null 2>&1 & echo $!|],
        env: env
      )

    pid = String.to_integer(String.trim(out))
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true) end)
    TestStragglers.note!(pid)
    :ok = wait_until(fn -> ProcessGroup.leader?(pid) end)
    pid
  end

  # The tree files this sweep wrote in the suite's own directory, told by the pid their lines
  # name: a tree file is exactly "pid start-time" lines.
  defp sweep_tree_files_naming(pid) do
    LoopctlRunner.TestTmp.suite_dir()
    |> Path.join("sweep-*")
    |> Path.wildcard()
    |> Enum.filter(&names?(&1, pid))
  end

  defp names?(path, pid) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.any?(&(hd(String.split(&1, " ")) == Integer.to_string(pid)))

      # Removed between the glob and the read, by the `after` of the sweep that wrote it.
      {:error, _reason} ->
        false
    end
  end

  @tag :env_ps
  test "the marker ends this run's straggler and nobody else's", ctx do
    marked = straggler!(marked: ctx.probe)
    # The same suite running in another worktree: it carries the same variable, a different
    # id, and an id this one is a prefix of — matched by anything short of a whole entry.
    other_run = straggler!(marked: ctx.probe <> "-other")
    # And what carries no marker at all: the developer's own sleep, the runner service.
    bystander = straggler!([])

    assert {:terminated, [^marked], _} = TestStragglers.sweep(ctx.marker, ctx.ledger, 2_000)
    refute os_pid_alive?(marked)
    assert os_pid_alive?(other_run)
    assert os_pid_alive?(bystander)
  end

  @tag :env_ps
  test "a marked process inside this BEAM's tree survives a sweep that ends a real straggler",
       ctx do
    # What a green suite really leaves marked: the emulator's own helpers, and any Port a
    # test still holds. They end with the BEAM and are nobody's leak.
    #
    # THE STRAGGLER IS THE POINT OF THIS TEST. With only the in-tree child, the candidate
    # list comes back empty and the sweep short-circuits, so terminate/3 is never called
    # and the child survives whatever the guard does — which is how a guard applied to the
    # report and not to the signalling passed for a fix. A live straggler forces the
    # signalling to run, and then sparing the child is a property of the code rather than
    # of a path not taken.
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: ["-c", "exec sleep 300"],
        env: [{~c"#{@probe_var}", to_charlist(ctx.probe)}]
      ])

    {:os_pid, child} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{child}"], stderr_to_stdout: true) end)
    :ok = wait_until(fn -> child in ProcessGroup.marked(ctx.marker) end)
    straggler = straggler!(marked: ctx.probe)

    assert {:terminated, [^straggler], _} = TestStragglers.sweep(ctx.marker, ctx.ledger, 2_000)
    refute os_pid_alive?(straggler)
    assert os_pid_alive?(child)
  end

  test "a straggler the ledger recorded is swept even inside this BEAM's tree", ctx do
    # The other half of the asymmetry: being a descendant spares a MARKED process, because
    # the marker catches the emulator's own helpers by accident. It spares nothing in the
    # ledger, where every entry was written deliberately, by a fixture, about a process it
    # had just detached on purpose.
    port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "exec sleep 300"]])
    {:os_pid, child} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{child}"], stderr_to_stdout: true) end)
    TestStragglers.note!(child, ctx.ledger)

    assert {:terminated, [^child], _} = TestStragglers.sweep(nil, ctx.ledger, 2_000)
    refute os_pid_alive?(child)
  end

  test "the ledger ends a straggler whose environment no ps can read", ctx do
    # macOS in miniature: `ps -E` cannot read an Apple binary's environment, so a `sleep`
    # carries no marker there and only the ledger finds it.
    recorded = straggler!([])
    TestStragglers.note!(recorded, ctx.ledger)

    # A ledger line whose start time no longer matches is a pid the kernel has since
    # handed to someone else. It is never signalled.
    stranger = straggler!([])
    File.write!(ctx.ledger, "#{stranger} Thu Jan 1 00:00:00 1970\n", [:append])

    assert {:terminated, [^recorded], _} = TestStragglers.sweep(ctx.marker, ctx.ledger, 2_000)
    refute os_pid_alive?(recorded)
    assert os_pid_alive?(stranger)
  end

  test "a straggler that ignores TERM is killed", ctx do
    # Swept by the ledger alone, not the marker: the escalation is the half of this that
    # has to hold on macOS too, where no `ps` can read this process's environment.
    stubborn = straggler!(stubborn: true)
    TestStragglers.note!(stubborn, ctx.ledger)

    assert {:killed, [^stubborn], _} = TestStragglers.sweep(nil, ctx.ledger, 2_000)
    refute os_pid_alive?(stubborn)
  end

  test "the suite's own sweep gives a shutting-down straggler the grace, not a kill", ctx do
    # THE ONLY STRAGGLER IN THIS SUITE THAT OCCUPIES THE MIDDLE OF TERM -> grace -> KILL,
    # which is why it exists and why it is not redundant with the TERM-ignoring one: that
    # one proves the escalation, this one proves the WAIT before it. No fixture in
    # test/support/bin/claude has this shape — measured, five of the six die within
    # single-digit milliseconds of a TERM and the sixth ignores it outright — so without
    # this nothing can tell whether the grace exists at all. What it stands in for is what
    # a half-run really leaves behind: a session launcher and its tree, and on a dev
    # machine a real CLI, none of which exits instantly.
    #
    # It goes through sweep_suite/1, never sweep/3, and that is the point: sweep/3 handed a
    # literal grace proves only that it honours what a caller passes, while @grace_ms — the
    # value the suite actually sweeps with — stays unread by any test, free to be set to
    # zero for speed with everything still green. The assertion is on WHICH SIGNAL ended
    # it, never on its being gone, which is true either way: :terminated is the TERM taking
    # effect inside the grace, :killed is the escalation firing on something that needed no
    # killing.
    shutting_down = straggler!(slow_term: true)
    TestStragglers.note!(shutting_down, ctx.ledger)

    # Lent the test's own targets, and given them back in an after: the suite's real marker
    # and ledger have to survive this test failing.
    report =
      capture_io(:stderr, fn ->
        Process.put(
          :sweep,
          TestStragglers.borrowing(ctx.probe, ctx.ledger, fn ->
            TestStragglers.sweep_suite(%{})
          end)
        )
      end)

    assert {:terminated, [^shutting_down], _} = Process.get(:sweep)
    refute os_pid_alive?(shutting_down)
    assert report =~ "ended :terminated"
    assert report =~ "#{shutting_down}"

    # Given back, or the end-of-run sweep has nothing left to sweep with.
    assert TestStragglers.marker() =~ ~r/^LOOPCTL_TEST_SUITE_ID=[0-9a-f-]{36}$/
    assert TestStragglers.ledger()
  end

  test "the fake CLI records what it detaches, and the sweep ends it", ctx do
    state = tmp_dir!("sweep-fixture")

    {_out, 0} =
      System.cmd(Path.join(fake_bin_dir(), "claude"), ["-p", "x"],
        env: [
          {"FAKE_STATE_DIR", state},
          {"FAKE_CLAUDE_MODE", "exit_leaving_stubborn_child"},
          {"LOOPCTL_TEST_STRAGGLERS", ctx.ledger}
        ],
        stderr_to_stdout: true
      )

    stubborn = read_int!(Path.join(state, "stubborn_pid"))
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{stubborn}"], stderr_to_stdout: true) end)

    assert ProcessGroup.recorded(ctx.ledger) == [stubborn]
    assert {:killed, [^stubborn], [command]} = TestStragglers.sweep(nil, ctx.ledger, 2_000)
    # The EXECUTABLE names it; its argv ("1002") is dropped with everything else, because argv is
    # where a credential rides. See the argv test below.
    assert command =~ "sleep"
    refute os_pid_alive?(stubborn)
  end

  test "argv is dropped WHOLE, because an argv can carry a credential", ctx do
    # The sweep reads `ps` to NAME a straggler, and for a triage session that command line is the
    # whole agents JSON plus the run's verdict token — a credential, in argv, printed into a test
    # report.
    #
    # THE FIRST VERSION OF THIS TEST PASSED WHILE LEAKING, and the assertions below are shaped by
    # that. A 120-byte head-cut kept ~97 bytes of the token, and `refute command =~ secret`
    # compared the WHOLE 404-byte value, which a 97-byte prefix does not match — green, leaking.
    # So: the value is RANDOM rather than a run of one character (a repeated character makes every
    # window of it identical and a window check meaningless), and no window of it may survive.
    secret = "tok_" <> Base.encode32(:crypto.strong_rand_bytes(60), padding: false)

    {:ok, pid} =
      Task.start(fn ->
        # The secret rides as an extra ARGV entry, which is what `ps` reads and what a real
        # verdict token does today; `sh -c` keeps it there without interpreting it. The trailing
        # `; :` keeps `sh` itself alive: macOS's sh is bash, which EXECs a lone command, so
        # `sh -c "sleep 30"` becomes `sleep 30` and the secret leaves argv before `pgrep` looks.
        {_out, _} = System.cmd("sh", ["-c", "sleep 30; :", secret], stderr_to_stdout: true)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    os_pid =
      wait_for_pid(fn ->
        {out, _} = System.cmd("pgrep", ["-f", secret], stderr_to_stdout: true)
        out |> String.split("\n", trim: true) |> List.first()
      end)

    start = LoopctlRunner.TestSupport.utc_start_time(os_pid)
    File.write!(ctx.ledger, "#{os_pid} #{start}\n")

    assert {_outcome, [^os_pid], [command]} = TestStragglers.sweep(nil, ctx.ledger, 2_000)
    # Named well enough to act on: the pid and the executable.
    assert command =~ "#{os_pid} "
    assert command =~ "sh"

    # NOTHING of the argv survives — not the whole value, and not any window of it. A prefix is
    # what the head-cut leaked, so a whole-value refutation is the assertion that could not fail.
    refute command =~ secret

    for window <- secret |> String.graphemes() |> Enum.chunk_every(8, 1, :discard) do
      refute String.contains?(command, Enum.join(window)),
             "a window of the argv survived into the straggler report"
    end

    # ...and the drop is SAID, or a reader cannot tell a short command line from a cut one.
    assert command =~ "bytes of argv dropped"
  end

  test "an executable whose path has a space is named whole, and its argv is still dropped",
       ctx do
    # The executable used to be the command line up to its first space, so `/tmp/a b/my sh -c ...`
    # was named `/tmp/a` and the rest of its own path was counted as argv. A symlink to sh stands
    # in for an app bundle's binary: macOS kills a copied system binary at exec, and `ps` names a
    # symlinked one by the path it was run as.
    dir = Path.join(tmp_dir!("sweep space"), "with space")
    File.mkdir_p!(dir)
    shell = Path.join(dir, "my sh")
    File.ln_s!("/bin/sh", shell)
    secret = "tok_" <> Base.encode32(:crypto.strong_rand_bytes(20), padding: false)

    {:ok, pid} =
      Task.start(fn ->
        {_out, _} = System.cmd(shell, ["-c", "sleep 30; :", secret], stderr_to_stdout: true)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    os_pid =
      wait_for_pid(fn ->
        {out, _} = System.cmd("pgrep", ["-f", secret], stderr_to_stdout: true)
        out |> String.split("\n", trim: true) |> List.first()
      end)

    File.write!(ctx.ledger, "#{os_pid} #{LoopctlRunner.TestSupport.utc_start_time(os_pid)}\n")

    assert {_outcome, [^os_pid], [command]} = TestStragglers.sweep(nil, ctx.ledger, 2_000)
    # Whole on macOS (`comm` is the path), the basename on Linux (`comm` is the name): either way
    # the part after the space survives, which the first-space split cut off.
    assert command =~ "my sh"
    refute command =~ secret
    refute command =~ "sleep 30"
    assert command =~ "bytes of argv dropped"
  end

  defp wait_for_pid(fun) do
    :ok = wait_until(fn -> is_binary(fun.()) end, 5_000)
    fun.() |> String.trim() |> String.to_integer()
  end

  test "nothing to sweep is not an error", ctx do
    assert TestStragglers.sweep(ctx.marker, ctx.ledger, 2_000) == {:already_gone, [], []}
    assert TestStragglers.sweep(nil, nil, 2_000) == {:already_gone, [], []}
  end

  test "the suite armed the sweep and registered it with ExUnit" do
    assert TestStragglers.marker() =~ ~r/^LOOPCTL_TEST_SUITE_ID=[0-9a-f-]{36}$/
    assert TestStragglers.ledger()

    assert Enum.any?(
             Application.fetch_env!(:ex_unit, :after_suite),
             &(Function.info(&1, :module) == {:module, TestStragglers})
           )
  end

  test "the env-ps decision this run was configured with is the probe's, and on Linux it is yes" do
    # Reads the decision the helper RECORDED, never a fresh probe: a probe that answers
    # false excludes the three tagged tests, and a canary that re-probes would get its own
    # second opinion, pass, and leave the exclusion in place unremarked — the silent skip
    # this canary exists to catch.
    decision = Application.fetch_env!(:loopctl_runner, :env_ps)

    # On Linux the answer is known independently of any probe: every process's environment
    # is served out of /proc. On macOS the probe is the only evidence there is.
    if :os.type() == {:unix, :linux}, do: assert(decision)

    # And the exclusion is what followed from it, which is the fact that decides whether
    # the tagged tests ran at all.
    if decision == false, do: assert(:env_ps in ExUnit.configuration()[:exclude])
  end

  test "a straggler with no start time is refused, never recorded as a line that cannot match" do
    # `recorded/1` compares a real start time against "" and drops the line, so a pid
    # recorded without one is invisible to the sweep for ever — and on macOS the ledger is
    # the whole mechanism. A pid that is already gone is exactly that case.
    {out, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    gone = String.to_integer(String.trim(out))
    ledger = Path.join(tmp_dir!("no-start"), "stragglers")

    assert_raise RuntimeError, ~r/no start time/, fn -> TestStragglers.note!(gone, ledger) end
    refute File.exists?(ledger)
  end

  test "a candidate with no start time is neither signalled nor reported as swept" do
    # `sweep/3` builds what it signals and what it reports out of ONE list, so a pid it
    # cannot pin leaves both. Kept in the report, it would tell the caller a process was
    # ended that was never signalled — and the window is real rather than theoretical: the
    # sweep forks a `ps` per candidate for its command line before it writes a line.
    {out, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    gone = String.to_integer(String.trim(out))
    live = straggler!([])

    report =
      capture_io(:stderr, fn ->
        Process.put(:pins, TestStragglers.pinned([gone, live], %{}))
      end)

    assert Process.get(:pins) == [{live, LoopctlRunner.TestSupport.utc_start_time(live)}]
    assert report =~ "no start time for #{gone}"
  end

  test "an empty start time is dropped, never pinned as a line that cannot match" do
    # The other shape of "no start time", and the one a nil guard lets through: `ps` exits
    # 0 with nothing to print, `start_time/1` squeezes that to "", and "" is truthy in
    # Elixir. Pinned, it writes "1234 " and `recorded/1` compares a real start against ""
    # and drops it — the straggler is invisible to the sweep for ever, which on macOS is
    # the whole mechanism. The shell twin guards the same shape with [ -z "$start" ].
    live = straggler!([])

    report =
      capture_io(:stderr, fn ->
        Process.put(:pins, TestStragglers.pinned([live], %{live => ""}))
      end)

    assert Process.get(:pins) == []
    assert report =~ "no start time for #{live}"
  end

  test "a recorded straggler is pinned by the ledger's start time, not a fresh read", ctx do
    # The ledger's line was written when the fixture detached the process — the only moment
    # a writer knows a start time a later pid reuse cannot counterfeit. Re-read here
    # instead, a straggler that exits just after the ledger scan verified it, and whose pid
    # is reused before the write, puts the STRANGER's start time in the tree file, where it
    # matches and the stranger is TERMed and KILLed.
    live = straggler!([])
    TestStragglers.note!(live, ctx.ledger)
    ledger_start = "Thu Jan 1 00:00:00 1970"

    refute LoopctlRunner.TestSupport.utc_start_time(live) == ledger_start
    assert TestStragglers.pinned([live], %{live => ledger_start}) == [{live, ledger_start}]

    # And that is the value the sweep threads through: the entry carries the file's own
    # start time, not one read after the scan.
    assert ProcessGroup.recorded_entries(ctx.ledger) == [
             {live, LoopctlRunner.TestSupport.utc_start_time(live)}
           ]
  end

  test "the sweep's tree file is written in the suite's own directory and removed after", ctx do
    # Observed WHILE a sweep runs, since the file exists only between the write and the
    # `after` that removes it. The straggler ignores TERM, so that window is the whole
    # grace and then some, never a race with the poller.
    stubborn = straggler!(stubborn: true)
    TestStragglers.note!(stubborn, ctx.ledger)

    task = Task.async(fn -> TestStragglers.sweep(nil, ctx.ledger, 2_000) end)

    :ok = wait_until(fn -> sweep_tree_files_naming(stubborn) != [] end)
    ours = sweep_tree_files_naming(stubborn)

    assert ours != []
    assert Enum.all?(ours, &(Path.basename(&1) =~ ~r/^sweep-[0-9a-f-]{36}$/))
    assert {:killed, [^stubborn], _} = Task.await(task, 30_000)
    assert sweep_tree_files_naming(stubborn) == []
  end

  test "a start time ps prints as empty is refused, not recorded as an unmatchable line" do
    # The "" half of the guard, which nothing on this machine produces by itself: `ps` here
    # always prints an lstart for a live pid. So `ps` is replaced for the length of one call
    # by one that exits 0 with nothing to say, which `TestSupport.utc_start_time/2` reads as nil. Read as
    # "", it is truthy: it would pass a nil-only guard and become the ledger line `recorded/1`
    # compares against a real start time and drops for ever. Safe because this
    # file is async: false and the swap spans a single call; every `ps` the fixtures need
    # has already run.
    live = straggler!([])
    ledger = Path.join(tmp_dir!("empty-start"), "stragglers")
    fake = Path.join(tmp_dir!("empty-ps"), "ps")
    File.write!(fake, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake, 0o755)

    previous = System.get_env("PATH")

    # Armed BEFORE the swap, never after. An exit landing between the two — an ExUnit
    # timeout, a linked exit — would leave the fake `ps` on PATH for every remaining sync
    # module, where `start_time/1` answers nil for every live pid, `pinnable?/1` drops every
    # candidate, and the ledger half of the sweep disarms itself for the rest of the run
    # with every test still reporting green.
    on_exit(fn -> System.put_env("PATH", previous) end)
    System.put_env("PATH", Path.dirname(fake) <> ":" <> previous)

    assert LoopctlRunner.TestSupport.utc_start_time(live) == nil
    assert_raise RuntimeError, ~r/no start time/, fn -> TestStragglers.note!(live, ledger) end

    System.put_env("PATH", previous)
    refute File.exists?(ledger)
  end

  @tag :env_ps
  test "a marker this BEAM carries matches the sweep's own ps" do
    # Why sweep_suite/1 deletes the variable before it scans: every `ps` and `kill` the
    # sweep spawns inherits this environment, so a marker still set here matches a probe
    # of the sweep's own making — a match that can never clear, which would spend the
    # whole grace and then report the suite's own tooling as a survivor.
    id = "selfmatch-#{System.unique_integer([:positive])}"
    System.put_env(@probe_var, id)
    on_exit(fn -> System.delete_env(@probe_var) end)

    assert ProcessGroup.marked(@probe_var <> "=" <> id) != []

    System.delete_env(@probe_var)
    assert ProcessGroup.marked(@probe_var <> "=" <> id) == []
  end
end
