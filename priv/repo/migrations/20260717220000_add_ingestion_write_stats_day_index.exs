defmodule Loopctl.Repo.Migrations.AddIngestionWriteStatsDayIndex do
  use Ecto.Migration

  @moduledoc """
  Day-leading index for the reject-rate scan + retention pruning.

  `Loopctl.Knowledge.IngestionHealth.detect_high_reject_rate/1` filters
  `ingestion_write_stats.day >= window_start` across ALL tenants (no tenant
  predicate) and groups by (tenant_id, source_type). The original supporting index
  `(tenant_id, day)` is tenant-LEADING, so a day-only predicate cannot range-seek
  it — the scan degraded to a sequential scan over an ever-growing rollup. This
  day-leading index makes the rolling-window predicate a true range seek and also
  serves the retention pruner's `day < cutoff` delete.
  """

  def change do
    create index(:ingestion_write_stats, [:day])
  end
end
