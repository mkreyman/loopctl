defmodule LoopctlRunner.TriageRun do
  @moduledoc """
  One triage dispatch, run to a verdict (design §4).

  Shaped like `LoopctlRunner.Run` and deliberately not sharing it: an implement run's whole
  middle is a worktree — created, branched, torn down, kept when it holds work — and a triage run
  has none. It reads the repository checkout where it is, states one verdict, and writes nothing
  else. What the two share is the run directory, the state file, the trace and the process-group
  discipline, which is why those come from the same modules.

  The order matters and each step is a precondition of the next:

    1. the run directory and `state.json`, so a crash is attributable before anything runs;
    2. the two tokens (`LoopctlRunner.TriageVerdict.mint_token/1` and `mint_escalate_token/1`),
       minted BEFORE the prompt is built because the prompt carries them — they are what make the
       verdict and the escalation the SESSION's rather than something a subagent it dispatches
       could state;
    3. the prompt, from the fenced report and the lenses this run actually grants;
    4. the session, with `LoopctlRunner.TriageTools`' contained set rather than the implement
       one;
    5. the verdict, read and validated against the contract before anything believes it.

  The outcome is one of `{:verdict, verdict}`, `{:incomplete, reason, detail}` or
  `{:error, reason}`. The incomplete reasons are the ones loopctl declared for `triage_verdict` in
  contract 1.9.0 — which this repo has NOT vendored yet (1.8.0 is current here, and carries no
  `incomplete` concept at all), so they are a local vocabulary chosen to match until the vendor
  pins them. They describe what the SESSION
  did: `session_crashed`, `wall_clock_exceeded`, `no_verdict_written` (including an escalation,
  whose own words go in the detail), and `verdict_invalid`. What the RUNNER could not do — no
  checkout, a budget over the configured ceiling, a verdict file it could not read — is
  `{:error, _}`, because none of those is the session's mistake to be reported as.
  """

  require Logger

  alias LoopctlRunner.{
    Config,
    Owner,
    Run,
    RunState,
    Session,
    Story,
    Trace,
    TriagePrompt,
    TriageTools,
    TriageVerdict
  }

  @type outcome ::
          {:verdict, map()}
          | {:incomplete, String.t(), String.t()}
          | {:error, String.t()}

  @type result :: %{
          run_id: String.t(),
          run_dir: String.t(),
          outcome: outcome(),
          session: Session.result() | nil
        }

  @doc """
  Runs `triage` (a `RunnerTriage` object) for `repo` in its local checkout.

  Options: `:binding` (written into `state.json`, the dispatch this run answers), `:lenses`
  (default `TriageTools.lenses/0`), `:wall_clock_s`, `:max_turns`, `:model`, `:run_id`.
  """
  @spec execute(Config.t(), map(), String.t(), keyword()) :: result()
  def execute(%Config{} = config, triage, repo, opts \\ []) do
    run_id = Keyword.get_lazy(opts, :run_id, &Session.uuid4/0)

    case record_id(triage) do
      {:ok, record} -> start(config, triage, repo, record, run_id, opts)
      {:error, reason} -> %{run_id: run_id, run_dir: nil, session: nil, outcome: {:error, reason}}
    end
  end

  # A uuid, checked before it is ever part of a path. This module does not validate the triage
  # object — the accept path does — and a record_id carrying `/` or `..` would put the run
  # directory outside runs_dir, where RunState.all/1 and the reaper's glob cannot see it: a run
  # nothing reaps and nothing reports.
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  defp record_id(%{"record_id" => id}) when is_binary(id) do
    if id =~ @uuid,
      do: {:ok, String.downcase(id)},
      else: {:error, "record_id #{inspect(id)} is not a uuid"}
  end

  defp record_id(_triage), do: {:error, "the triage object names no record_id"}

  defp start(config, triage, repo, record, run_id, opts) do
    run_dir = run_dir(config, record, run_id)

    RunState.update(
      run_dir,
      Keyword.get(opts, :binding, %{})
      |> Map.merge(%{
        "run_id" => run_id,
        "kind" => "triage",
        "record_id" => record,
        "repo" => repo,
        "status" => "running"
      })
      # Without the owner, Reaper.orphan? reads a LIVE triage run as an orphan — every state
      # lacking beam_os_pid is — so the next implement dispatch reaps first and kills its session.
      # The verdict is then never stated, by the runner's own hand.
      |> Map.merge(Owner.current())
    )

    {:ok, trace} = Trace.start_link(Path.join(run_dir, "trace.ndjson"), run_id)
    seq = Trace.emit(trace, "triage.started", nil, %{"record_id" => record, "repo" => repo})

    result =
      try do
        run(config, triage, repo, run_dir, run_id, trace, seq, opts)
      catch
        # EVERY way out, as `Run.execute/3` does: Session.run/1 exits on a launch or monitor
        # failure by design, and a raise anywhere in here would otherwise leave the run recorded
        # "running" with no outcome and no triage.finished — indistinguishable from one still
        # going, and now un-reaped too, because the owner this run records is alive.
        kind, reason ->
          %{
            run_id: run_id,
            run_dir: run_dir,
            session: nil,
            outcome: {:error, "the run failed: #{Exception.format(kind, reason, [])}"}
          }
      end

    finish(trace, seq, run_dir, result)
    result
  end

  # Guarded too: `RunState.update/2` writes and renames, and a full volume or a run directory the
  # session removed would otherwise raise HERE — leaving state.json at "running" with this BEAM's
  # live owner recorded, which is precisely the combination the reaper will never clean up.
  defp finish(trace, seq, run_dir, result) do
    name = outcome_name(result.outcome)
    Trace.emit(trace, "triage.finished", seq, %{"outcome" => name})
    Trace.close(trace)

    RunState.update(run_dir, %{
      "status" => name,
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    :ok
  rescue
    error -> Logger.error("the triage run's end could not be recorded: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.error("the triage run's end could not be recorded: #{inspect({kind, reason})}")
  end

  defp run(config, triage, repo, run_dir, run_id, trace, seq, opts) do
    with {:ok, name, path} <- checkout(config, repo),
         :ok <- budgets(config, opts),
         {:ok, token} <- TriageVerdict.mint_token(run_dir),
         {:ok, escalate} <- TriageVerdict.mint_escalate_token(run_dir) do
      lenses = Keyword.get(opts, :lenses, TriageTools.lenses())

      prompt =
        TriagePrompt.build(triage, repo, token: token, escalate_token: escalate, lenses: lenses)

      # Caught HERE, not only by the outer guard: Session.run/1 exits when its monitor dies, and
      # the outer catch would return {:error, _} without ever reading the run directory — throwing
      # away a verdict the session had already written and linked into place. `Run` catches the
      # same exit locally for the same reason.
      session =
        try do
          session(config, prompt, {name, path}, run_dir, run_id, trace, seq, opts)
        catch
          # Only :exit, as `Run.run_session/7` does. A raise in here is the runner's own bug and
          # belongs to the outer guard, which reports it as an error rather than dressing it up
          # as something the session did.
          :exit, reason ->
            Trace.emit(trace, "session.crashed", seq, %{"reason" => inspect(reason)})
            {:session_failed, inspect(reason)}
        end

      %{
        run_id: run_id,
        run_dir: run_dir,
        # `:session` is the session's own report or nil; a failure to supervise it is not a
        # report, and it is already carried in the outcome.
        session: if(match?({:session_failed, _}, session), do: nil, else: session),
        outcome: outcome(run_dir, session)
      }
    else
      {:error, reason} ->
        %{run_id: run_id, run_dir: run_dir, session: nil, outcome: {:error, reason}}
    end
  end

  # The checkout is READ, never branched: a triage session judges what is there.
  defp checkout(config, repo) do
    name = repo |> String.split("/") |> List.last()

    case Map.fetch(config.repos, name) do
      {:ok, path} ->
        if File.dir?(path), do: {:ok, name, path}, else: {:error, "#{path} is not a directory"}

      :error ->
        {:error, "#{repo} has no local checkout in repos"}
    end
  end

  # 2: the operator's ceilings bind a triage run exactly as `Story` binds an implement one. A
  # dispatch that asks for more is refused rather than quietly granted.
  defp budgets(config, opts) do
    cond do
      wall_clock_s(config, opts) > config.max_wall_clock_s ->
        {:error, "wall clock #{wall_clock_s(config, opts)}s is over this runner's limit"}

      max_turns(config, opts) > config.max_turns ->
        {:error, "#{max_turns(config, opts)} turns is over this runner's limit"}

      true ->
        :ok
    end
  end

  defp wall_clock_s(config, opts),
    do: Keyword.get(opts, :wall_clock_s, min(1800, config.max_wall_clock_s))

  defp max_turns(config, opts), do: Keyword.get(opts, :max_turns, min(60, config.max_turns))

  defp session(config, prompt, {repo_name, path}, run_dir, run_id, trace, seq, opts) do
    session_id = Session.uuid4()
    wall_clock_s = wall_clock_s(config, opts)
    max_turns = max_turns(config, opts)

    argv =
      TriageTools.claude_args(prompt, session_id, TriagePrompt.system_prompt(),
        max_turns: max_turns,
        model: Keyword.get(opts, :model)
      )

    # A Story only to satisfy what Session records about a run; nothing in the argv comes from it,
    # because `:argv` replaces the implement launcher's whole line.
    story = %Story{
      id: run_id,
      repo: repo_name,
      repo_path: path,
      base: "",
      branch: "",
      prompt: prompt,
      wall_clock_s: wall_clock_s,
      max_turns: max_turns,
      # Recorded so the trace says which model judged this report, not only that one ran.
      model: Keyword.get(opts, :model)
    }

    Session.run(
      config: config,
      story: story,
      worktree: path,
      run_dir: run_dir,
      trace: trace,
      parent: seq,
      session_id: session_id,
      argv: argv,
      # The repo's own knobs, exactly as an implement run gets them: design §4 has a triage
      # session reading the database, and session_env is where an operator configures that.
      env: Config.session_env_for(config, repo_name, run_id, run_id)
    )
  end

  # What the run produced, judged in the order that tells the truth: a verdict the session wrote
  # is the answer even if the session then failed, because it stated it; only then does how the
  # session ended matter.
  defp outcome(run_dir, session) do
    case TriageVerdict.read(run_dir) do
      {:ok, verdict} -> {:verdict, verdict}
      {:error, :none} -> incomplete(run_dir, session)
      {:error, {:invalid, reason}} -> {:incomplete, "verdict_invalid", reason}
      # The runner could not read what the session wrote. Reporting that as an invalid verdict
      # would blame the session for an operator's failing volume or mode change.
      {:error, {:unreadable, reason}} -> {:error, reason}
    end
  end

  # Order matters: the runner's own reasons first, because it KNOWS them, and a parked session's
  # TERM shows up as a non-zero exit that would otherwise read as a crash.
  #
  # First of all, the session monitor dying: whatever it wrote still counts, and outcome/2 has
  # already looked, so reaching here means there was no verdict to keep.
  defp incomplete(_run_dir, {:session_failed, detail}),
    do: {:incomplete, "session_crashed", "the session could not be supervised: #{detail}"}

  defp incomplete(_run_dir, %{reason: :wall_clock_exceeded}),
    do: {:incomplete, "wall_clock_exceeded", "the session ran out of wall clock"}

  defp incomplete(_run_dir, %{reason: reason}) when reason in [:parked, :not_group_leader],
    do: {:incomplete, "no_verdict_written", "the runner stopped the session: #{reason}"}

  # An escalation says the session judged it could not work at all — never WHY, since the text is
  # its own. `checkout_unreadable` would be the runner asserting a cause it never checked, and
  # sending whoever reads it to a checkout that is fine.
  defp incomplete(run_dir, %{reason: :escalated}),
    do: {:incomplete, "no_verdict_written", "the session escalated: #{escalation_text(run_dir)}"}

  defp incomplete(_run_dir, %{exit_status: status}) when status != 0,
    do: {:incomplete, "session_crashed", "the session exited #{status}"}

  defp incomplete(_run_dir, _session),
    do: {:incomplete, "no_verdict_written", "the session ended without stating a verdict"}

  # The session's own words, decoded out of the line rather than handed on as JSON.
  defp escalation_text(run_dir) do
    case Run.escalations(run_dir) do
      [_ | _] = reasons -> List.last(reasons)
      [] -> "no reason recorded"
    end
  end

  defp outcome_name({:verdict, _}), do: "verdict"
  defp outcome_name({:incomplete, reason, _}), do: "incomplete:#{reason}"
  defp outcome_name({:error, _}), do: "failed"

  defp run_dir(config, record, run_id) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    dir = Path.join(config.runs_dir, "triage-#{record}-#{stamp}-#{binary_part(run_id, 0, 8)}")
    File.mkdir_p!(dir)
    dir
  end
end
