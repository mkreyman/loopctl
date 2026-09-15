defmodule LoopctlRunner.Session do
  @moduledoc """
  One `claude -p` session, wrapped — never supervised directly (design §2).

  Owns the Port, which spawns `priv/bin/session-launcher.sh`, which execs claude-config's
  `claude-headless.sh`, which execs the CLI. Every way this session ends — clean exit,
  wall-clock budget, parked, runner shutdown — ends the launcher's process group AND every
  process carrying this session's `LOOP_SESSION_ID` marker, because the CLI's Bash tool
  detaches its commands into new sessions (see `LoopctlRunner.ProcessGroup`).

  Unattended flags (design §8): `--permission-mode dontAsk --permission-prompts none` runs only
  what is pre-allowed and removes `AskUserQuestion`, which makes waiting on a human impossible
  rather than costly, `--setting-sources ""` keeps the operator's and the repository's settings
  out, and `--max-turns` is the hard stop. Not `--bare`, which would drop the login.

  What a session can use at all is contained separately (`session_tools/0`): six built-in
  tools, no MCP server and no plugin tool. An implement session needs a shell and the file
  tools, and nothing that reaches beyond the worktree: no subagents, no loopctl MCP tools, no
  web. A triage session will need its read-only lenses as agents; it gets its own contained set
  when its contract exists (design §8), never this one widened.
  """

  use GenServer

  alias LoopctlRunner.{
    Config,
    Liveness,
    ProcessGroup,
    RunState,
    Story,
    StreamEvents,
    Trace,
    Worktree
  }

  # A line longer than this is cut and recorded as unparsed rather than buffered forever.
  @max_line 16_777_216
  @verify_group_after_ms 500

  @type result :: %{
          session_id: String.t(),
          os_pid: pos_integer(),
          exit_status: non_neg_integer(),
          reason: :exited | :wall_clock_exceeded | :parked | :not_group_leader | :escalated,
          duration_ms: non_neg_integer()
        }

  @doc """
  Runs the session to completion and returns its result.

  Options: `:config`, `:story`, `:worktree`, `:run_dir`, `:trace`, `:system_prompt` (what
  `--append-system-prompt` carries; the implement session's escalation prompt by default),
  `:parent` (the run's
  trace seq), and optionally `:session_id` and `:env` (extra `{name, value}` pairs).
  """
  @spec run(keyword()) :: result()
  def run(opts) do
    pid =
      case GenServer.start(__MODULE__, Keyword.put(opts, :waiter, self())) do
        {:ok, pid} -> pid
        {:error, reason} -> exit({:session_start_failed, reason})
      end

    ref = Process.monitor(pid)

    receive do
      {:session_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        exit({:session_crashed, reason})
    end
  end

  @spec launcher_script() :: String.t()
  def launcher_script, do: Application.app_dir(:loopctl_runner, "priv/bin/session-launcher.sh")

  @escalation_check_ms 2_000

  @doc "The absolute path of the escalation command a session is allowed to run."
  @spec escalate_script() :: String.t()
  def escalate_script, do: Application.app_dir(:loopctl_runner, "priv/bin/loop-escalate")

  @doc """
  Appended to the session's system prompt: how to ask for a human, since it cannot ask.

  A headless session has no AskUserQuestion and no hook observes a question it wanted to ask
  (KB 16d4ff67), so escalation is a command it calls: exactly one absolute path, pre-allowed.
  """
  @spec escalation_prompt() :: String.t()
  def escalation_prompt do
    """
    You are running unattended: nobody can answer a question, and guessing on a decision that \
    belongs to a human is worse than stopping. If you need a human to decide something — the \
    request is ambiguous, contradicts existing behaviour, removes behaviour someone added \
    deliberately, or needs a business call — run this command with the Bash tool, keeping the \
    quoted heredoc exactly as shown so nothing in your text is expanded, then stop working and \
    end your turn:

        #{escalate_script()} <<'ESCALATION'
        <the decision a human must make, and why>
        ESCALATION
    """
  end

  # What an unattended session can use at all, as opposed to what it may run without asking.
  # --allowedTools is an allow list: it grants, it does not remove. Measured on Claude Code
  # 2.1.270 (KB c6452b2b, and on minis with this runner's own flags): without these, a session
  # also had Agent, Workflow, Skill, SendMessage, RemoteTrigger, WebFetch, the cron tools, every
  # configured MCP server (loopctl's destructive tools, with this machine's keys) and every
  # function-hook plugin tool. A session that reads story text must have none of that:
  #   --tools            the built-ins it keeps;
  #   --strict-mcp-config --mcp-config '{"mcpServers":{}}'   no configured MCP server;
  #   --disallowedTools "mcp__*"                              no plugin tool, present or future.
  # Fixed here, never taken from a story or the config, so nothing a dispatch carries can widen it.
  @session_tools ~w(Read Edit Write Glob Grep Bash)

  # What a session may run without asking, which under dontAsk is everything it may run at all.
  # --permission-mode auto was the first choice and it contained nothing: its classifier approves
  # whatever it judges safe, so the first end-to-end run (2026-09-14) committed through a bash
  # wrapper, ran docker exec psql and gh, and read ~/.claude. Probed on Claude Code 2.1.270 with
  # claude-opus-5, the same prompt, one flag changed:
  #   auto     touch, bash -c, `git status && touch` and a Write outside the cwd all ran;
  #   dontAsk  each was denied, and only the rules below and the story's allowed_tools ran.
  # --setting-sources "" loads no user, project or local settings: no permission allow rules the
  # operator or the repository added (a session could otherwise write .claude/settings.json and
  # grant itself more), no hooks, no plugins. The login is kept, unlike --bare.
  # The file tools are scoped to the worktree, the session's cwd: outside it, Read, Grep and
  # Write were denied in the same probe.
  @file_rules ~w[Read(./**) Glob(./**) Grep(./**) Edit(./**) Write(./**)]

  @doc "The built-in tools every session is limited to."
  @spec session_tools() :: [String.t()]
  def session_tools, do: @session_tools

  @doc "The file-tool rules every session gets, scoped to its worktree."
  @spec file_rules() :: [String.t()]
  def file_rules, do: @file_rules

  @doc """
  The argv handed to claude-headless.sh.

  `system_prompt` is what `--append-system-prompt` carries, and it defaults to
  `escalation_prompt/0`, which is right for an implement session. A triage session must pass its
  own (`LoopctlRunner.TriagePrompt.system_prompt/0`): this one tells a session to run
  `loop-escalate` and stop when a request is ambiguous, which is the commonest triage verdict, so
  a triage session launched with it ends escalated with no verdict.
  """
  @spec claude_args(Story.t(), String.t(), String.t()) :: [String.t()]
  def claude_args(%Story{} = story, session_id, system_prompt \\ escalation_prompt()) do
    # -p is a flag, not an option taking a value: the prompt is positional, so a prompt
    # starting with "-" (a markdown list, front matter) would parse as an option.
    [
      "-p",
      "--output-format",
      "stream-json",
      "--verbose",
      "--session-id",
      session_id,
      "--permission-mode",
      "dontAsk",
      "--permission-prompts",
      "none",
      "--setting-sources",
      "",
      "--max-turns",
      Integer.to_string(story.max_turns),
      "--tools",
      Enum.join(@session_tools, ","),
      "--strict-mcp-config",
      "--mcp-config",
      ~s({"mcpServers":{}}),
      "--disallowedTools",
      "mcp__*"
    ] ++
      if(story.model, do: ["--model", story.model], else: []) ++
      Enum.flat_map(@file_rules ++ story.allowed_tools, &["--allowedTools", &1]) ++
      ["--allowedTools", "Bash(#{escalate_script()}:*)"] ++
      ["--append-system-prompt", system_prompt] ++
      ["--", story.prompt]
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    %Config{} = config = Keyword.fetch!(opts, :config)
    %Story{} = story = Keyword.fetch!(opts, :story)
    trace = Keyword.fetch!(opts, :trace)
    run_dir = Keyword.fetch!(opts, :run_dir)
    worktree = Keyword.fetch!(opts, :worktree)
    session_id = Keyword.get_lazy(opts, :session_id, &uuid4/0)

    stderr_log = Path.join(run_dir, "stderr.log")
    {:ok, stdout_io} = File.open(Path.join(run_dir, "stdout.ndjson"), [:append, :binary])
    tree_file = Path.join(run_dir, "stderr.log.tree")
    RunState.update(run_dir, %{session_id: session_id, tree_file: tree_file, status: "running"})

    port =
      Port.open({:spawn_executable, launcher_script()}, [
        :binary,
        :exit_status,
        cd: worktree,
        args: [
          stderr_log,
          config.claude_launcher
          | claude_args(story, session_id, Keyword.get(opts, :system_prompt, escalation_prompt()))
        ],
        env: port_env(run_dir, session_id, config, Keyword.get(opts, :env, []))
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    leader_start = ProcessGroup.start_time(os_pid)
    RunState.update(run_dir, %{pgid: os_pid, leader_start: leader_start})
    now = now_ms()

    session_seq =
      Trace.emit(trace, "session.started", Keyword.fetch!(opts, :parent), %{
        "session_id" => session_id,
        "os_pid" => os_pid,
        "cwd" => worktree,
        "launcher" => config.claude_launcher,
        "max_turns" => story.max_turns,
        "wall_clock_s" => story.wall_clock_s,
        "model" => story.model
      })

    Process.send_after(self(), :wall_clock, story.wall_clock_s * 1000)
    Process.send_after(self(), :verify_group, @verify_group_after_ms)
    Process.send_after(self(), :check_escalation, @escalation_check_ms)
    schedule_tick(config)

    {:ok,
     %{
       config: config,
       story: story,
       trace: trace,
       waiter: Keyword.fetch!(opts, :waiter),
       port: port,
       os_pid: os_pid,
       session_id: session_id,
       tree_file: tree_file,
       leader_start: leader_start,
       session_seq: session_seq,
       stream: StreamEvents.new(session_seq),
       stdout_io: stdout_io,
       partial: "",
       escalation_file: Path.join(run_dir, "escalations.ndjson"),
       escalations_seen: 0,
       started_ms: now,
       last_stdout_ms: now,
       reason: nil
     }}
  end

  defp port_env(run_dir, session_id, config, extra) do
    base = [
      {"LOOP_ESCALATE", escalate_script()},
      {"LOOP_MODE", "1"},
      {"LOOP_RUN_DIR", run_dir},
      {"LOOP_STORY_FILE", Path.join(run_dir, "story.json")},
      {"LOOP_SESSION_ID", session_id},
      {"LOOP_KILL_GRACE_S", Integer.to_string(config.kill_grace_s)},
      {"LOOP_TREE_POLL_S", Integer.to_string(config.tree_poll_s)},
      {"LOOP_TREE_FILE", Path.join(run_dir, "stderr.log.tree")}
    ]

    unset = ["ANTHROPIC_API_KEY" | Worktree.repo_locating_env()]

    # The repo's own session_env comes after PATH, so a configured PATH still wins; the names
    # release_env/1 unsets are refused in session_env by Config, so nothing there is lost.
    Enum.map(base ++ release_path(System.get_env()) ++ extra, fn {k, v} ->
      {to_charlist(k), to_charlist(v)}
    end) ++
      Enum.map(unset ++ release_env(System.get_env()), &{to_charlist(&1), false})
  end

  @doc """
  The names in `env` that belong to the runner's own release, which a session must not inherit.

  A release boots with `RELEASE_*` (the node's cookie among them), `EMU`, `PROGNAME`, `ROOTDIR`,
  `BINDIR` and `ERL_CRASH_DUMP_SECONDS`, and the daemon runs under `LOOPCTL_RUNNER_*`. The first end-to-end
  run inherited all of them, and `mix` in the story's repo ran against the release instead of
  the machine's own Erlang, until the session wrote a script to strip them.
  """
  @spec release_env(%{String.t() => String.t()}) :: [String.t()]
  def release_env(env) do
    env
    |> Map.keys()
    |> Enum.filter(&release_env_name?/1)
    |> Enum.sort()
  end

  # The release's bin script exports RELEASE_*, and erts-*/bin/erl exports EMU, PROGNAME,
  # ROOTDIR and BINDIR, all pointing into the release.
  @release_env_prefixes ["RELEASE_", "LOOPCTL_RUNNER_"]
  @release_env_names ~w(EMU PROGNAME ROOTDIR BINDIR ERL_CRASH_DUMP_SECONDS)

  @doc """
  Whether `name` is one `release_env/1` unsets. `Config` refuses these in `session_env`: the
  unset would silently win over a repo's value under the daemon, and only there.
  """
  @spec release_env_name?(String.t()) :: boolean()
  def release_env_name?(name),
    do: String.starts_with?(name, @release_env_prefixes) or name in @release_env_names

  @doc """
  `PATH` without the release's own directories, as a `{name, value}` pair, or nothing when the
  runner is not a release. A release puts its `erts-*/bin` and `bin` first, so a session's `erl`
  and `mix` would resolve to the runner's ERTS.
  """
  @spec release_path(%{String.t() => String.t()}) :: [{String.t(), String.t()}]
  def release_path(%{"RELEASE_ROOT" => root, "PATH" => path}) when root != "" do
    root = Path.expand(root)

    kept =
      path
      |> String.split(":")
      |> Enum.reject(&(&1 == root or String.starts_with?(&1, root <> "/")))

    [{"PATH", Enum.join(kept, ":")}]
  end

  def release_path(_env), do: []

  @impl true
  # Raw chunks, split here. The Port's own {:line, N} mode delivers a trailing
  # unterminated chunk AFTER {:exit_status, _} (measured, OTP 28), which loses the
  # CLI's final result line whenever it lacks a newline.
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    [rest | complete] = [state.partial, chunk] |> IO.iodata_to_binary() |> split_lines()
    state = Enum.reduce(Enum.reverse(complete), state, &handle_line/2)
    state = %{state | partial: rest, last_stdout_ms: now_ms()}

    if byte_size(rest) > @max_line,
      do: {:noreply, flush_partial(state)},
      else: {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = state |> flush_partial() |> record_escalations()
    reason = exit_reason(state.reason, status)
    stragglers = reap_stragglers(state)

    Trace.emit(state.trace, "session.exited", state.session_seq, %{
      "exit_status" => status,
      "reason" => Atom.to_string(reason),
      "duration_ms" => now_ms() - state.started_ms,
      "stragglers" => stragglers
    })

    result = %{
      session_id: state.session_id,
      os_pid: state.os_pid,
      exit_status: status,
      reason: reason,
      duration_ms: now_ms() - state.started_ms
    }

    send(state.waiter, {:session_result, self(), result})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(:verify_group, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:verify_group, state) do
    leader? = ProcessGroup.leader?(state.os_pid)

    Trace.emit(state.trace, "session.process_group", state.session_seq, %{
      "pgid" => state.os_pid,
      "leader" => leader?
    })

    # Without leadership the group kill would miss the tree, so the session is not
    # allowed to run on as though teardown could work.
    if leader? or ProcessGroup.command(state.os_pid) == nil,
      do: {:noreply, state},
      else: {:noreply, stop_session(state, :not_group_leader, %{"pgid" => state.os_pid})}
  end

  def handle_info(:wall_clock, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:wall_clock, %{reason: reason} = state) when reason != nil,
    do: {:noreply, state}

  def handle_info(:wall_clock, state) do
    data = %{"wall_clock_s" => state.story.wall_clock_s}
    {:noreply, stop_session(state, :wall_clock_exceeded, data)}
  end

  def handle_info(:check_escalation, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:check_escalation, %{reason: reason} = state) when reason != nil,
    do: {:noreply, state}

  # A session that escalated has handed the decision to a human; it is stopped even if it
  # keeps working, so nothing it does after asking can pre-empt the answer.
  def handle_info(:check_escalation, state) do
    case record_escalations(state) do
      %{reason: :escalated} = state ->
        {:noreply, stop_session(%{state | reason: nil}, :escalated, %{"stopped_by" => "runner"})}

      state ->
        Process.send_after(self(), :check_escalation, @escalation_check_ms)
        {:noreply, state}
    end
  end

  def handle_info(:liveness_tick, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:liveness_tick, %{reason: reason} = state) when reason != nil,
    do: {:noreply, state}

  def handle_info(:liveness_tick, state) do
    state =
      case observe(state) do
        {:parked, evidence} -> stop_session(state, :parked, evidence)
        _ -> state
      end

    schedule_tick(state.config)
    {:noreply, state}
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  # Anything else — a late message from a closed probe Port, a stray timer — must not
  # crash the monitor: terminate/2 would kill a healthy session.
  def handle_info(message, state) do
    Trace.emit(state.trace, "session.unexpected_message", state.session_seq, %{
      "message" => inspect(message, limit: 5)
    })

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = state) when port != nil do
    ProcessGroup.terminate(state.os_pid, grace_ms(state), kill_opts(state))
  end

  def terminate(_reason, _state), do: :ok

  defp observe(state) do
    config = state.config
    window_ms = config.park_after_s * 1000
    now = now_ms()
    files = Liveness.file_signals(config.claude_projects_dir, state.session_id)

    obs = %{
      now_ms: now,
      last_stdout_ms: state.last_stdout_ms,
      transcript_mtime_ms: files.transcript_mtime_ms,
      subagents_mtime_ms: files.subagents_mtime_ms,
      agent_status: :unknown
    }

    # The agents probe spawns a CLI, so it runs only once the cheap signals are quiet.
    case Liveness.evaluate(obs, window_ms) do
      {:active, _} = verdict ->
        verdict

      _ ->
        status =
          Liveness.agent_status(
            config.claude_launcher,
            state.session_id,
            config.agents_probe_timeout_s * 1000
          )

        verdict =
          %{obs | agent_status: status}
          |> Liveness.evaluate(window_ms)
          |> unless_port_spoke(state.port)

        Trace.emit(state.trace, "session.liveness", state.session_seq, verdict_data(verdict))
        verdict
    end
  end

  # The probe blocks this process for up to its timeout, so `obs` is stale by the time
  # it returns: the CLI may have printed its result and exited meanwhile, which also
  # makes `claude agents` report it absent. Output queued in the mailbox is activity.
  defp unless_port_spoke({:parked, _} = verdict, port) do
    {:messages, messages} = Process.info(self(), :messages)

    if Enum.any?(messages, &match?({^port, _}, &1)),
      do: {:active, [:stdout]},
      else: verdict
  end

  defp unless_port_spoke(verdict, _port), do: verdict

  # Emits a trace event per escalation line not yet seen, and marks the session escalated.
  defp record_escalations(state) do
    lines =
      case File.read(state.escalation_file) do
        {:ok, raw} -> String.split(raw, "\n", trim: true)
        {:error, _} -> []
      end

    new = Enum.drop(lines, state.escalations_seen)

    Enum.each(new, fn line ->
      Trace.emit(
        state.trace,
        "session.escalation_requested",
        state.session_seq,
        escalation_data(line)
      )
    end)

    state = %{state | escalations_seen: length(lines)}

    # An escalation outranks a park or wall-clock stop already under way: the session asked
    # for a human, and that is what the run must report.
    if new != [] and state.reason in [nil, :parked, :wall_clock_exceeded],
      do: %{state | reason: :escalated},
      else: state
  end

  defp escalation_data(line) do
    case JSON.decode(line) do
      {:ok, %{"reason" => reason} = record} when is_binary(reason) ->
        %{"reason" => String.slice(reason, 0, 4000), "ts" => record["ts"]}

      _ ->
        %{"reason" => nil, "unparseable_bytes" => byte_size(line)}
    end
  end

  @doc """
  Why a session ended, given the stop already under way (if any) and the exit status.

  A CLI that exits 0 exited on its own, even if a park stop had begun: that stop's TERM
  would have ended the launcher with 143.
  """
  @spec exit_reason(atom() | nil, non_neg_integer()) :: atom()
  def exit_reason(:parked, 0), do: :exited
  def exit_reason(nil, _status), do: :exited
  def exit_reason(reason, _status), do: reason

  defp verdict_data({:parked, evidence}), do: Map.put(evidence, "verdict", "parked")

  defp verdict_data({kind, signals}),
    do: %{"verdict" => Atom.to_string(kind), "signals" => Enum.map(signals, &Atom.to_string/1)}

  defp stop_session(state, reason, data) do
    Trace.emit(state.trace, "session.#{reason}", state.session_seq, data)
    outcome = ProcessGroup.terminate(state.os_pid, grace_ms(state), kill_opts(state))

    Trace.emit(state.trace, "session.terminated", state.session_seq, %{
      "reason" => Atom.to_string(reason),
      "outcome" => inspect(outcome)
    })

    %{state | reason: reason}
  end

  # The CLI can exit while children it detached from the group live on; the marker
  # still finds them.
  defp reap_stragglers(state) do
    case ProcessGroup.terminate(state.os_pid, grace_ms(state), kill_opts(state)) do
      :already_gone -> "none"
      outcome -> inspect(outcome)
    end
  end

  defp grace_ms(state), do: state.config.kill_grace_s * 1000

  defp kill_opts(state),
    do: [
      marker: ProcessGroup.marker(state.session_id),
      tree_file: state.tree_file,
      leader_start: state.leader_start
    ]

  # Returns [remainder | complete lines, newest first].
  defp split_lines(buffer) do
    buffer
    |> String.split("\n")
    |> Enum.reverse()
  end

  defp handle_line(line, state) do
    :ok = IO.binwrite(state.stdout_io, [line, "\n"])
    emit = fn type, parent, data -> Trace.emit(state.trace, type, parent, data) end
    %{state | stream: StreamEvents.handle_line(line, state.stream, emit)}
  end

  defp flush_partial(%{partial: ""} = state), do: state
  defp flush_partial(state), do: %{handle_line(state.partial, state) | partial: ""}

  defp schedule_tick(config),
    do: Process.send_after(self(), :liveness_tick, config.liveness_interval_s * 1000)

  defp now_ms, do: System.system_time(:millisecond)

  @doc false
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end
end
