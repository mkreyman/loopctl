defmodule Loopctl.Memory.RecallBumpCache do
  @moduledoc """
  Node-local, in-process cooldown cache for the recall-count hotness bump (#411 Gap 3).

  The graduation signal (`recall_count`) is bumped OFF the recall hot path, DEDUPED to
  at most once per memory per `Loopctl.Memory.recall_bump_cooldown_seconds/0`. That dedup
  ultimately lives in the `UPDATE ... WHERE last_recalled_at < cutoff` predicate, but on
  the async hot path that predicate still costs a Repo connection checkout on EVERY
  recall — even a cooldown NO-OP that bumps zero rows. Under a burst of recalls that
  amplifies reads 1:1 into writes on the shared write pool and fans out an unbounded set
  of background tasks (`Loopctl.Memory.bump_recall_counts/2`).

  This cache is the cheap in-process pre-filter that fixes both:

    * `filter_uncooled/2` drops the ids already bumped within the cooldown window BEFORE
      a task is spawned or a connection is taken, so an idle-window recall issues ZERO
      tasks and ZERO DB writes. Reads bypass any process — a direct, lock-free
      `:ets.lookup` on a `read_concurrency` table.
    * `mark/2` records the bump instant per `(tenant_id, memory_id)` after a write, so the
      next recall inside the window is filtered out here.

  The DB-side `WHERE last_recalled_at < cutoff` REMAINS the source of truth (this cache is
  node-local and lost on restart / not shared cross-node); the ETS layer is a spend
  optimization + fan-out damper, not the correctness guarantee. A periodic sweep evicts
  expired entries so the table stays bounded to memories bumped within one cooldown
  window. Mirrors the ETS-owner pattern of `Loopctl.Llm.SettingsCache` /
  `Loopctl.Knowledge.ExportConcurrency`: a single GenServer owns the table so it survives
  the transient recall/task process that wrote to it.
  """

  use GenServer

  require Logger

  @table :loopctl_recall_bump_cooldown
  @sweep_interval_ms :timer.minutes(5)

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the subset of `ids` that are NOT within their per-memory cooldown window on
  THIS node (never bumped here, or last bumped before the cooldown elapsed).

  A lock-free, read-only pre-filter: pure `:ets.lookup` per id, bypassing the owner
  GenServer. If the table is somehow absent (owner not yet booted), it fails OPEN —
  returning all ids — so the DB-side cooldown still guards the write.
  """
  @spec filter_uncooled(String.t(), [String.t()]) :: [String.t()]
  def filter_uncooled(tenant_id, ids) when is_binary(tenant_id) and is_list(ids) do
    now = now_ms()
    Enum.filter(ids, fn id -> uncooled?(tenant_id, id, now) end)
  rescue
    ArgumentError -> ids
  end

  @doc """
  Records a bump for each `(tenant_id, id)` so a subsequent recall inside the cooldown
  window is filtered by `filter_uncooled/2`. Direct writes to the public table (no
  GenServer round-trip); best-effort, swallows a missing-table error.
  """
  @spec mark(String.t(), [String.t()]) :: :ok
  def mark(tenant_id, ids) when is_binary(tenant_id) and is_list(ids) do
    expires_at = now_ms() + cooldown_ms()
    Enum.each(ids, fn id -> :ets.insert(@table, {{tenant_id, id}, expires_at}) end)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def table_name, do: @table

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        existing ->
          existing
      end

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp uncooled?(tenant_id, id, now) when is_binary(id) do
    case :ets.lookup(@table, {tenant_id, id}) do
      [{_key, expires_at}] -> now >= expires_at
      [] -> true
    end
  end

  defp uncooled?(_tenant_id, _id, _now), do: false

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # Evict entries whose cooldown has elapsed so the table stays bounded to memories
  # bumped within roughly one cooldown window.
  defp sweep_expired do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  rescue
    ArgumentError -> 0
  end

  defp cooldown_ms do
    Application.get_env(:loopctl, :memory_recall_bump_cooldown_seconds, 3600) * 1000
  end

  # Monotonic clock: entries store `now_ms() + cooldown_ms`, compared against `now_ms()`.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
