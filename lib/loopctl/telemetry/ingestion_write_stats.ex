defmodule Loopctl.Telemetry.IngestionWriteStats do
  @moduledoc """
  Self-rescuing `:telemetry` handler that folds every KB article WRITE OUTCOME into
  the durable `ingestion_write_stats` per-(tenant, source_type, day) rollup.

  Attached at boot next to `Loopctl.Telemetry.SlowQueryLogger` (in
  `Loopctl.Application.start/2`). Listens on `[:loopctl, :knowledge, :article_write]`
  (emitted from EVERY render path of `LoopctlWeb.ArticleController.create`) and, per
  event, upserts+increments the counter column that matches the event's `outcome`.

  ## Why a direct per-write upsert (not an ETS buffer)

  Article writes are LOW-FREQUENCY (a create/dedup/reject per API call, not a hot
  request-path event like the scale signals `Loopctl.Telemetry.ScaleAlerts` windows).
  A direct upsert per event is therefore acceptable and far simpler than an
  ETS-buffer + periodic flush — and it keeps the rollup transactionally consistent
  with the write it counts (the handler runs synchronously in the request process, so
  in tests it shares that process's sandboxed connection). If write volume ever grows
  hot, an ETS-buffer+flush (ScaleAlerts style) is the drop-in alternative.

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
      upsert_increment(tenant_id, source_type_of(metadata), column)
    end

    :ok
  rescue
    e ->
      # A dropped rollup increment must NEVER break the article write it observes.
      Logger.error("IngestionWriteStats handler error: #{Exception.message(e)}")
      :ok
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
