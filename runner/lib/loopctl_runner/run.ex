defmodule LoopctlRunner.Run do
  @moduledoc """
  Build order step 1a, end to end: one hand-filed story, one machine, merging nothing.

      reap orphans -> run dir + state -> worktree -> session -> teardown

  Every step lands in the run's trace under one root event, and every side effect's
  identity is in `state.json` before the side effect happens.

  Run directory layout, under the configured `runs_dir`:

      <run_id>/story.json      the validated story
      <run_id>/state.json      side-effect identities and status (RunState)
      <run_id>/trace.ndjson    the parent-linked event stream (Trace)
      <run_id>/stdout.ndjson   the CLI's stream-json, verbatim
      <run_id>/stderr.log      the CLI's stderr
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

  @spec execute(Config.t(), Story.t(), keyword()) :: result()
  def execute(%Config{} = config, %Story{} = story, opts \\ []) do
    reaped = Reaper.reap(config.runs_dir, config.kill_grace_s * 1000)
    run_id = run_id(story)
    run_dir = Path.join(config.runs_dir, run_id)
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

    RunState.update(
      run_dir,
      Map.merge(Owner.current(), %{
        "run_id" => run_id,
        "run_seq" => run_seq,
        "status" => "starting",
        "repo_path" => story.repo_path
      })
    )

    result =
      try do
        with_worktree(config, story, run_dir, trace, run_seq, opts)
      rescue
        # A raise must not leave the run recorded in flight. The worktree lock is already
        # released by the `after` in with_worktree.
        exception ->
          record_crash(run_dir, trace, run_seq, exception)
          reraise exception, __STACKTRACE__
      end

    Trace.emit(trace, "run.finished", run_seq, %{
      "status" => result.status,
      "error" => result.error
    })

    RunState.update(run_dir, %{
      status: result.status,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })

    Trace.close(trace)
    Map.merge(result, %{run_id: run_id, run_dir: run_dir})
  end

  # Best effort: whatever raised may be the run directory itself going away.
  defp record_crash(run_dir, trace, run_seq, exception) do
    Trace.emit(trace, "run.crashed", run_seq, %{"error" => Exception.message(exception)})
    RunState.update(run_dir, %{status: "crashed"})
    Trace.close(trace)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp with_worktree(config, story, run_dir, trace, run_seq, opts) do
    path = Worktree.path_for(story.repo_path, story.id)

    run_id = Path.basename(run_dir)

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

        run_session(config, story, run_dir, trace, run_seq, path, opts)

      {:error, reason} ->
        Trace.emit(trace, "worktree.failed", run_seq, %{"error" => reason})
        %{status: "failed", session: nil, teardown: nil, error: reason}
    end
  end

  defp run_session(config, story, run_dir, trace, run_seq, path, opts) do
    # Teardown runs even when the session monitor crashes. A BEAM that dies outright
    # never gets here: that is the launcher watchdog's job, then the reaper's.
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

  defp run_id(story) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{story.id}-#{stamp}-#{suffix}"
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end
end
