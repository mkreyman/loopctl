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

  ## Ordering matters — add nullable, backfill, THEN set the default

  A `DEFAULT now()` is VOLATILE, so adding the column with that default already
  attached would rewrite the table and stamp every existing row with the migration's
  own clock — which is precisely the corpus-wide flattening this column exists to
  prevent, performed by the fix itself. So: catalog-only ALTER first, backfill from
  `inserted_at`, and only then attach the default for future inserts. `SET DEFAULT`
  on an existing column touches no existing row.

  ## The backfill: `inserted_at`, and why that is the honest choice

  Nothing recorded authored time before this migration, and there is no body-revision
  trail to reconstruct it from. `inserted_at` is the best available evidence and it is
  CONSERVATIVE in the safe direction: `inserted_at <= updated_at` always holds, so a
  row can only be made to look OLDER than it looks today, never newer. The failure
  this issue is about is documents looking falsely NEW.

  It is not exact — an article whose body was genuinely edited after creation is
  understated by the gap — but the alternative, leaving the column null and falling
  back to `updated_at`, keeps the whole corpus on the field the re-embed poisons.
  The nil-fallback in `RankingPriors.recency_timestamp/1` stays regardless, so a row
  this backfill misses behaves exactly as it does today.

  ## No index

  The prior READS this column out of the lane projections and never filters or orders
  by it, so an index would serve no query shape. Adding one on a ~86k-row table for a
  column no predicate mentions is cost with no reader.

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

    # One statement over the whole table. `inserted_at` is NOT NULL, so this leaves no
    # row null and the `IS NULL` guard makes a re-run a no-op.
    execute(
      "UPDATE articles SET content_changed_at = inserted_at WHERE content_changed_at IS NULL"
    )

    execute("ALTER TABLE articles ALTER COLUMN content_changed_at SET DEFAULT now()")
  end

  def down do
    alter table(:articles) do
      remove_if_exists :content_changed_at, :utc_datetime_usec
    end
  end
end
