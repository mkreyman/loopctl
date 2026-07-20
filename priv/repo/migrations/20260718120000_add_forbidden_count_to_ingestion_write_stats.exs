defmodule Loopctl.Repo.Migrations.AddForbiddenCountToIngestionWriteStats do
  use Ecto.Migration

  @moduledoc """
  Adds a distinct `forbidden_count` counter for UPFRONT AUTHORIZATION (403) rejections.

  Previously the article-create controller folded 403 authz rejections (wrong
  scope/role, missing agent identity) into `validation_error_count`, so a caller
  merely mis-using scope/identity (a pure 403 storm) would trip the `high_reject_rate`
  detector with a misleading `dominant_reason` and mask a genuine
  `title_conflict`/`validation_error` ingestion outage. Authz rejections now increment
  this separate column, which `IngestionHealth.detect_high_reject_rate/1` deliberately
  does NOT read — permission misuse is tracked for observability but never counted as
  ingestion-pipeline ill-health.
  """

  def change do
    alter table(:ingestion_write_stats) do
      add :forbidden_count, :bigint, default: 0, null: false
    end
  end
end
