defmodule LoopctlRunner.Owner do
  @moduledoc """
  The identity of the BEAM that recorded a run or holds a lock, or of a process a grant names.

  A pid alone is not an identity: once a runner dies its pid is reused, and on a dev
  machine the next BEAM (a dev server, elixir-ls, a test run) is a likely taker. A stale
  "owner alive" answer is not harmless — it blocks every later run of that story. So an
  owner is the os pid AND that process's start, which a reused pid cannot match.

  THE START IS A VALUE THE KERNEL RECORDED AT FORK, never one computed from the clock now, so two
  readings of one process are EQUAL and are compared exactly. How it is read depends on the
  kernel, and a record says which by the start's own form:

    * **Linux: `"boot:<boot id>:<ticks>"`** — field 22 of `/proc/<pid>/stat`, the process's start
      in clock ticks since boot, with the boot those ticks count from
      (`/proc/sys/kernel/random/boot_id`). Neither moves when the wall clock is stepped, and a
      reused pid — or any pid after a reboot — does not match. procps `lstart` is NOT usable
      there: procps derives it from the wall clock now minus the uptime, so an NTP step moves it.
    * **macOS: `"utc:<lstart>"`** — `ps -o lstart=` read under `TZ=UTC` and `LC_ALL=C`,
      whitespace-normalised. BSD ps prints the kernel's `p_starttime`, the absolute time the
      process started, so the reading does not move with how long `ps` took, with a clock step
      after the start, or with the reader's timezone or locale — both of which change the printed
      string, and the daemon (launchd) and `mix loopctl.reap` (a shell) run under different ones.

  A start of one form judged on a kernel that reads the other cannot be compared: that is "cannot
  tell", which answers alive (see `alive?/1`). A pid that no longer exists is dead either way.

  THE LEGACY KEY IS STILL WRITTEN, because a runner built before this module read these forms is
  still reading what this one writes. The start above is `"beam_start_id"`. `"beam_started"`
  keeps the `ps -o lstart=` string master stored there — read in the reader's own timezone and
  locale, trimmed and nothing else — because master compares it byte for byte: a record without
  it is one an older runner's reap judges dead, and it kills that run's session. A record is
  judged by `"beam_start_id"` when it carries one in a form above and by `"beam_started"` when it
  does not — a record written by master, compared by the rule it was written under.
  A session's tree files record each process by `start_id/1`'s form on Linux and by
  `start_time/1`'s `"utc:"` form on macOS, which the session launcher's shell reads from a `ps`
  snapshot (`utc_starts/0`).
  """

  require Logger

  @type t :: %{required(String.t()) => term()}

  @current_key {__MODULE__, :current}
  @boot_id_key {__MODULE__, :boot_id}
  @outage_key {__MODULE__, :outage}

  # The environment the `utc:` start is read under. `LC_ALL` outranks `LANG` and `LC_TIME`, each
  # of which changes the day and month names `ps` prints.
  @utc_env [{"TZ", "UTC"}, {"LC_ALL", "C"}]
  # What `ps -o lstart=` prints under `@utc_env`, normalised: "Sat Sep 12 15:34:27 2026".
  @lstart_shape ~r/\A[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2} \d{4}\z/

  @doc """
  This BEAM's identity — its os pid and start — or `{:error, :no_start}` when the start cannot be
  read.

  Kept for the BEAM's life once read: the start is the kernel's record of the fork, which cannot
  change, so every run, lock and grant this BEAM records carries the same value.

  Nothing stands in for a reading that failed: a record written without a start is dead by design
  (`alive?/1`), and the next run's reap would kill the session it describes, while a start that is
  merely close — the VM's own, which a release boots seconds after its os process — is a WRONG
  start that reads just as dead. The same holds for the `ps lstart` string an older runner judges
  by. So a failure of either is returned, never kept, and the next call reads again; a caller
  refuses to record rather than record without one.
  """
  @spec current() :: {:ok, t()} | {:error, :no_start}
  def current do
    case :persistent_term.get(@current_key, nil) do
      nil -> read_current(String.to_integer(System.pid()))
      owner -> {:ok, owner}
    end
  end

  defp read_current(pid) do
    case sample(pid) do
      {:ok, started, lstart} when is_binary(lstart) ->
        owner = of(pid, started, lstart)
        :persistent_term.put(@current_key, owner)
        {:ok, owner}

      _ ->
        {:error, :no_start}
    end
  end

  @doc """
  The identity of os process `pid`, in the shape `current/0` gives this BEAM's, so `alive?/1`
  judges it the same way — carrying too the `ps lstart` string `lstart/1` returns. The start is
  read now; nil when it cannot be read.
  """
  @spec of(integer()) :: t()
  def of(pid) when is_integer(pid) do
    case sample(pid) do
      {:ok, started, lstart} -> of(pid, started, lstart)
      _ -> of(pid, nil)
    end
  end

  @doc """
  An identity from a pid and a start the caller already holds, and optionally the `ps lstart`
  string a runner built before `"beam_start_id"` judges by.
  """
  @spec of(integer(), String.t() | nil, String.t() | nil) :: t()
  def of(pid, started, lstart \\ nil) when is_integer(pid),
    do: %{"beam_os_pid" => pid, "beam_start_id" => started, "beam_started" => lstart}

  @doc """
  The `ps lstart` start an identity carries, whitespace-normalised as
  `LoopctlRunner.ProcessGroup` compares it, or nil when it carries none.
  """
  @spec lstart(map()) :: String.t() | nil
  def lstart(%{"beam_started" => lstart}) when is_binary(lstart), do: normalize_start(lstart)
  def lstart(_), do: nil

  @doc """
  Whether two identities name one process: the same pid, and the same start as `alive?/1`
  compares a record with a reading — exactly in this module's forms, whitespace-normalised in
  master's. False when either carries no start.
  """
  @spec same?(map(), map()) :: boolean()
  def same?(%{"beam_os_pid" => pid} = one, %{"beam_os_pid" => pid} = other)
      when is_integer(pid) do
    case {start_of(one), start_of(other)} do
      {nil, _} -> false
      {_, nil} -> false
      {started, now} -> same_start?(started, now)
    end
  end

  def same?(_one, _other), do: false

  @doc """
  True when the recorded owner is still the same running process: the pid exists and its start
  matches the recorded one — `"beam_start_id"`, or for a record master wrote, `"beam_started"`.

  An owner recorded WITHOUT a start is dead: a pid alone cannot tell the owner from whatever
  reused it, and a stale "alive" blocks that story's runs indefinitely.

  One reading per question, which answers existence and start together. A pid that reading says
  does not exist is dead. A reading that could not be taken at all — `ps` missing, failing to
  spawn, or saying something that is not a process's row, `/proc` unreadable — or a start recorded
  in the other kernel's form cannot tell, and that is answered ALIVE, because calling a live owner
  dead reaps its run. It is logged once per outage: the first cannot-tell after a reading that
  answered warns, and none after it does until another reading answers.
  """
  @spec alive?(map()) :: boolean()
  def alive?(%{"beam_os_pid" => pid} = owner) when is_integer(pid) do
    case start_of(owner) do
      nil -> false
      started -> same_process?(pid, started)
    end
  end

  def alive?(_), do: false

  @doc """
  `alive?/1` for a grant's SESSION line: the launcher, a shell. The same identity check when a
  start was recorded; one recorded by pid alone is alive while that pid exists. A leaked grant
  costs a directory entry, a live session's grant swept mid-run costs its subagent's commits.
  """
  @spec process_alive?(map()) :: boolean()
  def process_alive?(%{"beam_os_pid" => pid} = owner) when is_integer(pid) do
    if start_of(owner) == nil, do: exists?(pid), else: alive?(owner)
  end

  def process_alive?(_), do: false

  defp exists?(pid) do
    case reading(pid) do
      {:ok, _} -> true
      :gone -> false
      {:cannot_tell, why} -> cannot_tell(pid, why)
    end
  end

  # The start a record is judged by: the one this module writes, else the one master wrote. A
  # `"beam_start_id"` that is not a string is in no form this module reads, and master's is used.
  defp start_of(%{"beam_start_id" => started}) when is_binary(started), do: started
  defp start_of(%{"beam_started" => started}) when is_binary(started), do: started
  defp start_of(_), do: nil

  defp same_process?(pid, started) do
    case form(started) do
      :lstart -> lstart_matches?(pid, started)
      form -> start_matches?(pid, form, started)
    end
  end

  defp start_matches?(pid, form, started) do
    case reading(pid) do
      {:ok, now} ->
        if form(now) == form,
          do: same_start?(started, now),
          else:
            cannot_tell(
              pid,
              "its start was recorded as #{form} and this kernel reads #{form(now)}"
            )

      :gone ->
        false

      {:cannot_tell, why} ->
        cannot_tell(pid, why)
    end
  end

  # A run or lock recorded by a runner that stored `ps lstart`, compared by the rule it was
  # written under: read in this process's own timezone and locale, as master read it. Such
  # records end with the runs and locks that carry them.
  defp lstart_matches?(pid, started) do
    case ps(pid, ["lstart="]) do
      {:ok, now} -> same_start?(started, now)
      :gone -> false
      {:cannot_tell, why} -> cannot_tell(pid, why)
    end
  end

  # The one comparison of two starts, for a record against a reading and a record against a
  # record alike. This module's forms are a value the kernel recorded, so equal or not the same
  # process; master's is a string `ps` pads, compared as master compared it once normalised.
  defp same_start?(started, now) do
    case {form(started), form(now)} do
      {:lstart, :lstart} -> normalize_start(started) == normalize_start(now)
      {form, form} -> started == now
      _ -> false
    end
  end

  defp form("boot:" <> _), do: :boot
  defp form("utc:" <> _), do: :utc
  defp form(started) when is_binary(started), do: :lstart

  @doc false
  # Which way this kernel's starts are read: `:boot` on Linux, `:utc` elsewhere. The suite reads
  # it to run each kernel's tests where that kernel's reading is the one in use.
  @spec clock() :: :boot | :utc
  def clock, do: if(match?({:unix, :linux}, :os.type()), do: :boot, else: :utc)

  @doc false
  # Field 22 of a `/proc/<pid>/stat` line, the start in clock ticks since boot; nil when absent.
  # Field 2 is the command name in parentheses, which may itself hold spaces and ")", so fields
  # are counted from the LAST ")": field 3 is the first after it, which makes field 22 the 20th.
  @spec start_ticks(String.t()) :: non_neg_integer() | nil
  def start_ticks(stat) do
    with [_ | _] = parens <- :binary.matches(stat, ")"),
         {at, 1} = List.last(parens),
         after_comm = binary_part(stat, at + 1, byte_size(stat) - at - 1),
         digits when is_binary(digits) <- after_comm |> String.split() |> Enum.at(19),
         {ticks, ""} <- Integer.parse(digits) do
      ticks
    else
      _ -> nil
    end
  end

  # {:ok, start} in this kernel's form, :gone when `pid` names no process, {:cannot_tell, why}
  # when the reading could not be taken. What judging a record needs, and no more: one `ps` on
  # macOS, none on Linux.
  defp reading(pid, env \\ [])
  defp reading(pid, _env) when pid < 1, do: :gone

  defp reading(pid, env) do
    case clock() do
      :boot -> boot_reading(pid)
      :utc -> utc_reading(pid, env)
    end
  end

  # A reading that also carries the process's `ps lstart` string as master read it — in this
  # process's own timezone and locale — or nil when that could not be read: {:ok, start, lstart},
  # or what `reading/1` answers. Two readings of one process, because a `ps` reads under one
  # timezone; asked only when an identity is recorded, never when one is judged.
  defp sample(pid) do
    with {:ok, started} <- reading(pid) do
      lstart =
        case ps(pid, ["lstart="]) do
          {:ok, out} -> String.trim(out)
          _ -> nil
        end

      {:ok, started, lstart}
    end
  end

  defp utc_reading(pid, env) do
    with {:ok, out} <- ps(pid, ["lstart="], utc(env)) do
      lstart = normalize_start(out)

      if lstart =~ @lstart_shape,
        do: {:ok, "utc:" <> lstart},
        else: {:cannot_tell, "`ps -o lstart=` printed #{inspect(out)}"}
    end
  end

  defp boot_reading(pid) do
    with {:ok, boot_id} <- boot_id(),
         {:ok, stat} <- proc_stat(pid) do
      case start_ticks(stat) do
        nil -> {:cannot_tell, "/proc/#{pid}/stat carries no start"}
        ticks -> {:ok, "boot:#{boot_id}:#{ticks}"}
      end
    end
  end

  # One boot's id, which cannot change while this BEAM runs, so it is read once.
  defp boot_id do
    case :persistent_term.get(@boot_id_key, nil) do
      nil -> read_boot_id()
      id -> {:ok, id}
    end
  end

  defp read_boot_id do
    with {:ok, raw} <- File.read("/proc/sys/kernel/random/boot_id"),
         id when id != "" <- String.trim(raw) do
      :persistent_term.put(@boot_id_key, id)
      {:ok, id}
    else
      _ -> {:cannot_tell, "/proc/sys/kernel/random/boot_id could not be read"}
    end
  end

  defp proc_stat(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        answered({:ok, stat})

      # :esrch is a process that ended while its file was being read.
      {:error, reason} when reason in [:enoent, :esrch] ->
        answered(:gone)

      {:error, reason} ->
        {:cannot_tell, "/proc/#{pid}/stat could not be read (#{:file.format_error(reason)})"}
    end
  end

  # `ps -o <field> ... -p <pid>`, one `-o` per field, under `env` on top of this process's own.
  # {:ok, output} when it printed the row, :gone when it RAN and said no, {:cannot_tell, why}
  # otherwise.
  #
  # "Said no" is exit 1 with NOTHING printed, stderr included: how procps and BSD ps both report a
  # pid that does not exist (and a pid below 1 names no process at all). Any other non-zero exit,
  # or one that printed something — `ps` saying what went wrong — is not an answer about the pid,
  # and read as one it called a live owner dead and reaped its run. Resolved on PATH by
  # `System.cmd/3` itself; a `ps` that is not there raises, and is rescued.
  defp ps(pid, fields, env \\ [])
  defp ps(pid, _fields, _env) when pid < 1, do: :gone

  defp ps(pid, fields, env) do
    args = Enum.flat_map(fields, &["-o", &1]) ++ ["-p", Integer.to_string(pid)]

    "ps"
    |> System.cmd(args, stderr_to_stdout: true, env: env)
    |> ps_answer()
  rescue
    e -> {:cannot_tell, "`ps` could not be run (#{Exception.message(e)})"}
  end

  defp ps_answer({out, status}) do
    case {String.trim(out), status} do
      {"", 0} -> {:cannot_tell, "`ps` printed nothing"}
      {_row, 0} -> answered({:ok, out})
      {"", 1} -> answered(:gone)
      {said, status} -> {:cannot_tell, "`ps` exited #{status}: #{inspect(said)}"}
    end
  end

  @doc false
  # The counter the cannot-tell warning is limited by, made once when the application starts
  # (`LoopctlRunner.Application`), so judging an owner never writes a persistent term: each write
  # of one is a global GC pass. A BEAM that never started the application has none and says
  # every cannot-tell.
  @spec init_outage_counter() :: :ok
  def init_outage_counter do
    if :persistent_term.get(@outage_key, nil) == nil,
      do: :persistent_term.put(@outage_key, :atomics.new(1, signed: false))

    :ok
  end

  # A reading that answered ends the outage the last warning was about, so the next one is said.
  defp answered(answer) do
    case :persistent_term.get(@outage_key, nil) do
      nil -> :ok
      counter -> :atomics.put(counter, 1, 0)
    end

    answer
  end

  defp cannot_tell(pid, why) do
    if first_in_outage?() do
      Logger.warning(
        "cannot tell whether os pid #{pid} is running: #{why}. " <>
          "Every owner this BEAM cannot judge is treated as ALIVE, so a dead runner's runs and " <>
          "subagent git grants are kept, not reaped, until a reading answers again."
      )
    end

    true
  end

  defp first_in_outage? do
    case :persistent_term.get(@outage_key, nil) do
      nil -> true
      counter -> :atomics.add_get(counter, 1, 1) == 1
    end
  end

  # The reader's environment for a UTC reading (`System.cmd/3`'s `:env`, added to this process's
  # own): TZ and the locale are overridden, which is the point, and a caller shows that by passing
  # one rather than changing this BEAM's. A start read in the reader's own zone mismatched between
  # the daemon (launchd) and `mix loopctl.reap` (a shell), or across a timezone change, and a live
  # session's processes read as strangers (#66).
  defp utc(env), do: Enum.reject(env, fn {name, _} -> name in ["TZ", "LC_ALL"] end) ++ @utc_env

  @doc """
  `ps -o lstart=` for `pid` in this process's own timezone and locale, whitespace-normalised, or
  nil: the untagged form a runner before #66 wrote in tree files and `leader_start`, which
  matches only when reader and writer share a zone. Never raises.
  """
  @spec local_start_time(integer(), [{String.t(), String.t()}]) :: String.t() | nil
  def local_start_time(pid, env \\ []) when is_integer(pid) do
    case ps(pid, ["lstart="], env) do
      {:ok, out} -> normalize_start(out)
      _ -> nil
    end
  end

  @doc """
  The start of `pid` in this kernel's owner form — the `"beam_start_id"` `of/1` records — or nil
  when it cannot be read, in ONE reading. A session records its launcher's by this form
  (`leader_start_id`), and on Linux the launcher records each tree-file process by it
  (`"boot:<boot id>:<ticks>"`): a value the kernel fixed at fork, so neither a timezone nor a clock
  step moves it. `env` is the reader's environment, which it does not depend on. Never raises.
  """
  @spec start_id(integer(), [{String.t(), String.t()}]) :: String.t() | nil
  def start_id(pid, env \\ []) when is_integer(pid) do
    case reading(pid, env) do
      {:ok, started} -> started
      _ -> nil
    end
  end

  @doc """
  Every live process's start as the session launcher records it on macOS (and on Linux with no
  readable boot id), from ONE `ps -A` snapshot under UTC and the C locale:
  `{:ok, %{pid => "utc:<lstart>"}}`, or `:cannot_tell` when `ps` fails, cannot run or lists
  nothing. For `LoopctlRunner.ProcessGroup`, which judges a whole tree file per poll. Never raises.
  """
  @spec utc_starts([{String.t(), String.t()}]) ::
          {:ok, %{pos_integer() => String.t()}} | :cannot_tell
  def utc_starts(env \\ []), do: snapshot_starts(utc(env), "utc:")

  @doc """
  `utc_starts/0` in the untagged local form `local_start_time/1` gives, for tree-file lines a
  runner before #66 wrote. Never raises.
  """
  @spec local_starts([{String.t(), String.t()}]) ::
          {:ok, %{pos_integer() => String.t()}} | :cannot_tell
  def local_starts(env \\ []), do: snapshot_starts(env, "")

  defp snapshot_starts(env, prefix) do
    case System.cmd("ps", ["-A", "-o", "pid=,lstart="], stderr_to_stdout: true, env: env) do
      {out, 0} ->
        starts =
          for line <- String.split(out, "\n", trim: true),
              [pid_s, raw] <- [String.split(String.trim_leading(line), " ", parts: 2)],
              {pid, ""} <- [Integer.parse(pid_s)],
              start = normalize_start(raw),
              prefix == "" or start =~ @lstart_shape,
              into: %{},
              do: {pid, prefix <> start}

        if starts == %{}, do: :cannot_tell, else: {:ok, starts}

      _failed ->
        :cannot_tell
    end
  rescue
    _ -> :cannot_tell
  end

  @doc """
  A start time with its whitespace collapsed. `ps lstart` pads a one-digit day with a second
  space ("Tue Sep  8"), and the session launcher's awk collapses it; compared raw, every start
  time recorded on days 1-9 mismatched.
  """
  @spec normalize_start(String.t()) :: String.t()
  def normalize_start(start), do: start |> String.split() |> Enum.join(" ")
end
