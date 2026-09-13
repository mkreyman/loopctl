defmodule LoopctlRunner.Runs do
  @moduledoc "Facts about this machine's runs, read from the run registry, for the control plane."

  alias LoopctlRunner.{Owner, RunState}

  @in_flight ["starting", "running"]

  @doc "Runs in flight on a live BEAM on this machine — the join's and status's `in_flight`."
  @spec in_flight(String.t()) :: non_neg_integer()
  def in_flight(runs_dir) do
    Enum.count(RunState.all(runs_dir), fn {_dir, state} ->
      state["status"] in @in_flight and Owner.alive?(state)
    end)
  end

  @doc "When a run on this machine last succeeded, ISO 8601, or nil — the sample's `last_build_at`."
  @spec last_success_at(String.t()) :: String.t() | nil
  def last_success_at(runs_dir) do
    runs_dir
    |> RunState.all()
    |> Enum.flat_map(fn
      {_dir, %{"status" => "succeeded", "finished_at" => at}} when is_binary(at) -> [at]
      _ -> []
    end)
    |> Enum.max(fn -> nil end)
  end
end
