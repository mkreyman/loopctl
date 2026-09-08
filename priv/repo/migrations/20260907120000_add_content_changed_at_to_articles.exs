defmodule Loopctl.Repo.Migrations.AddContentChangedAtToArticles do
  @moduledoc """
  AUTHORED age for the recency prior, separated from LAST-MUTATION time (#791).

  `Loopctl.Knowledge.RankingPriors.recency_decay/2` measured a document's age from
  `updated_at`, which ANY write to the row bumps — a re-embed / content-hash refresh
  (`Loopctl.Knowledge.update_embedding/4`), a link write, a suppression flip. A model
  migration or a bulk re-embed therefore reset a years-old note's apparent freshness to "now"
  and, run across the whole corpus, FLATTENED the recency signal for every document at once.
  The prior is live by default (`:knowledge_recency_weight`, `config/config.exs`) and rides
  the primary search path, so the next embedding migration would have degraded ranking
  corpus-wide with nothing reporting it.

  `content_changed_at` is stamped on insert and advanced ONLY when the BODY actually changes
  (`Loopctl.Knowledge.Article.create_changeset/2` and the `stamp_content_changed_at/1` step in
  `update_changeset/2`). A re-embed, a content-hash refresh, a link write, a suppression flip,
  a curation mark and the nightly `:generic_title` retitle all leave it alone — none of them
  changes what the document SAYS.

  **Never add `:content_changed_at` to a changeset `cast` list.** It is a ranking input, so a
  caller that could write it could pin its own article at maximum freshness forever — the same
  "a ranking prior must not read a caller-writable field" rule that moved the MOC-hub signal
  off `tags` and onto `idempotency_key`. A COLUMN and not a `metadata` key for the reason
  `previous_title` (20260826120000), `staged_draft_at` (20260827120000) and the suppression
  trio (20260905120000) are columns: `metadata` is cast and whole-map-REPLACED by
  `PATCH /api/v1/knowledge/:id`, so one ordinary request would erase it.

  ## Ordering matters — add nullable, THEN set the default

  A `DEFAULT` of the clock is VOLATILE, so adding the column with that default already
  attached would rewrite the table and stamp every existing row with the migration's own
  clock — the corpus-wide flattening this column exists to prevent, performed by the fix
  itself, and with no chance to seed the real value. So: catalog-only ALTER first, then
  attach the default for future inserts. `SET DEFAULT` touches no existing row, so the
  schema change rewrites nothing; the row write is the batched backfill below. The default
  is `timezone('utc', now())` and not `now()`: the column is `timestamp WITHOUT time zone`,
  so a `timestamptz` is cast through the session `TimeZone`, and a non-UTC database would
  store local wall time on every `insert_all` path that skips the changeset.

  ## Backfill — batched, and it is what makes the column true for the legacy corpus

  Seeding `content_changed_at := updated_at` freezes each pre-#791 row's apparent age into a
  field no later write moves. It bakes in flattening that already happened — there is no
  body-revision trail to reconstruct authored time from — but leaving the column NULL bakes in
  that same past AND keeps every FUTURE write flattening the row, since the `coalesce` would
  read `updated_at` forever: the next bulk re-embed still resets the corpus to "now" and
  empties the staleness lint, the outcome #791 exists to stop. (`inserted_at` is wrong the
  other way — it understates every article edited after creation and floods the lint.)

  It runs OUTSIDE the ADD COLUMN transaction in `@batch_size` chunks: no long lock, ~86k rows
  not in one transaction, autovacuum reclaiming between batches (an HNSW scan SKIPS dead
  elements, so unvacuumed churn makes live rows unreachable to the semantic lane), and Fly's
  5-minute `release_command` budget spent a batch at a time. `@max_batches` bounds the loop; a
  row it does not reach stays NULL and falls back to `updated_at` as before.

  ## No index

  The prior reads this column out of the lane projections. The staleness lint filters and
  orders on `coalesce(content_changed_at, updated_at)` — a non-sargable expression no plain
  b-tree can serve — and `articles.updated_at`, which that scan filtered on before, carries
  no index either, so the plan class is unchanged. An expression index is the only shape
  that would help, and it has no reader yet.

  ## RLS

  Nothing to do. `articles` already has row-level security with its per-tenant policy; adding a
  column does not change it, and the policy is on the ROW, so the new column inherits it. The
  `tenancy-rls` skill's `ENABLE ROW LEVEL SECURITY` rule is for NEW tables. Checked.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  # Rows per statement; the loop bound (~29x the corpus) stops an unreachable row spinning.
  @batch_size 5_000
  @max_batches 500

  def up do
    alter table(:articles) do
      add_if_not_exists :content_changed_at, :utc_datetime_usec
    end

    execute(
      "ALTER TABLE articles ALTER COLUMN content_changed_at SET DEFAULT now() AT TIME ZONE 'utc'"
    )

    # `alter`/`execute` are QUEUED until `up/0` returns; `repo().query!` is not.
    flush()
    backfill_authored_age()
  end

  # One bounded UPDATE per batch, each its own transaction. Idempotent (NULL rows only).
  defp backfill_authored_age do
    Enum.reduce_while(1..@max_batches, :ok, fn _batch, acc ->
      %{num_rows: rows} =
        repo().query!("""
        WITH batch AS (
          SELECT id FROM articles WHERE content_changed_at IS NULL LIMIT #{@batch_size}
        )
        UPDATE articles a SET content_changed_at = a.updated_at
        FROM batch WHERE a.id = batch.id
        """)

      if rows == 0, do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  def down do
    alter table(:articles) do
      remove_if_exists :content_changed_at, :utc_datetime_usec
    end
  end
end
