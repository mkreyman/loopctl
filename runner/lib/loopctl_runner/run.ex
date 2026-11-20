defmodule LoopctlRunner.Run do
  @moduledoc """
  Build order step 1a, end to end: one hand-filed story, one machine, merging nothing.

      reap orphans -> run dir + state -> worktree -> session -> teardown

  Every step lands in the run's trace under one root event, and every side effect's
  identity is in `state.json` before the side effect happens.

  A run is identified by a UUID (`run_id`, in `state.json`, every trace line and the
  worktree lock). Its directory under `runs_dir` has a readable name instead,
  `<story id>-<UTC stamp>-<first 8 hex of the run id>`:

      <dir>/story.json      the validated story, written at run start and again once a
                            `:prompt` builder has built the prompt its session is given
      <dir>/state.json      side-effect identities and status (RunState)
      <dir>/trace.ndjson    the parent-linked event stream (Trace)
      <dir>/stdout.ndjson   the CLI's stream-json, verbatim
      <dir>/stderr.log      the CLI's stderr
  """

  alias LoopctlRunner.{
    ClaimEnded,
    Config,
    Owner,
    Reaper,
    RunState,
    Session,
    Story,
    Trace,
    Worktree,
    WorktreeLock
  }

  @type result :: %{
          required(:run_id) => String.t(),
          required(:run_dir) => String.t(),
          required(:status) => String.t(),
          required(:session) => Session.result() | nil,
          required(:teardown) => map() | nil,
          required(:error) => String.t() | nil,
          # Set by a run that stopped short of the stage its teardown implies: a refused prompt.
          optional(:reached) => String.t()
        }

  @typedoc """
  What `:on_stage` is called with, in this order: `{:started, %{run_id, run_dir}}` once
  `state.json` exists; `{:worktree, %{branch, worktree_path}}` once the worktree exists;
  `{:implementing, %{}}` as the session starts; `{:observed, stages}` once the session is over,
  when the run's `:observe` saw any (each `%{"to" => stage, "effects" => map}`, in order, already
  in `state.json` as `observed_stages`); and `{:finished, summary}` however the run ends (a raise
  included, just before it is re-raised), whose summary names the stage the run `reached`. A run
  that never gets a worktree goes from `:started` straight to `:finished`, and one whose prompt is
  refused from `:worktree` to `:finished`.
  """
  @type stage_event ::
          {:started, %{run_id: String.t(), run_dir: String.t()}}
          | {:worktree, %{branch: String.t(), worktree_path: String.t()}}
          | {:implementing, map()}
          | {:observed, [map()]}
          | {:finished, map()}

  @doc """
  Runs the story to the end and returns its result.

  Options: `:env` (extra session environment), `:keep_worktree`, `:binding` (a map written into
  the initial `state.json` before anything else happens, e.g. the dispatch this run serves),
  `:on_stage` (a one-argument function called with each `t:stage_event/0`), and `:prompt` (a
  one-argument function given the commit the worktree was cut from and returning `{:ok, prompt}`
  or `{:refuse, reason, detail}`, called once the worktree exists and replacing `story.prompt`:
  `LoopctlRunner.DispatchRun.prompt/4`), `:observe` (a one-argument function given
  `%{cut_from: commit}` once a session that started is over, however it ended, and returning the
  stages it saw, which the run records and announces as `{:observed, stages}`:
  `LoopctlRunner.DispatchRun.observe/4`), and `:mcp_args` (default `[]`; only the eval harness
  sets it, to `LoopctlRunner.Session.mcp_isolation/1`). A refusal starts no session: the worktree is torn down
  and the run ends `refused`, its error naming the reason. A builder that raises tears the
  worktree down too, and the run crashes.

  A story whose `deadline_at` has passed when the run begins (`Story.check_deadline/4`) costs no
  work: no reap, no fetch, no worktree, no session. Its state is written — the binding, and the
  status `deadline_passed` — with `terminal_reported` `skipped` (`RunState.finish/2`), and
  `:finished` reports that status from `claimed`, which `LoopctlRunner.DispatchRun.end_reports/1`
  answers with nothing: escalating the story would call for a human none is needed by, and after
  its deadline the claim is loopctl's lease sweep's to release. One that passes while the tree is
  cut ends the same way from `worktree`, its tree torn down, checked again before `implementing`
  is announced — the last check, immediately before the session.

  A session that STARTED keeps the stop it started with (`Story.stop_after/4`). One its deadline
  stops ends `stopped_at_deadline`, never `wall_clock_exceeded`: it overran no budget of its own,
  and `LoopctlRunner.DispatchRun.session_ended/2` reports it `crashed`, which re-queues the story
  rather than escalating it.
  """
  @summary_key {__MODULE__, :finished_summary}

  @spec execute(Config.t(), Story.t(), keyword()) :: result()
  def execute(%Config{} = config, %Story{} = story, opts \\ []) do
    # `:finished` goes out from ONE place, the `after`, so it is sent exactly once however the run
    # ends: a return, a raise, an exit or a throw, inside the worktree step or after it. The
    # summary it carries is left in the process dictionary by whichever path ended the run.
    Process.delete(@summary_key)
    # The contract identifies a run by UUID; the directory keeps a name a person can find.
    run_id = Session.uuid4()
    run_dir = Path.join(config.runs_dir, run_dir_name(story, run_id))

    try do
      run(config, story, run_id, run_dir, opts)
    catch
      kind, reason ->
        Process.put(@summary_key, unfinished(run_dir, crash_error(kind, reason)))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      stage(
        opts,
        {:finished,
         Process.delete(@summary_key) || unfinished(run_dir, "the run ended without a summary")}
      )
    end
  end

  @doc """
  A caught crash as a run's `error`: the kind first — an exit or a throw has no exception message
  — and the banner, cut to 500 characters.
  """
  @spec crash_error(atom(), term()) :: String.t()
  def crash_error(kind, reason),
    do: "#{kind}: " <> String.slice(Exception.format_banner(kind, reason), 0, 500)

  @doc """
  The summary of a run that did not finish on its own — it raised, exited, or its process or its
  owner died — from what it left on disk, the only account of it that outlives it: the stage it
  recorded reaching (`state.json` `reached`, written BEFORE each stage's side effect, so a run
  never recorded as `implementing` started no session) and what its session escalated with.

  A session that ran `loop-escalate` handed the story to a human, so its run is `escalated` however
  it ended after; `crashed` would lose the escalation and re-queue the story. A run with no
  readable state got no further than its claim, so it reached `claimed`. A state from before
  `reached` was recorded as the run progresses carries none, and gives `nil`: its caller keeps
  the default it always had.
  """
  @spec unfinished(String.t() | nil, String.t()) :: map()
  def unfinished(run_dir, error) do
    escalations = if run_dir, do: escalations(run_dir), else: []

    %{
      status: if(escalations == [], do: "crashed", else: "escalated"),
      error: error,
      escalations: escalations,
      reached: recorded_reached(run_dir),
      # Where the run lives on disk.
      run_dir: run_dir
    }
  end

  defp recorded_reached(nil), do: "claimed"

  defp recorded_reached(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{} = state} -> state["reached"]
      _ -> "claimed"
    end
  end

  defp run(config, story, run_id, run_dir, opts) do
    # THIS BEAM'S IDENTITY FIRST, before anything is written. A run recorded without its owner's
    # start reads dead to every check, so the next run's reap would kill this one's session; with
    # no start to record, nothing is started.
    owner =
      case Owner.current() do
        {:ok, owner} ->
          owner

        {:error, :no_start} ->
          raise "refusing to start a run: this BEAM's own start time could not be read, " <>
                  "and a run recorded without it would be reaped as an orphan"
      end

    # THE deadline guard, before anything that costs work: the reap below can fetch, and the
    # worktree step fetches and cuts. Judged again before the session is announced
    # (`run_session/7`), and the session's own timer is what bounds a run that passes both.
    deadline =
      Story.check_deadline(story.deadline_at, story.wall_clock_s, config, DateTime.utc_now())

    # From the CONFIG, never from `System.user_home!/0` here: this line runs in every test that
    # runs a Run, so a hardcoded home is a suite that sweeps the operator's grants. The reaper's
    # own worktree locks record the owner already read above.
    reaped =
      if deadline == :ok,
        do:
          Reaper.reap(config.runs_dir, config.kill_grace_s * 1000, config.grant_dir,
            projects_dir: config.claude_projects_dir,
            owner: {:ok, owner}
          ),
        else: []

    File.mkdir_p!(run_dir)

    # Every run directory has its story from the start. A prompt a `:prompt` builder makes later
    # is written over it when it exists (`build_prompt/4`); until then the story says it has none.
    write_story(run_dir, story)

    {:ok, trace} = Trace.start_link(Path.join(run_dir, "trace.ndjson"), run_id)

    run_seq =
      Trace.emit(trace, "run.started", nil, %{
        "story_id" => story.id,
        "repo" => story.repo,
        "branch" => story.branch,
        "base" => story.base,
        "host" => hostname(),
        "reaped_before_start" => length(reaped)
      })

    # The binding is in the first write, before any side effect: a run whose dispatch is not
    # recorded beside it could never ship its trace.
    RunState.update(
      run_dir,
      Map.merge(Keyword.get(opts, :binding, %{}), %{
        "run_id" => run_id,
        "run_seq" => run_seq,
        "status" => "starting",
        "reached" => "claimed",
        "repo_path" => story.repo_path
      })
      |> Map.merge(owner)
    )

    stage(opts, {:started, %{run_id: run_id, run_dir: run_dir}})

    result =
      case deadline do
        :ok ->
          try do
            with_worktree(config, story, run_dir, trace, run_seq, run_id, owner, opts)
          catch
            # Any way out must not leave the run recorded in flight. The worktree lock is already
            # released by the `after` in with_worktree.
            kind, reason ->
              record_crash(run_dir, trace, run_seq, Exception.format_banner(kind, reason))
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        {:passed, detail} ->
          Trace.emit(trace, "run.deadline_passed", run_seq, %{"error" => detail})

          %{
            status: "deadline_passed",
            session: nil,
            teardown: nil,
            error: detail,
            reached: "claimed"
          }
      end

    Trace.emit(trace, "run.finished", run_seq, %{
      "status" => result.status,
      "error" => result.error
    })

    summary = summary(result, run_dir)

    # `reached` is recorded so a Control that did not see the run end can still report its
    # terminal stage from the right place.
    # A run that passed its deadline owes nothing, and `RunState.finish/2` says so in this write.
    # The session's turn count and whether it left work behind go beside it too, so the
    # `session_ended` a later Control rebuilds from here says what this one's said.
    RunState.finish(
      run_dir,
      %{
        status: result.status,
        reached: summary.reached,
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
      |> put_known(:turns_used, summary.turns_used)
      |> put_known(:work_left_behind, summary.work_left_behind)
    )

    Trace.close(trace)
    Process.put(@summary_key, summary)
    Map.merge(result, %{run_id: run_id, run_dir: run_dir})
  end

  defp put_known(map, _key, nil), do: map
  defp put_known(map, key, value), do: Map.put(map, key, value)

  # The stage is recorded before it is announced and before what it stands for happens, so a run
  # that dies in it is reported from where it really was (`unfinished/2`).
  defp reach(run_dir, opts, reached, event) do
    RunState.update(run_dir, %{reached: reached})
    stage(opts, event)
  end

  @doc "Calls the run's `:on_stage` with `event`, when it has one."
  @spec stage(keyword(), term()) :: term()
  def stage(opts, event) do
    case Keyword.get(opts, :on_stage) do
      nil -> :ok
      on_stage -> on_stage.(event)
    end
  end

  # What the run's end is reported as: its status, why the session ended, and the session's own
  # escalation text, which is untrusted data and only ever recorded.
  defp summary(result, run_dir) do
    %{
      status: result.status,
      error: result.error,
      exit_reason: result.session && Atom.to_string(result.session.reason),
      exit_status: result.session && result.session.exit_status,
      escalations: escalations(run_dir),
      reached: reached(result),
      # Contract 1.27.0's two optional facts about the session, nil when not known: the CLI's own
      # turn count, and whether its branch held commits origin's refs did not reach at its end.
      turns_used: result.session && Map.get(result.session, :turns_used),
      work_left_behind: Map.get(result, :work_left_behind),
      # Where the run lives on disk.
      run_dir: run_dir
    }
  end

  # The last stage the run reached: a run that got no worktree never started a session, and one
  # whose prompt was refused got a worktree and no further.
  defp reached(%{reached: reached}), do: reached
  defp reached(%{teardown: nil}), do: "claimed"
  defp reached(_result), do: "implementing"

  defp write_story(run_dir, story),
    do: File.write!(Path.join(run_dir, "story.json"), JSON.encode!(Story.to_map(story)))

  @doc false
  @spec escalations(String.t()) :: [String.t()]
  def escalations(run_dir) do
    case File.read(Path.join(run_dir, "escalations.ndjson")) do
      {:ok, raw} ->
        for line <- String.split(raw, "\n", trim: true),
            {:ok, %{"reason" => reason}} <- [JSON.decode(line)],
            is_binary(reason),
            do: reason

      {:error, _} ->
        []
    end
  end

  # Best effort: whatever raised may be the run directory itself going away. The status is the one
  # the run's end is reported with, so a later Control reading it back reports the same end.
  defp record_crash(run_dir, trace, run_seq, error) do
    Trace.emit(trace, "run.crashed", run_seq, %{"error" => error})
    RunState.update(run_dir, %{status: unfinished(run_dir, error).status})
    Trace.close(trace)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp with_worktree(config, story, run_dir, trace, run_seq, run_id, owner, opts) do
    # The session environment is rendered per run (Config.session_env_for/3).
    opts = Keyword.put(opts, :run_id, run_id)

    path = Worktree.path_for(story.repo_path, story.id)

    case WorktreeLock.acquire(config.runs_dir, path, run_id, owner) do
      :ok ->
        try do
          claim_worktree(config, story, run_dir, trace, run_seq, opts, path)
        after
          WorktreeLock.release(config.runs_dir, path, run_id)
        end

      {:error, {:held, holder}} ->
        reason = "worktree #{path} is in use by live run #{holder}"
        Trace.emit(trace, "worktree.failed", run_seq, %{"error" => reason})
        %{status: "failed", session: nil, teardown: nil, error: reason}
    end
  end

  defp claim_worktree(config, story, run_dir, trace, run_seq, opts, path) do
    RunState.update(run_dir, %{
      worktree: %{path: path, branch: story.branch, base: story.base, status: "creating"}
    })

    case Worktree.create(story.repo_path, path, story.branch, story.base) do
      {:ok, created} ->
        RunState.take_ownership(config.runs_dir, run_dir, path)

        Trace.emit(
          trace,
          "worktree.created",
          run_seq,
          Map.merge(
            %{"path" => path, "reused" => created.reused, "start" => created.start},
            fetch_data(created.fetch)
          )
        )

        reach(
          run_dir,
          opts,
          "worktree",
          {:worktree, %{branch: story.branch, worktree_path: path}}
        )

        case prompted(story, created.cut_from, run_dir, trace, run_seq, path, opts) do
          {:ok, story} ->
            # The commit the tree was cut from travels to what runs after the session
            # (`observe_session/4`), which reads the delivery mode from it as the prompt did.
            opts = Keyword.put(opts, :cut_from, created.cut_from)
            run_session(config, story, run_dir, trace, run_seq, path, opts)

          {:refuse, reason, detail} ->
            no_session(
              story,
              run_dir,
              trace,
              run_seq,
              path,
              opts,
              "refused",
              "#{reason}: #{detail}"
            )
        end

      {:error, reason} ->
        Trace.emit(trace, "worktree.failed", run_seq, %{"error" => reason})
        %{status: "failed", session: nil, teardown: nil, error: reason}
    end
  end

  # A dispatch's prompt is built here, once the tree exists, and never before: what it states — the
  # delivery mode, read from the commit the tree was cut from — and whether the run may start at
  # all are decided by the builder. The tree already exists, so a builder that raises (or exits,
  # or throws) tears it down the way a refusal does before the run crashes on.
  defp prompted(story, cut_from, run_dir, trace, run_seq, path, opts) do
    build_prompt(story, cut_from, run_dir, opts)
  catch
    kind, reason ->
      teardown = teardown(story, trace, run_seq, path, opts)
      record_worktree(run_dir, story, path, teardown, opts)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp build_prompt(story, cut_from, run_dir, opts) do
    case Keyword.get(opts, :prompt) do
      nil when story.prompt == nil ->
        raise ArgumentError, "story #{story.id} has no prompt and the run was given no :prompt"

      nil ->
        {:ok, story}

      build ->
        with {:ok, prompt} <- build.(cut_from) do
          story = %{story | prompt: prompt}
          write_story(run_dir, story)
          {:ok, story}
        end
    end
  end

  # What actually happened, not what was intended: a failed removal stays findable by the reaper
  # instead of being recorded as gone.
  defp record_worktree(run_dir, story, path, teardown, opts) do
    RunState.update(run_dir, %{
      worktree: %{
        path: path,
        branch: story.branch,
        base: story.base,
        status: worktree_status(teardown, opts)
      }
    })
  end

  # No session: the worktree goes the way it would after one, and the run records why — `refused`
  # by its prompt, or `deadline_passed` while the tree was cut.
  defp no_session(story, run_dir, trace, run_seq, path, opts, status, error) do
    Trace.emit(trace, "session.refused", run_seq, %{"error" => error})
    teardown = teardown(story, trace, run_seq, path, opts)
    record_worktree(run_dir, story, path, teardown, opts)

    %{status: status, session: nil, teardown: teardown, error: error, reached: "worktree"}
  end

  defp worktree_status(teardown, opts) do
    if Keyword.get(opts, :keep_worktree, false),
      do: "kept",
      else: Worktree.status_after(teardown)
  end

  @claim_ended "loopctl ended the claim this run was dispatched under before its session started"

  # THE deadline guard before the session, immediately before `implementing` is announced: cutting
  # the tree and building the prompt take time, and a stage reported for a session that will not
  # start is a stage loopctl moves the story on for. Nothing checks after it: a session started
  # here is bounded by its own stop timer (`Story.stop_after/4`).
  #
  # Beside it, the CLAIM (contract 1.22.0): one loopctl ended while the tree was cut
  # (`LoopctlRunner.ClaimEnded`) gets no session, since its work is not to be sent and its session
  # is to be stopped; the run ends `claim_ended` from `worktree`, an escalation Control does not send.
  defp run_session(config, story, run_dir, trace, run_seq, path, opts) do
    if ClaimEnded.ended?(config.runs_dir, Keyword.get(opts, :binding, %{})) do
      no_session(story, run_dir, trace, run_seq, path, opts, "claim_ended", @claim_ended)
    else
      case Story.check_deadline(story.deadline_at, story.wall_clock_s, config, DateTime.utc_now()) do
        :ok ->
          start_session(config, story, run_dir, trace, run_seq, path, opts)

        {:passed, detail} ->
          no_session(story, run_dir, trace, run_seq, path, opts, "deadline_passed", detail)
      end
    end
  end

  defp start_session(config, story, run_dir, trace, run_seq, path, opts) do
    # Teardown runs even when the session monitor crashes. A BEAM that dies outright
    # never gets here: that is the launcher watchdog's job, then the reaper's.
    reach(run_dir, opts, "implementing", {:implementing, %{}})

    {session, error} =
      try do
        {Session.run(
           config: config,
           story: story,
           worktree: path,
           # The runner cut this worktree on a branch of its own, so this run's session may hold
           # the subagent git grant. A triage run has no branch of its own and gets none.
           own_worktree: true,
           run_dir: run_dir,
           trace: trace,
           parent: run_seq,
           mcp_args: Keyword.get(opts, :mcp_args, []),
           env:
             Config.session_env_for(config, story.repo, story.id, Keyword.fetch!(opts, :run_id)) ++
               Keyword.get(opts, :env, [])
         ), nil}
      catch
        :exit, reason ->
          Trace.emit(trace, "session.crashed", run_seq, %{"reason" => inspect(reason)})
          {nil, "session monitor crashed: #{inspect(reason)}"}
      end

    # Read from the tree BEFORE teardown, which may delete the branch it asks about.
    left_behind = Worktree.work_left_behind(path, story.branch)
    teardown = teardown(story, trace, run_seq, path, opts)
    record_worktree(run_dir, story, path, teardown, opts)
    observe_session(run_dir, trace, run_seq, opts)

    %{
      status: session_status(session),
      session: session,
      teardown: teardown,
      error: error,
      work_left_behind: left_behind
    }
  end

  # US-48.16: what the run's `:observe` sees once the session is over, however it ended — for a
  # pr-mode dispatch, the stages its pull request reached (`DispatchRun.observe/4`). Written to
  # `state.json` BEFORE it is announced, as `reached` is before each stage, so a Control that never
  # saw the announcement — it died, or this task did — still reports it from what is on disk.
  # Announced before `:finished`, so its stage reports queue ahead of the run's end. An observer
  # that raises costs the run nothing but the observation.
  defp observe_session(run_dir, trace, run_seq, opts) do
    case Keyword.get(opts, :observe) do
      nil ->
        :ok

      observe ->
        observed = observed(observe, %{cut_from: Keyword.get(opts, :cut_from)}, trace, run_seq)

        if observed != [] do
          RunState.update(run_dir, %{observed_stages: observed})
          stage(opts, {:observed, observed})
        end

        :ok
    end
  end

  defp observed(observe, context, trace, run_seq) do
    observed =
      case observe.(context) do
        list when is_list(list) ->
          Enum.filter(list, &match?(%{"to" => to} when is_binary(to), &1))

        _other ->
          []
      end

    Trace.emit(trace, "forge.observed", run_seq, %{"stages" => Enum.map(observed, & &1["to"])})
    observed
  catch
    kind, reason ->
      Trace.emit(trace, "forge.failed", run_seq, %{"error" => crash_error(kind, reason)})
      []
  end

  defp teardown(story, trace, run_seq, path, opts) do
    if Keyword.get(opts, :keep_worktree, false) do
      Trace.emit(trace, "worktree.kept", run_seq, %{"path" => path})
      %{worktree: :kept, branch: :kept}
    else
      outcome = Worktree.remove_if_clean(story.repo_path, path, story.branch, story.base)

      Trace.emit(trace, "worktree.#{Worktree.status_after(outcome)}", run_seq, %{
        "worktree" => inspect(outcome.worktree),
        "branch" => inspect(outcome.branch)
      })

      outcome
    end
  end

  # A branch cut from the local base because origin's could not be fetched starts on stale code;
  # the trace says so, with git's reason.
  defp fetch_data(:ok), do: %{"fetch" => "ok"}
  defp fetch_data(:skipped), do: %{"fetch" => "skipped"}
  defp fetch_data({:error, error}), do: %{"fetch" => "failed", "fetch_error" => error}

  @doc """
  A run's status from how its session ended: `succeeded` for an exit 0, `failed` for any other
  exit, `stopped_at_deadline` for a session the dispatch's `deadline_at` stopped, the session's own
  stop reason otherwise, and `crashed` for anything that is not a session's end — no session, or
  one whose monitor crashed.
  """
  @spec session_status(term()) :: String.t()
  def session_status(%{reason: :exited, exit_status: 0}), do: "succeeded"
  def session_status(%{reason: :exited}), do: "failed"

  # Stopped by the dispatch's deadline_at, not by its own wall clock: its own status, never
  # `wall_clock_exceeded` — which `DispatchRun.session_ended/2` reports as a budget the story
  # overran and loopctl escalates — and reported `crashed` from it.
  def session_status(%{reason: :wall_clock_exceeded, stop_bound: :deadline}),
    do: "stopped_at_deadline"

  def session_status(%{reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
  def session_status(_no_session), do: "crashed"

  defp run_dir_name(story, run_id) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    "#{story.id}-#{stamp}-#{binary_part(run_id, 0, 8)}"
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end
end
