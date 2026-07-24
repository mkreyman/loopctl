defmodule Loopctl.Repo.Migrations.HealSkippedLegacyEmbeddingColumns do
  @moduledoc """
  #495 — re-add the legacy `articles.embedding` / `memories.embedding` columns that
  the pgvector guard in `20260410022854` / `20260709000000` SKIPPED on a fresh install
  where `CREATE EXTENSION vector` was unavailable at migrate time (migrations run as
  the non-superuser `loopctl_admin`).

  Those guard migrations are marked done and never re-run, so once an operator enables
  pgvector (superuser `CREATE EXTENSION vector`) the columns stay missing — yet the
  DEFAULT read path (`Embeddings.side_table_reads_enabled?/0` is off by default) and
  the dim-1536 dual-write both use them, so the app is broken until they exist. Alex's
  self-host recovery (issue #495) was exactly this `ALTER TABLE ... ADD COLUMN` by
  hand; this migration does it idempotently so the next self-hoster does not have to.

  Guarded + `IF NOT EXISTS`, so on any deployment where pgvector was available all
  along (the hosted instance, CI, dev) the columns already exist and this is a no-op.
  When pgvector is STILL absent it stays a no-op (semantic search is unavailable
  wholesale there — nothing to heal).

  Scope note: this restores the COLUMNS (correctness — reads and the dual-write need
  them). The legacy HNSW indexes (`20260410022906` etc.) are also guard-skipped on
  such installs; without them the legacy `<->` read is an exact sequential scan —
  correct, and fine for a fresh small corpus. Re-adding those indexes is a
  performance-only follow-up.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'articles' AND column_name = 'embedding'
        ) THEN
          ALTER TABLE articles ADD COLUMN embedding vector(1536);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'memories' AND column_name = 'embedding'
        ) THEN
          ALTER TABLE memories ADD COLUMN embedding vector(1536);
        END IF;
      END IF;
    END $$;
    """)
  end

  # No-op: this migration only ADDS columns that earlier migrations already own.
  # Dropping them here would fight `20260410022854`/`20260709000000` ownership and
  # could destroy a healed column's data. Reversal belongs to those migrations.
  def down, do: :ok
end
