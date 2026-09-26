defmodule Loopctl.Repo.Migrations.AddSourceMd5ToArticleEmbeddings do
  @moduledoc """
  Which version of its article an embedding row was made from (#896).

  `source_md5` is the md5 of `title <> "\\n\\n" <> body` as the writer read it. Postgres
  computes the same expression over the article's current text, so "is this system
  article embedded from its current text" is one anti-join, with no clock involved and no
  dependence on how the article was written (a changeset, or a seeding migration's raw
  upsert). `embedding_content_hash` cannot serve: it hashes the `TextBudget`-cut text,
  which Postgres cannot reproduce.

  Nullable and not backfilled. A row without it reads stale once; the materialization
  worker then compares the stored content hash with the current text and, when they
  match, only stamps `source_md5`, with no provider call.
  """
  use Ecto.Migration

  def change do
    alter table(:article_embeddings) do
      add :source_md5, :string
    end
  end
end
