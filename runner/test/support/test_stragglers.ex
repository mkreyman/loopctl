defmodule LoopctlRunner.TestStragglers do
  @moduledoc false
  # Ending the suite's OWN detached processes when the suite ends, however it ends.
  #
  # test/support/bin/claude detaches processes on purpose: a setsid'd `sleep`, a child
  # holding the Port's stdout, a TERM-ignoring one. They are what prove ProcessGroup and
  # the Reaper reach a tree the kernel has already reparented to init. Nothing ended them
  # when a test failed partway, because the assertion that would have is the one that
  # never ran, and each survivor then held a pid slot until its `sleep` expired.
  #
  # Two discriminators, because neither covers both platforms alone:
  #
  #   * the LEDGER, the primary one: the fixture appends "pid start-time" for every
  #     process it detaches, at the moment it detaches it — the only moment the writer can
  #     know a start time that a later pid reuse cannot counterfeit. It is exactly the
  #     format the launcher's tree file uses, so `ProcessGroup.recorded/1` reads it
  #     unchanged, start-time check included. This is the only net on macOS, where `ps -E`
  #     cannot read an Apple binary's environment and every straggler here is one.
  #   * the MARKER, a second net for a straggler nothing recorded: `LOOPCTL_TEST_SUITE_ID`
  #     is set on this BEAM before ExUnit starts, so every process the suite spawns
  #     inherits it, and a `ps` that can read environments finds it. Linux only, in
  #     practice.
  #
  # Neither can match anything outside this run: the value is a fresh uuid, so a developer's
  # own `sleep`, a suite running in another worktree, and the live loopctl-runner service
  # are all invisible to it.

  alias LoopctlRunner.{ProcessGroup, Session}

  @marker_var "LOOPCTL_TEST_SUITE_ID"
  @probe_var "LOOPCTL_TEST_ENV_PS_PROBE"
  @ledger_var "LOOPCTL_TEST_STRAGGLERS"
  # Long enough for the fixture's TERM-ignoring child to reach the KILL, short enough that
  # a clean suite pays only the first poll.
  @grace_ms 2_000
  # The probe's budget is wall clock, not attempts, and its target outlives that budget by
  # an order of magnitude: see visible?/3.
  @probe_budget_ms 3_000
  @probe_life_s 30

  @doc "Sets the marker and the ledger path this BEAM's children will inherit."
  @spec arm() :: :ok
  def arm do
    id = Session.uuid4()
    System.put_env(@marker_var, id)
    System.put_env(@ledger_var, Path.join(LoopctlRunner.TestTmp.suite_dir(), "stragglers-#{id}"))
    :ok
  end

  @doc "The suite marker as `ProcessGroup.marked/1` matches it, or nil when nothing armed it."
  @spec marker() :: String.t() | nil
  def marker do
    case System.get_env(@marker_var) do
      nil -> nil
      id -> @marker_var <> "=" <> id
    end
  end

  @doc "The ledger path, or nil when nothing armed it."
  @spec ledger() :: String.t() | nil
  def ledger, do: System.get_env(@ledger_var)

  @doc """
  Whether this machine's `ps` prints another process's environment, which is all the marker
  half of the sweep is.

  Linux prints it. macOS refuses it for an Apple-signed binary, and every straggler here is
  one — a `sleep`, a `/bin/sh` — so there the ledger is the whole mechanism. Probed, never
  inferred from `:os.type/0`: the probe is the same shape the fixtures detach, so it answers
  for what the sweep will actually meet.
  """
  @spec env_ps?() :: boolean()
  def env_ps? do
    id = "probe-#{System.unique_integer([:positive])}"

    {out, 0} =
      System.cmd("/bin/sh", ["-c", "sleep #{@probe_life_s} >/dev/null 2>&1 & echo $!"],
        env: [{@probe_var, id}]
      )

    pid = String.to_integer(String.trim(out))
    deadline = System.monotonic_time(:millisecond) + @probe_budget_ms

    try do
      visible?(pid, @probe_var <> "=" <> id, deadline)
    after
      System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end
  end

  # A false answer here silently excludes three tests, so it has to mean "this `ps` will not
  # print another process's environment" and never "the probe outran its own target". Each
  # attempt is a full `ps` over every process, which on a loaded box costs hundreds of
  # milliseconds, so the budget is counted in WALL CLOCK and the target outlives it by an
  # order of magnitude. A target that is gone while the budget remains is a broken probe
  # rather than a verdict about the platform, and says so instead of answering.
  defp visible?(pid, marker, deadline) do
    cond do
      pid in ProcessGroup.marked(marker) ->
        true

      LoopctlRunner.TestSupport.utc_start_time(pid) == nil ->
        raise "env-ps probe target #{pid} died before any scan could see it"

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        visible?(pid, marker, deadline)
    end
  end

  @doc """
  Records `pid` in the ledger, for a straggler a test detached itself.

  The start time is read now, while the process is certainly the one meant: recorded after
  it has exited, a reused pid would match and the sweep would signal a stranger.
  """
  @spec note!(pos_integer(), String.t() | nil) :: :ok
  def note!(pid, ledger \\ ledger())
  def note!(_pid, nil), do: :ok

  def note!(pid, ledger) do
    start = LoopctlRunner.TestSupport.utc_start_time(pid)

    # A line with no start time is worse than no line: `recorded/1` compares the real start
    # against "" and drops it, so the process is invisible to the sweep for ever — and on
    # macOS the ledger is the whole mechanism. Every caller has just watched this pid become
    # a group leader, so an unreadable start time is an anomaly, and one that is said out
    # loud beats one recorded as a line that cannot match. What counts as unreadable is
    # `pinnable?/1`, the same test the sweep pins by: one definition, or the two ends of the
    # ledger disagree about which lines are worth writing.
    if pinnable?(start) do
      File.write!(ledger, "#{pid} #{start}\n", [:append])
    else
      raise "cannot record straggler #{pid}: no start time, so it is already gone"
    end
  end

  @doc """
  Lends the suite's marker and ledger to `fun`, and puts the suite's own back afterwards.

  `sweep_suite/1` reads its targets from the environment, so this is how a test reaches it
  without aiming it at the whole run's stragglers. The restore is in an `after`, because a
  test that fails here would otherwise leave the suite with no marker and no ledger, and
  the sweep at the end of the run would find nothing and say so cheerfully.
  """
  @spec borrowing(String.t(), String.t(), (-> result)) :: result when result: var
  def borrowing(marker_id, ledger, fun) do
    saved = {System.get_env(@marker_var), System.get_env(@ledger_var)}
    System.put_env(@marker_var, marker_id)
    System.put_env(@ledger_var, ledger)

    try do
      fun.()
    after
      restore(@marker_var, elem(saved, 0))
      restore(@ledger_var, elem(saved, 1))
    end
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  @doc """
  The `ExUnit.after_suite/1` callback: ends every straggler this run left behind, with the
  one grace period the suite is configured for.

  Runs on a failing suite and on one cut short by `--max-failures` — the runner calls its
  after_suite callbacks after the case loop returns, whatever the stats say. It does NOT
  run when the BEAM is killed outright (a second Ctrl-C), which is why the fixture's own
  sleeps stay bounded.

  Returns `sweep/3`'s result, which ExUnit ignores and a test does not: passing `@grace_ms`
  is this function's job, and a caller handing `sweep/3` a literal proves nothing about it.
  """
  @spec sweep_suite(map()) :: {ProcessGroup.outcome(), [pos_integer()], [String.t()]}
  def sweep_suite(_stats) do
    marker = marker()
    ledger = ledger()

    # Dropped BEFORE the scan, never after. `marked/1` finds processes by their
    # environment, and the `ps` and `kill` that the sweep itself spawns inherit this
    # BEAM's — so while the variable is set, every scan matches its own probe, a match
    # that can never clear, and terminate/3 would spend its whole grace before reporting
    # the suite's own `ps` as a survivor.
    System.delete_env(@marker_var)
    System.delete_env(@ledger_var)

    result = sweep(marker, ledger, @grace_ms)

    case result do
      {_outcome, [], _} ->
        :ok

      {outcome, pids, commands} ->
        # A straggler at suite end means a test never reached its teardown: say so, since
        # the suite otherwise ends green with no sign of it, and name each command — which
        # fixture leaked is the only question worth asking next.
        IO.puts(
          :stderr,
          "straggler sweep: #{length(pids)} process(es) outlived the suite, ended " <>
            "#{inspect(outcome)}\n" <> Enum.map_join(commands, "\n", &("  " <> &1))
        )
    end

    if ledger, do: File.rm(ledger)
    result
  end

  @doc """
  TERM, then KILL, every live process carrying `marker` or recorded in `ledger`.

  Returns `ProcessGroup.terminate/3`'s outcome, the pids that were still alive when the
  sweep started, and their command lines; `{:already_gone, [], []}` when there was nothing
  to end, which is what a suite whose tests all tore down reports — and what a run reports
  when EVERY candidate was unpinnable, since `pinned/2` drops those from the signalling and
  they must not be reported as swept either. One unpinnable candidate among pinnable ones
  collapses nothing: the result carries the real terminate outcome and the pids that were
  pinned, and the drop is visible only on `pinned/2`'s stderr line, never in what is
  returned here.

  The pids returned are the ones that were SIGNALLED: both lists here are built from
  `pinned/2`'s, so the report cannot name a process the tree file never carried.
  """
  @spec sweep(String.t() | nil, String.t() | nil, non_neg_integer()) ::
          {ProcessGroup.outcome(), [pos_integer()], [String.t()]}
  def sweep(marker, ledger, grace_ms) do
    entries = ProcessGroup.recorded_entries(ledger)
    candidates = Enum.uniq(escaped(marker) ++ Enum.map(entries, &elem(&1, 0)))

    case pinned(candidates, Map.new(entries)) do
      [] ->
        {:already_gone, [], []}

      pins ->
        pids = Enum.map(pins, &elem(&1, 0))

        # Read before the signal: a process that has been killed has no command line left
        # to name it by. ARGV IS DROPPED WHOLE — see `describe/1`.
        commands = Enum.map(pids, &"#{&1} #{describe(&1)}")

        {terminate_only(pins, grace_ms), pids, commands}
    end
  end

  # THE EXECUTABLE AND NOTHING ELSE. What this line is FOR is naming a straggler so a person can
  # tell what leaked — a `claude` from a `mix test` from a browser — and argv is not needed for
  # that. Argv IS where a credential rides: a triage session's carries the whole agents JSON and
  # that run's verdict token, in a place any `ps` can read.
  #
  # A LENGTH CAP WAS THE FIRST FIX AND IT LEAKED, which is why this one drops argv rather than
  # trimming it. `binary_part(command, 0, 120)` keeps the HEAD, and the head of
  # `sh -c "sleep 30" <token>` is the shell plus the first ~97 bytes OF THE TOKEN — a cut that is
  # structural AND POSITIONAL, and only the first property is the safe one. Nor is anything here
  # looking for something secret-shaped: a redactor that pattern-matches fails OPEN on a value
  # carrying a regex metacharacter and prints the credential in full with no error (KB cf9bc09a).
  #
  # The executable is `ps -o comm=`, asked for on its own, never the command line split at its
  # first space: an executable whose path has a space in it (`/Applications/Some App.app/...`) would
  # be cut there, and what followed the cut — the rest of the path AND the argv — counted as
  # dropped. The command line is read only to say how much was dropped, and nothing of it is kept.
  defp describe(pid) do
    case executable(pid) do
      nil -> "(already gone)"
      executable -> executable <> dropped(ProcessGroup.command(pid), executable)
    end
  end

  defp executable(pid) do
    case System.cmd("ps", ["-o", "comm=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          executable -> executable
        end

      _ ->
        nil
    end
  end

  # What follows the executable on the command line, counted and never shown. When the command
  # line does not begin with the executable as `ps` names it (argv[0] is the program's to set),
  # the whole of it is counted.
  defp dropped(nil, _executable), do: ""

  defp dropped(command, executable) do
    case command |> String.replace_prefix(executable, "") |> String.trim_leading() do
      "" -> ""
      argv -> " (+#{byte_size(argv)} bytes of argv dropped: an argv can carry a credential)"
    end
  end

  @doc """
  Pairs each candidate pid with the start time that will pin it in the tree file, and drops
  the ones that have none.

  The pin is the whole of what makes a tree file safe against pid reuse, so a pid without
  one cannot be signalled at all: written as a line with an empty start it matches nothing
  for ever, and signalled without a check it could reach a stranger. A dropped pid is named
  on stderr and left out of what is returned, so what `sweep/3` reports as swept is what it
  actually signalled — the sweep has just forked a `ps` per candidate for its command line,
  so a candidate dying inside that window is a real thing and not a theoretical one.

  For a pid the LEDGER recorded, the start time is the ledger's own, threaded through from
  `ProcessGroup.recorded_entries/1`: it was captured when the fixture detached the process
  and has just been verified against the live one. Re-reading it here would reopen the very
  window the ledger closes — the process exits after that verification, the pid is reused,
  and the stranger's start time is what gets written, matched and killed. Only a pid found
  by the MARKER, which carries no start time of its own, is read fresh.

  Both shapes of "no start time" are dropped: nil, and the "" that `start_time/1` answers
  when `ps` exits 0 with nothing to print. "" is truthy in Elixir, which is how it used to
  pass a nil-only guard and become the unmatchable line this drop exists to prevent.
  """
  @spec pinned([pos_integer()], %{optional(pos_integer()) => String.t()}) ::
          [{pos_integer(), String.t()}]
  def pinned(pids, recorded) do
    {pins, dropped} =
      pids
      |> Enum.map(&{&1, pin_start(&1, recorded)})
      |> Enum.split_with(fn {_pid, start} -> pinnable?(start) end)

    if dropped != [] do
      IO.puts(
        :stderr,
        "straggler sweep: no start time for " <>
          Enum.map_join(dropped, ", ", fn {pid, _} -> "#{pid}" end) <>
          " — not signalled, and not reported as swept"
      )
    end

    pins
  end

  # `ps` answers "" as well as nil — an exit 0 with nothing to print — and "" is truthy in
  # Elixir, which is how it used to pass a nil-only guard and become the line that can never
  # match. The shell twin in test/support/bin/claude guards the same two shapes with -z.
  # `start_time/1` folds stderr into stdout, so a `ps` warning can also arrive where a start
  # time belongs; that shape is not detectable here and fails the tree file's own match.
  defp pinnable?(start), do: start not in [nil, ""]

  defp pin_start(pid, recorded) do
    case Map.fetch(recorded, pid) do
      {:ok, start} -> start
      :error -> LoopctlRunner.TestSupport.utc_start_time(pid)
    end
  end

  # `terminate/3` re-derives its own members from the options it is handed, so handing it
  # `marker:` would hand straight back everything `escaped/1` has just removed: the
  # emulator's children would be TERMed and KILLed, unnamed in what this function returns,
  # and a slow one would burn the grace and flip the outcome to :killed — the misreport the
  # grace exists to prevent, arriving by the other door. `gone?/2` re-reads that set on
  # every poll, so filtering the candidate list upstream cannot fix it; the signalling has
  # to be given the filtered set itself.
  #
  # A TREE FILE is how `terminate/3` is told "these exact processes", in the launcher's own
  # "pid start-time" format, so a pid recycled between this write and the signal is still
  # checked and spared. Which gap that closes depends on where the start time came from,
  # and `pinned/2` is where it is decided: a LEDGER straggler carries the start its
  # recorder captured at detach time, so the scan-to-write gap is closed too; a MARKED one
  # has no earlier start to thread, so for it only the write-to-signal gap is closed and a
  # pid recycled before the write would be signalled. Nothing is lost by pinning the set:
  # at suite end nothing is being spawned any more.
  #
  # The name is a uuid because `System.unique_integer/1` is unique per NODE and the
  # sequences overlap heavily across BEAMs, while parallel worktrees are this fleet's
  # default. Two suites landing on one name is not a stray file but a wrong answer: the
  # second write truncates the first one's list, so the first signals the second's
  # stragglers, and its `File.rm` then empties the file under a sweep still polling, which
  # reads the empty set as :terminated for a process that never got the KILL. (A SIGKILLed
  # BEAM skips the `after` and leaves the file in the suite's root, which the next suite sweeps.)
  defp terminate_only(pins, grace_ms) do
    file = Path.join(LoopctlRunner.TestTmp.suite_dir(), "sweep-#{Session.uuid4()}")
    File.write!(file, Enum.map(pins, fn {pid, start} -> "#{pid} #{start}\n" end))

    try do
      ProcessGroup.terminate(nil, grace_ms, tree_file: file)
    after
      File.rm(file)
    end
  end

  # Marked processes that have left this BEAM's tree, which is the only kind that leaked.
  # The emulator's own children carry the marker too, having inherited its environment —
  # `inet_gethost`, and any Port a test still holds open — and they are not stragglers:
  # they end with the BEAM, or, for a session launcher, its watchdog ends the whole tree
  # when the Port's pipe closes. Measured on a GREEN suite, which left two `inet_gethost`
  # helpers and nothing else.
  defp escaped(marker) do
    own = MapSet.new(ProcessGroup.descendants(String.to_integer(System.pid())))
    Enum.reject(ProcessGroup.marked(marker), &MapSet.member?(own, &1))
  end
end
