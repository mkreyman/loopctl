defmodule Loopctl.IndexHealth do
  @moduledoc """
  Boot-time validity probe for performance-critical indexes (US-27.9a hardening).

  A `CREATE INDEX CONCURRENTLY` that is interrupted (deploy timeout, dropped
  connection) leaves an **INVALID** index behind. A migration re-run with
  `IF NOT EXISTS` then no-ops (it sees the name), so the invalid index silently
  persists and the planner ignores it — every query that relied on it degrades to a
  Seq Scan. At scale that is a latent latency/DoS amplifier that no existing check
  surfaces until users complain (see `docs/runbooks/knowledge-scale.md`).

  This module checks, at boot, that each critical index exists AND is `indisvalid`,
  logging a WARNING and emitting a `[:loopctl, :index_health, :invalid]` telemetry
  event for any that is missing or invalid — so the documented manual recovery
  (`DROP INDEX CONCURRENTLY ...; re-run the migration`) is triggered by an alert
  rather than by a production incident. It is log-only and never blocks boot.
  """

  require Logger

  alias Loopctl.AdminRepo

  # Indexes whose absence/invalidity silently degrades a hot path to a Seq Scan.
  # Add to this list whenever a new CONCURRENTLY-built index becomes load-bearing.
  @critical_indexes [
    {"articles_tenant_inserted_id_idx", "US-27.9a article keyset pagination"}
  ]

  @doc """
  Checks every critical index and warns (log + telemetry) on any that is missing or
  INVALID. Returns `:ok` always; wrapped in a rescue so a probe failure never blocks
  boot. `which/0` lets a health endpoint or test inspect the configured list.
  """
  @spec warn_if_invalid_indexes() :: :ok
  def warn_if_invalid_indexes do
    Enum.each(@critical_indexes, fn {name, purpose} ->
      case index_validity(name) do
        :valid ->
          :ok

        :invalid ->
          emit(name, purpose, :invalid)

          Logger.warning(
            "IndexHealth: index #{name} (#{purpose}) is INVALID — a failed " <>
              "CREATE INDEX CONCURRENTLY left it unusable; the planner will Seq Scan. " <>
              "Recover: DROP INDEX CONCURRENTLY IF EXISTS #{name}; then re-run the migration."
          )

        :missing ->
          emit(name, purpose, :missing)

          Logger.warning(
            "IndexHealth: index #{name} (#{purpose}) is MISSING — the supporting " <>
              "migration has not run (or the index was dropped); the dependent query " <>
              "path will Seq Scan at scale."
          )
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning("IndexHealth boot check skipped: #{Exception.message(e)}")
      :ok
  end

  @doc "The configured critical-index list (name + purpose), for health endpoints/tests."
  @spec which() :: [{String.t(), String.t()}]
  def which, do: @critical_indexes

  # :valid | :invalid | :missing — via pg_index.indisvalid (the catalog truth).
  @spec index_validity(String.t()) :: :valid | :invalid | :missing
  def index_validity(name) when is_binary(name) do
    %{rows: rows} =
      AdminRepo.query!(
        """
        SELECT i.indisvalid
        FROM pg_class c
        JOIN pg_index i ON i.indexrelid = c.oid
        WHERE c.relname = $1
        """,
        [name]
      )

    case rows do
      [[true]] -> :valid
      [[false]] -> :invalid
      [] -> :missing
    end
  end

  defp emit(name, purpose, state) do
    :telemetry.execute(
      [:loopctl, :index_health, :invalid],
      %{count: 1},
      %{index: name, purpose: purpose, state: state}
    )
  end
end
