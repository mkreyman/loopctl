defmodule Loopctl.Repo.Migrations.AddSessionMemoriesSeq do
  use Ecto.Migration

  # US-28.2: `session_history/2` must return a session's turns in strict INSERTION
  # order (AC-28.2.5). Ordering by `inserted_at` alone tiebreaks on the random
  # binary_id PK (Ecto.UUID v4, non-monotonic), so two turns appended within the same
  # microsecond could sort nondeterministically. Add a `bigserial` sequence column: a
  # strictly-monotonic, gap-tolerant insertion counter that gives `session_history/2`
  # a deterministic tiebreaker regardless of clock resolution.
  #
  # `session_memories` is brand-new (created same-day in `CreateMemoryStores`), so the
  # `bigserial` default backfills the (effectively empty) table without a rewrite risk.

  def change do
    alter table(:session_memories) do
      add :seq, :bigserial, null: false
    end

    # Backs the chronological read ordered by the monotonic sequence within a session.
    create index(:session_memories, [:tenant_id, :session_id, :seq])
  end
end
