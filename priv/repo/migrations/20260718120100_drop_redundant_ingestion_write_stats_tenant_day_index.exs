defmodule Loopctl.Repo.Migrations.DropRedundantIngestionWriteStatsTenantDayIndex do
  use Ecto.Migration

  @moduledoc """
  Drops the redundant `(tenant_id, day)` index on `ingestion_write_stats`.

  The create migration added `index(:ingestion_write_stats, [:tenant_id, :day])`, but it
  has NO read consumer:

    * the reject-rate scan (`IngestionHealth.detect_high_reject_rate/1`) filters
      `day >= window_start` with no tenant predicate, so it uses the day-leading
      `[:day]` index (migration 20260717220000);
    * retention pruning (`day < cutoff`) also uses `[:day]`;
    * tenant+day point lookups are already served by the unique index on
      `(tenant_id, COALESCE(source_type, ''), day)`.

  So `(tenant_id, day)` was maintained on every write-outcome upsert (a hot, storm-time
  path) for zero benefit — pure write amplification. Drop it.
  """

  def change do
    drop_if_exists index(:ingestion_write_stats, [:tenant_id, :day])
  end
end
