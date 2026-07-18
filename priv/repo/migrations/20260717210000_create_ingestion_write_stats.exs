defmodule Loopctl.Repo.Migrations.CreateIngestionWriteStats do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  @moduledoc """
  Durable per-(tenant, source_type, day) rollup of KB article WRITE OUTCOMES.

  The capture-silence monitor (`ingestion_anomalies`) detects "writes STOPPED"
  by reading the `articles` table — but a REJECTED write leaves no article row,
  so a high-rejection-rate outage (the server side of the 409 title_conflict /
  validation drops — the OTHER signature of the 3-month capture outage) is
  invisible to a row-count monitor. This table is fed by the self-rescuing
  `[:loopctl, :knowledge, :article_write]` telemetry handler
  (`Loopctl.Telemetry.IngestionWriteStats`) so write OUTCOMES are counted even
  when nothing is persisted, and `IngestionHealth` can flag a `:high_reject_rate`
  anomaly off this rollup.
  """

  def change do
    create table(:ingestion_write_stats, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # NULLABLE: an article write may carry no source_type (the advisory field is
      # optional). NULL buckets distinctly from any named source_type via the
      # COALESCE expression index below.
      add :source_type, :string

      add :day, :date, null: false

      # Per-outcome counters (bigint so a high-throughput tenant/day never overflows).
      # Mapped from the telemetry `outcome`:
      #   :created         -> created_count
      #   :deduplicated    -> deduplicated_count
      #   :gated_to_draft  -> drafted_count
      #   :title_conflict  -> title_conflict_count
      #   :validation_error-> validation_error_count
      add :created_count, :bigint, default: 0, null: false
      add :deduplicated_count, :bigint, default: 0, null: false
      add :drafted_count, :bigint, default: 0, null: false
      add :title_conflict_count, :bigint, default: 0, null: false
      add :validation_error_count, :bigint, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Lookup index for the rolling-window reject-rate scan (day-leading so the
    # `day >= window_start` predicate is a range seek).
    create index(:ingestion_write_stats, [:tenant_id, :day])

    # Idempotent upsert key. COALESCE(source_type, '') makes a NULL source_type
    # bucket distinctly (NULLs are never equal in a plain unique index, which would
    # let duplicate NULL-source rows accumulate and break ON CONFLICT increment).
    # The telemetry handler's insert targets this exact expression via
    # `conflict_target: {:unsafe_fragment, "(tenant_id, COALESCE(source_type, ''), day)"}`.
    create unique_index(
             :ingestion_write_stats,
             ["tenant_id", "COALESCE(source_type, '')", "day"],
             name: :ingestion_write_stats_tenant_source_day_unique
           )

    enable_rls(:ingestion_write_stats)
  end
end
