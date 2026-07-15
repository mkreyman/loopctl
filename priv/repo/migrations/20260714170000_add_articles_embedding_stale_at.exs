defmodule Loopctl.Repo.Migrations.AddArticlesEmbeddingStaleAt do
  use Ecto.Migration

  # US-37.4 (review MED #2): a content edit of an ALREADY-embedded published
  # article must NOT destroy its existing vector while it waits for the async
  # batch drainer to re-embed it — otherwise the article drops out of vector
  # search / novelty scoring for the whole (batching-lengthened) async gap.
  #
  # `embedding_stale_at` is a non-destructive staleness marker: on a content
  # change we set it (keeping the CURRENT vector searchable) instead of nulling
  # `embedding`. The row re-enters the pending set via
  # `list_articles_pending_embedding/2`'s `embedding IS NULL OR embedding_stale_at
  # IS NOT NULL` predicate; the batch worker overwrites the vector and CLEARS the
  # flag (`Article.embedding_changeset/3`). The old vector survives until the
  # replacement lands.
  #
  # The partial index backs BOTH the per-tenant pending reader and the
  # cross-tenant `tenant_ids_with_pending_*` sweep query (review HIGH #1), so the
  # periodic backstop sweep is an index scan, not a seq scan over every article.

  def change do
    alter table(:articles) do
      add :embedding_stale_at, :utc_datetime_usec
    end

    create index(:articles, [:tenant_id, :updated_at, :id],
             where:
               "status = 'published' AND (embedding IS NULL OR embedding_stale_at IS NOT NULL)",
             name: :articles_pending_embedding_idx
           )
  end
end
