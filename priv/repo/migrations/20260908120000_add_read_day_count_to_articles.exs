defmodule Loopctl.Repo.Migrations.AddReadDayCountToArticles do
  @moduledoc """
  The USAGE signal the importance ranking prior reads (#790).

  `Loopctl.Knowledge.RankingPriors` had no importance term at all, so a note nothing has
  opened in eleven months ranked level with one four sessions opened last week at equal
  relevance and age. `Knowledge.heat_index/2` already treats usage as the authority on
  importance, and heat never reached ranking.

  Heat cannot be READ at ranking time: `heat_index/2` is a `HeavyRead` aggregate over
  `article_access_events` plus an `AdminRepo` projection under a split node-level pool bound,
  while `RankingPriors` is pure and `merge_results/5` must stay DB-free. So the value is
  STORED on the row and projected onto the result map, exactly the way `category`,
  `content_changed_at`, `tags` and `idempotency_key` already are.

  ## What the column holds

  The number of DISTINCT UTC DAYS on which this article received a caller-chosen body read
  (`Knowledge.heat_read_access_types/0`, i.e. `get`) inside the stamping window. NOT raw read
  counts and NOT distinct readers:

    * raw counts are the pinning defect #567/#569/#572 were each fixed for — an article can
      inflate its own rank with a `knowledge_get` loop, and a day counts once however long
      the loop runs;
    * distinct READERS is near-flat here. `heat_counts_query/5` records why in its own
      comment: "under a fleet sharing one key EVERY article ties at 1".

  Drills stay uncounted, as they are on the heat index, for the #569/#572 reason: being SHOWN
  must not produce the rank that showed it.

  ## No backfill, and that is the point

  NULL is the exact pre-change behaviour: `RankingPriors.importance_factor/4` returns a
  factor of exactly 1.0 for a nil or zero count, so every row in the corpus keeps the score
  it has today until the nightly pass stamps it. There is nothing to reconstruct — the
  measurement is derived from `article_access_events`, which the nightly stamp reads directly
  — so the batched, `@disable_ddl_transaction`, resumable shape #791's migration needed
  (20260907120000, where a NULL column would have kept ranking on the poisoned field forever)
  buys nothing here. This is a catalog-only `ADD COLUMN` with no default and no volatile
  expression: it rewrites no rows and takes no long lock.

  Deliberately NO default either. A `DEFAULT 0` is not more correct than NULL — both read as
  neutral — and attaching one would only invite a future reader to treat "0" as measured
  rather than as absent.

  ## Never cast it

  It is a live RANKING INPUT, so a caller that could write it could pin its own article at
  maximum importance forever — the same rule that moved the MOC-hub signal off `tags` and
  onto `idempotency_key`, and that keeps `content_changed_at` out of every cast list. A
  COLUMN and not a `metadata` key for the reason `previous_title` (20260826120000),
  `staged_draft_at` (20260827120000), the suppression trio (20260905120000) and
  `content_changed_at` (20260907120000) are columns: `metadata` is cast and
  whole-map-REPLACED by `PATCH /api/v1/knowledge/:id`, so one ordinary request would erase
  it — and here erasure is not the worst case, since the same request could SET it.

  ## No index

  The prior reads this column out of the lane projections, by primary key. The nightly stamp
  writes it by an id list it has just computed from the events table. Neither is a predicate
  on this column, so there is nothing for an index to serve.

  ## RLS

  Nothing to do. `articles` already has row-level security with its per-tenant policy; adding
  a column does not change it, and the policy is on the ROW, so the new column inherits it.
  The `tenancy-rls` skill's `ENABLE ROW LEVEL SECURITY` rule is for NEW tables. The stamp
  writes through `AdminRepo`, where RLS does nothing and the explicit `tenant_id` predicate
  is the whole isolation — see `Loopctl.Knowledge.Importance`, which carries that predicate
  on both the read and the write, and never stamps a system canonical (NULL `tenant_id`),
  since no single tenant's reads may decide a shared row's rank.
  """

  use Ecto.Migration

  def up do
    alter table(:articles) do
      add_if_not_exists :read_day_count, :integer
    end
  end

  def down do
    alter table(:articles) do
      remove_if_exists :read_day_count, :integer
    end
  end
end
