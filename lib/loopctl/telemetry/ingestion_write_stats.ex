defmodule Loopctl.Telemetry.IngestionWriteStats do
  @moduledoc """
  Self-rescuing `:telemetry` handler that folds every KB article WRITE OUTCOME into
  the durable `ingestion_write_stats` per-(tenant, source_type, day) rollup.

  Attached at boot next to `Loopctl.Telemetry.SlowQueryLogger` (in
  `Loopctl.Application.start/2`). Listens on `[:loopctl, :knowledge, :article_write]`
  (emitted from EVERY render path of `LoopctlWeb.ArticleController.create`) and, per
  event, upserts+increments the counter column that matches the event's `outcome`.

  ## Off the request path (async by default) — why not a blocking per-write upsert

  Article writes are typically low-frequency (a create/dedup/reject per API call, not a
  hot request-path event like the scale signals `Loopctl.Telemetry.ScaleAlerts`
  windows), so a direct upsert per event is far simpler than an ETS-buffer + periodic
  flush. BUT a `:telemetry` handler runs SYNCHRONOUSLY in the emitting (request)
  process, and the BYPASSRLS `AdminRepo` pool is small (3 conns in prod) and already
  carries the per-request rate-limiter upsert — so a blocking upsert here would couple
  article-write tail latency to AdminRepo pool checkout (up to the checkout timeout)
  under pool pressure or a DB blip. To decouple, the increment is dispatched to a
  supervised, fire-and-forget task (`async?/0`, default true) so the request path never
  blocks on it.

  ## Bounded fan-out (the reject storm is the worst case)

  The `:high_reject_rate` detector this rollup feeds triggers on a client HAMMERING
  create in a retry loop — i.e. write volume SPIKES exactly when the rollup is under
  the most write pressure. An unbounded task fan-out would then spawn one AdminRepo
  upsert per rejected write, contending for the 3-conn pool (shared with the rate
  limiter + auth) and amplifying the very outage the detector exists to catch. So the
  dispatch goes through the BOUNDED `Loopctl.Telemetry.IngestionWriteStatsTaskSupervisor`
  (`max_children`, default 200): over the cap `start_child` returns
  `{:error, :max_children}` and the increment is DROPPED (best-effort analytics) rather
  than queueing unbounded checkouts. If write volume ever grows hot enough to pressure
  the pool even under the cap, an ETS-buffer+flush (ScaleAlerts style) is the drop-in
  next step.

  In TEST the dispatch runs INLINE (`config :loopctl, #{inspect(__MODULE__)}, async:
  false`) so the upsert shares the emitting test process's sandboxed connection and the
  rollup row is readable back synchronously.

  ## Self-rescuing (never break the request path — nor let :telemetry detach us)

  Like `Loopctl.Telemetry.SlowQueryLogger` / `LoopctlWeb.DBErrorLogger`, a handler
  MUST NOT break the request it observes: a failed upsert (DB blip, pool exhaustion,
  a raise) is logged and swallowed — the article write already succeeded/failed on
  its own path and must not be affected by a dropped rollup increment.

  Crucially, `:telemetry` PERMANENTLY DETACHES a handler that lets ANY failure escape
  (error/exit/throw — see `telemetry:execute/3`'s invoke wrapper), which would silently
  and permanently stop feeding this rollup for the node's lifetime and blind the
  high_reject_rate detector — the exact silent-monitoring-death this epic exists to
  prevent. The top-level `rescue` only catches raises (`:error`), but the async dispatch
  (`Task.Supervisor.start_child/2`, a `GenServer.call`) can EXIT (`:noproc`) if the task
  supervisor is momentarily down (its crash/restart, or app-shutdown ordering). So the
  dispatch is additionally wrapped in a `try/catch` covering `:exit`/`:throw`, ensuring
  no failure class can escape `handle_event/4`.

  ## RLS convention (BYPASSRLS + explicit tenant_id)

  Writes go through `Loopctl.AdminRepo` (BYPASSRLS) with `tenant_id` set explicitly on
  the struct — the same RLS-bypass-with-explicit-predicate convention
  `IngestionHealth` / `CostAnomaly` use for operator/system rollups. An event with no
  `tenant_id` (nothing to attribute) or an unmapped `outcome` is skipped.
  """

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.IngestionWriteStats
  alias Loopctl.TelemetryEvents

  @handler_id __MODULE__
  @conflict_target {:unsafe_fragment, "(tenant_id, COALESCE(source_type, ''), day)"}

  @doc """
  Attaches the article-write rollup handler. Idempotent: a duplicate attach (code
  reload) is ignored rather than raised.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(
           @handler_id,
           TelemetryEvents.article_write(),
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the handler (used in focused tests)."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(_event, _measurements, metadata, _config) do
    tenant_id = Map.get(metadata, :tenant_id)
    outcome = Map.get(metadata, :outcome)
    column = outcome && IngestionWriteStats.column_for(outcome)

    if is_binary(tenant_id) and not is_nil(column) do
      dispatch_upsert(tenant_id, source_type_of(metadata), column)
    end

    :ok
  rescue
    e ->
      # A dropped rollup increment must NEVER break the article write it observes.
      Logger.error("IngestionWriteStats handler error: #{Exception.message(e)}")
      :ok
  end

  # Async (prod default): hand the upsert to the BOUNDED supervisor as a fire-and-forget
  # task so the request process never blocks on AdminRepo pool checkout, and a write
  # storm cannot fan out to unbounded concurrent checkouts. Inline (test): run in the
  # emitting process so it shares the sandboxed connection.
  #
  # NOTHING may escape here: `start_child` is a `GenServer.call` that EXITS (`:noproc`)
  # if the supervisor is momentarily down — an escaping exit would make `:telemetry`
  # permanently detach this handler and silently kill the rollup. So we catch every
  # class and swallow it; a lost increment is best-effort analytics, never a broken
  # write nor a dead detector.
  @task_supervisor Loopctl.Telemetry.IngestionWriteStatsTaskSupervisor
  defp dispatch_upsert(tenant_id, source_type, column) do
    if async?() do
      dispatch_async(tenant_id, source_type, column)
    else
      upsert_increment(tenant_id, source_type, column)
    end
  end

  defp dispatch_async(tenant_id, source_type, column) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           safe_upsert_increment(tenant_id, source_type, column)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        # Bounded supervisor at capacity (a write burst): DROP the increment rather
        # than block the observed request or queue an unbounded AdminRepo checkout.
        Logger.warning(
          "IngestionWriteStats: task supervisor at capacity; dropping #{column} increment"
        )

      {:error, reason} ->
        Logger.warning("IngestionWriteStats: failed to start upsert task: #{inspect(reason)}")
    end

    :ok
  catch
    kind, reason ->
      # :exit (:noproc) if the supervisor is down, etc. Never let it escape to :telemetry.
      Logger.warning("IngestionWriteStats: upsert dispatch #{kind}: #{inspect(reason)}")
      :ok
  end

  # Task body runs in its OWN process, outside handle_event's rescue, so it self-rescues:
  # a DB blip logs instead of surfacing as a supervised-task crash report.
  defp safe_upsert_increment(tenant_id, source_type, column) do
    upsert_increment(tenant_id, source_type, column)
  rescue
    e -> Logger.error("IngestionWriteStats async upsert error: #{Exception.message(e)}")
  end

  # Whether to run the rollup upsert off the request path (default true). Test pins it
  # false so the upsert shares the emitting process's sandboxed connection.
  @spec async?() :: boolean()
  def async? do
    :loopctl
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:async, true)
  end

  defp upsert_increment(tenant_id, source_type, column) do
    now = DateTime.utc_now()
    day = DateTime.to_date(now)

    attrs = %{source_type: source_type, day: day} |> Map.put(column, 1)
    changeset = IngestionWriteStats.changeset(%IngestionWriteStats{tenant_id: tenant_id}, attrs)

    case AdminRepo.insert(changeset,
           on_conflict: [inc: [{column, 1}], set: [updated_at: now]],
           conflict_target: @conflict_target
         ) do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "IngestionWriteStats: failed to upsert #{column} for tenant #{tenant_id}: " <>
            "#{inspect(changeset.errors)}"
        )
    end
  end

  # source_type is advisory + nullable; treat any non-binary (absent/malformed) as
  # nil so it lands in the COALESCE('') bucket.
  defp source_type_of(metadata) do
    case Map.get(metadata, :source_type) do
      st when is_binary(st) -> st
      _ -> nil
    end
  end
end
