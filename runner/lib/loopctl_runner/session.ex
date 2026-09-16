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

  require Logger

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

  Options: `:config`, `:story`, `:worktree`, `:run_dir`, `:trace`, `:argv` (the whole argv, for a
  run with its own contained set), `:system_prompt` (what `--append-system-prompt` carries on the
  default argv; the implement session's escalation prompt),
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

  # The argv a run wants. `:argv` is the seam a run with a different contained set uses — a
  # triage run passes `LoopctlRunner.TriageTools.claude_args/4`'s result, which has its own tools,
  # its own rules and the lens definitions. Without it this module would be the only launcher and
  # every run would get the implement session's containment, silently.
  defp argv(story, session_id, opts) do
    case Keyword.get(opts, :argv) do
      nil ->
        claude_args(story, session_id, Keyword.get(opts, :system_prompt, escalation_prompt()))

      argv when is_list(argv) ->
        checked(argv, session_id)
    end
  end

  # Every launch used to go through `claude_args/3`, which pins the containment. A supplied argv
  # is checked for the same flags rather than trusted to repeat them: one missing
  # `--setting-sources` launches an unattended session with the operator's settings, hooks,
  # plugins and MCP servers, and nothing else in this module would notice. The session id is
  # checked by VALUE — an argv that merely mentions it (in the prompt, in the agents JSON) while
  # omitting the flag leaves the CLI generating its own, and the marker, LOOP_SESSION_ID and the
  # liveness transcript then key to an id nothing runs under: a healthy session reads as parked,
  # and the runner terminates it.
  @required_argv %{
    "--session-id" => :session_id,
    "--permission-mode" => "dontAsk",
    "--permission-prompts" => "none",
    "--setting-sources" => "",
    "--mcp-config" => ~s({"mcpServers":{}}),
    "--disallowedTools" => "mcp__*"
  }

  # Pinned to a VALUE above; these two are pinned only to being there, because their values are
  # the run type's own — a triage session's tool pool is not an implement session's. Missing
  # `--max-turns` leaves an unattended session with no turn ceiling at all, and missing `--tools`
  # hands its pool back Agent, Workflow, Skill, SendMessage, WebFetch and every plugin tool
  # (`--disallowedTools mcp__*` covers only the MCP half).
  @required_present ~w(--tools --max-turns)

  defp checked(argv, session_id) do
    unless "--strict-mcp-config" in argv do
      raise ArgumentError, "a session's argv must carry --strict-mcp-config"
    end

    Enum.each(@required_present, fn flag ->
      case value_after(argv, flag) do
        value when is_binary(value) and value != "" ->
          :ok

        other ->
          raise ArgumentError, "a session's argv must carry #{flag}, got #{inspect(other)}"
      end
    end)

    Enum.each(@required_argv, fn {flag, expected} ->
      expected = if expected == :session_id, do: session_id, else: expected

      case value_after(argv, flag) do
        ^expected ->
          :ok

        other ->
          raise ArgumentError,
                "a session's argv must carry #{flag} #{inspect(expected)}, not #{inspect(other)}"
      end
    end)

    argv
  end

  defp value_after(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> nil
      index -> Enum.at(argv, index + 1)
    end
  end

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
        args: [stderr_log, config.claude_launcher | argv(story, session_id, opts)],
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

  # Credentials the runner's own environment may carry, which a session must not inherit. The
  # Port environment is built by SUBTRACTION, not construction: the session inherits the daemon's
  # whole environment and keeps everything this list does not name, so a credential missing from
  # here reaches the session silently.
  #
  # ANTHROPIC_API_KEY outranks the claude.ai login, which is why `claude-headless.sh` unsets it
  # too (Config refuses any other launcher) — this is the same removal one layer earlier.
  # SSH_AUTH_SOCK and SSH_AGENT_PID are live in the daemon's environment on a dev machine
  # (measured on minis, 2026-09-16): an agent socket holding the operator's GitHub identity, next
  # to a worktree whose `origin` is `git@github.com:...` and whose `.git` is the parent's. NO
  # SECOND LAYER IS ADDED BY REMOVING THEM, and an earlier draft of this comment implied one: on
  # the Linux boxes the identity GitHub accepts is `~/.ssh/id_ed25519` as a PLAIN FILE under the
  # inherited HOME, which ssh reads with no agent involved. So this closes the agent path while
  # the key-file path stays open, and what still stands between a session and a push as the
  # operator is `git push` being off the allow-list — one layer, as before. Closing the rest
  # needs the deploy key's `IdentitiesOnly=yes` with an explicit `IdentityFile`, or a HOME of the
  # session's own, neither of which is here yet. The agent goes because no session wants it in
  # either design: the planned deploy key passes `IdentityAgent=none`, which refuses it outright.
  # GPG_AGENT_INFO is the same class as the ssh agent and is also live on a dev machine: a socket
  # to an agent holding the operator's private keys. UNSETTING IT IS NECESSARY AND NOT SUFFICIENT,
  # and the limit belongs here rather than in whoever next reads the list: it is the LEGACY
  # discovery path, which modern GnuPG ignores in favour of a fixed socket under XDG_RUNTIME_DIR
  # ($XDG_RUNTIME_DIR/gnupg/S.gpg-agent), and XDG_RUNTIME_DIR is inherited on purpose (it is a
  # capability the session may need, and unsetting it breaks more than it closes). So this entry
  # closes the old path and leaves the current one open; the remedy for the rest is the OS
  # boundary this runner does not have yet, not another name here.
  # GH_TOKEN, GITHUB_TOKEN and the askpass pair are in no runner environment today and are named
  # defensively, so a machine that later gains one does not hand it over. The askpass pair is a
  # credential-ACQUISITION path rather than a credential: it names a program git and ssh run to
  # obtain one, so an unattended session could acquire the operator's credential with no terminal
  # anywhere in the picture. Both names are needed, because git falls through GIT_ASKPASS ->
  # core.askPass -> SSH_ASKPASS: removing one alone just moves the path down one rung. IT DOES
  # NOT CLOSE THE LADDER, though an earlier draft here claimed it did: rung 2 is `core.askPass`
  # in `~/.gitconfig`, which no unset touches because it is a FILE, reached through the inherited
  # HOME. ssh, with no config-file rung of its own, does fail closed; git falls to rung 2 and
  # then asks a terminal it does not have.
  @credential_env ~w(ANTHROPIC_API_KEY SSH_AUTH_SOCK SSH_AGENT_PID GPG_AGENT_INFO GH_TOKEN
                     GITHUB_TOKEN GIT_ASKPASS SSH_ASKPASS)

  @doc "Every credential name `port_env/4` unsets by NAME. The shape deny is separate."
  @spec credential_env() :: [String.t()]
  def credential_env, do: @credential_env

  @doc """
  Whether `name` is a credential `port_env/4` unsets. `Config` refuses these in `session_env` for
  the same reason it refuses `release_env_name?/1`: the unset wins over a repo's value, and only
  under the daemon, so a configured credential would vanish where nothing could see it.
  """
  @spec credential_env_name?(String.t()) :: boolean()
  def credential_env_name?(name), do: name in @credential_env

  # THE NAME LIST ABOVE IS CALIBRATED TO ONE ENVIRONMENT AND THERE ARE TWO. Under systemd the
  # daemon's environment is the unit's, which carries no credential at all; `mix loopctl.serve`
  # (Mix.Tasks.Loopctl.Serve) sets LOOPCTL_RUNNER_DAEMON=1, joins the pool and accepts dispatches
  # from the OPERATOR'S LOGIN SHELL, where 41 names matching token/secret/key/password/api/
  # credential were counted on minis, 2026-09-16 — none of them on the list, every one of them
  # subtracted from nothing and handed to a session with a Bash tool.
  #
  # THIS IS A HEURISTIC OVER A HOSTILE-BY-DEFAULT ENVIRONMENT, not a guarantee. It catches the
  # conventional spellings and misses a credential named for what it opens (a bare `NPM_AUTH`, a
  # `PGPASSFILE` pointing at a file) — a shape deny cannot do better, because the set it must
  # exclude is open. THE REAL FIX IS TO CONSTRUCT THE ENVIRONMENT INSTEAD OF SUBTRACTING FROM IT:
  # enumerate what a session legitimately needs (PATH, HOME, LANG, the asdf and XDG furniture)
  # and pass only that, which turns every unknown name into a default-deny. That is a bigger
  # change than this one and it fails LOUDLY when the enumeration is short — the runner stops
  # building rather than leaking — which is why it is the right answer and not a drop-in.
  @credential_shapes ~w(TOKEN SECRET PASSWORD PASSWD PASSPHRASE CREDENTIAL API_KEY PRIVATE_KEY)

  @doc """
  Whether `name` has the SHAPE of a credential, whatever this runner knows about it by name.

  Matched case-insensitively against the conventional spellings, plus a `_KEY` suffix or infix,
  which is what `AWS_SECRET_ACCESS_KEY`, `HEX_API_KEY` and `FLY_API_TOKEN` have in common and
  what `HOME`, `PATH`, `LANG`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` do not.
  """
  @spec credential_shaped?(String.t()) :: boolean()
  def credential_shaped?(name) do
    up = String.upcase(name)

    Enum.any?(@credential_shapes, &String.contains?(up, &1)) or
      String.ends_with?(up, "_KEY") or String.contains?(up, "_KEY_")
  end

  @doc """
  The names in `env` that have a credential's shape, sorted — what the name list cannot enumerate.
  """
  @spec credential_shaped_env(%{String.t() => String.t()}) :: [String.t()]
  def credential_shaped_env(env) do
    env
    |> Map.keys()
    |> Enum.filter(&credential_shaped?/1)
    |> Enum.sort()
  end

  # A DIFFERENT CLASS from the list above, and "is it a credential?" is the wrong test for it:
  # these name a PROGRAM GIT EXECUTES for every transport operation. Whatever puts a value in the
  # daemon's environment gets arbitrary code run by every git call an unattended session makes,
  # with no credential anywhere in the picture — and a value that merely redirects `ssh` also
  # decides which identity git authenticates with, so it overrides a deploy key silently.
  # `Config` needs no companion check here: `@reserved_env` already refuses every `GIT_` name in
  # `session_env`, which is why `credential_env_name?/1` stays about credentials only.
  @git_program_env ~w(GIT_SSH_COMMAND GIT_SSH)

  @doc "Every name `port_env/4` unsets because it names a program git executes."
  @spec git_program_env() :: [String.t()]
  def git_program_env, do: @git_program_env

  @doc """
  What `port_env/4` unsets, for the daemon's `env` and the `{name, value}` pairs a caller supplies.

  TWO RULES, AND THEY DIFFER ON PURPOSE. The name lists are UNCONDITIONAL: every name in them is
  unset whatever anyone supplies, because each is a credential this runner knows by name or a
  program git executes, and there is no session that wants one. The SHAPE deny is a heuristic over
  an environment nobody enumerated, and a heuristic is wrong sometimes — `SECRET_KEY_BASE` for a
  test env, a `*_PUBLISHABLE_KEY` that is public by design, a `*_TOKENS` tuning knob. So a shaped
  name a caller supplies DELIBERATELY is not unset: the operator naming it in the config's
  `session_env` has made the judgement the shape cannot, for the one repo that needs it.

  That escape hatch is deliberately `session_env` and deliberately not a keep-list in this module.
  A keep-list here would apply to every repo, session and machine, for ever, with nobody
  revisiting it — an unscoped exemption is a silent global disable (KB 7a9afe2e), and enumerating
  safe spellings fails the same way enumerating dangerous ones does (KB 909ba2b2). `session_env`
  is per repo, in a mode-600 file only the operator writes, and revocable in one place.
  """
  @spec unset_names(%{String.t() => String.t()}, [{String.t(), String.t()}]) :: [String.t()]
  def unset_names(env, extra) do
    supplied = MapSet.new(extra, fn {name, _value} -> name end)
    shaped = Enum.reject(credential_shaped_env(env), &MapSet.member?(supplied, &1))

    @credential_env ++ @git_program_env ++ shaped ++ Worktree.repo_locating_env()
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

    env = System.get_env()
    unset = unset_names(env, extra)
    log_shaped(session_id, credential_shaped_env(env), unset)

    # The repo's own session_env comes after PATH, so a configured PATH still wins; the names
    # release_env/1 unsets are refused in session_env by Config, so nothing there is lost.
    #
    # THE DEPLOY KEY CANNOT BE WIRED BY EITHER OBVIOUS ROUTE, and both are closed for different
    # reasons. GIT_SSH_COMMAND is unset UNCONDITIONALLY above, so a value supplied in the BASE
    # environment — `Environment=` in rel/systemd/loopctl-runner.service, `EnvironmentVariables`
    # in the launchd plist, which is where a per-machine key would naturally go — never reaches a
    # session at all. And the unsets are appended AFTER `extra`, so for a name in both THE UNSET
    # WINS and a value passed through `:env` is removed again; re-ordering these two `Enum.map`s
    # is what would fix that half, and it would NOT recover the service-definition half.
    # Whoever wires the deploy key must supply the command by a path the unset cannot reach — an
    # explicit option this module reads, not an environment variable it also deletes.
    #
    # The one exception to that ordering, and it is expressed as a SUBTRACTION rather than a
    # re-order: a SHAPED name the caller supplies is never put in `unset` at all (`unset_names/2`),
    # so it survives whatever the order is. Re-ordering these two `Enum.map`s would have made
    # EVERY unset overridable by any `:env` caller — ANTHROPIC_API_KEY included — which is a much
    # larger grant than the one being made.
    #
    # Unsetting GIT_SSH_COMMAND is itself a WIDENING and is kept deliberately: git falls back to
    # plain `ssh`, which reads the inherited `~/.ssh/config` and offers the operator's key, so
    # this removes an operator's restriction as readily as an attacker's redirection. It stays
    # because the value is also arbitrary code git executes, and because nothing legitimately
    # sets it today; the moment something does, it needs the explicit path above.
    # `LoopctlRunner.RunTest` has a characterisation test naming today's `extra` behaviour.
    Enum.map(base ++ release_path(env) ++ extra, fn {k, v} ->
      {to_charlist(k), to_charlist(v)}
    end) ++
      Enum.map(unset ++ release_env(env), &{to_charlist(&1), false})
  end

  # A silent irreversible subtraction is worse than a loud one even when it is right: without this
  # an operator meets the shape deny as a build that fails for no stated reason, with the name
  # they need nowhere in any log. NAMES ONLY, never values — this is written on every session
  # start, on a machine whose environment carries live credentials.
  defp log_shaped(session_id, shaped, unset) do
    {dropped, kept} = Enum.split_with(shaped, &(&1 in unset))
    # The advice is only true for names session_env would ACCEPT. A name on @credential_env is
    # unset unconditionally and Config refuses it there, so recommending it produces a config that
    # will not load — which raises in daemon_children!/0 and aborts the release preflight, for a
    # name this line suggested. A lowercase one has no hatch either: the shape test upcases and
    # the config's name format does not.
    {hatchable, unconditional} = Enum.split_with(dropped, &Config.session_env_allows?/1)

    case notes(hatchable, unconditional, kept) do
      [] -> :ok
      notes -> Logger.info("session #{session_id}: " <> Enum.join(notes, "; "))
    end
  end

  defp notes(hatchable, unconditional, kept) do
    [
      if(hatchable != [],
        do:
          "unsetting #{length(hatchable)} credential-shaped name(s): " <>
            Enum.join(hatchable, ", ") <>
            " (name one in this repo's session_env to keep it)"
      ),
      if(unconditional != [],
        do: "unset unconditionally, with no way to keep them: " <> Enum.join(unconditional, ", ")
      ),
      if(kept != [], do: "kept by session_env: " <> Enum.join(kept, ", "))
    ]
    |> Enum.reject(&is_nil/1)
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
