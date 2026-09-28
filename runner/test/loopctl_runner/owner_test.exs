defmodule LoopctlRunner.OwnerTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Owner

  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  # A live os process that is not a BEAM, ended when the test is.
  defp live_sleep! do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:exit_status, args: ["60"]])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true) end)
    pid
  end

  # A pid no process holds: one that just exited.
  defp dead_pid do
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    String.to_integer(String.trim(out))
  end

  # A start in the form the OTHER kernel records, which this one cannot compare.
  defp other_form(_started) do
    case Owner.clock() do
      :utc -> "boot:6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d:123456"
      :boot -> "utc:Sat Sep 12 15:34:27 2026"
    end
  end

  test "this BEAM is its own live owner, its start in the form this kernel records" do
    assert {:ok, %{"beam_start_id" => started} = owner} = Owner.current()
    assert Owner.alive?(owner)

    case Owner.clock() do
      :utc -> assert started =~ ~r/\Autc:[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2} [\d:]{8} \d{4}\z/
      :boot -> assert started =~ ~r/\Aboot:[0-9a-f-]+:[0-9]+\z/
    end
  end

  test "two identities are one process's only on the same pid and exactly the same start" do
    utc = &Owner.of(7, "utc:Sat Sep 12 15:34:" <> &1)
    boot = &Owner.of(7, "boot:b1:" <> &1)

    assert Owner.same?(utc.("27 2026"), utc.("27 2026"))
    # One second apart is another process: the start is the kernel's record, not a measurement.
    refute Owner.same?(utc.("27 2026"), utc.("28 2026"))
    assert Owner.same?(boot.("500"), boot.("500"))
    refute Owner.same?(boot.("500"), boot.("501"))
    # The same ticks in another boot are another process: every pid is reused after a reboot.
    refute Owner.same?(boot.("500"), Owner.of(7, "boot:b2:500"))
    refute Owner.same?(utc.("27 2026"), boot.("500"))
    refute Owner.same?(utc.("27 2026"), %{utc.("27 2026") | "beam_os_pid" => 8})
    refute Owner.same?(Owner.of(7, nil), Owner.of(7, nil))

    # A grant line carries no `ps lstart`; the owner it is compared with carries both.
    assert Owner.same?(utc.("27 2026"), Owner.of(7, "utc:Sat Sep 12 15:34:27 2026", "Sat Sep 12"))

    # Master's form, as master compared it: padding is not a difference.
    assert Owner.same?(
             %{"beam_os_pid" => 7, "beam_started" => "Tue Sep  8 01:02:03 2026"},
             %{"beam_os_pid" => 7, "beam_started" => "Tue Sep 8 01:02:03 2026"}
           )
  end

  test "a /proc stat line gives its start ticks, counted past a command name holding ') '" do
    # Field 22. The command name is field 2, in parentheses, and may hold spaces and ")": counted
    # from the first ")", this line's field 22 would be a different number.
    stat =
      "4242 (beam.smp) x) (y) S 1 4242 4242 0 -1 4194560 12345 0 0 0 100 50 0 0 20 0 " <>
        "30 0 987654 2147483647 12345 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0\n"

    assert Owner.start_ticks(stat) == 987_654
    assert Owner.start_ticks("4242 (sh) S 1 2 3") == nil
    assert Owner.start_ticks("no parentheses at all") == nil
  end

  test "an owner whose pid is gone is not alive" do
    pid = dead_pid()
    %{"beam_start_id" => started} = owner!()
    refute Owner.alive?(Owner.of(pid, started))
    refute Owner.process_alive?(Owner.of(pid, nil))
  end

  test "a start this process never had is a reused pid, so not alive" do
    # The record keeps this process's true `ps lstart` string beside it: the start this runner
    # wrote is the one it judges by, and the legacy one is only for a record that has no other.
    %{"beam_start_id" => started} = owner = owner!()
    refute Owner.alive?(%{owner | "beam_start_id" => other_start(started)})
  end

  test "an owner recorded without a start is dead, even while its pid is held" do
    # A pid alone cannot tell the owner from whatever reused it, and a stale "alive" blocks that
    # story's runs indefinitely.
    refute Owner.alive?(%{owner!() | "beam_start_id" => nil, "beam_started" => nil})
  end

  @tag :tmp_dir
  test "a start in the other kernel's form cannot be judged: alive and warned, unless it is gone",
       %{tmp_dir: dir} do
    # Calling a live owner dead reaps its run, so what cannot be compared is kept, and said. A pid
    # that no longer exists is dead whatever form its start was recorded in. In a VM of its own:
    # the warning is said once per outage, and in this one a concurrent test may already have.
    with_ps(dir)
    %{"beam_os_pid" => pid, "beam_start_id" => started} = owner!()
    other = other_form(started)
    expr = "{#{alive_expr(pid, other)}, #{alive_expr(dead_pid(), other)}}"

    {out, 0} = owner_in_vm(dir, expr, logger: true)
    assert out =~ "{true,false}"
    assert out =~ "its start was recorded as"
  end

  test "a grant's session line recorded by pid alone is alive while that pid exists" do
    # A leaked grant is cheap; a live session's grant swept mid-run costs its subagent's commits.
    pid = live_sleep!()
    assert Owner.process_alive?(Owner.of(pid, nil))
    assert Owner.process_alive?(Owner.of(pid))
  end

  test "a run recorded with a ps lstart start is judged by that string's rule" do
    pid = String.to_integer(System.pid())
    lstart = Owner.start_time(pid)
    assert is_binary(lstart)
    # As master wrote it: `"beam_started"` and no `"beam_start_id"`.
    assert Owner.alive?(%{
             "beam_os_pid" => pid,
             "beam_started" => String.replace(lstart, " ", "  ")
           })

    refute Owner.alive?(%{"beam_os_pid" => pid, "beam_started" => "Thu Jan  1 00:00:00 1970"})
    assert Owner.normalize_start(" Tue Sep  8 01:02:03 2026\n") == "Tue Sep 8 01:02:03 2026"
  end

  test "no function raises for pid 0 or a negative pid; each is no such process" do
    for pid <- [0, -1, -12_345] do
      refute Owner.alive?(Owner.of(pid, other_form(nil)))
      refute Owner.alive?(Owner.of(pid, owner!()["beam_start_id"]))
      refute Owner.process_alive?(Owner.of(pid, nil))
      assert Owner.start_time(pid) == nil
      assert Owner.of(pid) == Owner.of(pid, nil)
    end
  end

  test "an identity read by pid is this BEAM's own, exactly" do
    %{"beam_os_pid" => pid, "beam_start_id" => started} = owner!()
    %{"beam_start_id" => read} = launcher = Owner.of(pid)
    assert read == started
    # The same one reading carries the `ps lstart` form ProcessGroup compares a leader by.
    assert Owner.lstart(launcher) == Owner.start_time(pid)
    assert Owner.of(dead_pid())["beam_start_id"] == nil
  end

  # `LoopctlRunner.Owner.alive?/1` as master shipped it, before `"beam_start_id"`: a runner built
  # from master is still reading what this one writes, and reaps whatever this says is dead.
  defp master_alive?(%{"beam_os_pid" => pid, "beam_started" => started})
       when is_integer(pid) and is_binary(started) do
    read =
      case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(pid)],
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end

    read == started
  end

  defp master_alive?(_), do: false

  test "a record written now is alive to a runner built before beam_start_id, and dead once gone" do
    # Through JSON, as a run's state and a lock are stored. Without the legacy string, master's
    # reap reads this BEAM's live run as an orphan and kills its session.
    {:ok, owner} = Owner.current()
    record = JSON.decode!(JSON.encode!(owner))

    assert master_alive?(record)
    assert Owner.alive?(record)
    refute master_alive?(%{record | "beam_os_pid" => dead_pid()})
  end

  test "a start_id in no form this module reads is judged by the legacy start beside it" do
    # A record from a build that stored another form: master's string still says who owns it.
    {:ok, %{"beam_started" => lstart} = owner} = Owner.current()
    assert Owner.alive?(%{owner | "beam_start_id" => 1_790_000_000})

    refute Owner.alive?(%{
             owner
             | "beam_start_id" => 1_790_000_000,
               "beam_started" => "x" <> lstart
           })

    refute Owner.alive?(%{owner | "beam_start_id" => 1_790_000_000, "beam_started" => nil})
  end

  test "judging an owner writes no persistent term, whatever it answers" do
    # Each write of one is a global GC pass, and the cannot-tell warning used to flip one per
    # outage: a start in the other kernel's form cannot tell, and this BEAM's own answers.
    owner = owner!()
    unjudgeable = %{owner | "beam_start_id" => other_form(owner["beam_start_id"])}
    parent = self()

    judge =
      spawn(fn ->
        receive do
          :go ->
            send(parent, {:judged, Enum.map([unjudgeable, owner, unjudgeable], &Owner.alive?/1)})
        end
      end)

    for mfa <- [{:persistent_term, :put, 2}, {:persistent_term, :erase, 1}],
        do: :erlang.trace_pattern(mfa, true, [:global])

    on_exit(fn ->
      for mfa <- [{:persistent_term, :put, 2}, {:persistent_term, :erase, 1}],
          do: :erlang.trace_pattern(mfa, false, [:global])
    end)

    :erlang.trace(judge, true, [:call])

    capture_log(fn ->
      send(judge, :go)
      assert_receive {:judged, [true, true, true]}, 5_000
    end)

    ref = :erlang.trace_delivered(judge)
    assert_receive {:trace_delivered, ^judge, ^ref}, 5_000

    # OTP's logger caches a module's level on that module's first log line, once for the BEAM's
    # life; that one is the logger's, not this module's.
    assert traced_writes(judge) |> Enum.reject(&match?([{:logger_config, Owner}, _], &1)) == []
  end

  defp traced_writes(pid) do
    receive do
      {:trace, ^pid, :call, {:persistent_term, _, args}} -> [args | traced_writes(pid)]
    after
      0 -> []
    end
  end

  # `ps` as `script`, alone on a PATH of its own.
  defp fake_ps!(dir, script) do
    File.mkdir_p!(dir)
    ps = Path.join(dir, "ps")
    File.write!(ps, "#!/bin/sh\n" <> script)
    File.chmod!(ps, 0o755)
    dir
  end

  @tag :tmp_dir
  test "only a ps that exits 1 saying nothing is a gone pid; one that says why cannot tell", %{
    tmp_dir: dir
  } do
    # A `ps` that failed is not an answer about the pid: read as "gone", it called a live owner
    # dead and reaped its run. A record master wrote is judged through `ps` on every kernel.
    said = fake_ps!(Path.join(dir, "said"), "echo 'ps: sysctl: resource busy' >&2\nexit 1\n")
    killed = fake_ps!(Path.join(dir, "killed"), "kill -9 $$\n")
    silent = fake_ps!(Path.join(dir, "silent"), "exit 1\n")

    legacy =
      "'Elixir.LoopctlRunner.Owner':'alive?'(\#{<<\"beam_os_pid\">> => #{dead_pid()}, " <>
        "<<\"beam_started\">> => <<\"Thu Jan  1 00:00:00 1970\">>})"

    expr =
      "{#{legacy}, #{putenv_path(killed)}, #{legacy}, #{putenv_path(silent)}, #{legacy}}"

    {out, 0} = owner_in_vm(said, expr, logger: true)

    assert out =~ "{true,true,true,true,false}"
    assert out =~ "`ps` exited 1: \"ps: sysctl: resource busy\""
  end

  describe "Linux, where a start is boot-relative" do
    @describetag clock: :boot

    test "this BEAM's start is its /proc stat ticks in this boot, and exactly that" do
      %{"beam_os_pid" => pid, "beam_start_id" => started} = owner = owner!()
      boot_id = String.trim(File.read!("/proc/sys/kernel/random/boot_id"))
      ticks = Owner.start_ticks(File.read!("/proc/#{pid}/stat"))
      assert started == "boot:#{boot_id}:#{ticks}"

      # Equal or not the owner: no tolerance, because nothing moves a boot-relative start.
      refute Owner.alive?(%{owner | "beam_start_id" => "boot:#{boot_id}:#{ticks + 1}"})
      refute Owner.alive?(%{owner | "beam_start_id" => "boot:0-previous-boot:#{ticks}"})
    end
  end

  # Owner resolves `ps` on the BEAM's own PATH, which only a VM started with another PATH can
  # change without disturbing every async test beside it. `dirname` and `basename` are the two
  # commands the `erl` launcher script itself needs. `logger: true` starts this application, as
  # every mix task and the daemon do — and with it Elixir's Logger, without which the VM's default
  # handler drops every log in the `:elixir` domain.
  defp owner_in_vm(dir, expr, opts \\ []) do
    for tool <- ~w(dirname basename),
        do: File.ln_s(System.find_executable(tool), Path.join(dir, tool))

    ebins =
      Enum.map([:elixir, :logger, :eex], &Path.join(:code.lib_dir(&1), "ebin")) ++
        Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    eval =
      if Keyword.get(opts, :logger, false),
        do:
          "{ok, _} = application:ensure_all_started(loopctl_runner), " <>
            "io:format(\"~p~n\", [catch #{expr}]), logger_std_h:filesync(default), halt().",
        else: "io:format(\"~p~n\", [catch #{expr}]), halt()."

    {out, status} =
      System.cmd(
        Path.join([:code.root_dir(), "bin", "erl"]),
        ["-noshell"] ++ Enum.flat_map(ebins, &["-pa", &1]) ++ ["-eval", eval],
        env: [{"PATH", dir} | Keyword.get(opts, :env, [])],
        stderr_to_stdout: true
      )

    {String.trim(out), status}
  end

  defp with_ps(dir) do
    File.mkdir_p!(dir)
    File.ln_s(System.find_executable("ps"), Path.join(dir, "ps"))
    dir
  end

  # Erlang source that points the child VM's PATH at `dir`.
  defp putenv_path(dir), do: ~s|os:putenv("PATH", "#{dir}")|

  # `Owner.alive?/1` on `pid` recorded with start `started`, as Erlang source.
  defp alive_expr(pid, started),
    do:
      "'Elixir.LoopctlRunner.Owner':'alive?'(\#{<<\"beam_os_pid\">> => #{pid}, " <>
        "<<\"beam_start_id\">> => <<\"#{started}\">>})"

  # A dead owner's record in this kernel's form, for a question only `ps` can answer.
  @dead_start "utc:Thu Jan 1 00:00:00 1970"

  describe "macOS, where a start is the one the kernel recorded, read through ps in UTC" do
    @describetag clock: :utc

    @tag :tmp_dir
    test "one process's start reads the same under every timezone and locale", %{tmp_dir: dir} do
      # The daemon runs under launchd, a `mix loopctl.reap` under a shell: two TZs, two locales,
      # judging one record. What `ps` prints moves with both, so the start is read under neither.
      with_ps(dir)
      %{"beam_os_pid" => pid, "beam_start_id" => started} = owner!()
      read = "maps:get(<<\"beam_start_id\">>, 'Elixir.LoopctlRunner.Owner':'of'(#{pid}))"

      for env <- [
            [{"TZ", "Pacific/Chatham"}],
            [{"TZ", "UTC"}],
            [{"TZ", "America/Anchorage"}, {"LC_ALL", "fr_FR.UTF-8"}]
          ] do
        {out, 0} = owner_in_vm(dir, "{#{read}, #{alive_expr(pid, started)}}", env: env)
        assert out == ~s|{<<"#{started}">>,true}|, "read under #{inspect(env)}"
      end
    end

    test "a start one second away is another process: the comparison is exact" do
      # Nothing about a reading moves the start it gives, so no tolerance hides a reused pid whose
      # process began within one.
      %{"beam_start_id" => "utc:" <> lstart} = owner = owner!()
      [_, head, secs, year] = Regex.run(~r/\A(.*:)(\d{2}) (\d{4})\z/, lstart)

      other =
        if secs == "59",
          do: "58",
          else: String.pad_leading("#{String.to_integer(secs) + 1}", 2, "0")

      refute Owner.alive?(%{owner | "beam_start_id" => "utc:#{head}#{other} #{year}"})
      assert Owner.alive?(%{owner | "beam_start_id" => "utc:#{head}#{secs} #{year}"})
    end

    @tag :tmp_dir
    test "with no ps nothing raises, an owner is alive, and this BEAM records no start until ps" <>
           " answers",
         %{tmp_dir: dir} do
      # Cannot tell is alive: calling a live owner dead reaps its run. But this BEAM's OWN start is
      # never guessed: a record written without it, or with a stand-in, reads dead to every
      # check. The failure is not kept, so the first call after ps returns records the real one.
      assert {"true", 0} = owner_in_vm(dir, alive_expr(dead_pid(), @dead_start))

      ps_dir = with_ps(Path.join(dir, "with-ps"))

      {out, 0} =
        owner_in_vm(
          dir,
          "{'Elixir.LoopctlRunner.Owner':current(), #{putenv_path(ps_dir)}, " <>
            "'Elixir.LoopctlRunner.Owner':current()}"
        )

      assert out =~ ~r/\A\{\{error,no_start\},\s*true,\s*\{ok,/
      assert out =~ ~r/<<"beam_start_id">> => <<"utc:/
      assert out =~ ~r/<<"beam_started">> => <<"/
    end

    @tag :tmp_dir
    test "a ps that prints something that is not a start cannot tell, and records none", %{
      tmp_dir: dir
    } do
      # Compared exactly, a row that is not a start would call every live owner dead.
      fake_ps!(dir, "echo 'not a start'\n")

      assert {out, 0} =
               owner_in_vm(
                 dir,
                 "{#{alive_expr(dead_pid(), @dead_start)}, 'Elixir.LoopctlRunner.Owner':current()}",
                 logger: true
               )

      assert out =~ "{true,{error,no_start}}"
      assert out =~ ~s|`ps -o lstart=` printed "not a start\\n"|
    end

    @tag :tmp_dir
    test "cannot-tell is said once per outage, naming what failed", %{tmp_dir: dir} do
      # Twice in one outage is one warning; a ps that answers ends the outage, so the next one is
      # said too — a stuck state that recurs is seen each time it does.
      ps_dir = with_ps(Path.join(dir, "with-ps"))
      no_ps = alive_expr(dead_pid(), @dead_start)

      expr =
        "{#{no_ps}, #{no_ps}, #{putenv_path(ps_dir)}, #{alive_expr(dead_pid(), @dead_start)}, " <>
          "#{putenv_path(dir)}, #{no_ps}, #{no_ps}}"

      {out, 0} = owner_in_vm(dir, expr, logger: true)

      assert out =~ "{true,true,true,false,true,true,true}"
      assert length(String.split(out, "cannot tell whether os pid")) == 3
      assert out =~ "`ps` could not be run"
    end

    @tag :tmp_dir
    test "a ps that ran and exited non-zero is a dead owner, and spends no warning", %{
      tmp_dir: dir
    } do
      # The pid is gone: that is an answer, not a cannot-tell. Once PATH loses `ps`, the one
      # warning this outage gives is still there to be said.
      with_ps(dir)

      expr =
        ~s|{#{alive_expr(dead_pid(), @dead_start)}, os:putenv("PATH", "/nonexistent"), | <>
          "#{alive_expr(dead_pid(), @dead_start)}}"

      {out, 0} = owner_in_vm(dir, expr, logger: true)

      assert out =~ "{false,true,true}"
      assert length(String.split(out, "cannot tell whether os pid")) == 2
    end

    @tag :tmp_dir
    test "judging an owner costs one ps, alive or dead, and none for a pid below 1", %{
      tmp_dir: dir
    } do
      # Every run, lock and grant sweep asks; one `ps` answers existence and start together. A pid
      # below 1 names no process, and `ps -p 0` or `-p -1` is not asked what that means.
      count = Path.join(dir, "count")
      ps = Path.join(dir, "ps")

      File.write!(
        ps,
        "#!/bin/sh\necho x >> '#{count}'\nexec '#{System.find_executable("ps")}' \"$@\"\n"
      )

      File.chmod!(ps, 0o755)
      File.ln_s(System.find_executable("sh"), Path.join(dir, "sh"))
      %{"beam_os_pid" => pid, "beam_start_id" => started} = owner!()

      expr =
        "{#{alive_expr(pid, started)}, #{alive_expr(dead_pid(), started)}, " <>
          "#{alive_expr(0, started)}, #{alive_expr(-1, started)}}"

      assert {"{true,false,false,false}", 0} = owner_in_vm(dir, expr)

      assert File.read!(count) == "x\nx\n"
    end
  end
end
