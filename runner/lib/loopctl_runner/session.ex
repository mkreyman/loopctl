defmodule LoopctlRunner.Session do
  @moduledoc """
  One `claude -p` session, wrapped — never supervised directly (design §2).

  Owns the Port, which spawns `priv/bin/session-launcher.sh`, which execs claude-config's
  `claude-headless.sh`, which execs the CLI. Every way this session ends — clean exit,
  wall-clock budget, parked, runner shutdown — ends the launcher's process group AND every
  process carrying this session's `LOOP_SESSION_ID` marker, because the CLI's Bash tool
  detaches its commands into new sessions (see `LoopctlRunner.ProcessGroup`).

  THIS SESSION IS A LOCAL AGENT. Mark, 2026-09-16, in three instructions that settled it: *"All
  agents must run with the yolo mode, the same as I'm running all my sessions now!"*, *"everything
  must inherit my entire user scoped claude setup"*, and *"the same claude setup means the same
  claude setup as the local agents. with the same rules and workflows. the same soul.md, the same
  claude.md, etc"*. So it runs `--permission-mode bypassPermissions`, composes no `--allowedTools`,
  passes no `--setting-sources` and excludes no tool or MCP server (the verify@1 session alone
  passes `--setting-sources user`, which keeps all of the user scope and drops only the project
  scope of the pull request it judges: `LoopctlRunner.VerifyPrompt`). It inherits `SOUL.md`, the user
  `CLAUDE.md`, the hooks, the plugins, the agents, the skills and the MCP set. How it FINISHES is
  the repository's delivery mode, which its prompt states (`LoopctlRunner.DispatchPrompt`): in a
  `pr` repository, the one mode, it runs the operator's delivery loop — open the PR, review, fix
  every finding, wait for green CI — because that is what those files say to do, and stops short
  of the merge, which loopctl's merge gate decides and the runner executes (US-48.17).

  WHAT REMAINS IS NOT A PERMISSION. Each answers "what is physically true of an unattended
  process", never "what should an agent be allowed to do":

    * `--permission-prompts none` — there is no human on the other end. Not "may not ask": asking
      cannot be ANSWERED, and without this a session blocks for ever on a dialog nobody sees.
    * `--max-turns` — a budget loopctl sets per story.
    * `claude-headless.sh` with `ANTHROPIC_API_KEY` unset — a BILLING control, measured at ~USD 300
      in one night when an environment key silently outranked the claude.ai login (KB b38ef90e).
      Not part of anyone's Claude setup. IT IS NOT THE LAST WORD ON THE ENVIRONMENT, though the
      unset order makes it look like one: the inherited settings are loaded AFTER both this and
      `port_env/4`'s scrub, and an `env` block in the inherited settings is applied to the
      session's environment, so it is a third injection path that neither control can see. What
      that block carries is the operator's configuration, not a property of this design.

  WHY LOOPCTL'S MCP TOOLS ARE NOT EXCLUDED, since the argument for it is easy to rebuild. It was going to be
  `--disallowedTools mcp__loopctl__*`, on the ground that a session holding `claim_story` and
  `contract_story` could move the very story it was dispatched to implement, making the actor and
  the record-keeper one process. That is wrong twice over. The story-lifecycle protocol — the
  `loopctl-contract`, `loopctl-status` and `loopctl-mcp` skills, and `/loopctl:implement` — IS
  BUILT ON THOSE TOOLS, so excluding them would have disabled the very workflow it claimed to
  protect. And a locally dispatched `elixir-engineer` holds them today with nobody objecting; if
  the custody model needs a guarantee the tools cannot give, that is loopctl's to solve in
  loopctl, not something this runner papers over by amputating tools.

  THE GENERAL RULE, learned the expensive way in one hour: DENY BY NAME, WITH A REASON PER NAME.
  The first instinct was to deny a class — all MCP, a fixed tool pool — and grant exceptions back;
  that inverts who has to notice a mistake, and it took three corrections to find the two
  capabilities it had silently removed (tidewave, then playwright, then `Agent` and `SendMessage`
  hiding inside `--tools`).

  THE DELIVERY LOOP'S OWN GATES NOW APPLY INSIDE A SESSION, and the first real run is where we
  learn what that costs. The review-round counter, the merge gate (which refuses `gh pr merge` on a
  branch with no counted round) and the drip-feed gate are all hooks in the inherited settings.
  That is wanted — it is the same loop a local session runs — but a session can be BLOCKED by a
  gate it cannot answer, and that will look like a stall rather than a refusal.

  THE STORY LIFECYCLE IS NOT THIS REPO'S. Contract, claim, stage reporting, verification: all of
  it lives in the operator's skills and commands, written for exactly this job. Do not reimplement
  any of it here. The runner cuts the worktree, launches the session, watches the process, tears
  the tree down, and reports the stages it can actually observe: the worktree, the session's
  start, and (US-48.16, through `DispatchRun.observe/4`) what the forge says of a pr-mode
  session's pull request once the session is over.
  """

  use GenServer

  require Logger

  alias LoopctlRunner.{
    Config,
    GitGrant,
    Liveness,
    Owner,
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
          reason:
            :exited
            | :wall_clock_exceeded
            | :max_turns_exceeded
            | :parked
            | :not_group_leader
            | :escalated,
          # Which bound stopped a `:wall_clock_exceeded` session: its own start + `wall_clock_s`,
          # or the dispatch's `deadline_at`. nil for every other end.
          stop_bound: :wall_clock | :deadline | nil,
          duration_ms: non_neg_integer(),
          # `num_turns` of the CLI's last result line (`StreamEvents.turns/1`), nil without one.
          turns_used: non_neg_integer() | nil
        }

  @doc """
  Runs the session to completion and returns its result.

  Options: `:config`, `:story`, `:worktree`, `:run_dir`, `:trace`, `:argv` (the whole argv, for a
  run with its own contained set), `:system_prompt` (what `--append-system-prompt` carries on the
  default argv; the implement session's escalation prompt),
  `:parent` (the run's
  trace seq), and optionally `:session_id`, `:env` (extra `{name, value}` pairs) and
  `:own_worktree` (default false).

  `:own_worktree` says the runner cut this session's worktree on a BRANCH of its own — an implement
  run — and it decides one thing: the subagent git grant, prepared before the launcher starts and
  armed once it has (`LoopctlRunner.GitGrant.prepare/2`, then `LoopctlRunner.GitGrant.arm/2`). It is
  false for a triage run, which has no branch of its own, and false by default so a launcher added
  later gets no grant unless it asks.

  Whether a session may still start under the story's `deadline_at` is the caller's to decide,
  immediately before it calls this (`Story.check_deadline/4`, in `LoopctlRunner.Run` and
  `LoopctlRunner.TriageRun`); here the deadline only fixes when the session is stopped.
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
  (KB 16d4ff67), so escalation is a command it calls: exactly one absolute path, named in the
  prompt. Nothing denies it any more; the path still has to REACH the prompt or a session has no
  way to ask.
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

  # NOTHING LIMITS THE TOOL POOL: the argv names no tool set, so a session has every tool a locally
  # dispatched agent has — `Agent` to dispatch the engineer agent a repo's CLAUDE.md names,
  # `SendMessage` to ask a peer session, `WebFetch` and `WebSearch` to read documentation, `Skill`
  # to load a repo skill. If a tool ever has to be withheld, deny it BY NAME with a reason per
  # name: denying a class and granting exceptions back leaves every capability in that class
  # missing until somebody asks the right question.

  # The argv a run wants. `:argv` is the seam a run with a different contained set uses — a
  # triage run passes `LoopctlRunner.TriageTools.claude_args/4`'s result, which has its own tools,
  # its own rules and the lens definitions. Without it this module would be the only launcher and
  # every run would get the implement session's containment, silently.
  defp argv(story, session_id, opts) do
    case Keyword.get(opts, :argv) do
      nil ->
        claude_args(
          story,
          session_id,
          Keyword.get(opts, :system_prompt, escalation_prompt()),
          Keyword.get(opts, :mcp_args, [])
        )

      argv when is_list(argv) ->
        checked(argv, session_id)
    end
  end

  # A supplied argv is checked for the flags that are mechanically necessary rather than
  # trusted to repeat them. They are not permission controls: without `--permission-prompts none`
  # a session blocks for ever on a dialog nobody will see, and a session running under an id other
  # than the one this module tracks makes a healthy session read as parked, after which the runner
  # terminates it. The session id is
  # checked by VALUE — an argv that merely mentions it (in the prompt, in the agents JSON) while
  # omitting the flag leaves the CLI generating its own, and the marker, LOOP_SESSION_ID and the
  # liveness transcript then key to an id nothing runs under: a healthy session reads as parked,
  # and the runner terminates it.
  @required_argv %{
    "--session-id" => :session_id,
    "--permission-mode" => "bypassPermissions",
    "--permission-prompts" => "none"
  }

  # Pinned only to being there, because its value is the run type's own: a story's turn budget is
  # not a triage run's. Missing, an unattended session has no turn ceiling at all.
  @required_present ~w(--max-turns)

  defp checked(argv, session_id) do
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

  `mcp_args` is spliced in before the system prompt and is `[]` on every dispatched session, so
  their argv is unchanged by it. Only the eval harness sets it (`mcp_isolation/1`).
  """
  @spec claude_args(Story.t(), String.t(), String.t(), [String.t()]) :: [String.t()]
  def claude_args(
        %Story{} = story,
        session_id,
        system_prompt \\ escalation_prompt(),
        mcp_args \\ []
      ) do
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
      "bypassPermissions",
      "--permission-prompts",
      "none",
      "--max-turns",
      Integer.to_string(story.max_turns)
    ] ++
      if(story.model, do: ["--model", story.model], else: []) ++
      mcp_args ++
      ["--append-system-prompt", system_prompt] ++
      ["--", story.prompt]
  end

  @doc """
  The MCP isolation an EVAL session runs under, and nothing else ever does: `--strict-mcp-config`
  with `--mcp-config` naming `config_path`, a file holding `{"mcpServers":{}}`. The CLI then loads
  no MCP server at all, the operator's loopctl entry included, whose own `env` names the server and
  its keys, so no session environment can redirect it (US-48.10, AC-48.10.5: an eval never reaches
  the production socket). A dispatched session never gets this: it keeps the operator's MCP set,
  as the runner's CLAUDE.md posture requires.
  """
  @spec mcp_isolation(String.t()) :: [String.t()]
  def mcp_isolation(config_path), do: ["--strict-mcp-config", "--mcp-config", config_path]

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    %Config{} = config = Keyword.fetch!(opts, :config)
    %Story{} = story = Keyword.fetch!(opts, :story)
    trace = Keyword.fetch!(opts, :trace)
    run_dir = Keyword.fetch!(opts, :run_dir)
    worktree = Keyword.fetch!(opts, :worktree)
    session_id = Keyword.get(opts, :session_id) || uuid4()
    # Built, and checked, BEFORE anything is written outside the run directory: `checked/2`
    # raises here, and a grant armed ahead of it would leak on every refused argv.
    checked_argv = argv(story, session_id, opts)

    stderr_log = Path.join(run_dir, "stderr.log")
    {:ok, stdout_io} = File.open(Path.join(run_dir, "stdout.ndjson"), [:append, :binary])
    tree_file = Path.join(run_dir, "stderr.log.tree")
    RunState.update(run_dir, %{session_id: session_id, tree_file: tree_file, status: "running"})

    # LIVE, because a session loads the operator's user settings: `block-subagent-git.sh` is one of
    # their hooks, and without this grant it refuses the commit of every engineer agent the session
    # dispatches, while that agent's report reads as having chosen not to commit.
    #
    # ARMED ONLY FOR A RUN ON A BRANCH OF ITS OWN (`:own_worktree`), which is the only place the
    # grant's reason holds (`LoopctlRunner.GitGrant`): an engineer agent committing to the branch
    # the runner cut for this story. A triage run has no branch of its own to commit to. PREPARED
    # here, with this BEAM as its owner, and armed once the Port is open, below: nil when it could
    # not be prepared, so the session is told of no grant that cannot exist.
    grant_path =
      if Keyword.get(opts, :own_worktree, false), do: prepare_grant(config, session_id)

    # terminate/2 does not run for an init that raises, and the grant's owner is the BEAM this
    # runs in — the daemon's, which outlives the session. Whatever raises once the grant is
    # prepared disarms it first, pending file and grant alike (either not written is simply not
    # there to remove).
    try do
      port =
        Port.open({:spawn_executable, launcher_script()}, [
          :binary,
          :exit_status,
          cd: worktree,
          args: [stderr_log, config.claude_launcher | checked_argv],
          env:
            port_env(
              run_dir,
              session_id,
              config,
              # WHERE the grant is, when one was prepared — not that there is one: the file is the
              # grant, and arming it comes after this fork (`LoopctlRunner.GitGrant`). The session
              # can compute the path anyway from its own id and HOME, so this hands over nothing
              # new; what it buys is that the path a session sees is the one the runner ARMS, which
              # a test's directory makes differ. UNSET when this session has none — none asked for,
              # or none that could be prepared — so a value in the runner's own environment is
              # never passed off as this session's.
              Keyword.get(opts, :env, []) ++ [{"LOOP_GIT_GRANT", grant_path || false}]
            )
        ])

      # A launcher that exits before this line has closed its Port, and `Port.info/2` is nil for a
      # closed one. That is a failed start, named as one: the exit is caught below, the grant is
      # disarmed, and `run/1` reports `{:session_start_failed, :launcher_exited_at_start}`.
      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> os_pid
          nil -> exit(:launcher_exited_at_start)
        end

      # The stop bound is fixed HERE, where the session has started: the earlier of this start +
      # wall_clock_s and the moment it must be signalled to be gone by the dispatch's deadline_at —
      # deadline_at less the kill grace (TERM, then up to kill_grace_s before KILL) and the
      # clock-skew margin (`Story.stop_after/4`, `Story.deadline_margin_s/0`).
      {stop_after_ms, stop_bound} =
        Story.stop_after(
          story,
          DateTime.utc_now(),
          config.kill_grace_s,
          Story.deadline_margin_s()
        )

      # ONE reading of the launcher, for the grant's session line and for `leader_start` alike: two
      # would be two answers about one process, taken at two moments.
      launcher = Owner.of(os_pid)
      grant = arm_grant(grant_path, launcher)

      # From that one reading: the launcher's start in the kernel's form, which ProcessGroup compares
      # a leader by (`Owner.start_id/1`), and the local `ps lstart` a runner before #66 compares
      # instead.
      leader_start_id = launcher["beam_start_id"]
      leader_start = Owner.lstart(launcher)

      RunState.update(run_dir, %{
        pgid: os_pid,
        leader_start: leader_start,
        leader_start_id: leader_start_id
      })

      now = now_ms()

      session_seq =
        Trace.emit(trace, "session.started", Keyword.fetch!(opts, :parent), %{
          "session_id" => session_id,
          "os_pid" => os_pid,
          "cwd" => worktree,
          "launcher" => config.claude_launcher,
          "max_turns" => story.max_turns,
          "wall_clock_s" => story.wall_clock_s,
          "deadline_at" => deadline_iso(story),
          "stop_after_ms" => stop_after_ms,
          "stop_bound" => Atom.to_string(stop_bound),
          "model" => story.model
        })

      Process.send_after(self(), :wall_clock, stop_after_ms)
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
         # The grant this session armed, or nil: teardown removes the path that was WRITTEN rather
         # than recomputing one, so a config whose directory moved cannot leave the file behind.
         grant: grant,
         tree_file: tree_file,
         leader_start: leader_start,
         leader_start_id: leader_start_id,
         session_seq: session_seq,
         stream: StreamEvents.new(session_seq),
         stdout_io: stdout_io,
         partial: "",
         escalation_file: Path.join(run_dir, "escalations.ndjson"),
         escalations_seen: 0,
         started_ms: now,
         last_stdout_ms: now,
         stop_bound: stop_bound,
         # The ref of the agents probe in flight (`start_probe/1`), or nil: one at a time.
         probe: nil,
         reason: nil
       }}
    catch
      kind, reason ->
        GitGrant.disarm(grant_path)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # PREPARED BEFORE THE PORT OPENS, SO THE SESSION IS TOLD THE TRUTH. `LOOP_GIT_GRANT` is fixed at
  # the fork, so whether to set it has to be decided before the launcher's pid exists: the owner
  # line is written to a pending name first, and only a grant whose write succeeded is announced.
  # A failure is logged by `GitGrant.prepare/2` and the session runs with the variable unset.
  defp prepare_grant(config, session_id) do
    case GitGrant.prepare(config, session_id) do
      {:ok, path} -> path
      {:error, _} -> nil
    end
  end

  # ARMED AFTER THE PORT OPENS, THE LAUNCHER JOINING THE OWNER IN THE ONE RENAME. A grant visible
  # before the launcher's line was in it would name only this BEAM, which outlives the session, so
  # a Session killed outright would leave a grant no sweep removed while the daemon lived. The gap
  # this opens is harmless: nothing in the session can use the grant before its first tool call,
  # seconds after launch, while this lands milliseconds after the fork; a Session killed before it
  # leaves a pending file the sweep removes once its owner is gone. An arm that fails here leaves
  # `LOOP_GIT_GRANT` naming a path that holds no grant, which is what that variable means: the
  # FILE is the grant, and a session that finds none has none. `GitGrant.arm/2` logs it.
  defp arm_grant(nil, _launcher), do: nil

  defp arm_grant(path, launcher) do
    case GitGrant.arm(path, launcher) do
      {:ok, path} -> path
      {:error, _} -> nil
    end
  end

  # The one credential a session does not inherit, and it is a BILLING control rather than a
  # permission: ANTHROPIC_API_KEY outranks the claude.ai login (~USD 300 in one night, KB
  # b38ef90e), which is why `claude-headless.sh` unsets it too (Config refuses any other launcher)
  # — this is the same removal one layer earlier. Everything else in the daemon's environment
  # reaches the session, as it reaches an attended one. Mark, 2026-09-27: "unattended sessions
  # should enjoy the same permissions as attended sessions -- no less."
  @credential_env ~w(ANTHROPIC_API_KEY)

  @doc "Every credential name `port_env/4` unsets."
  @spec credential_env() :: [String.t()]
  def credential_env, do: @credential_env

  @doc """
  What `port_env/4` unsets: the billing credential and the variables that point git at another
  repository. Unconditional: a caller's `:env` does not keep one.
  """
  @spec unset_names() :: [String.t()]
  def unset_names, do: @credential_env ++ Worktree.repo_locating_env()

  defp port_env(run_dir, session_id, config, extra) do
    base =
      [
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

    # The repo's own session_env comes after PATH, so a configured PATH still wins; the names
    # release_env/1 unsets are refused in session_env by Config, so nothing there is lost.
    # A `false` value in `extra` unsets that name, as it does for an Erlang Port: it is how the
    # grant's variable is kept from a session that has no grant.
    Enum.map(base ++ release_path(env) ++ verdict_check(env) ++ extra, fn
      {k, false} -> {to_charlist(k), false}
      {k, v} -> {to_charlist(k), to_charlist(v)}
    end) ++
      Enum.map(unset_names() ++ release_env(env), &{to_charlist(&1), false})
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

  @doc """
  `LOOP_VERDICT_CHECK`, the release's own `bin` script, as a `{name, value}` pair, or nothing when
  the runner is not a release. `loop-verdict` runs it as `eval` to judge a verdict with
  `LoopctlRunner.TriageVerdict.check_file/1` before recording it, so a session hears that its
  verdict breaks the contract while it can still correct it. The `RELEASE_*` names stay unset
  (`release_env/1`): this passes the one path the check needs and not the node's cookie, and the
  eval VM it starts is not distributed.

  Advisory, never a gate: a session can unset it for its own call, and the daemon still judges
  the recorded file with `TriageVerdict.read/1`. Unset, `loop-verdict` records unchecked.
  """
  @spec verdict_check(%{String.t() => String.t()}) :: [{String.t(), String.t()}]
  def verdict_check(%{"RELEASE_ROOT" => root}) when root != "" do
    bin = Path.join([Path.expand(root), "bin", "loopctl_runner"])
    if File.regular?(bin), do: [{"LOOP_VERDICT_CHECK", bin}], else: []
  end

  def verdict_check(_env), do: []

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
    reason = exit_reason(state.reason, status, StreamEvents.result(state.stream))
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
      stop_bound: if(reason == :wall_clock_exceeded, do: state.stop_bound),
      duration_ms: now_ms() - state.started_ms,
      # The CLI's own count from its last result line, nil when it printed none (contract 1.27.0).
      turns_used: StreamEvents.turns(state.stream)
    }

    # Disarmed BEFORE the waiter hears: a result in hand means the grant is gone, so nothing
    # acting on the result — the next run's sweep, a shutdown, a test — can see it still armed.
    GitGrant.disarm(state.grant)
    send(state.waiter, {:session_result, self(), result})
    {:stop, :normal, %{state | port: nil, grant: nil}}
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

  # A stop at deadline_at is this one timer too — the contract calls deadline_at "A STOP BOUND: end
  # the session by the EARLIER of your own start + `wall_clock_seconds` and this instant" — and the
  # result's `stop_bound` says which end fired. They are REPORTED differently, which is the runs'
  # business, not this process's: a deadline stop is no budget the story overran
  # (`LoopctlRunner.Run`, `LoopctlRunner.DispatchRun.session_ended/2`).
  def handle_info(:wall_clock, state) do
    data = %{
      "wall_clock_s" => state.story.wall_clock_s,
      "deadline_at" => deadline_iso(state.story),
      # Which of the two ends this was, so a reader of the trace need not do the arithmetic.
      "stopped_by" => Atom.to_string(state.stop_bound)
    }

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
    schedule_tick(state.config)
    {:noreply, observe(state)}
  end

  # The agents probe's answer. Judged only while the session is still running unstopped: one that
  # lands after a stop is stale, and the stop already decided the session's end.
  def handle_info({ref, status}, %{probe: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | probe: nil}

    if state.port != nil and state.reason == nil,
      do: {:noreply, judge_probe(state, status)},
      else: {:noreply, state}
  end

  # A probe that died answered nothing, which is not evidence either way: the next tick asks again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{probe: ref} = state),
    do: {:noreply, %{state | probe: nil}}

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  # Anything else — a late message from a closed probe Port, a stray timer — must not
  # crash the monitor: terminate/2 would kill a healthy session.
  def handle_info(message, state) do
    Trace.emit(state.trace, "session.unexpected_message", state.session_seq, %{
      "message" => inspect(message, limit: 5)
    })

    {:noreply, state}
  end

  # Every end but a normal exit, whose handler has already disarmed (and cleared `grant`). The tree
  # is killed FIRST: removed while the session still runs, the grant would have the hook refuse a
  # commit its subagent is making during the kill's grace period. Disarmed in `after`, because the
  # kill can raise, and this BEAM — the grant's owner — lives on, so no sweep would remove it.
  @impl true
  def terminate(_reason, %{grant: grant, port: port} = state) do
    if port != nil, do: ProcessGroup.terminate(state.os_pid, grace_ms(state), kill_opts(state))
  after
    GitGrant.disarm(grant)
  end

  # The agents probe spawns a CLI, so it runs only once the cheap signals are quiet, and only one
  # at a time: a tick that finds one in flight leaves it to answer.
  defp observe(state) do
    case Liveness.evaluate(observation(state, :unknown), window_ms(state)) do
      {:active, _} -> state
      _ when state.probe != nil -> state
      _ -> %{state | probe: start_probe(state)}
    end
  end

  # OFF this process: the probe can take up to `agents_probe_timeout_s`, and a Session blocked on
  # it would hold every message behind it — the wall clock and deadline stop above all, which would
  # then kill the session that much after the deadline loopctl's lease sweep acts on. Linked, so it
  # dies with a Session that is killed; a Session that ends normally leaves it to its own timeout,
  # which kills the CLI it started, and its answer goes nowhere. This process traps exits, so a
  # probe that crashes is an `{:EXIT, _, _}` ignored below and a `:DOWN` handled above.
  defp start_probe(%{config: config, session_id: session_id}) do
    %Task{ref: ref} =
      Task.async(fn ->
        Liveness.agent_status(
          config.claude_launcher,
          session_id,
          config.agents_probe_timeout_s * 1000
        )
      end)

    ref
  end

  # Judged on a FRESH reading of the cheap signals, not the one that sent the probe: this process
  # kept handling the Port while the probe ran, so output that arrived meanwhile is in
  # `last_stdout_ms` already.
  defp judge_probe(state, status) do
    verdict =
      state
      |> observation(status)
      |> Liveness.evaluate(window_ms(state))
      |> unless_port_spoke(state.port)

    Trace.emit(state.trace, "session.liveness", state.session_seq, verdict_data(verdict))

    case verdict do
      {:parked, evidence} -> stop_session(state, :parked, evidence)
      _ -> state
    end
  end

  defp observation(state, agent_status) do
    files = Liveness.file_signals(state.config.claude_projects_dir, state.session_id)

    %{
      now_ms: now_ms(),
      last_stdout_ms: state.last_stdout_ms,
      transcript_mtime_ms: files.transcript_mtime_ms,
      subagents_mtime_ms: files.subagents_mtime_ms,
      agent_status: agent_status
    }
  end

  defp window_ms(state), do: state.config.park_after_s * 1000

  # Output queued in the mailbox BEHIND the probe's answer has not reached `last_stdout_ms` yet: the
  # CLI may have printed its result and be exiting, which also makes `claude agents` report it
  # absent. It is activity.
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
  Why a session ended, given the stop already under way (if any), the exit status and the
  `subtype` of the CLI's last `result` line (`StreamEvents.result/1`).

  A CLI that exits 0 exited on its own, even if a park stop had begun: that stop's TERM
  would have ended the launcher with 143. A CLI whose result line says `error_max_turns` ran out
  of the `--max-turns` budget (the subtype 2.1.283 prints), which the runner could not otherwise
  tell from any other failing exit; it outranks a park for the same reason an exit 0 does — the
  CLI had already stopped on its own — and never a wall-clock stop or an escalation, which the
  runner or the session chose.
  """
  @spec exit_reason(atom() | nil, non_neg_integer(), String.t() | nil) :: atom()
  def exit_reason(reason, status, result \\ nil)

  def exit_reason(reason, _status, "error_max_turns") when reason in [nil, :parked],
    do: :max_turns_exceeded

  def exit_reason(:parked, 0, _result), do: :exited
  def exit_reason(nil, _status, _result), do: :exited
  def exit_reason(reason, _status, _result), do: reason

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
      leader_start: state.leader_start,
      leader_start_id: state.leader_start_id
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

  defp deadline_iso(%Story{deadline_at: nil}), do: nil
  defp deadline_iso(%Story{deadline_at: deadline}), do: DateTime.to_iso8601(deadline)
end
