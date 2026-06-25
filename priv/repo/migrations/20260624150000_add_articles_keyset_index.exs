defmodule Loopctl.Repo.Migrations.AddArticlesKeysetIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc false
  # Composite btree index backing the article-list KEYSET cursor (US-27.9a):
  #   WHERE tenant_id = $1 AND (inserted_at, id) > ($2, $3)
  #   ORDER BY inserted_at ASC, id ASC LIMIT n+1
  #
  # The cursor key MUST be the (inserted_at, id) TUPLE — `inserted_at` is
  # utc_datetime_usec and bulk insert_all ties timestamps per batch, and the PK
  # is a random binary_id (no monotonic bigint to fall back on). This index lets
  # the planner seek straight to a deep page instead of Seq-Scanning the corpus
  # (AC-27.9a.2; proven by the :scale_nightly refute_full_scan/1 plan test).
  #
  # Built CONCURRENTLY (outside a ddl transaction) so the build does not block
  # writes to the ~76k-row articles table online.

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_tenant_inserted_id_idx
    ON articles (tenant_id, inserted_at, id)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS articles_tenant_inserted_id_idx")
  end
end
