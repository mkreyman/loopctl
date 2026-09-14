defmodule LoopctlRunner.Run do
  @moduledoc """
  Build order step 1a, end to end: one hand-filed story, one machine, merging nothing.

      reap orphans -> run dir + state -> worktree -> session -> teardown

  Every step lands in the run's trace under one root event, and every side effect's
  identity is in `state.json` before the side effect happens.

  A run is identified by a UUID (`run_id`, in `state.json`, every trace line and the
  worktree lock). Its directory under `runs_dir` has a readable name instead,
  `<story id>-<UTC stamp>-<first 8 hex of the run id>`:

      <dir>/story.json      the validated story
      <dir>/state.json      side-effect identities and status (RunState)
      <dir>/trace.ndjson    the parent-linked event stream (Trace)
      <dir>/stdout.ndjson   the CLI's stream-json, verbatim
      <dir>/stderr.log      the CLI's stderr
  """

  alias LoopctlRunner.{
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
          run_id: String.t(),
          run_dir: String.t(),
          status: String.t(),
          session: Session.result() | nil,
          teardown: map() | nil,
          error: String.t() | nil
        }

  @typedoc """
  What `:on_stage` is called with, in this order: `{:started, %{run_id, run_dir}}` once
  `state.json` exists; `{:worktree, %{branch, worktree_path}}` once the worktree exists;
  `{:implementing, %{}}` as the session starts; and `{:finished, summary}` however the run ends
  (a raise included, just before it is re-raised), whose summary names the stage the run
  `reached`. A run that never gets a worktree goes from `:started` straight to `:finished`.
  """
  @type stage_event ::
          {:started, %{run_id: String.t(), run_dir: String.t()}}
          | {:worktree, %{branch: String.t(), worktree_path: String.t()}}
          | {:implementing, map()}
          | {:finished, map()}

  @doc """
  Runs the story to the end and returns its result.

  Options: `:env` (extra session environment), `:keep_worktree`, `:binding` (a map written into
  the initial `state.json` before anything else happens, e.g. the dispatch this run serves), and
  `:on_stage` (a one-argument function called with each `t:stage_event/0`).
  """
  @summary_key {__MODULE__, :finished_summary}

  @spec execute(Config.t(), Story.t(), keyword()) :: result()
  def execute(%Config{} = config, %Story{} = story, opts \\ []) do
    # `:finished` goes out from ONE place, the `after`, so it is sent exactly once however the run
    # ends: a return, a raise, an exit or a throw, inside the worktree step or after it. The
    # summary it carries is left in the process dictionary by whichever path ended the run.
    Process.delete(@summary_key)

    try do
      run(config, story, opts)
    catch
      kind, reason ->
        Process.put(@summary_key, crash_summary(kind, reason))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      stage(
        opts,
        {:finished,
         Process.delete(@summary_key) ||
           %{status: "crashed", error: "the run ended without a summary", escalations: []}}
      )
    end
  end

  # The kind is what a reader needs first: an exit or a throw has no exception message.
  defp crash_summary(kind, reason) do
    %{
      status: "crashed",
      error: "#{kind}: " <> String.slice(Exception.format_banner(kind, reason), 0, 500),
      escalations: []
    }
  end

  defp run(config, story, opts) do
    reaped = Reaper.reap(config.runs_dir, config.kill_grace_s * 1000)
    # The contract identifies a run by UUID; the directory keeps a name a person can find.
    run_id = Session.uuid4()
    run_dir = Path.join(config.runs_dir, run_dir_name(story, run_id))
    File.mkdir_p!(run_dir)
    File.write!(Path.join(run_dir, "story.json"), JSON.encode!(Story.to_map(story)))

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
        "repo_path" => story.repo_path
      })
      |> Map.merge(Owner.current())
    )

    stage(opts, {:started, %{run_id: run_id, run_dir: run_dir}})

    result =
      try do
        with_worktree(config, story, run_dir, trace, run_seq, run_id, opts)
      catch
        # Any way out must not leave the run recorded in flight. The worktree lock is already
        # released by the `after` in with_worktree.
        kind, reason ->
          record_crash(run_dir, trace, run_seq, Exception.format_banner(kind, reason))
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    Trace.emit(trace, "run.finished", run_seq, %{
      "status" => result.status,
      "error" => result.error
    })

    summary = summary(result, run_dir)

    # `reached` is recorded so a Control that did not see the run end can still report its
    # terminal stage from the right place.
    RunState.update(run_dir, %{
      status: result.status,
      reached: summary.reached,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })

    Trace.close(trace)
    Process.put(@summary_key, summary)
    Map.merge(result, %{run_id: run_id, run_dir: run_dir})
  end

  defp stage(opts, event) do
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
      # The last stage the run reached: a run that got no worktree never started a session.
      reached: if(result.teardown, do: "implementing", else: "claimed")
    }
  end

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

  # Best effort: whatever raised may be the run directory itself going away.
  defp record_crash(run_dir, trace, run_seq, error) do
    Trace.emit(trace, "run.crashed", run_seq, %{"error" => error})
    RunState.update(run_dir, %{status: "crashed"})
    Trace.close(trace)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp with_worktree(config, story, run_dir, trace, run_seq, run_id, opts) do
    path = Worktree.path_for(story.repo_path, story.id)

    case WorktreeLock.acquire(config.runs_dir, path, run_id) do
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

        Trace.emit(trace, "worktree.created", run_seq, %{
          "path" => path,
          "reused" => created.reused
        })

        stage(opts, {:worktree, %{branch: story.branch, worktree_path: path}})
        run_session(config, story, run_dir, trace, run_seq, path, opts)

      {:error, reason} ->
        Trace.emit(trace, "worktree.failed", run_seq, %{"error" => reason})
        %{status: "failed", session: nil, teardown: nil, error: reason}
    end
  end

  defp run_session(config, story, run_dir, trace, run_seq, path, opts) do
    # Teardown runs even when the session monitor crashes. A BEAM that dies outright
    # never gets here: that is the launcher watchdog's job, then the reaper's.
    stage(opts, {:implementing, %{}})

    {session, error} =
      try do
        {Session.run(
           config: config,
           story: story,
           worktree: path,
           run_dir: run_dir,
           trace: trace,
           parent: run_seq,
           env: Keyword.get(opts, :env, [])
         ), nil}
      catch
        :exit, reason ->
          Trace.emit(trace, "session.crashed", run_seq, %{"reason" => inspect(reason)})
          {nil, "session monitor crashed: #{inspect(reason)}"}
      end

    teardown = teardown(story, trace, run_seq, path, opts)

    # What actually happened, not what was intended: a failed removal stays findable by
    # the reaper instead of being recorded as gone.
    worktree_status =
      if Keyword.get(opts, :keep_worktree, false),
        do: "kept",
        else: Worktree.status_after(teardown)

    RunState.update(run_dir, %{
      worktree: %{path: path, branch: story.branch, base: story.base, status: worktree_status}
    })

    %{status: session_status(session), session: session, teardown: teardown, error: error}
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

  defp session_status(nil), do: "crashed"
  defp session_status(%{reason: :exited, exit_status: 0}), do: "succeeded"
  defp session_status(%{reason: :exited}), do: "failed"
  defp session_status(%{reason: reason}), do: Atom.to_string(reason)

  defp run_dir_name(story, run_id) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    "#{story.id}-#{stamp}-#{binary_part(run_id, 0, 8)}"
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end
end
