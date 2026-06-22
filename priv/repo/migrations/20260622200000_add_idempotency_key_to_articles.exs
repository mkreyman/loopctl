defmodule Loopctl.Repo.Migrations.AddIdempotencyKeyToArticles do
  use Ecto.Migration

  @moduledoc """
  Adds a per-article `idempotency_key` for idempotent capture (#137).

  A client supplies a stable key per logical article (e.g. a content hash, or
  `book:<id>:note:<n>`). Re-capturing the same key is a clean no-op that returns
  the existing article instead of creating a partial duplicate. This is distinct
  from `source_type`/`source_id`, which identify the SHARED source entity (a
  review, an ingestion job, a book) across many articles and so cannot be unique.

  The partial unique index allows unlimited rows with a NULL key (the default,
  for callers that don't opt into idempotency) while enforcing one article per
  (tenant_id, idempotency_key) when a key is given.
  """

  def change do
    alter table(:articles) do
      add :idempotency_key, :string
    end

    create unique_index(:articles, [:tenant_id, :idempotency_key],
             name: :articles_tenant_idempotency_key_idx,
             where: "idempotency_key IS NOT NULL"
           )
  end
end
