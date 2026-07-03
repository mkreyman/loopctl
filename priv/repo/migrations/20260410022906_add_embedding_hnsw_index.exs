defmodule Loopctl.Repo.Migrations.AddEmbeddingHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # The capability-based (amname='hnsw') detection/create/drop SQL lives in
  # `Loopctl.Repo.HnswIndex`, parameterized by table name, so the migration
  # behaviour can be exercised in isolation against a per-test throwaway table
  # (see test/loopctl/repo/reconcile_hnsw_index_migration_test.exs) instead of
  # the shared, sandbox-uninsolated `articles_embedding_hnsw_idx`. For the
  # default `"articles"` these emit the same SQL this migration always ran.

  def up do
    # AC-27.14.2: the existence guard is capability-based (ANY hnsw index on
    # articles already present), symmetric with down/0's amname-based
    # detection — NOT a hard-coded `indexname = 'articles_embedding_idx'`
    # check. The old name-based guard only saw the migration's own name, so
    # from prod's drift state {articles_embedding_hnsw_idx} this up-step would
    # create a SECOND, redundant hnsw index. Skipping when any hnsw index on
    # articles(embedding) exists (detected by am.amname='hnsw') means the
    # two-index state can never arise.
    execute(Loopctl.Repo.HnswIndex.create_if_absent_sql("articles"))
  end

  def down do
    # AC-27.14.2: drop ALL hnsw indexes actually present on articles(embedding),
    # detected by access method (amname='hnsw'), NOT by a hard-coded name. The
    # original down-step was `DROP INDEX IF EXISTS articles_embedding_idx`,
    # which silently NO-OPs against prod's out-of-band
    # `articles_embedding_hnsw_idx` — a rollback that would leave the live index
    # orphaned. Iterating over EVERY hnsw index (rather than `LIMIT 1`) means
    # that even if multiple hnsw indexes somehow coexist, the down-step leaves
    # none orphaned.
    execute(Loopctl.Repo.HnswIndex.drop_all_sql("articles"))
  end
end
