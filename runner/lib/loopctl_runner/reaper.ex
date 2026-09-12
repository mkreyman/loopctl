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
    runs_dir
    |> Path.join("*/state.json")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.filter(&orphan?/1)
    |> Enum.map(fn run_dir ->
      {:ok, state} = RunState.read(run_dir)
      reap_run(run_dir, state, grace_ms)
    end)
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

  defp reap_run(run_dir, %{"status" => status} = state, grace_ms) when status in @in_flight do
    group = reap_group(state, grace_ms)
    worktree = reap_worktree(run_dir, state, &Worktree.remove_if_clean/4)
    record(run_dir, state, group, worktree)
    RunState.update(run_dir, %{status: "reaped"})
    %{run_id: state["run_id"], process_group: group, worktree: worktree}
  end

  defp reap_run(run_dir, state, _grace_ms) do
    worktree = reap_worktree(run_dir, state, &Worktree.remove_if_clean/4)
    record(run_dir, state, "not in flight", worktree)
    %{run_id: state["run_id"], process_group: "not in flight", worktree: worktree}
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

  defp reap_worktree(
         run_dir,
         %{
           "worktree" =>
             %{"path" => path, "branch" => branch, "base" => base, "status" => wt_status} =
               recorded,
           "repo_path" => repo
         },
         removal
       )
       when wt_status not in ["handed_off", "removed"] do
    # A live run may have adopted this path since the entry was written; its lock says so.
    case WorktreeLock.live_holder(Path.dirname(run_dir), path) do
      nil -> remove_recorded(run_dir, recorded, repo, path, branch, base, removal)
      holder -> "held by live run #{holder}; not touched"
    end
  end

  defp reap_worktree(_run_dir, _state, _removal), do: "none recorded or handed off"

  defp remove_recorded(run_dir, recorded, repo, path, branch, base, removal) do
    outcome = removal.(repo, path, branch, base)
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
