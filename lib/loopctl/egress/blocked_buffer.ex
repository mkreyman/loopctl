defmodule Loopctl.Egress.BlockedBuffer do
  @moduledoc """
  Debounces the blocked-decision WRITE off the egress refusal path (US-41.4,
  AC-41.4.6).

  ## Bounding rows is not the same as bounding writes

  `egress_blocked_decisions` rows are deduplicated per
  `(tenant_id, scope_key, endpoint_host, reason, window_start)`, so a
  misconfigured harvest loop already produced only ONE ROW per minute per tuple.
  But the row dedup was achieved with an upsert PER BLOCKED CALL: thousands of DB
  round-trips a minute, every one of them taking a row-level lock on the SAME
  conflict-target row, all serialized against the 3-connection BYPASSRLS pool —
  the very pool `Loopctl.Egress.effective_local_only?/1` needs to decide the next
  call. A hot refusal loop would therefore starve the privacy control itself,
  which is the outcome AC-41.4.6's "one misconfigured harvest loop would
  otherwise flood the audit path" exists to prevent.

  So the COUNTS accumulate in ETS (`:ets.update_counter/4`, lock-free) and one
  upsert per tuple per flush interval carries the accumulated delta. The EXACT
  per-call rate is unaffected: it lives in the `[:loopctl, :egress, :blocked]`
  telemetry counter, emitted unbuffered on every refusal.

  ## Not custody-critical

  These rows are an AGGREGATED operator signal (US-41.7 serializes them into the
  custody claim as counts, not as individual events). A node dying with a
  sub-interval buffer loses at most one interval of increments for that node —
  acceptable for a counter whose exact value is already available in telemetry.
  Do NOT reuse this debounce for any audit/custody write.

  ## Design (mirrors `Loopctl.TouchBuffer`)

  A single `use GenServer` OWNS a `:public`, `:named_table` ETS table. The refusal
  path writes the table DIRECTLY, so the GenServer is never on the hot path; it
  exists only to be a stable table owner and to run the flush timer. If the table
  is somehow absent (the owner is mid-restart) the write falls back to a direct
  upsert — a refusal is never lost because a cache was down.

  `flush_tenant/1` drains ONE tenant's keys, which is what `async: true` tests
  use: a global drain from test A would take test B's buffered rows and then fail
  to insert them (a different sandbox connection owns that tenant).
  """

  use GenServer

  require Logger

  @table :loopctl_egress_blocked_buffer
  @default_flush_ms :timer.seconds(5)

  alias Loopctl.Egress.Scope

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Accumulates ONE blocked decision for `(scope, host, reason, window)`.

  Lock-free (`:ets.update_counter/4`). Falls back to a direct upsert if the table
  is unavailable.
  """
  @spec record(Scope.t(), String.t(), String.t(), DateTime.t()) :: :ok
  def record(%Scope{} = scope, host, reason, window) do
    key = {scope.tenant_id, scope.project_id, Scope.key(scope), host, reason, window}
    _ = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  rescue
    ArgumentError ->
      # No table (owner restarting / not started): write straight through rather
      # than dropping the record.
      Loopctl.Egress.upsert_blocked_decision(row(key_fields(scope, host, reason, window)), 1)
  end

  @doc "Drains and persists this node's buffered counters for ONE tenant."
  @spec flush_tenant(Ecto.UUID.t()) :: :ok
  def flush_tenant(tenant_id) when is_binary(tenant_id) do
    @table
    |> :ets.match({{tenant_id, :"$1", :"$2", :"$3", :"$4", :"$5"}, :_})
    |> Enum.each(fn [project_id, scope_key, host, reason, window] ->
      drain({tenant_id, project_id, scope_key, host, reason, window})
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drains and persists EVERY buffered counter on this node (the periodic flush)."
  @spec flush_all() :: :ok
  def flush_all do
    @table |> :ets.match({:"$1", :_}) |> Enum.each(fn [key] -> drain(key) end)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def table_name, do: @table

  # `:ets.take/2` is atomic: the count is removed and returned in one step, so a
  # concurrent refusal recreates the key at 1 rather than having its increment
  # silently dropped between a read and a delete.
  defp drain(key) do
    case :ets.take(@table, key) do
      [{^key, count}] when count > 0 -> Loopctl.Egress.upsert_blocked_decision(row(key), count)
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp key_fields(scope, host, reason, window) do
    {scope.tenant_id, scope.project_id, Scope.key(scope), host, reason, window}
  end

  defp row({tenant_id, project_id, scope_key, host, reason, window}) do
    %{
      tenant_id: tenant_id,
      project_id: project_id,
      scope_key: scope_key,
      endpoint_host: host,
      reason: reason,
      window_start: window
    }
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])

        existing ->
          existing
      end

    Process.flag(:trap_exit, true)
    schedule_flush()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_all()
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    flush_all()
    :ok
  end

  # `:infinity` disables the periodic flush. The TEST env sets it: the flush runs
  # in THIS process, which owns no Ecto sandbox connection, so a periodic drain
  # would take an async test's buffered counters and then fail to insert them.
  # Tests call `Loopctl.Egress.flush_blocked_decisions/1` instead.
  defp schedule_flush do
    case Application.get_env(:loopctl, :egress_blocked_flush_ms, @default_flush_ms) do
      :infinity -> :ok
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :flush, ms)
    end
  end
end
