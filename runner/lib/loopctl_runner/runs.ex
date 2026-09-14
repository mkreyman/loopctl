defmodule LoopctlRunner.Runs do
  @moduledoc "Facts about this machine's runs, read from the run registry, for the control plane."

  alias LoopctlRunner.{Owner, RunState}

  @in_flight ["starting", "running"]

  @doc "Runs in flight on a live BEAM on this machine — the join's and status's `in_flight`."
  @spec in_flight(String.t()) :: non_neg_integer()
  def in_flight(runs_dir), do: in_flight(runs_dir, MapSet.new())

  @doc """
  Like `in_flight/1`, but not counting runs bound to any of `dispatch_ids`: the control client
  counts the runs it started itself from the moment it accepts them, before their `state.json`
  exists, and must not count them twice once it does.
  """
  @spec in_flight(String.t(), MapSet.t(String.t())) :: non_neg_integer()
  def in_flight(runs_dir, dispatch_ids) do
    Enum.count(RunState.all(runs_dir), fn {_dir, state} ->
      state["status"] in @in_flight and not MapSet.member?(dispatch_ids, state["dispatch_id"]) and
        Owner.alive?(state)
    end)
  end

  @doc """
  When a run on this machine last succeeded, ISO 8601 in UTC, or nil — the sample's
  `last_build_at`.

  Each `finished_at` is parsed, compared as a time and re-rendered. A value that does not parse
  (hand-edited, truncated, written without an offset) is skipped: the contract checks this
  field as a date-time, and one bad file must not fail every join and stop the runner.
  """
  @spec last_success_at(String.t()) :: String.t() | nil
  def last_success_at(runs_dir) do
    runs_dir
    |> RunState.all()
    |> Enum.flat_map(fn
      {_dir, %{"status" => "succeeded", "finished_at" => at}} when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, datetime, _offset} -> [datetime]
          {:error, _} -> []
        end

      _ ->
        []
    end)
    |> Enum.max(DateTime, fn -> nil end)
    |> then(&(&1 && &1 |> DateTime.truncate(:second) |> DateTime.to_iso8601()))
  end
end
