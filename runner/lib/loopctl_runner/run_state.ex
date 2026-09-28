defmodule LoopctlRunner.RunState do
  @moduledoc """
  The run's `state.json`: the identity of every side effect, written BEFORE acting.

  This is the worktree registry and the reaper's input. A stage records what it is about
  to create (design §3), so a run that dies between "about to" and "done" still names the
  worktree and the process group it left behind, and the next boot can clean them up.
  """

  @spec path(String.t()) :: String.t()
  def path(run_dir), do: Path.join(run_dir, "state.json")

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(run_dir) do
    with {:ok, raw} <- File.read(path(run_dir)) do
      JSON.decode(raw)
    end
  end

  @doc "Every run directory under `runs_dir` with its decoded state, in path order."
  @spec all(String.t()) :: [{String.t(), map()}]
  def all(runs_dir) do
    runs_dir
    |> Path.join("*/state.json")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.flat_map(fn run_dir ->
      case read(run_dir) do
        {:ok, state} when is_map(state) -> [{run_dir, state}]
        _ -> []
      end
    end)
  end

  @doc """
  Records that the run at `run_dir` now owns the worktree at `path`.

  The path is the same for every run of a story, so the registry would otherwise hold
  several entries for one directory and the reaper could act on a stale one — force-
  retrying an old run's removal after a later run adopted the worktree and put work in it.
  Every other run's entry for `path` that still claims it is marked `handed_off`, which
  the reaper never touches.
  """
  @spec take_ownership(String.t(), String.t(), String.t()) :: :ok
  def take_ownership(runs_dir, run_dir, path) do
    for {other, %{"worktree" => %{"path" => ^path, "status" => status} = wt}} <- all(runs_dir),
        other != run_dir,
        status not in ["removed", "handed_off"] do
      update(other, %{worktree: Map.put(wt, "status", "handed_off")})
    end

    :ok
  end

  @doc "Merges `changes` into the state file, atomically (write-then-rename)."
  @spec update(String.t(), map()) :: map()
  def update(run_dir, changes) do
    current =
      case read(run_dir) do
        {:ok, map} -> map
        _ -> %{}
      end

    next = Map.merge(current, stringify(changes))
    # A unique temp name: another run's take_ownership may update this file concurrently.
    tmp = path(run_dir) <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, JSON.encode!(next))
    File.rename!(tmp, path(run_dir))
    next
  end

  @doc """
  Records a run's end — `changes`, which carry its `status` — and, in the SAME write, whether that
  end is already settled. A run that ended `deadline_passed` started no session and owes loopctl
  nothing (after its deadline the claim is loopctl's lease sweep's to release), so it is written
  `terminal_reported` `skipped`, and no later Control goes looking for an end to report. Implement
  and triage runs both end through here, so the two cannot disagree about it.
  """
  @spec finish(String.t(), map()) :: map()
  def finish(run_dir, changes) do
    changes = stringify(changes)
    update(run_dir, Map.merge(changes, settled(changes["status"])))
  end

  defp settled("deadline_passed"), do: %{"terminal_reported" => "skipped"}
  defp settled(_status), do: %{}

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
