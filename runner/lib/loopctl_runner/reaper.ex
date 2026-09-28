defmodule LoopctlRunner.Reaper do
  @moduledoc """
  Cleanup of runs whose runner died (design §8: "reap orphans at runner boot, since teardown
  only runs on the happy path"). It runs before every run and from `mix loopctl.reap`, so it
  runs beside live sessions — a daemon's, or another run's — and touches only what a DEAD owner
  left.

  A run is an orphan when the BEAM that owned it is gone and either its `state.json` says
  it was still in flight, or its teardown failed to remove the worktree. For an in-flight
  orphan the reaper ends the session's processes (see `terminate/3` on the group and the
  session marker) and removes the worktree only if it holds no work — a worktree with
  uncommitted changes or commits is kept, so re-running the story adopts it. A worktree whose
  entry says it is `scratch` (a triage run's detached tree) is removed whatever it holds, and with
  it the Claude project directory a run's own tree made (`:projects_dir`). A
  worktree is only removed while the reaper holds its `WorktreeLock`, so a live run cannot take
  it up between the check and the removal; a lock that is held, or that cannot be taken at all, is
  skipped, never waited on or raised over. A failed removal is retried. Each reap is appended to
  that run's own trace.

  Run at the start of every implement AND triage run, and by `mix loopctl.reap`.
  """

  require Logger

  alias LoopctlRunner.{
    GitGrant,
    Owner,
    ProcessGroup,
    RunState,
    Trace,
    TriageRun,
    Worktree,
    WorktreeLock
  }

  @in_flight ["starting", "running"]
  # Entries whose path is not, or is no longer, this run's to remove: removed already, handed to a
  # later run, a triage tree RELEASED for the next run to refresh, or one never prepared — the
  # path may hold something that was in the way, or the reused tree another run owns.
  @not_this_runs ["handed_off", "removed", "released", "not_prepared"]
  # A removal git keeps refusing (a locked worktree) is someone's deliberate state, not a
  # transient: stop retrying and leave it to a human.
  @max_removal_attempts 3
  @launcher_name "session-launcher.sh"

  @type reaped :: %{run_id: String.t(), process_group: String.t(), worktree: String.t()}

  @doc """
  Reaps every orphan under `runs_dir`, and sweeps leaked subagent git grants out of `grant_dir`.

  THE GRANT DIRECTORY IS REQUIRED, with no default: a default right in production is destructive
  in a test, which drives this same path and must never sweep the operator's real `~/.claude`.
  Callers pass their config's `grant_dir`, where it is visible.

  The sweep removes only a grant whose owner BEAM or recorded session is no longer running
  (`LoopctlRunner.GitGrant.sweep/1`), so a live session's grant survives it whichever process reaps.

  Options:

    * `:projects_dir` — the config's `claude_projects_dir`, where an orphaned triage run's project
      directory is removed from; without it none is.
    * `:owner` — this BEAM's `LoopctlRunner.Owner.current/0` reading, when the caller has already
      taken one; read here otherwise. It is what the reaper records in the `WorktreeLock` it holds
      for a removal, and a reading with no start takes no lock: that orphan's tree is not touched
      this reap and is revisited by the next, its removal attempts unspent.
  """
  @spec reap(String.t(), non_neg_integer(), String.t() | nil, keyword()) :: [reaped()]
  def reap(runs_dir, grace_ms, grant_dir, opts \\ []) do
    # A leaked subagent git grant is an orphan of the same kind, for the same reason: it is removed
    # by the session's own teardown, which a halt or a hard kill never reaches. Swept first because
    # it costs one directory listing and cannot fail the reap.
    case GitGrant.sweep(grant_dir) do
      [] -> :ok
      swept -> Logger.info("reaper: removed #{length(swept)} leaked subagent git grant(s)")
    end

    orphans =
      runs_dir
      |> Path.join("*/state.json")
      |> Path.wildcard()
      |> Enum.map(&Path.dirname/1)
      |> Enum.filter(&orphan?/1)
      |> Enum.map(fn run_dir ->
        {:ok, state} = RunState.read(run_dir)
        {run_dir, state}
      end)

    # An orphan's session ends before its tree is read: a process still running could still be
    # writing. Each tree is read ONCE (`Worktree.work_in/4`), and the bases those reads say origin must
    # answer for are fetched together — each a network call bounded at thirty seconds, this runs
    # before every run, and a tree with nothing committed, a dirty one, a held one or a scratch one
    # needs none.
    plans =
      Enum.map(orphans, fn {run_dir, state} ->
        group = end_session(state, grace_ms)
        {run_dir, state, group, plan(run_dir, state)}
      end)

    fetched = fetch_origins(plans)
    owner = Keyword.get_lazy(opts, :owner, &Owner.current/0)

    Enum.map(plans, fn {_run_dir, state, _group, _plan} = planned ->
      reaped = finish(planned, fetched, owner)
      remove_project_dir(state, opts[:projects_dir])
      reaped
    end)
  end

  # One fetch per distinct repo and base, all at once: in series a reap of N repos offline waited
  # N times the fetch timeout. A fetch that outlives its own bound is reported as failed.
  defp fetch_origins(plans) do
    keys =
      for {_run_dir, _state, _group, {:remove, recorded, repo, work, _seen}} <- plans,
          Worktree.asks_origin?(work),
          uniq: true,
          do: {repo, recorded["base"]}

    keys
    |> Task.async_stream(fn {repo, base} -> Worktree.fetch_base(repo, base) end,
      max_concurrency: max(length(keys), 1),
      timeout: Worktree.fetch_timeout_ms() + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip_with(keys, fn
      {:ok, fetch}, key -> {key, fetch}
      {:exit, reason}, key -> {key, {:error, "fetch did not return: #{inspect(reason)}"}}
    end)
    |> Map.new()
  end

  # Scratch only: an implement run's project directory is its session's record, and a kept
  # worktree's session may be resumed. `TriageRun.remove_project_dir/2` matches only a directory
  # whose cwd carried the run id, so the reused tree's one directory is never touched.
  defp remove_project_dir(%{"worktree" => %{"scratch" => true}, "run_id" => run_id}, dir)
       when is_binary(dir) and is_binary(run_id),
       do: TriageRun.remove_project_dir(dir, run_id)

  defp remove_project_dir(_state, _projects_dir), do: :ok

  defp orphan?(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"status" => status} = state} when status in @in_flight ->
        not owner_alive?(state)

      {:ok, %{"worktree" => %{"status" => "remove_failed"}} = state} ->
        not owner_alive?(state)

      _ ->
        false
    end
  end

  defp owner_alive?(state), do: Owner.alive?(state)

  defp end_session(%{"status" => status} = state, grace_ms) when status in @in_flight,
    do: reap_group(state, grace_ms)

  defp end_session(_state, _grace_ms), do: "not in flight"

  defp finish({run_dir, state, group, plan}, fetched, owner) do
    worktree =
      case plan do
        {:skip, message} ->
          message

        {:scratch, recorded, repo} ->
          remove_scratch(run_dir, state, recorded, repo, owner)

        {:remove, recorded, repo, work, seen} ->
          fetch = Map.get(fetched, {repo, recorded["base"]}, :skipped)
          remove_locked(run_dir, state, recorded, repo, {work, seen}, fetch, owner)
      end

    record(run_dir, state, group, worktree)
    if state["status"] in @in_flight, do: RunState.update(run_dir, %{status: "reaped"})
    %{run_id: state["run_id"], process_group: group, worktree: worktree}
  end

  defp record(run_dir, state, group, worktree) do
    {:ok, trace} = Trace.start_link(Path.join(run_dir, "trace.ndjson"), state["run_id"])

    Trace.emit(trace, "run.reaped", state["run_seq"], %{
      "process_group" => group,
      "worktree" => worktree,
      "previous_status" => state["status"]
    })

    Trace.close(trace)
  end

  # The session marker is an identity pids cannot counterfeit by being reused, so marked
  # processes are always ended. The group is signalled only while its leader is still
  # our launcher.
  defp reap_group(state, grace_ms) do
    pgid = state["pgid"]
    session_id = state["session_id"]
    marker = if is_binary(session_id), do: ProcessGroup.marker(session_id)
    group_ours? = is_integer(pgid) and ProcessGroup.alive?(pgid) and launcher?(pgid)
    opts = [marker: marker, tree_file: state["tree_file"], leader_start: state["leader_start"]]

    outcome = ProcessGroup.terminate(if(group_ours?, do: pgid), grace_ms, opts)

    cond do
      outcome != :already_gone ->
        inspect(outcome)

      is_integer(pgid) and ProcessGroup.alive?(pgid) ->
        "pid reused by #{ProcessGroup.command(pgid)}; not signalled"

      true ->
        "gone"
    end
  end

  defp launcher?(pgid), do: (ProcessGroup.command(pgid) || "") =~ @launcher_name

  defp plan(
         run_dir,
         %{
           "worktree" =>
             %{"path" => path, "branch" => branch, "base" => base, "status" => wt_status} =
               recorded,
           "repo_path" => repo
         }
       )
       when wt_status not in @not_this_runs do
    # A scratch worktree — detached, so nothing a session wrote there is anywhere else — is removed
    # whatever it holds, exactly as `TriageRun`'s own teardown removes one, so it has nothing to read
    # and nothing to fetch. Kept, it would stay for ever: a kept tree leaves the run `reaped`, which
    # `orphan?/1` never revisits. Decided by what the ENTRY says rather than by the run's kind,
    # because it is a property of the tree.
    if recorded["scratch"] == true do
      {:scratch, recorded, repo}
    else
      plan_removal(run_dir, recorded, repo, path, branch, base)
    end
  end

  defp plan(_run_dir, _state), do: {:skip, "none recorded or handed off"}

  # A live run may have adopted this path since the entry was written; its lock says so. What the
  # read saw is taken first, so a change made while it reads is a change the removal sees.
  defp plan_removal(run_dir, recorded, repo, path, branch, base) do
    case WorktreeLock.live_holder(Path.dirname(run_dir), path) do
      nil ->
        seen = Worktree.fingerprint(repo, path, branch, base)
        {:remove, recorded, repo, Worktree.work_in(repo, path, branch, base), seen}

      holder ->
        {:skip, "held by live run #{holder}; not touched"}
    end
  end

  # The plan was read before the fetch, which can take thirty seconds, and a run may adopt the tree
  # or anything may write to it in that window. So the removal holds the tree's lock, which no run
  # can then take, and checks under it that the tree is as the plan read it: one that changed is
  # kept, not decided by the earlier reading. What is compared is the refs and status the plan read
  # (`Worktree.fingerprint/4`), never the plan's answer: the fetch itself changes the answer — a
  # branch origin's base now reaches by history reads as holding nothing once it has run — and a
  # changed answer kept every such branch.
  defp remove_locked(run_dir, state, recorded, repo, planned, fetch, owner) do
    with_lock(run_dir, state, recorded, owner, fn ->
      %{"path" => path, "branch" => branch, "base" => base} = recorded
      {work, seen} = planned

      case Worktree.fingerprint(repo, path, branch, base) do
        ^seen ->
          Worktree.remove_if_clean(repo, path, branch, base, work, fetch)

        now ->
          reason = "changed while origin was fetched: #{inspect(seen)}, now #{inspect(now)}"
          %{worktree: {:kept, reason}, branch: {:kept, reason}}
      end
    end)
  end

  defp remove_scratch(run_dir, state, recorded, repo, owner) do
    with_lock(run_dir, state, recorded, owner, fn ->
      Worktree.remove(repo, recorded["path"], recorded["branch"], recorded["base"])
    end)
  end

  # The tree's lock held for the removal alone, so a run of the same story is refused for as short a
  # time as possible. TAKEN, not only read: a triage repo's reused tree is taken up by every run on
  # that repo, and a run that locked it between a read and the removal would have its tree removed
  # from under it. TRIED, never waited on, and never raised over: the reaper runs at the start of
  # every run, so a lock it cannot take — held, or a lock directory that will not be made — skips
  # this one orphan rather than stalling or crashing the run that called it. The lock records this
  # BEAM as its owner, so a BEAM whose own start cannot be read takes none: a lock written without
  # it reads dead to every check, and a live run could take the tree over mid-removal.
  #
  # A reaper that cannot read its own start is not a failed removal of THIS orphan — nothing about
  # the orphan was tried — so it spends none of the orphan's attempts: the entry is left for the
  # next reap, as `remove_failed` so it is revisited once this run is marked `reaped`, with its
  # count as it was.
  defp with_lock(run_dir, _state, recorded, {:error, :no_start}, _remove) do
    reason = "this BEAM's own start time could not be read"
    Logger.warning("the reaper takes no lock for #{recorded["path"]}; not touched: #{reason}")
    RunState.update(run_dir, %{worktree: Map.put(recorded, "status", "remove_failed")})
    "not touched: #{reason}"
  end

  defp with_lock(run_dir, state, recorded, {:ok, owner}, remove) do
    runs_dir = Path.dirname(run_dir)
    path = recorded["path"]
    reaper = "reaper-" <> (state["run_id"] || Path.basename(run_dir))

    case WorktreeLock.try_acquire(runs_dir, path, reaper, owner) do
      :ok ->
        outcome =
          try do
            remove.()
          after
            WorktreeLock.release(runs_dir, path, reaper)
          end

        record_removal(run_dir, recorded, outcome)

      {:error, {:held, holder}} ->
        "held by live run #{holder}; not touched"

      # Counted as a failed removal, so the entry is revisited (and abandoned after the same three
      # attempts) rather than left `created` on a run that is about to be marked `reaped`.
      {:error, {:unavailable, reason}} ->
        Logger.error("the reaper could not take the lock for #{path}; not touched: #{reason}")

        record_removal(run_dir, recorded, %{
          worktree: {:error, "lock: #{reason}"},
          branch: :absent
        })
    end
  end

  defp record_removal(run_dir, recorded, outcome) do
    attempts = Map.get(recorded, "removal_attempts", 0) + 1

    status =
      case Worktree.status_after(outcome) do
        "remove_failed" when attempts >= @max_removal_attempts -> "remove_abandoned"
        status -> status
      end

    RunState.update(run_dir, %{
      worktree: Map.merge(recorded, %{"status" => status, "removal_attempts" => attempts})
    })

    inspect(outcome)
  end
end
