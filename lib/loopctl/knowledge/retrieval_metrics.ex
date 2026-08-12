defmodule Loopctl.Knowledge.RetrievalMetrics do
  @moduledoc """
  Retrieval-precision metric (agents' KB #3) — closes the loop on whether retrieval is
  actually improving.

  The signal: of the articles a search SURFACED on a given day — the first
  #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} of each call, which is all
  that gets recorded — how many did the agent then OPEN (a `get`/`context` on the same
  article, by the same api_key, within a follow-through window)? That share is
  `precision`. It's a mechanical proxy, computed
  purely from `article_access_events` — no LLM, no labels — and it should trend UP as
  dedup (#1), navigation (#5) and conflict resolution (#4) make the corpus cleaner and
  the top results more on-target.

  Honest caveat: it measures search → *open*, not search → *useful*. An agent that uses
  a snippet without opening the article counts as a miss, so the absolute number
  undercounts precision. The bias is consistent, so the TREND is the meaningful thing.

  ## What each denominator is (#582)

  `searched` counts RECORDED SURFACED RESULTS — one `article_access_events` row per
  result a search put in front of the agent, capped at the first
  #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} results of each search
  (`Knowledge.maybe_record_search_access/5` writes no more than that per call) — NOT
  search calls. `precision` is therefore
  `followed_through / searched`: "the share of the RECORDED surfaced results the agent
  then opened", i.e. precision@#{Loopctl.Knowledge.Analytics.max_recorded_search_results()},
  not precision over the full result set. A call that returned 50 results contributes
  #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} to `searched`, and an open
  of its rank-35 result correlates to no recorded row and counts in neither term. The
  name reads like a count of searches, which is exactly how it got misreported, so the
  payload also carries `results_recorded` (the same number, named for the unit it
  actually has) and the per-CALL series alongside it:

  - `searches` — distinct `metadata->>'search_id'` values, i.e. actual QUERY-bearing
    search calls. Query-less enumeration (`list` / `list_keyset`) records `"search"`
    rows too, and is EXCLUDED here: paging the corpus is browsing, not searching, and
    counting a page as a search inflates the denominator with calls that were never
    going to be "answered" by an open.
  - `searches_with_follow_through` / `search_follow_through` — the share of SEARCHES
    that led to at least one open. This is the quantity a reader who misreads
    `precision` has in mind; it is now computable instead of being confused for it.
    It carries two biases of its own, in OPPOSITE directions — see "Two more biases"
    below — so read it as an indicator, never as an exact rate.
  - `results_returned` — the true, un-truncated number of results those same counted
    calls returned. Only the first
    #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} results per search get
    a row (`Knowledge.maybe_record_search_access/5`), so this exceeds the number of rows
    those calls recorded whenever a page hit the cap.

  The call-level filter is per ROW, not per day. A row qualifies only if it carries a
  `search_id` (nothing written before #582 does) and a non-enumeration `mode`, so a day
  that MIXES qualifying and non-qualifying rows — the first day after deploy always
  does — reports a PARTIAL `searches`/`results_returned` rather than `0`. For the same
  reason `results_returned` is NOT comparable to `searched`: the two are computed over
  different row populations, and `results_returned < searched` is the normal reading of
  a day whose rows are mostly legacy or enumeration. Compare `results_returned` against
  the rows the COUNTED calls wrote, never against the day-wide `searched`.

  ## Two structural exclusions — precision is an UPPER BOUND

  `article_access_events.article_id` is NOT NULL and every row needs an `api_key_id`, so
  two classes of search are unrecordable and appear in NO denominator here:

  1. a search that returned ZERO results (the purest miss), and
  2. a search made without an api key.

  Both are excluded from numerator and denominator alike, which biases every ratio on
  this surface UP. Do not close the gap by inventing a null-`article_id` row: that would
  put a counted class and an uncounted class on one number, the failure the heat-index
  invariant exists to prevent. `Loopctl.TelemetryEvents.knowledge_hybrid_provenance/0`
  is where hit/miss including empties is observable.

  ## Two more biases on `search_follow_through` — they point OPPOSITE ways

  1. The #{Loopctl.Knowledge.Analytics.max_recorded_search_results()}-row recording cap
     biases it DOWN. A call that returned more results than the cap still counts in
     `searches`, but an open of a result beyond the cap correlates to no recorded row, so
     that call can never reach `searches_with_follow_through`. Bigger pages ⇒ more of the
     followed-through set is invisible.
  2. Crediting biases it UP: an open is credited to EVERY search in the window that
     surfaced that article, not only the one that immediately preceded it.
     `with_follow_through/2` correlates on (tenant, api_key, article, window) and
     deliberately NOT on `search_id`, so refine-and-re-search over an overlapping result
     set — the modal agent flow — credits the missed search as well as the successful
     one, in exactly the repeated-near-miss case this metric exists to surface.

  ## The proxy is gameable in one direction — never optimise it alone

  `precision` rises when a search returns FEWER results, with no better retrieval
  whatsoever: shrink the denominator and the ratio climbs. (Above the recording cap the
  denominator saturates, so returning MORE results stops lowering it — the gaming
  direction bites under the cap only.) Read it WITH the absolute `followed_through` and
  the volume figures (`searched`, `searches`, `results_returned`) — a real improvement
  raises follow-through while volume holds; a gamed one shows the ratio up and the volume
  collapsing.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.RetrievalMetricSnapshot

  @default_window_seconds 1800

  # `"search"` access rows are ALSO written by the query-less enumeration paths —
  # `Knowledge.list_filtered/2` (mode `"list"`) and `Knowledge.list_keyset/2` (mode
  # `"list_keyset"`). They belong in `searched` (they did surface results) but NOT in the
  # per-CALL series, which is documented as counting search calls: an agent paging the
  # corpus would otherwise add one "search" per page and drag `search_follow_through`
  # toward zero without a single search having missed. Every other mode
  # (`keyword`/`semantic`/`combined`/`combined_fallback`/`hybrid_*`) carries a query and
  # is counted.
  @enumeration_modes ~w(list list_keyset)

  # Infrastructure traffic is excluded from EVERY figure here, unconditionally (#673).
  #
  # `scripts/smoke.sh` issues two searches per run and NEVER opens a result. It is
  # structurally incapable of contributing to a numerator while contributing to every
  # denominator, and it was 66% of recorded searches on the first day of data — which is
  # most of why precision read 1-4% and looked like a catastrophic retrieval failure. A
  # metric that a health check can only ever drag down is not measuring retrieval.
  #
  # No opt-in to include it, deliberately, despite the handoff proposing one. There is no
  # question this table answers better WITH a health check in the denominator, so a flag
  # would only offer a way to compute the misleading number on purpose.
  #
  # FORWARD-LOOKING ONLY. Rows written before the smoke test began declaring itself carry no
  # `entrypoint` key at all, so historical days remain contaminated and are NOT comparable
  # with days after the tag ships. That is stated in the payload rather than left for a
  # reader to discover from a step change in the series.
  @infra_entrypoints ~w(smoke)

  defp exclude_infra_traffic(query) do
    where(
      query,
      [s],
      is_nil(fragment("?->>'entrypoint'", s.metadata)) or
        fragment("?->>'entrypoint'", s.metadata) not in ^@infra_entrypoints
    )
  end

  @doc """
  Compute precision for a single `day` (a `Date`) and follow-through `window_seconds`.

  Returns `%{searched, results_recorded, followed_through, precision, searches,
  searches_with_follow_through, search_follow_through, results_returned, day,
  window_seconds, curated_searched, curated_followed_through, curated_precision,
  retrieved_searched, retrieved_followed_through, retrieved_precision}`.

  `searched` (and its self-describing twin `results_recorded`) is a count of RECORDED
  SURFACED RESULTS — capped at the first
  #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} per call, so `precision`
  is precision@that-cap; `searches` is a count of QUERY-BEARING search CALLS (enumeration
  pages and pre-#582 rows carry no call identity and are excluded — the filter is per
  ROW, so a mixed day reports a partial figure, not `0`). See the moduledoc for why both
  are reported, for the cap's opposite-signed effects on `search_follow_through`, and for
  why neither ratio may be optimised alone.

  The `curated_*`/`retrieved_*` fields (US-31.2, AC-31.2.5) are the SAME
  searched/followed_through/precision computation, restricted to `"search"` events
  whose `metadata->>'mode'` is `"hybrid_curated"` / `"hybrid_retrieved"` (set by
  `Loopctl.Knowledge.hybrid_search/3`) — so the hybrid resolver's provenance decision
  is observable through this NAMED surface, not just via ad-hoc raw
  `article_access_events` queries on the mode tag. Non-hybrid search events (`"keyword"`,
  `"semantic"`, `"combined"`, etc.) contribute to the top-level `searched`/
  `followed_through`/`precision` only, never to either provenance bucket.
  """
  @spec compute(Ecto.UUID.t(), Date.t(), pos_integer()) :: map()
  def compute(tenant_id, %Date{} = day, window_seconds \\ @default_window_seconds) do
    day_start = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
    day_end = DateTime.add(day_start, 1, :day)

    searched_q =
      from(s in ArticleAccessEvent,
        as: :s,
        where: s.tenant_id == ^tenant_id,
        where: s.access_type == "search",
        where: s.accessed_at >= ^day_start and s.accessed_at < ^day_end
      )
      |> exclude_infra_traffic()

    searched = AdminRepo.aggregate(searched_q, :count, :id)
    followed = compute_followed_through(searched_q, window_seconds)
    precision = safe_precision(followed, searched)

    curated_q = where(searched_q, [s], fragment("?->>'mode' = ?", s.metadata, "hybrid_curated"))
    curated_searched = AdminRepo.aggregate(curated_q, :count, :id)
    curated_followed = compute_followed_through(curated_q, window_seconds)
    curated_precision = safe_precision(curated_followed, curated_searched)

    retrieved_q =
      where(searched_q, [s], fragment("?->>'mode' = ?", s.metadata, "hybrid_retrieved"))

    retrieved_searched = AdminRepo.aggregate(retrieved_q, :count, :id)
    retrieved_followed = compute_followed_through(retrieved_q, window_seconds)
    retrieved_precision = safe_precision(retrieved_followed, retrieved_searched)

    call = compute_call_level(searched_q, window_seconds)

    %{
      day: day,
      window_seconds: window_seconds,
      searched: searched,
      results_recorded: searched,
      followed_through: followed,
      precision: precision,
      searches: call.searches,
      searches_with_follow_through: call.searches_with_follow_through,
      search_follow_through: call.search_follow_through,
      results_returned: call.results_returned,
      curated_searched: curated_searched,
      curated_followed_through: curated_followed,
      curated_precision: curated_precision,
      retrieved_searched: retrieved_searched,
      retrieved_followed_through: retrieved_followed,
      retrieved_precision: retrieved_precision
    }
  end

  # Shared "searched -> followed-through within window" correlated-exists count, reused
  # for the aggregate AND each provenance bucket so the follow-through definition can
  # never drift between the three.
  #
  # `"drill"` counts here, DELIBERATELY, and this is the one place the #569 split reverses.
  # That access type exists so `heat_index/2` cannot rank on reads it caused itself, but this
  # metric asks a different question — was a body DELIVERED after a search — and a drill
  # delivers one. Omitting it would silently under-report follow-through by exactly the reads
  # that moved to the new type, which looks like a precision regression on the day #569 ships
  # rather than a definition change. This is why the two access-type sets stay separate and
  # are NOT unified: they answer different questions and diverge on purpose (see the note at
  # `@heat_read_access_types`).
  #
  # The correlation is (tenant, api_key, article, window) and NOT `search_id`, so one open
  # credits EVERY search in the window that surfaced that article. That is a documented
  # upward bias on `search_follow_through` (moduledoc, "Two more biases"), not an oversight:
  # binding on `search_id` would attribute nothing to a search whose result the agent opened
  # after re-running the query, which is the same open read a different way.
  defp compute_followed_through(searched_q, window_seconds) do
    searched_q
    |> with_follow_through(window_seconds)
    |> AdminRepo.aggregate(:count, :id)
  end

  defp with_follow_through(searched_q, window_seconds) do
    searched_q
    |> where(
      [s],
      exists(
        from(o in ArticleAccessEvent,
          where:
            o.tenant_id == parent_as(:s).tenant_id and
              o.api_key_id == parent_as(:s).api_key_id and
              o.article_id == parent_as(:s).article_id and
              o.access_type in ["get", "context", "drill"] and
              o.accessed_at > parent_as(:s).accessed_at and
              fragment(
                "? <= ? + (? * interval '1 second')",
                o.accessed_at,
                parent_as(:s).accessed_at,
                ^window_seconds
              )
        )
      )
    )
  end

  # Per-SEARCH-CALL aggregates (#582). `searched` above counts surfaced RESULTS; these
  # count the calls that surfaced them, so "share of results opened" and "share of
  # searches that led to an open" stop being the same number read two ways.
  #
  # Only rows carrying a `search_id` participate. Rows written before #582 have none,
  # and grouping on a NULL key would collapse every one of them into a single phantom
  # "search" — a fabricated denominator is worse than a missing one, so they contribute
  # 0 here and remain fully counted in `searched`/`precision`.
  #
  # Enumeration modes are excluded too (see `@enumeration_modes`): the row filter is per
  # ROW, so a day mixing browse pages, legacy rows and real searches reports only the
  # real searches here rather than an all-or-nothing 0.
  defp compute_call_level(searched_q, window_seconds) do
    with_id =
      searched_q
      |> where([s], not is_nil(fragment("?->>'search_id'", s.metadata)))
      |> where(
        [s],
        fragment("coalesce(?->>'mode', '')", s.metadata) not in ^@enumeration_modes
      )

    searches = count_distinct_searches(with_id)
    with_ft = with_id |> with_follow_through(window_seconds) |> count_distinct_searches()

    %{
      searches: searches,
      searches_with_follow_through: with_ft,
      search_follow_through: safe_precision(with_ft, searches),
      results_returned: sum_results_returned(with_id)
    }
  end

  defp count_distinct_searches(query) do
    from(s in query, select: count(fragment("?->>'search_id'", s.metadata), :distinct))
    |> AdminRepo.one()
    |> Kernel.||(0)
  end

  # Every row in a search's batch carries that search's OWN `results_returned`, so the
  # figure is per-call and must be de-duplicated by `search_id` before summing —
  # summing the rows would multiply it by the batch size. The regex guard keeps a
  # malformed metadata value from turning an analytics read into a cast error; a bad
  # value contributes 0 rather than crashing the daily snapshot.
  defp sum_results_returned(with_id) do
    per_call =
      from(s in with_id,
        group_by: fragment("?->>'search_id'", s.metadata),
        select: %{
          n:
            max(
              fragment(
                "CASE WHEN ?->>'results_returned' ~ '^[0-9]+$' THEN (?->>'results_returned')::int ELSE 0 END",
                s.metadata,
                s.metadata
              )
            )
        }
      )

    from(p in subquery(per_call), select: coalesce(sum(p.n), 0))
    |> AdminRepo.one()
    |> Kernel.||(0)
  end

  defp safe_precision(_followed, 0), do: 0.0
  defp safe_precision(followed, searched), do: followed / searched

  @doc """
  Compute a day's precision and upsert the snapshot (idempotent per tenant/day/window).
  Returns `{:ok, %RetrievalMetricSnapshot{}}`.
  """
  @spec snapshot(Ecto.UUID.t(), Date.t(), pos_integer()) ::
          {:ok, RetrievalMetricSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def snapshot(tenant_id, %Date{} = day, window_seconds \\ @default_window_seconds) do
    m = compute(tenant_id, day, window_seconds)

    attrs = %{
      day: m.day,
      window_seconds: m.window_seconds,
      searched: m.searched,
      followed_through: m.followed_through,
      precision: m.precision,
      searches: m.searches,
      searches_with_follow_through: m.searches_with_follow_through,
      search_follow_through: m.search_follow_through,
      results_returned: m.results_returned,
      curated_searched: m.curated_searched,
      curated_followed_through: m.curated_followed_through,
      curated_precision: m.curated_precision,
      retrieved_searched: m.retrieved_searched,
      retrieved_followed_through: m.retrieved_followed_through,
      retrieved_precision: m.retrieved_precision,
      computed_at: DateTime.utc_now()
    }

    %RetrievalMetricSnapshot{tenant_id: tenant_id}
    |> RetrievalMetricSnapshot.changeset(attrs)
    |> AdminRepo.insert(
      on_conflict:
        {:replace,
         [
           :searched,
           :followed_through,
           :precision,
           :searches,
           :searches_with_follow_through,
           :search_follow_through,
           :results_returned,
           :curated_searched,
           :curated_followed_through,
           :curated_precision,
           :retrieved_searched,
           :retrieved_followed_through,
           :retrieved_precision,
           :computed_at,
           :updated_at
         ]},
      conflict_target: [:tenant_id, :day, :window_seconds]
    )
  end

  @doc """
  The precision time series, most recent day first. Opts: `:limit` (default 30),
  `:offset`. Returns `%{data: [snapshot maps], meta: %{limit, offset, total_count}}`.
  """
  @spec list_snapshots(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def list_snapshots(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 30) |> max(1) |> min(365)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base = from(s in RetrievalMetricSnapshot, where: s.tenant_id == ^tenant_id)
    total_count = AdminRepo.aggregate(base, :count, :id)

    data =
      from(s in base,
        order_by: [desc: s.day, desc: s.window_seconds],
        limit: ^limit,
        offset: ^offset,
        select: %{
          day: s.day,
          window_seconds: s.window_seconds,
          searched: s.searched,
          # Same number as `searched`, named for its UNIT: RECORDED surfaced results
          # (capped per call by `Analytics.max_recorded_search_results/0`), not search
          # calls. The misreading #582 records happened at exactly this boundary, so the
          # payload states the denominator instead of relying on a doc elsewhere — and it
          # says "recorded", because naming it for the full surfaced set would restate
          # the same class of false denominator this fix exists to remove.
          results_recorded: s.searched,
          followed_through: s.followed_through,
          precision: s.precision,
          searches: s.searches,
          searches_with_follow_through: s.searches_with_follow_through,
          search_follow_through: s.search_follow_through,
          results_returned: s.results_returned,
          curated_searched: s.curated_searched,
          curated_followed_through: s.curated_followed_through,
          curated_precision: s.curated_precision,
          retrieved_searched: s.retrieved_searched,
          retrieved_followed_through: s.retrieved_followed_through,
          retrieved_precision: s.retrieved_precision
        }
      )
      |> AdminRepo.all()

    %{data: data, meta: %{limit: limit, offset: offset, total_count: total_count}}
  end
end
