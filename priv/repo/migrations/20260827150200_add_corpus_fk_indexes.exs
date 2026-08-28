defmodule Loopctl.Repo.Migrations.AddCorpusFkIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc false
  # US-43.1 (review) — index the REFERENCING column of the corpus tier's three FKs.
  #
  # Every btree `20260827150000_create_corpus_tables.exs` builds leads with something
  # else — the pkeys, `(corpus_id, source_ref, locator)`, `(tenant_id,
  # document_chunk_id, dim)`, and the per-dimension HNSW partials — so nothing serves
  # the `DELETE FROM <child> WHERE <fk> = $1` that Postgres's referential-integrity
  # cascade issues, with no tenant predicate it could use them with. This is exactly
  # the defect `20260721090000_add_article_embeddings_article_id_index.exs` fixed on
  # `article_embeddings` under "US-41.1 (review)"; the corpus tier copied that table's
  # create migration and not its corrective index.
  #
  #   * `document_chunk_embeddings(document_chunk_id)` — the one that matters. It is
  #     worse here than for articles, whose deletes are single-row and interactive:
  #     `Loopctl.Corpus.delete_chunks_for_source/3` is US-43.2's per-document RE-INDEX
  #     prune, so it deletes a whole document's chunks on every re-index and fires the
  #     RI delete once per chunk — N sequential scans of a table AC-43.1.12 expects to
  #     be large. `delete_corpus/2` has the same shape at corpus scale.
  #   * `document_chunks(tenant_id)` — its only indexes are the pkey and
  #     `(corpus_id, source_ref, locator)`, so the `tenants -> document_chunks`
  #     cascade seq-scans it on tenant delete.
  #   * `corpora(project_id)` — `ON DELETE SET NULL`, so a project delete seq-scans
  #     `corpora`. Smallest table, lowest priority, same one-line fix.
  #
  # `corpora -> document_chunks` needs nothing: the unique index already leads with
  # `corpus_id`. Built CONCURRENTLY, matching the precedent migration.

  def up do
    for {table, column, name} <- indexes() do
      create_if_not_exists(index(table, [column], name: name, concurrently: true))
    end
  end

  def down do
    for {table, column, name} <- indexes() do
      drop_if_exists(index(table, [column], name: name, concurrently: true))
    end
  end

  defp indexes do
    [
      {:document_chunk_embeddings, :document_chunk_id,
       :document_chunk_embeddings_document_chunk_id_index},
      {:document_chunks, :tenant_id, :document_chunks_tenant_id_index},
      {:corpora, :project_id, :corpora_project_id_index}
    ]
  end
end
