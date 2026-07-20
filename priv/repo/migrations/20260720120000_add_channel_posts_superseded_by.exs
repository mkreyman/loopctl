defmodule Loopctl.Repo.Migrations.AddChannelPostsSupersededBy do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # US-454 (defect 3): supersession as a REAL, machine-readable terminal state.
  # A post whose successor exists carries superseded_by = the successor's id, so
  # directed-handoff discovery can EXCLUDE retired handoffs (mirroring how a DONE
  # claim gates a handoff out) and the history read can MARK them. Self-FK with
  # nilify_all: hard-deleting (US-39.7) the successor clears the marker rather
  # than dangling.
  #
  # REVIVAL SEMANTICS: when a successor is redacted or TTL-swept, nilify_all
  # clears the predecessor's superseded_by, which CAN resurrect the retired
  # handoff into discovery. This is an ACCEPTED edge case: supersession is a
  # best-effort retirement signal, not a permanent tombstone. A predecessor that
  # re-enters discovery after its successor disappears is still subject to the
  # normal claim-and-done lifecycle. Correcting a handoff that is ACTIVELY CLAIMED
  # requires posting the correction under a NEW anchor (different key) — same-key
  # supersession of a claimed handoff is blocked by the active claim correlation.
  #
  # CREATE/DROP INDEX CONCURRENTLY (outside a DDL transaction, migration lock
  # disabled) so the build takes no ACCESS EXCLUSIVE lock on channel_posts —
  # the hottest write table (one post per session-turn). Mirrors the repo's
  # documented CONCURRENTLY convention (20260719120000, 20260718130000).
  def up do
    alter table(:channel_posts) do
      add :superseded_by, references(:channel_posts, type: :binary_id, on_delete: :nilify_all)
    end

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS channel_posts_superseded_by_idx
    ON channel_posts (superseded_by)
    WHERE superseded_by IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS channel_posts_superseded_by_idx")

    alter table(:channel_posts) do
      remove :superseded_by
    end
  end
end
