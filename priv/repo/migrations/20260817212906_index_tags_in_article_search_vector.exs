defmodule Loopctl.Repo.Migrations.IndexTagsInArticleSearchVector do
  @moduledoc """
  Phase 3 of the KB retrieval plan — put the curated TAG vocabulary into the keyword index.

  `articles.search_vector` has indexed `title` (weight A) and `body` (weight B) since
  `20260410021836`. It has never indexed `tags`, and a production measurement is what makes
  that a defect rather than a design choice: sampling 3,000 published articles
  (2026-08-17) found **59.9% of topical tag instances carry vocabulary that appears
  nowhere in the article's own title or body** — 28,720 instances, only 11,508 findable.
  So roughly three fifths of the hand-curated topical vocabulary in this corpus cannot be
  keyword-matched at all. Re-measure with the query in
  `docs/runbooks/retrieval_eval.md`.

  Tags land at weight `C`, strictly below title and body, so a tag match never outranks a
  title match on `ts_rank_cd`.

  ## Machine-minted provenance tags are excluded, and why the exclusion is not cosmetic

  Topical tags are LLM-generated once at ingest (`Loopctl.Workers.ContentIngestionWorker`
  -> `LlmExtractor`, which returns title/body/category/tags in one shot); nothing re-tags an
  existing article. Alongside them the harvest sourcers mint opaque per-source PROVENANCE
  ids as tags — `url-42516bb95051`, `book-0be008289fe8`, `yt-bH722QgRlhQ`, `pp-1-12` — and
  since #583 those move into the reserved `idem-<family>-<digest>` namespace.

  Postgres tokenizes a hyphenated word into the compound AND its parts, so indexing them
  would put the bare lexemes `url`, `book`, `doc`, `part`, `chapter`, `idem` onto tens of
  thousands of rows — measured 2026-08-17: `doc-` 37,877 instances, `book-` 17,047, `pp-`
  14,108, `yt-` 11,573, `url-` 8,671. Every one of those is an ordinary English query word,
  so the cost is not index size but PRECISION on legitimate queries.

  ## The prefix list is NOT written here

  It comes from `Loopctl.Knowledge.ProvenanceTags.sql_pattern/0`, the module that now owns
  the one answer to "which tag prefixes are provenance rather than vocabulary" and derives
  `idem-` from `IdempotencyTag.reserved_prefix/0` so the reserved namespace cannot drift
  from the thing suppressing it. A hand-written list here would have been the THIRD in this
  repo, and its first draft proved the point by omitting `idem-` entirely — so every future
  capture id would have been indexed.

  A generated column cannot call Elixir, so the pattern is BAKED IN at migration time, the
  same way `20260724190000` bakes in the regconfig. `Loopctl.Knowledge.ProvenanceTagsTest`
  fails if the stored pattern and the current list diverge, and the remedy is a new
  migration.

  ## Cost

  `DROP COLUMN` + `ADD COLUMN ... GENERATED` rewrites the table and rebuilds the GIN
  index under an ACCESS EXCLUSIVE lock. Measured on production 2026-08-17: 85,294 rows,
  138 MB heap, 59 MB FTS index — on the order of a minute or two during which reads and
  writes to `articles` block. That is a real, short, self-healing outage and it is called
  out in `CHANGELOG.md` rather than left for an operator to discover.
  """

  use Ecto.Migration

  alias Loopctl.Knowledge.ProvenanceTags
  alias Loopctl.Search.Regconfig

  def up do
    create_searchable_tags_function()
    rebuild(Regconfig.get(), tags: true)
  end

  def down do
    rebuild(Regconfig.get(), tags: false)
    execute("DROP FUNCTION IF EXISTS loopctl_searchable_tags(text[])")
  end

  # `array_to_string/2` is declared STABLE by Postgres (its volatility has to cover every
  # element type's output function), and a generated column rejects anything not
  # IMMUTABLE. For `text[]` with a constant separator the result genuinely depends on the
  # input alone, so wrapping it in an IMMUTABLE SQL function is sound rather than a lie to
  # the planner. `tags::text` was the other candidate and is rejected for the same
  # volatility reason.
  defp create_searchable_tags_function do
    pattern = ProvenanceTags.sql_pattern()

    execute("""
    CREATE OR REPLACE FUNCTION loopctl_searchable_tags(text[])
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $fn$
      SELECT coalesce(
        array_to_string(
          ARRAY(SELECT t FROM unnest($1) AS t WHERE t !~ '#{pattern}'),
          ' '
        ),
        ''
      )
    $fn$
    """)
  end

  defp rebuild(regconfig, tags: tags?) do
    tag_clause =
      if tags? do
        " ||\n      setweight(to_tsvector('#{regconfig}', loopctl_searchable_tags(tags)), 'C')"
      else
        ""
      end

    execute("DROP INDEX IF EXISTS articles_search_vector_idx")
    execute("ALTER TABLE articles DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE articles ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('#{regconfig}', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('#{regconfig}', coalesce(body, '')), 'B')#{tag_clause}
    ) STORED
    """)

    execute("CREATE INDEX articles_search_vector_idx ON articles USING GIN (search_vector)")
  end
end
