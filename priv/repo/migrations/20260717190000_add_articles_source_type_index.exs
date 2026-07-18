defmodule Loopctl.Repo.Migrations.AddArticlesSourceTypeIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Index backing the hourly IngestionHealth capture-silence scan
  (`Loopctl.Knowledge.IngestionHealth.detect/1`).

  detect/1 is a GLOBAL scan: it filters `articles.inserted_at >= window_start`
  (the rolling 30-day establishment window), joins to active tenants, groups by
  (tenant_id, source_type) and reads max(inserted_at). The COST that matters is the
  read must be bounded to the recency window, NOT the whole corpus.

  Column order therefore LEADS with `inserted_at` so the `inserted_at >= window_start`
  predicate is an index RANGE SEEK — the planner reads only the last-30-days slice of
  the index instead of full-scanning `articles` (which would grow O(total articles ever)
  as the corpus ages). `(tenant_id, source_type)` trail the range column so the scan is
  covering for the group/select (index-only), avoiding heap fetches. An earlier draft
  put `inserted_at` LAST, which gave the planner no leading equality/range column to
  seek on — that could not bound the read to the window at scale.

  Built CONCURRENTLY (outside a DDL transaction) so the build does not take a SHARE
  lock that blocks INSERT/UPDATE/DELETE on the hot, growing `articles` table — i.e. so
  the migration for a capture-silence monitor does not itself cause capture silence at
  deploy time. Mirrors the existing articles-index convention (metadata GIN, source
  keyset, general keyset), all of which use @disable_ddl_transaction + CONCURRENTLY.
  """

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_inserted_tenant_source_idx
    ON articles (inserted_at, tenant_id, source_type)
    WHERE source_type IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS articles_inserted_tenant_source_idx")
  end
end
