defmodule Loopctl.Repo.Migrations.AddOriginAttributionToArticleAccessEvents do
  use Ecto.Migration

  @moduledoc """
  Records WHICH search surfaced an article that an agent then opened.

  Until now the link was not stored, only inferred at query time, and the inference had two
  structural blind spots that each produced a plausible wrong number:

  1. `get`/`context`/`drill` rows carry no `search_id` — only `access_type = 'search'` rows
     do (one per surfaced result). So the obvious join measures "did the search return
     anything", which is ~98% everywhere.
  2. `RetrievalMetrics.with_follow_through/2` correlates on `api_key_id`, and the injected
     recall hook searches under a DIFFERENT key from the session that reads. Measured
     2026-08-17: the hook's key made 1,071 searches and 1 read ever, while the MCP key made
     0 searches of that kind and 2,535 reads. The whole injected channel — 71% of traffic —
     therefore scores a structural ZERO in that metric, and a zero there means "unmeasurable",
     not "nobody read anything".

  `origin_search_id` is resolved SERVER-SIDE at write time (`Analytics.do_record_sync/5`) and
  is never accepted from a caller. That is the same rule `search_id` already follows
  (#582): a call-level identity the caller controls is a metric the caller can game, and here
  a forged origin would let any agent manufacture apparent follow-through for its own article
  — the heat-index failure (#567/#569) one table over.

  `origin_attribution` labels HOW the link was established, so a reader never mistakes an
  inference for an observation:

    * `same_key`  — the reading key also surfaced the article in the window. Exact.
    * `cross_key` — another key in the same tenant surfaced it. This is the hook -> session
                    case; plausible, and NOT proof, because two agents in one tenant can
                    search the same article independently.
    * `none`      — nothing surfaced it in the window: the agent went straight to the
                    article (a wiki link, an id cited in CLAUDE.md, a MOC hop). Previously
                    indistinguishable from "no follow-through", though it is the opposite.

  Both columns are nullable: rows written before this migration have no origin, and surfacing
  rows (`search`, `index`) never get one. RLS is NOT modified — `tenant_id` remains the sole
  isolation boundary and these are reporting dimensions, not trust boundaries.
  """

  def up do
    alter table(:article_access_events) do
      add :origin_search_id, :binary_id
      add :origin_attribution, :string
    end

    # The write-time lookup: "most recent surfacing row for this (tenant, article)". Partial
    # on the surfacing type so the index stays small and the lookup stays a point query —
    # this runs inside the fire-and-forget recorder on every read, so it must not become a
    # scan. Ordering by accessed_at DESC serves the LIMIT 1 directly.
    execute(
      """
      CREATE INDEX article_access_events_surface_lookup_idx
        ON article_access_events (tenant_id, article_id, accessed_at DESC)
        WHERE access_type = 'search'
      """,
      "DROP INDEX IF EXISTS article_access_events_surface_lookup_idx"
    )

    # The read side: roll opens up by the search that produced them.
    execute(
      """
      CREATE INDEX article_access_events_origin_search_idx
        ON article_access_events (tenant_id, origin_search_id)
        WHERE origin_search_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS article_access_events_origin_search_idx"
    )

    # Counting the attribution classes for a day without touching the heap.
    execute(
      """
      CREATE INDEX article_access_events_origin_attribution_idx
        ON article_access_events (tenant_id, origin_attribution, accessed_at)
        WHERE origin_attribution IS NOT NULL
      """,
      "DROP INDEX IF EXISTS article_access_events_origin_attribution_idx"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS article_access_events_origin_attribution_idx")
    execute("DROP INDEX IF EXISTS article_access_events_origin_search_idx")
    execute("DROP INDEX IF EXISTS article_access_events_surface_lookup_idx")

    alter table(:article_access_events) do
      remove :origin_attribution
      remove :origin_search_id
    end
  end
end
