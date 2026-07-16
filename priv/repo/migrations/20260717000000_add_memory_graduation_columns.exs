defmodule Loopctl.Repo.Migrations.AddMemoryGraduationColumns do
  use Ecto.Migration

  # #411 Gap 3 (PR C): recall-count tracking + graduation of HOT long-term memories
  # into durable knowledge articles.
  #
  #   * `recall_count`    — how many times this memory has been returned by a HEALTHY
  #     semantic recall (the hotness signal the graduation sweep thresholds on). Bumped
  #     OFF the recall hot path (see `Loopctl.Memory.bump_recall_counts/2`), so a bump
  #     failure never affects a recall response.
  #   * `last_recalled_at`— the instant of the most recent counted recall (observability
  #     + a future recency signal). NULL until first recalled.
  #   * `graduated_at`    — set once the memory's content has been graduated to a durable
  #     knowledge article (any novelty-gate verdict — created/gated_to_draft/duplicate/
  #     deduplicated all mean "now durable"). NULL = not yet graduated. The sweep skips
  #     a non-NULL row so a memory is graduated at most once.
  #
  # `create_if_not_exists` on every column keeps the migration idempotent/re-runnable.

  def change do
    alter table(:memories) do
      add_if_not_exists :recall_count, :integer, null: false, default: 0
      add_if_not_exists :last_recalled_at, :utc_datetime_usec, null: true
      add_if_not_exists :graduated_at, :utc_datetime_usec, null: true
    end

    # Partial index backing the cross-tenant graduation sweep candidate query
    # (`Loopctl.Workers.MemoryGraduationSweepWorker`): live, not-yet-graduated memories
    # ordered by hotness within a tenant. The predicate matches the sweep's WHERE
    # (`graduated_at IS NULL AND superseded_by IS NULL`) so the index stays small — it
    # only holds rows still eligible for graduation — and it is a plain btree that does
    # NOT touch the HNSW embedding indexes.
    create_if_not_exists index(:memories, [:tenant_id, :recall_count],
                           where: "graduated_at IS NULL AND superseded_by IS NULL",
                           name: :memories_graduation_sweep_idx
                         )
  end
end
