defmodule LoopctlRunner.TestSupport do
  @moduledoc false

  alias LoopctlRunner.Config

  @headless Path.expand("~/workspace/claude-config/bin/claude-headless.sh")

  def headless_launcher, do: @headless

  def fake_bin_dir, do: Path.expand("bin", __DIR__)

  @doc "This BEAM's `LoopctlRunner.Owner` identity, which a test BEAM can always read."
  def owner! do
    {:ok, owner} = LoopctlRunner.Owner.current()
    owner
  end

  @doc """
  `owner` as a grant line records it, and `LoopctlRunner.GitGrant.holders/1` reads it back: its
  pid and start, without the `ps lstart` string only a run or lock record carries.
  """
  def granted(owner), do: %{owner | "beam_started" => nil}

  @doc """
  A start of the same form as `started` that its process never had: a reused pid's, in whichever
  form this kernel records (`LoopctlRunner.Owner.clock/0`).
  """
  def other_start("utc:" <> _), do: "utc:Thu Jan 1 00:00:00 1970"

  def other_start("boot:" <> _ = started) do
    [boot, id, ticks] = String.split(started, ":")
    Enum.join([boot, id, String.to_integer(ticks) + 360_000], ":")
  end

  def tmp_dir!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "loopctl-runner-test-#{label}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  # An ssh stand-in that records what it was given, the fetching git's stdin, and fails.
  def recording_ssh!(dir) do
    record = Path.join(dir, "ssh-record")
    ssh = Path.join(dir, "record-ssh")

    File.write!(ssh, """
    #!/bin/sh
    p=$PPID
    while [ "$p" -gt 1 ]; do
      case "$(ps -o comm= -p "$p")" in *git) break ;; esac
      p=$(ps -o ppid= -p "$p" | tr -d ' ')
    done
    stdin=$(readlink "/proc/$p/fd/0" 2>/dev/null || lsof -a -p "$p" -d 0 -Fn 2>/dev/null | sed -n 's/^n//p')
    printf '%s\n' "args=$*" "prompt=${GIT_TERMINAL_PROMPT-unset}" "stdin=$stdin" > #{record}
    exit 1
    """)

    File.chmod!(ssh, 0o755)
    {ssh, record}
  end

  def git_repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "master"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "test"])
    git!(dir, ["config", "core.hooksPath", "/dev/null"])
    File.write!(Path.join(dir, "README.md"), "fixture\n")
    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  def git!(dir, args) do
    env = Enum.map(LoopctlRunner.Worktree.repo_locating_env(), &{&1, nil})
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: env)
    String.trim(out)
  end

  def config_map(root, overrides \\ %{}) do
    Map.merge(
      %{
        "runs_dir" => Path.join(root, "runs"),
        "claude_projects_dir" => Path.join(root, "projects"),
        # NEVER the operator's ~/.claude: the reaper sweeps this directory, and the suite drives
        # the production path. The after-suite canary in test_helper.exs is what notices if this
        # stops being true.
        "grant_dir" => Path.join(root, "grants"),
        "claude_launcher" => @headless,
        "repos" => %{"fixture" => Path.join(root, "repo")},
        "branch_prefixes" => ["loop/"],
        "max_wall_clock_s" => 60,
        "max_turns" => 10,
        "park_after_s" => 1,
        "liveness_interval_s" => 1,
        "kill_grace_s" => 2,
        "agents_probe_timeout_s" => 5,
        "tree_poll_s" => 1,
        # Production's is 60: a suite whose deadline tests each waited out a minute of session
        # would be a suite nobody runs. The guard's own test sets the real one.
        "min_session_s" => 1
      },
      overrides
    )
  end

  def config!(root, overrides \\ %{}) do
    {:ok, config} = Config.from_map(config_map(root, overrides))
    config
  end

  def story_map(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "s1",
        "repo" => "fixture",
        "base" => "master",
        "branch" => "loop/s1",
        "prompt" => "do the thing",
        "wall_clock_s" => 30,
        "max_turns" => 5
      },
      overrides
    )
  end

  @doc "Sets the fake CLI's environment for the duration of a test."
  def fake_env!(state_dir, vars) do
    previous = System.get_env("PATH")
    System.put_env("PATH", fake_bin_dir() <> ":" <> previous)
    System.put_env("FAKE_STATE_DIR", state_dir)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    fn ->
      System.put_env("PATH", previous)
      Enum.each(["FAKE_STATE_DIR" | Enum.map(vars, &elem(&1, 0))], &System.delete_env/1)
    end
  end

  def os_pid_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))
  end

  def wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> sleep_then_wait(fun, deadline)
    end
  end

  defp sleep_then_wait(fun, deadline) do
    Process.sleep(50)
    do_wait(fun, deadline)
  end

  @doc "True once the launcher's tree file records `pid`."
  def recorded?(tree_file, pid) do
    case File.read(tree_file) do
      {:ok, raw} -> raw |> String.split("\n") |> Enum.any?(&String.starts_with?(&1, "#{pid} "))
      _ -> false
    end
  end

  def read_int!(path), do: path |> File.read!() |> String.trim() |> String.to_integer()

  @doc """
  A session's tree as the launcher records it: a detached process, `"pid start"` in the tree file,
  which a Port closing does not end. `ignore_term` makes it one that outlives a TERM, so ending it
  takes the whole grace. Killed when the test exits.
  """
  def live_session!(ignore_term) do
    trap = if ignore_term, do: ~s|$SIG{TERM} = "IGNORE"; |, else: ""

    {out, 0} =
      System.cmd("/bin/sh", [
        "-c",
        ~s|perl -MPOSIX -e '#{trap}POSIX::setsid(); exec "sleep", "30"' >/dev/null 2>&1 & echo $!|
      ])

    session = String.to_integer(String.trim(out))

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-KILL", "#{session}"], stderr_to_stdout: true)
    end)

    :ok = wait_until(fn -> utc_start_time(session) != nil end)
    session
  end

  @doc """
  A zone fourteen hours from UTC, so no machine running the suite reads it as its own, or nil when
  this host's tz database lacks it: glibc then reads the name as UTC, and a test of timezone
  independence would pass without testing anything, so such a test is skipped, visibly.
  """
  def far_timezone do
    tz = "Pacific/Kiritimati"

    case System.cmd("date", ["+%z"], env: [{"TZ", tz}]) do
      {"+1400\n", 0} -> tz
      _ -> nil
    end
  end

  @doc """
  `pid`'s start in the "utc:" form the session launcher records on macOS, read from one
  `Owner.utc_starts/1` snapshot under the reader's `env`, or nil.
  """
  def utc_start_time(pid, env \\ []) do
    case LoopctlRunner.Owner.utc_starts(env) do
      {:ok, starts} -> Map.get(starts, pid)
      :cannot_tell -> nil
    end
  end

  @doc "A process's start in the form the session launcher records it on this kernel."
  def tree_start(pid) do
    case LoopctlRunner.Owner.clock() do
      :boot -> LoopctlRunner.Owner.start_id(pid)
      :utc -> utc_start_time(pid)
    end
  end
end
