defmodule Loopctl.Repo.Migrations.AddArticleEmbeddingsArticleIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc false
  # US-41.1 (review) — index `article_embeddings(article_id)`.
  #
  # Every btree the side-table create migration built LEADS with `tenant_id`
  # (pkey, (tenant_id, article_id, dim), (tenant_id, dim), the per-dimension HNSW
  # partials), so NOTHING serves a lookup on `article_id` ALONE. But two hot paths do
  # exactly that with no `tenant_id` predicate:
  #
  #   * the `articles_propagate_live_denorm` AFTER UPDATE trigger runs
  #     `UPDATE article_embeddings ae ... WHERE ae.article_id = NEW.id` on every
  #     article status transition (publish / archive / supersede). It cannot carry
  #     `tenant_id` because a SYSTEM article's rows span every tenant.
  #   * the FK `article_id REFERENCES articles(id) ON DELETE CASCADE` needs an index on
  #     the referencing column, or every article delete seq-scans the whole side table.
  #
  # `memory_embeddings` escapes this only because it happens to carry
  # `(memory_id, subject_id)`. Built CONCURRENTLY (outside a ddl transaction) so the
  # build does not block writes on a table as large as the whole article corpus.

  def up do
    create_if_not_exists(
      index(:article_embeddings, [:article_id],
        name: :article_embeddings_article_id_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:article_embeddings, [:article_id],
        name: :article_embeddings_article_id_index,
        concurrently: true
      )
    )
  end
end
