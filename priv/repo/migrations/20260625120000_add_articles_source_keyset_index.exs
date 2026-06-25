defmodule Loopctl.Repo.Migrations.AddArticlesSourceKeysetIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc false
  # Composite btree index backing the BY-SOURCE knowledge-index KEYSET enumeration
  # (US-27.9b):
  #   WHERE tenant_id = $1 AND source_id = $2
  #     AND (inserted_at, id) > ($3, $4)
  #   ORDER BY inserted_at ASC, id ASC LIMIT n+1
  #
  # by-source is a SELECTIVE scalar equality (`source_id =`). Without this index the
  # planner would walk the (tenant_id, inserted_at, id) keyset btree and apply
  # `source_id =` as a heap-recheck — at prod scale that scans far past the matching
  # rows for a deep page (a full-corpus-ish read the :scale_nightly refute_full_scan
  # would catch). Leading with (tenant_id, source_id) lets the planner seek straight to
  # the source's rows and walk them in (inserted_at, id) order — strictly index-ordered,
  # no Sort. The general (tenant_id, inserted_at, id) btree from US-27.9a remains the
  # residual-free / by-tag fallback.
  #
  # Built CONCURRENTLY (outside a ddl transaction) so the build does not block writes
  # to the ~76k-row articles table online.

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_tenant_source_inserted_id_idx
    ON articles (tenant_id, source_id, inserted_at, id)
    WHERE source_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS articles_tenant_source_inserted_id_idx")
  end
end
