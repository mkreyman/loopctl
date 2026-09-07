defmodule Loopctl.Repo.Migrations.AddContentChangedAtToArticles do
  @moduledoc """
  AUTHORED age for the recency prior, separated from LAST-MUTATION time (#791).

  `Loopctl.Knowledge.RankingPriors.recency_decay/2` measured a document's age from
  `updated_at`, and `updated_at` is bumped by ANY write that changes the row —
  including a re-embed / content-hash refresh (`Loopctl.Knowledge.update_embedding/4`),
  a link write, a suppression flip. A model migration or a bulk re-embedding backfill
  therefore reset a years-old note's apparent freshness to "now" and, run across the
  whole corpus, FLATTENED the recency signal for every document at once. The prior is
  live by default (`:knowledge_recency_weight`, `config/config.exs`) and rides the
  primary search path, so the next embedding migration would have degraded ranking
  corpus-wide with nothing reporting that it had happened.

  `content_changed_at` is stamped on insert and advanced ONLY when the BODY actually
  changes (`Loopctl.Knowledge.Article.create_changeset/2` and the
  `stamp_content_changed_at/1` step in `update_changeset/2`). A re-embed, a
  content-hash refresh, a link write, a suppression flip, a curation mark and the
  nightly `:generic_title` retitle all leave it alone — none of them changes what the
  document SAYS.

  **Never add `:content_changed_at` to a changeset `cast` list.** It is a ranking
  input, so a caller that could write it could pin its own article at maximum
  freshness forever — the same "a ranking prior must not read a caller-writable
  field" rule that moved the MOC-hub signal off `tags` and onto `idempotency_key`.
  A COLUMN and not a `metadata` key for the reason `previous_title` (20260826120000),
  `staged_draft_at` (20260827120000) and the suppression trio (20260905120000) are
  columns: `metadata` is cast and whole-map-REPLACED by
  `PATCH /api/v1/knowledge/:id`, so one ordinary request would erase it.

  ## Ordering matters — add nullable, THEN set the default

  A `DEFAULT now()` is VOLATILE, so adding the column with that default already
  attached would rewrite the table and stamp every existing row with the migration's
  own clock — which is precisely the corpus-wide flattening this column exists to
  prevent, performed by the fix itself. So: catalog-only ALTER first, and only then
  attach the default for future inserts. `SET DEFAULT` on an existing column touches
  no existing row, so this migration rewrites nothing.

  ## No backfill — the nil-fallback IS the backfill

  Nothing recorded authored time before this migration and there is no body-revision
  trail to reconstruct it from, so every whole-corpus guess is wrong in one direction:
  `inserted_at` understates every article edited after creation (and would flip each of
  them into the staleness lint at deploy, whose suggested_action is "review and update
  or archive"), while `updated_at` bakes in the exact re-embed flattening this column
  exists to undo. Both are also a whole-table UPDATE run inside the ADD COLUMN's ACCESS
  EXCLUSIVE transaction: ~86k rows, each re-running the STORED generated `search_vector`
  over the full body, writing entries into 19 indexes, and leaving a dead
  `articles_embedding_hnsw_idx` element behind — and an HNSW scan SKIPS dead elements,
  so live rows go UNREACHABLE to the semantic lane until a VACUUM on a QUIET database.
  Long enough, too, to risk Fly's 5-minute default `release_command` timeout.

  So legacy rows stay NULL and `RankingPriors.recency_timestamp/1` — and the SQL
  `coalesce` the staleness lint uses — resolves them to `updated_at`, exactly as today.
  The deploy therefore changes no existing row's ranking or lint verdict at all; the
  column diverges from `updated_at` only as real body edits stamp it. That also makes
  the nil-fallback the LIVE path for the whole pre-#791 corpus rather than a claim about
  rows that do not exist.

  ## No index

  The prior reads this column out of the lane projections. The staleness lint does
  filter and order on it, but on `coalesce(content_changed_at, updated_at)` — a
  non-sargable expression no plain b-tree index can serve — and `articles.updated_at`,
  which that same scan filtered on before, carries no index either, so the plan class is
  unchanged. An expression index is the only shape that would help, and it has no reader
  yet.

  ## RLS

  Nothing to do. `articles` already has row-level security enabled with its per-tenant
  policy; adding a column to an existing table does not change the policy, and the
  policy is on the ROW, so the new column inherits it. The `tenancy-rls` skill's
  `ENABLE ROW LEVEL SECURITY` rule applies to NEW tables only. Checked, not assumed.
  """

  use Ecto.Migration

  def up do
    alter table(:articles) do
      add_if_not_exists :content_changed_at, :utc_datetime_usec
    end

    # No backfill: see the moduledoc. Existing rows stay NULL and resolve to
    # `updated_at` through the nil-fallback, so the deploy is behaviour-neutral.
    execute("ALTER TABLE articles ALTER COLUMN content_changed_at SET DEFAULT now()")
  end

  def down do
    alter table(:articles) do
      remove_if_exists :content_changed_at, :utc_datetime_usec
    end
  end
end
