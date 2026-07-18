defmodule Loopctl.Telemetry.IngestionWriteStats do
  @moduledoc """
  Self-rescuing `:telemetry` handler that folds every KB article WRITE OUTCOME into
  the durable `ingestion_write_stats` per-(tenant, source_type, day) rollup.

  Attached at boot next to `Loopctl.Telemetry.SlowQueryLogger` (in
  `Loopctl.Application.start/2`). Listens on `[:loopctl, :knowledge, :article_write]`
  (emitted from EVERY render path of `LoopctlWeb.ArticleController.create`) and, per
  event, upserts+increments the counter column that matches the event's `outcome`.

  ## Off the request path (async by default) — why not a blocking per-write upsert

  Article writes are LOW-FREQUENCY (a create/dedup/reject per API call, not a hot
  request-path event like the scale signals `Loopctl.Telemetry.ScaleAlerts` windows),
  so a direct upsert per event is far simpler than an ETS-buffer + periodic flush. BUT
  a `:telemetry` handler runs SYNCHRONOUSLY in the emitting (request) process, and the
  BYPASSRLS `AdminRepo` pool is small (3 conns in prod) and already carries the
  per-request rate-limiter upsert — so a blocking upsert here would couple article-write
  tail latency to AdminRepo pool checkout (up to the checkout timeout) under pool
  pressure or a DB blip. To decouple, the increment is dispatched to a supervised,
  fire-and-forget `Loopctl.TaskSupervisor` task (`async?/0`, default true) so the
  request path never blocks on it. If write volume ever grows hot enough to pressure
  the pool from the task side, an ETS-buffer+flush (ScaleAlerts style) is the drop-in
  next step.

  In TEST the dispatch runs INLINE (`config :loopctl, #{inspect(__MODULE__)}, async:
  false`) so the upsert shares the emitting test process's sandboxed connection and the
  rollup row is readable back synchronously.

  ## Self-rescuing (never break the request path)

  Like `Loopctl.Telemetry.SlowQueryLogger` / `LoopctlWeb.DBErrorLogger`, a handler
  MUST NOT break the request it observes: a failed upsert (DB blip, pool exhaustion,
  a raise) is logged and swallowed — the article write already succeeded/failed on
  its own path and must not be affected by a dropped rollup increment.

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

  # Async (prod default): hand the upsert to a supervised fire-and-forget task so the
  # request process never blocks on AdminRepo pool checkout. Inline (test): run in the
  # emitting process so it shares the sandboxed connection. `start_child` returning an
  # error is swallowed by the caller's rescue — a lost increment must not break the write.
  defp dispatch_upsert(tenant_id, source_type, column) do
    if async?() do
      Task.Supervisor.start_child(Loopctl.TaskSupervisor, fn ->
        safe_upsert_increment(tenant_id, source_type, column)
      end)

      :ok
    else
      upsert_increment(tenant_id, source_type, column)
    end
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
