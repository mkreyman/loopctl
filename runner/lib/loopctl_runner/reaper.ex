defmodule LoopctlRunner.Reaper do
  @moduledoc """
  Boot-time cleanup of runs whose runner died (design §8: "reap orphans at runner boot,
  since teardown only runs on the happy path").

  A run is an orphan when the BEAM that owned it is gone and either its `state.json` says
  it was still in flight, or its teardown failed to remove the worktree. For an in-flight
  orphan the reaper ends the session's processes (see `terminate/3` on the group and the
  session marker) and removes the worktree only if it holds no work — a worktree with
  uncommitted changes or commits is kept, so re-running the story adopts it. A failed
  removal is retried. Each reap is appended to that run's own trace.
  """

  alias LoopctlRunner.{Owner, ProcessGroup, RunState, Trace, Worktree, WorktreeLock}

  @in_flight ["starting", "running"]
  # A removal git keeps refusing (a locked worktree) is someone's deliberate state, not a
  # transient: stop retrying and leave it to a human.
  @max_removal_attempts 3
  @launcher_name "session-launcher.sh"

  @type reaped :: %{run_id: String.t(), process_group: String.t(), worktree: String.t()}

  @spec reap(String.t(), non_neg_integer()) :: [reaped()]
  def reap(runs_dir, grace_ms) do
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
    # before every run, and a tree with nothing committed, a dirty one or a held one needs none.
    plans =
      Enum.map(orphans, fn {run_dir, state} ->
        group = end_session(state, grace_ms)
        {run_dir, state, group, plan(run_dir, state)}
      end)

    fetched = fetch_origins(plans)
    Enum.map(plans, &finish(&1, fetched))
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

  defp finish({run_dir, state, group, plan}, fetched) do
    worktree =
      case plan do
        {:skip, message} ->
          message

        {:remove, recorded, repo, work, seen} ->
          fetch = Map.get(fetched, {repo, recorded["base"]}, :skipped)
          remove_locked(run_dir, state, recorded, repo, {work, seen}, fetch)
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
       when wt_status not in ["handed_off", "removed"] do
    # A live run may have adopted this path since the entry was written; its lock says so. What the
    # read saw is taken first, so a change made while it reads is a change the removal sees.
    case WorktreeLock.live_holder(Path.dirname(run_dir), path) do
      nil ->
        seen = Worktree.fingerprint(repo, path, branch, base)
        {:remove, recorded, repo, Worktree.work_in(repo, path, branch, base), seen}

      holder ->
        {:skip, "held by live run #{holder}; not touched"}
    end
  end

  defp plan(_run_dir, _state), do: {:skip, "none recorded or handed off"}

  # The plan was read before the fetch, which can take thirty seconds, and a run may adopt the tree
  # or anything may write to it in that window. So the removal holds the tree's lock, which no run
  # can then take, and checks under it that the tree is as the plan read it: one that changed is
  # kept, not decided by the earlier reading. What is compared is the refs and status the plan read
  # (`Worktree.fingerprint/4`), never the plan's answer: the fetch itself changes the answer — a
  # branch origin's base now reaches by history reads as holding nothing once it has run — and a
  # changed answer kept every such branch.
  defp remove_locked(run_dir, state, recorded, repo, planned, fetch) do
    runs_dir = Path.dirname(run_dir)
    path = recorded["path"]
    reaper = "reaper-" <> (state["run_id"] || Path.basename(run_dir))

    case WorktreeLock.acquire(runs_dir, path, reaper) do
      :ok ->
        try do
          remove_recorded(run_dir, recorded, repo, planned, fetch)
        after
          WorktreeLock.release(runs_dir, path, reaper)
        end

      {:error, {:held, holder}} ->
        "held by live run #{holder}; not touched"
    end
  end

  defp remove_recorded(run_dir, recorded, repo, planned, fetch) do
    %{"path" => path, "branch" => branch, "base" => base} = recorded

    {work, seen} = planned

    outcome =
      case Worktree.fingerprint(repo, path, branch, base) do
        ^seen ->
          Worktree.remove_if_clean(repo, path, branch, base, work, fetch)

        now ->
          reason = "changed while origin was fetched: #{inspect(seen)}, now #{inspect(now)}"
          %{worktree: {:kept, reason}, branch: {:kept, reason}}
      end

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
