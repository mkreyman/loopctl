defmodule Loopctl.Repo.Migrations.AddSearchVectorToDocumentChunks do
  use Ecto.Migration

  @moduledoc """
  US-43.2 — the KEYWORD lane of `corpus_search`.

  US-43.1 created `document_chunks` and deliberately left the FTS column to this
  story, because this is the story that adds the lane that reads it.

  ## `coalesce(text, '')` is load-bearing, not defensive

  `text` is NULLABLE: that is the `:client_embedded` (mode B) state, where the
  client embedded locally and the server holds a vector it cannot read. A
  generated expression over a NULL column yields NULL, so the coalesce is what
  keeps the column computable for every row — and a mode B chunk then carries an
  EMPTY tsvector, which no `websearch_to_tsquery` can match. Mode B therefore gets
  no keyword lane by construction rather than by a mode check at the query site.

  ## The regconfig is baked in at migration time

  A generated column cannot read runtime config, so `Loopctl.Search.Regconfig.get/0`
  is resolved HERE and interpolated as a literal (the same shape
  `20260410021836_add_search_vector_to_articles.exs` uses for `articles`, and the
  reason `to_tsvector` stays IMMUTABLE and therefore indexable). The query site
  binds the SAME regconfig as a `?::text::regconfig` parameter.

  This does NOT promise the two can never disagree: `20260724190000_apply_fts_regconfig.exs`
  does not re-run when `FTS_REGCONFIG` changes later, so on such a deployment the
  stored vectors keep the stemmer they were built with until an operator rebuilds
  them deliberately. That rebuild is out of scope here, exactly as it is for articles.

  Unlike the article column there is no `setweight` — a chunk has one text field, so
  there are no fields to weight against each other.
  """

  def up do
    regconfig = Loopctl.Search.Regconfig.get()

    execute("""
    ALTER TABLE document_chunks ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('#{regconfig}', coalesce(text, ''))) STORED
    """)

    execute(
      "CREATE INDEX document_chunks_search_vector_idx ON document_chunks USING GIN (search_vector)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS document_chunks_search_vector_idx")
    execute("ALTER TABLE document_chunks DROP COLUMN IF EXISTS search_vector")
  end
end
