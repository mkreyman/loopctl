defmodule Loopctl.TouchBuffer do
  @moduledoc """
  Debounces the two per-request *liveness* touch-writes off the authentication
  hot path (US-33.4): `agents.last_seen_at` and `api_keys.last_used_at`.

  Every authenticated request previously issued TWO synchronous `UPDATE`s on the
  small (3-connection) BYPASSRLS `AdminRepo` pool — one per touched row. A
  fast-looping agent hammers the SAME two rows on every request, producing
  row-lock contention and dead-tuple bloat for a value nobody reads with
  per-request precision. This module collapses N per-request writes into ONE
  batched periodic write per active id.

  ## Not custody-critical

  `last_seen_at`/`last_used_at` are declared LIVENESS HEURISTICS, never custody
  or audit signals. No auth/custody gate reads them (see the consumer audit
  below), so bounded staleness is acceptable. **Do NOT** apply this debounce to
  any custody/audit write.

  ## Consumer audit (AC-33.4.5)

  Every reader of `last_seen_at`/`last_used_at` in `lib/` tolerates
  seconds-scale staleness, so debouncing is safe:

    * `Loopctl.Tenants.count_active_agents/0` — `where: last_seen_at > (now -
      24h)`, a 24h liveness window; seconds of staleness is irrelevant.
    * API serializers only (`api_key_controller`, `agent_controller`,
      `api_spec/schemas`) — display fields, never a gate.
    * The auth/custody path (`verify_api_key/1`, `valid_now?/1`, `RequireAuth`,
      `CheckCustodyHalt`) gates on `revoked_at`/`expires_at`/`custody_halted_at`
      — NEVER on `last_used_at`/`last_seen_at`.

  ### Collateral: a liveness touch no longer bumps `updated_at`

  The OLD touch path went through a changeset (`change(agent, last_seen_at:
  now) |> AdminRepo.update()`), so `timestamps()` auto-advanced
  `agents.updated_at` / `api_keys.updated_at` on every authenticated request.
  The batched flush issues a RAW `UPDATE` that sets ONLY
  `last_seen_at`/`last_used_at` (below), so a liveness touch no longer moves
  `updated_at`. `updated_at` is a serialized field (`Jason.Encoder` derive), so
  this is a deliberate, observable behavior change — but benign: no reader gates
  liveness on `agents`/`api_keys` `updated_at` (`count_active_agents/0` filters
  `last_seen_at`), and `updated_at` now tracks only real record mutations
  (role/expiry/revoke changes) rather than being churned by every request.

  NOT in scope (left synchronous): the WebAuthn authenticator `last_used_at`
  (`root_authenticator`, `web_authn/reauth`) is a custody-critical assertion
  alongside `sign_count` and is unrelated to these two liveness columns.

  ## Design (mirrors `Loopctl.Auth.ApiKeyCache`, US-33.3)

  A single `use GenServer` OWNS a `:public`, `:named_table` ETS table. The
  request path writes the table DIRECTLY (`record_agent/2` / `record_api_key/2`
  are `:ets.insert` from the request process) — the GenServer is NEVER on the
  hot path and can't bottleneck throughput. It exists only to be the stable
  owner of the table (so it survives the transient request/Task/Oban process
  that populated it) and to run the periodic flush timer.

  Each request records `{:agent, agent_id} => now` / `{:api_key, api_key_id} =>
  now` in ETS. A later request for the same id always carries a `>=` timestamp,
  so an unconditional `:ets.insert` keeps (approximately) the max in the buffer;
  any sub-interval out-of-order write is irrelevant for a liveness heuristic, and
  the flush's monotonic `GREATEST` guard (below) prevents regression versus the
  DB across flushes.

  ## Flush — batched, monotonic, tenant-safe

  On each interval (and on graceful shutdown) the buffer is DRAINED atomically
  (`:ets.take` per key) and grouped by target table. Each target issues
  `UPDATE ... FROM (VALUES ...)` statements over its drained ids — so a flush is
  O(scopes) tables and, per table, O(ceil(ids / chunk_size)) chunked
  statements (NOT one statement per id).

  Each target is flushed inside its OWN rescue (`flush_target/3`). `drain/1`
  `:ets.take`'d BOTH targets' entries up front, so a raise while flushing one
  target — a sustained per-table lock-timeout, or a latent `build_values` bug
  for that column — must NOT unwind past its sibling and skip the sibling's
  already-drained window. Without per-target isolation a DETERMINISTIC agents
  failure would starve `api_keys.last_used_at` EVERY interval indefinitely (the
  targets share one flush). Isolated, the failing target loses `<= 1` interval
  (AC-33.4.4) and the sibling still flushes:

      UPDATE agents AS t
      SET last_seen_at = GREATEST(t.last_seen_at, v.ts)
      FROM (VALUES ($1::uuid, $2::timestamp), ...) AS v(id, ts)
      WHERE t.id = v.id

    * **Chunked** — each `VALUES` row contributes 2 bound params (id + ts) and
      Postgres caps a statement at 65,535 bound params, so a single UPDATE could
      carry at most ~32k ids. At epic_33 scale (tens of thousands of
      concurrently-active agents per flush interval) one unbounded UPDATE would
      exceed that cap and raise — and because `drain/1` has already removed the
      entries from ETS, the swallowed raise would silently lose the whole
      window. So drained entries are `Enum.chunk_every(@flush_chunk_size)` and
      each chunk is its own bounded UPDATE.

    * **Monotonic** — `GREATEST(col, v.ts)` (Postgres `GREATEST` ignores NULLs,
      so it also seeds a previously-NULL column) means a delayed flush can only
      advance a timestamp FORWARD, never regress it below what is already in the
      DB.
    * **Tenant-safe** — ids are globally-unique UUIDs, so `WHERE t.id = v.id`
      is self-scoping: a cross-tenant write is impossible and no `tenant_id`
      predicate is needed. Writes go through `AdminRepo` (BYPASSRLS) exactly as
      the previous synchronous touch writers did.

  ## Bounded staleness (config, default a few seconds)

  The flush interval is config-driven (`config :loopctl, Loopctl.TouchBuffer,
  flush_interval_ms: ...`). `last_seen_at`/`last_used_at` are therefore at most
  one interval stale — documented and acceptable for a liveness heuristic. On
  graceful shutdown `terminate/2` flushes the buffer; on a crash at most one
  interval of buffered touches is lost (best-effort).

  ## Sandbox / testing

  Unlike `ApiKeyCache`, the flush DOES hit the DB. To keep it Ecto-Sandbox-safe,
  the flush core runs in the CALLING process — the periodic timer calls it inside
  the GenServer (real pool in prod), but `flush/1` can be invoked directly from a
  test process (which owns the sandbox connection) against a per-test table, so
  no cross-process sandbox ownership is required. `record/3`, `peek/2` and
  `flush/1` all take an explicit table so a test can drive an isolated instance.
  """

  use GenServer

  require Logger

  alias Loopctl.AdminRepo

  @table :loopctl_touch_buffer

  # Config-driven flush interval (a few seconds default). Bounded staleness of
  # last_seen_at/last_used_at is at most this long (AC-33.4.4). Overridable per
  # env in config; test env sets it high so the app-tree singleton never
  # auto-flushes and interferes with the sandbox (tests flush explicitly).
  @default_flush_interval_ms Application.compile_env(
                               :loopctl,
                               [__MODULE__, :flush_interval_ms],
                               :timer.seconds(5)
                             )

  # ETS key tag => {sql_table, timestamp_column}. Drives the batched flush; the
  # table/column names are compile-time constants owned here (never user input),
  # so interpolating them into the UPDATE is safe — only the ids/timestamps are
  # parameterized.
  @targets [agent: {"agents", "last_seen_at"}, api_key: {"api_keys", "last_used_at"}]

  # Max drained entries per UPDATE statement. Each entry emits 2 bound params
  # (id + ts) and the Postgres wire protocol caps a statement at 65,535 bound
  # params, so one UPDATE could carry at most ~32k ids before AdminRepo.query!/2
  # raises. drain/1 has ALREADY :ets.take'd the entries before the UPDATE runs
  # and do_flush/1 swallows a raise, so an over-limit statement would silently
  # lose the entire drained window — and at epic_33 scale (tens of thousands of
  # concurrently-active agents/keys per flush interval) it would fail EVERY
  # interval, freezing last_seen_at/last_used_at. Chunk well under the cap (2 *
  # 5_000 = 10_000 params/statement) so a flush issues O(ids/chunk) bounded
  # UPDATEs instead. (Canonical: KB "Chunk bulk inserts to respect database
  # parameter limits".)
  @flush_chunk_size 5_000

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records the latest `last_seen_at` for `agent_id` in the buffer (no DB write on
  the request path). Best-effort — never raises, never blocks the request.
  """
  @spec record_agent(binary(), DateTime.t()) :: :ok
  def record_agent(agent_id, %DateTime{} = ts) when is_binary(agent_id),
    do: record(@table, {:agent, agent_id}, ts)

  @doc """
  Records the latest `last_used_at` for `api_key_id` in the buffer (no DB write
  on the request path). Best-effort — never raises, never blocks the request.
  """
  @spec record_api_key(binary(), DateTime.t()) :: :ok
  def record_api_key(api_key_id, %DateTime{} = ts) when is_binary(api_key_id),
    do: record(@table, {:api_key, api_key_id}, ts)

  @doc """
  Core buffer write into `table`. Unconditional insert keeps the latest
  timestamp per key (a later request always carries a `>=` timestamp). Wrapped
  so a vanished table (mid-restart) never crashes the request.
  """
  @spec record(atom(), {:agent | :api_key, binary()}, DateTime.t()) :: :ok
  def record(table, {tag, id} = key, %DateTime{} = ts)
      when tag in [:agent, :api_key] and is_binary(id) do
    :ets.insert(table, {key, ts})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Reads the buffered (pending, un-flushed) timestamp for `key` from `table`.
  Returns `{:ok, ts}` or `:miss`. Used by tests to assert a request recorded
  into the buffer without a synchronous DB write.
  """
  @spec peek(atom(), {:agent | :api_key, binary()}) :: {:ok, DateTime.t()} | :miss
  def peek(table \\ @table, key) do
    case :ets.lookup(table, key) do
      [{^key, ts}] -> {:ok, ts}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Flushes the singleton buffer NOW (drains it and writes the batched maxima).
  Runs in the CALLING process so it uses that process's DB connection.
  """
  @spec flush() :: :ok
  def flush, do: do_flush(@table)

  @doc """
  Flushes an explicit `table` NOW — for a per-test isolated instance.
  """
  @spec flush(atom()) :: :ok
  def flush(table) when is_atom(table), do: do_flush(table)

  @doc false
  def table_name, do: @table

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 fires on supervisor-initiated shutdown and can do
    # the final flush (AC-33.4.4). Without this a shutdown signal would kill the
    # process without running terminate/2.
    Process.flag(:trap_exit, true)

    table = Keyword.get(opts, :table, @table)
    ensure_table(table)

    interval = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    schedule_flush(interval)

    {:ok, %{table: table, interval: interval}}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush(state.table)
    schedule_flush(state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort final flush so buffered touches survive graceful shutdown.
    do_flush(state.table)
    :ok
  end

  # --- Private ---

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      existing ->
        existing
    end
  end

  # A non-integer interval (e.g. a test that never wants an auto-flush) disables
  # the timer; the buffer is then flushed only explicitly via flush/1.
  defp schedule_flush(interval) when is_integer(interval),
    do: Process.send_after(self(), :flush, interval)

  defp schedule_flush(_), do: nil

  # Flush core — atomically drain the buffer, group by target table, and issue
  # batched monotonic chunked UPDATEs per non-empty target. Runs in the caller so
  # the DB write uses the caller's connection (prod: the GenServer; tests: the
  # test process that owns the sandbox connection).
  #
  # Each target flushes inside its OWN rescue (flush_target/3), so one target's
  # failure cannot swallow the sibling's already-drained window (see moduledoc).
  # This outer rescue is a final safety net for drain/group_by only — a flush
  # must never crash the owner (or a caller).
  defp do_flush(table) do
    drained = drain(table)
    grouped = Enum.group_by(drained, fn {{tag, _id}, _ts} -> tag end)

    Enum.each(@targets, fn {tag, {sql_table, column}} ->
      flush_target(sql_table, column, Map.get(grouped, tag, []))
    end)

    :ok
  rescue
    e ->
      Logger.warning("TouchBuffer flush failed: #{inspect(e)}")
      :ok
  end

  # Atomically remove and return every buffered entry. `:ets.take/2` deletes the
  # key and returns its object in one operation, so a concurrent newer write for
  # a key already drained lands in the NEXT window (never silently dropped).
  defp drain(table) do
    keys = :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
    Enum.flat_map(keys, fn key -> :ets.take(table, key) end)
  rescue
    ArgumentError -> []
  end

  defp flush_target(_sql_table, _column, []), do: :ok

  # Chunk the drained ids so no single UPDATE exceeds the Postgres bound-param
  # cap (see @flush_chunk_size). Each chunk is its own bounded statement.
  #
  # Rescue is PER-TARGET on purpose: drain/1 has already :ets.take'd every
  # target's entries, so a raise here (lock-timeout, or a latent build_values
  # bug for this column) must be contained to THIS target — it must not unwind
  # into do_flush and skip the sibling target's already-drained window. We log
  # and return :ok; this target loses <= one interval (AC-33.4.4), the sibling
  # still flushes.
  defp flush_target(sql_table, column, entries) do
    entries
    |> Enum.chunk_every(@flush_chunk_size)
    |> Enum.each(fn chunk -> flush_chunk(sql_table, column, chunk) end)

    :ok
  rescue
    e ->
      Logger.warning("TouchBuffer flush failed for #{sql_table}: #{inspect(e)}")
      :ok
  end

  defp flush_chunk(sql_table, column, entries) do
    {values_sql, params} = build_values(entries)

    sql =
      "UPDATE #{sql_table} AS t SET #{column} = GREATEST(t.#{column}, v.ts) " <>
        "FROM (VALUES #{values_sql}) AS v(id, ts) WHERE t.id = v.id"

    AdminRepo.query!(sql, params)
    :ok
  end

  # Builds the `(VALUES ...)` list and the flat parameter list. Ids are dumped to
  # 16-byte binaries (the `::uuid` param type) and timestamps to NaiveDateTime
  # (the `::timestamp` column type, matching the utc_datetime_usec storage). Only
  # the first row carries the type casts; the rest are inferred from it.
  defp build_values(entries) do
    params =
      Enum.flat_map(entries, fn {{_tag, id}, ts} ->
        [Ecto.UUID.dump!(id), DateTime.to_naive(DateTime.truncate(ts, :microsecond))]
      end)

    rows =
      entries
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_entry, idx} ->
        id_pos = idx * 2 - 1
        ts_pos = idx * 2

        if idx == 1,
          do: "($#{id_pos}::uuid, $#{ts_pos}::timestamp)",
          else: "($#{id_pos}, $#{ts_pos})"
      end)

    {rows, params}
  end
end
