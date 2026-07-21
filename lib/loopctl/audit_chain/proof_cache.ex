defmodule Loopctl.AuditChain.ProofCache do
  @moduledoc """
  Supervised owner of a small, bounded ETS memo for merkle inclusion proofs
  (US-41.7, AC-41.7.4).

  ## Why

  `Loopctl.AuditChain.inclusion_proof/2` reads every `entry_hash` up to the signed
  tree head and folds the whole tree to extract one O(log n) path. That is fine
  once per STH inside the periodic sign job; it is not fine per request on a
  PUBLIC, unauthenticated route. `LoopctlWeb.Plugs.PublicProofThrottle` bounds the
  request RATE; this bounds the repeated WORK, which is the other half: a proof is
  a pure function of `(tenant, leaf position, STH)`, all three immutable, so the
  same request can never need recomputing while the STH stands.

  ## What is cached

  The PROOF, not the leaf set. A proof is O(log n) 32-byte hashes — kilobytes at
  most — whereas memoising the whole hash list would trade a CPU amplifier for a
  memory one. Entries are keyed by `{tenant_id, position, sth_position}` so a new
  tree head naturally produces a new key rather than serving a stale proof, and
  the table is capped (`@max_entries`) with a TTL so an enumeration attack cannot
  grow it without bound — over the cap the cache simply stops admitting, degrading
  to the uncached (still throttled) path rather than evicting hot entries.
  """

  use GenServer

  require Logger

  @table :audit_chain_proof_cache
  @ttl_ms :timer.minutes(30)
  @max_entries 2_000
  @sweep_interval_ms :timer.minutes(5)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the memoised proof for `key`, or computes it with `fun` and memoises it.

  Never fails the caller: if the table is missing (the owner is not running, e.g.
  in a minimal test harness) the value is simply computed.
  """
  @spec fetch({Ecto.UUID.t(), integer(), integer()}, (-> term())) :: term()
  def fetch(key, fun) when is_function(fun, 0) do
    now = System.monotonic_time(:millisecond)

    case lookup(key, now) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(key, value, now)
        value
    end
  end

  @doc "Drops every memoised proof. Used by tests and by an operator on demand."
  @spec clear() :: :ok
  def clear do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp lookup(key, now) do
    if table?() do
      case :ets.lookup(@table, key) do
        [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
        _ -> :miss
      end
    else
      :miss
    end
  end

  defp put(key, value, now) do
    if table?() and :ets.info(@table, :size) < @max_entries do
      :ets.insert(@table, {key, value, now + @ttl_ms})
    end

    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
