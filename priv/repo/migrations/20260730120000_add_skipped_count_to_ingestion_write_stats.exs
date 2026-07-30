defmodule Loopctl.Repo.Migrations.AddSkippedCountToIngestionWriteStats do
  use Ecto.Migration

  @moduledoc """
  Adds a distinct `skipped_count` counter for high-overlap proposals DISCARDED by
  `on_low_novelty: :skip`.

  A skip persists no article row and hands the caller no article reference, so folding
  it into `deduplicated_count` (which means "the content already exists AS a row you
  were pointed at") would let a drop storm — a mis-tuned overlap threshold, or an
  unattended writer whose every capture suddenly scores high — read as a healthy
  dedup-heavy day. Like `created`/`deduplicated`/`drafted` it is a NON-REJECT attempt,
  so it joins `IngestionHealth.detect_high_reject_rate/1`'s denominator without moving
  its numerator, and it doubles as the capture-silence liveness signal for a source
  whose writes are all being skipped.
  """

  def change do
    alter table(:ingestion_write_stats) do
      add :skipped_count, :bigint, default: 0, null: false
    end
  end
end
