defmodule Loopctl.Repo.Migrations.AddEmbeddingContentHashToArticles do
  @moduledoc """
  Idempotency key for article embedding generation (BYO embeddings review #12).

  Stores the SHA-256 hex digest of the exact text that was embedded (title + body,
  truncated) alongside the vector. `ArticleEmbeddingWorker` skips re-calling the
  (paid) provider on an Oban retry when the article already carries an embedding
  whose stored content-hash matches the current content — so a retry after a
  post-embed failure never re-bills the tenant for identical content.

  Nullable, no backfill: existing articles simply have `NULL` until their next
  embedding refresh.
  """
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :embedding_content_hash, :string, null: true
    end
  end
end
