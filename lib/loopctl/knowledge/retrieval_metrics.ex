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

  ## Exact attribution, and the channel the correlated metric cannot see

  `followed_through` correlates on `(tenant, api_key, article, window)`. That `api_key`
  binding is deliberate and is pinned by a test ("an open by a DIFFERENT api_key does not
  count") — but it has a consequence nothing recorded until now: **the injected recall hook
  searches under a different key from the session that reads.** Measured on prod
  2026-08-17, the hook's key made 1,071 searches and 1 deliberate read ever, while the
  session key made 2,535 reads. So the channel carrying 71% of all search volume scores a
  structural ZERO in `followed_through`, and that zero means "unmeasurable", not "unread" —
  the same `0.0`-vs-`n/a` distinction `RetrievalEval` already insists on.

  `Analytics.resolve_origin/5` therefore resolves each read's originating search at WRITE
  time, server-side, into `article_access_events.origin_search_id` / `origin_attribution`,
  and three counters are reported beside the correlated ones:

  - `attributed_opens` — reads whose originating search is known (`same_key` + `cross_key`).
  - `cross_key_opens` — the subset surfaced by a different key. **This is the injected
    channel.** It is circumstantial by construction: two agents in one tenant can reach the
    same article independently, which is why it is labelled rather than merged into
    `attributed_opens` blindly.
  - `direct_opens` — reads nothing surfaced (`none`): the agent went to an article by link
    or cited id. Previously indistinguishable from "surfaced and ignored", which is close to
    its opposite.

  **Unit warning, because this is exactly where #582 went wrong once already.** These three
  count READS. `followed_through` counts SURFACED RESULTS that were later opened. They are
  not comparable and neither is a refinement of the other — keep both.

  A read whose `origin_attribution` is NULL is in none of the three: pre-migration rows,
  surfacing rows, and the two cases `resolve_origin/5` refuses to classify — a surfacing row
  predating #582 carries no `search_id` (the article WAS surfaced, so `none` would be false,
  but there is no id to attribute to), and a `drill` nothing surfaced (the progressive index
  records no surfacing row, so calling the documented way of following it a direct open
  would be its opposite).

  **Two windows, and they are not the same knob.** `origin_attribution` is baked in at write
  time using `Analytics.origin_window_seconds/0` and cannot be re-asked of history; the
  correlated metrics take `window_seconds` at query time. They share a default so the common
  case agrees by construction. A divergence between `attributed_opens` and
  `followed_through` after someone passes a different `window_seconds` is that mismatch, not
  a bug.

  ## What `quiet` does NOT mean

  `searches_scored_with_follow_through`, `searches_reformulated` and `searches_quiet`
  partition `searches_scored` — NOT `searches` (#711). The partition exists because treating
  every not-opened search as a failure is wrong, and
  `docs/runbooks/search-events-analysis.md` says so outright: "an agent whose question is
  answered by the snippet correctly opens nothing, and that is a success this metric scores
  as a failure."

  A REFORMULATION — the SAME SESSION issuing a LATER SEARCH CALL with a DIFFERENT QUERY
  inside the window, having opened nothing — is the one member of that bucket that is closest
  to an unambiguous failure, so it is peeled out. What remains is named `quiet` and is STILL
  a mixture: "the snippet sufficed" and "the rows were ignored" are indistinguishable here,
  and this instrumentation does not resolve them. Do not rename it to anything that asserts
  satisfaction, and do not compute a rate that treats it as either. Follow-through remains a
  floor, never a satisfaction rate.

  `searches_scored` is smaller than `searches`, and the gap is NOT quiet traffic. A search is
  scoreable only if it carries a session identity (stamped forward-looking, so every row
  written before #711 is unscoreable) and comes from a channel that can react to a result at
  all (the recall hook and the session-start auto-query cannot — see
  `@no_reformulation_entrypoints`). Report `searches - searches_scored` as unscoreable rather
  than inferring anything from it: it is an `n/a`, not a zero.

  Both of those replaced proxies that were measuring something else. Scoring on `api_key_id`
  made the figure a function of search DENSITY — two shared keys, a 127-second median gap
  between searches on one of them, so "another search happened on this key" was ~always true
  and read as 97% reformulation. Comparing `search_id` without the query text counted a
  verbatim retry as a reformulation. Both are documented at `reformulation_exists/1`.

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
  alias Loopctl.Tenants.Tenant

  @default_window_seconds 1800

  # WHICH SET OF DEFINITIONS PRODUCED A ROW.
  #
  # Stamped on every snapshot and published in the series. Three changes have already altered
  # what a figure here MEANS, each forward-looking, each leaving no mark on the row:
  #
  #   * #582 redefined `searched` from search CALLS to recorded surfaced RESULTS;
  #   * #673 began excluding infrastructure traffic, so days either side are not comparable;
  #   * #711 rescoped the disposition trio onto `searches_scored` and fixed a reformulation
  #     predicate that had been measuring search density.
  #
  # A session comparing across one of those boundaries is comparing DEFINITIONS, not days, and
  # nothing in the data let it notice. That is the machine that manufactures "numbers that
  # don't make sense", and this column is the mark that stops it.
  #
  # BUMP THIS whenever you change what an existing figure means, add one, remove one, or
  # rename one — then RE-SNAPSHOT the affected days, or accept that the series carries two
  # definitions and say so. `retrieval_metrics_test.exs` pins the version against the exact
  # key set `compute/3` returns, so a SHAPE change cannot land without a bump. A change of
  # MEANING that keeps the same keys — #711 was exactly that — is not mechanically detectable,
  # so it is on you: if a reader would draw a different conclusion from the same number, bump.
  #
  #   v0  rows predating this column. Definitions unknown; do not compare them with v1+.
  #   v1  post-#711/#712/#713: disposition trio partitions `searches_scored`; no curated /
  #       retrieved provenance breakdown; reads and impressions separated on the analytics
  #       surfaces.
  @metric_version 1

  @doc """
  The definition-set version stamped on snapshots written by this code. See `@metric_version`.
  """
  @spec metric_version() :: pos_integer()
  def metric_version, do: @metric_version

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
  #
  # `skill-eval` joined on 2026-08-17 (claude-config#322). It is the same SHAPE of traffic as
  # `smoke` and for a sharper reason: `bin/skill-trigger-eval.py` runs each eval query through
  # a real `claude -p` subject whose recall hooks then search for real, and **the subject is
  # killed at its first tool call** — so those searches are structurally incapable of ever
  # following through, while contributing to every denominator. Two of its queries were
  # visible in the data as distinct strings appearing exactly 12 times (4 runs x 3 repeats).
  #
  # This corrects an attribution I got wrong: the plan blamed the recall CANARY, which turns
  # out to issue no request to loopctl at all — every one of its hook invocations is pinned to
  # `http://127.0.0.1:9` behind a recording curl shim. Giving the canary a label would have
  # changed nothing.
  #
  # `session-start` is deliberately NOT here. It is one auto-query per session from
  # `hooks/session-start.sh`, which began declaring itself in the same change; before that it
  # sent no client context at all and sat in the NULL bucket. It is REAL traffic from a real
  # session that goes on to do real work, so it is its own channel to be measured, not infra
  # to be excluded. Expect a step change out of NULL dated 2026-08-17 that is bookkeeping
  # rather than behaviour.
  @infra_entrypoints ~w(smoke skill-eval)

  # Channels that are counted everywhere else but CANNOT be scored for reformulation (#711).
  #
  # The recall hook (`hook`) and the session-start auto-query (`session-start`) each emit
  # exactly ONE mechanically-distilled query per prompt. They are shell scripts issuing
  # direct HTTP: they never see what the previous query returned, hold no conversation state,
  # and cannot decide to ask again. A channel with no feedback loop cannot reformulate, so
  # counting it as such is a category error rather than a measurement — and it was the single
  # largest contributor to the inflated figure, because `hook` fires on every user prompt.
  #
  # They are deliberately NOT `@infra_entrypoints`. Their traffic is real, a real session goes
  # on to open what they surface, and `cross_key_opens` exists precisely to credit that. This
  # narrows ONE metric that cannot see them, and changes no denominator anywhere else.
  @no_reformulation_entrypoints ~w(hook session-start)

  defp exclude_infra_traffic(query) do
    where(
      query,
      [s],
      is_nil(fragment("?->>'entrypoint'", s.metadata)) or
        fragment("?->>'entrypoint'", s.metadata) not in ^@infra_entrypoints
    )
  end

  # The read-side half of the same exclusion: drop an open whose SURFACING search declared
  # an infra entrypoint. The lookback reaches one day before the counted day because an open
  # is attributed to a search inside the follow-through window, which can cross midnight;
  # `search_id` is filtered non-null so the `NOT IN` can never go NULL and silently drop the
  # whole day.
  defp exclude_infra_origins(query, tenant_id, day_start, day_end) do
    infra_search_ids =
      from(s in ArticleAccessEvent,
        where: s.tenant_id == ^tenant_id,
        where: s.access_type == "search",
        where: s.accessed_at >= ^DateTime.add(day_start, -1, :day),
        where: s.accessed_at < ^day_end,
        where: fragment("?->>'entrypoint'", s.metadata) in ^@infra_entrypoints,
        where: not is_nil(fragment("?->>'search_id'", s.metadata)),
        select: fragment("(?->>'search_id')::uuid", s.metadata)
      )

    where(
      query,
      [o],
      is_nil(o.origin_search_id) or o.origin_search_id not in subquery(infra_search_ids)
    )
  end

  @doc """
  Compute precision for a single `day` (a `Date`) and follow-through `window_seconds`.

  Returns `%{searched, results_recorded, followed_through, precision, searches,
  searches_with_follow_through, search_follow_through, results_returned, day,
  window_seconds, attributed_opens,
  cross_key_opens, direct_opens, searches_scored, searches_scored_with_follow_through,
  searches_reformulated, searches_quiet}`.

  `searched` (and its self-describing twin `results_recorded`) is a count of RECORDED
  SURFACED RESULTS — capped at the first
  #{Loopctl.Knowledge.Analytics.max_recorded_search_results()} per call, so `precision`
  is precision@that-cap; `searches` is a count of QUERY-BEARING search CALLS (enumeration
  pages and pre-#582 rows carry no call identity and are excluded — the filter is per
  ROW, so a mixed day reports a partial figure, not `0`). See the moduledoc for why both
  are reported, for the cap's opposite-signed effects on `search_follow_through`, and for
  why neither ratio may be optimised alone.

  There is deliberately NO `curated_*`/`retrieved_*` provenance breakdown here any more
  (US-31.2 / AC-31.2.5, removed #712). It was structurally incapable of reporting anything,
  for two independent reasons, and published a confident `0` for both:

    * NOTHING HAS EVER BEEN CURATED. `list_curated_sources` requires `curated_at IS NOT
      NULL` (`Knowledge.curated_sources_base_query/2`); production held 0 such articles out
      of 85,325 at removal, the shipped `scope: :system` canonicals included. Every
      provenance decision therefore resolves `:retrieved` over an empty candidate set, so
      `curated_searched` was a constant `0` that looked like a measurement.
    * IT READ THE WRONG TAG NAMESPACE. The buckets filtered `mode` for `"hybrid_curated"` /
      `"hybrid_retrieved"`, which only `hybrid_search/3` writes. Since #670 the DEFAULT
      search path makes the same provenance decision and tags it `"combined_curated"` /
      `"combined_retrieved"` (`Knowledge.combined_search_mode/1`). At removal that was 8,090
      rows the metric could not see against 252 it could — so it ignored ~97% of the very
      traffic its own docstring claimed made the decision "observable through this NAMED
      surface".

  If the provenance question is worth answering again, BOTH must be true first: something
  must actually set `curated_at`, and the filter must match the `combined_*` tags. Restoring
  the fields without the second is restoring a metric that reads a namespace nothing writes.
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

    call = compute_call_level(searched_q, window_seconds)
    opens = compute_open_attribution(tenant_id, day_start, day_end)
    dispositions = compute_dispositions(searched_q, window_seconds)

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
      attributed_opens: opens.attributed_opens,
      cross_key_opens: opens.cross_key_opens,
      direct_opens: opens.direct_opens,
      searches_scored: dispositions.searches_scored,
      searches_scored_with_follow_through: dispositions.searches_scored_with_follow_through,
      searches_reformulated: dispositions.searches_reformulated,
      searches_quiet: dispositions.searches_quiet
    }
  end

  # ---------------------------------------------------------------------------
  # Exact attribution (unit: READS) and search disposition (unit: SEARCH CALLS)
  # ---------------------------------------------------------------------------

  # Counts READ rows by how their originating search was established
  # (`ArticleAccessEvent.origin_attribution/0`, resolved server-side at write time).
  #
  # This is the counterpart to `followed_through`, not a replacement, and the two are NOT
  # comparable: `followed_through` counts SURFACED RESULTS that were later opened, this
  # counts the OPENS themselves. Both are kept because each answers a question the other
  # cannot:
  #
  #   * `followed_through` correlates on `api_key_id`, so the injected recall hook — which
  #     searches under one key while the session reads under another — scores a structural
  #     ZERO there. `cross_key_opens` is exactly that population, and it was unrepresentable
  #     before the column existed.
  #   * `direct_opens` (`origin_attribution = "none"`) is the agent going straight to an
  #     article by link or cited id. It used to be indistinguishable from "surfaced and
  #     ignored", which is close to its opposite.
  #
  # A row whose attribution is NULL is neither: pre-migration rows, surfacing rows, and the
  # two cases `resolve_origin/5` deliberately refuses to classify — a surfacing row from
  # before #582 that carries no `search_id` (the article WAS surfaced, so calling it `none`
  # would be false, and there is no id to attribute to), and a `drill` with no surfacing row
  # (the progressive index writes none, so `none` would name the index's own opposite).
  defp compute_open_attribution(tenant_id, day_start, day_end) do
    rows =
      from(o in ArticleAccessEvent,
        where: o.tenant_id == ^tenant_id,
        where: o.accessed_at >= ^day_start and o.accessed_at < ^day_end,
        where: not is_nil(o.origin_attribution),
        group_by: o.origin_attribution,
        select: {o.origin_attribution, count(o.id)}
      )
      # Same infra exclusion as every other counter on this payload. Without it the two
      # families describe different populations — the searches an excluded entrypoint made
      # are gone from `searched`/`searches` while its reads still count here — and an
      # operator comparing them reads a gap that is bookkeeping, not behaviour.
      #
      # It takes TWO predicates because a READ row is not a search row. `entrypoint` is
      # written by `search_access_meta/3` onto `access_type = "search"` rows only, so
      # `exclude_infra_traffic/1` alone matched nothing here and the exclusion was inert.
      # The read's own link to the infra channel is `origin_search_id` — resolved
      # server-side at write time — so an open is dropped when the search that SURFACED it
      # declared an infra entrypoint. `exclude_infra_traffic/1` still runs, for a read that
      # carries its own `:access_metadata`.
      |> exclude_infra_traffic()
      |> exclude_infra_origins(tenant_id, day_start, day_end)
      |> AdminRepo.all()
      |> Map.new()

    same = Map.get(rows, "same_key", 0)
    cross = Map.get(rows, "cross_key", 0)

    %{
      attributed_opens: same + cross,
      cross_key_opens: cross,
      direct_opens: Map.get(rows, "none", 0)
    }
  end

  # Partitions `searches` into opened / reformulated / quiet.
  #
  # WHY THIS EXISTS. `search_follow_through` treats every not-opened search as a failure, and
  # `docs/runbooks/search-events-analysis.md` is explicit that this is wrong: "an agent whose
  # question is answered by the snippet correctly opens nothing, and that is a success this
  # metric scores as a failure." The not-opened bucket is therefore a mixture, and until now
  # there was no way to see inside it.
  #
  # A REFORMULATION is the one member of that bucket that is unambiguously a failure: the
  # agent asked again, from the same key, inside the window, with a DIFFERENT query. So it is
  # peeled out and the remainder is named `quiet` — deliberately not `sufficed`, because it
  # is still "the snippet answered it OR the rows were ignored" and this instrumentation does
  # NOT resolve that. Naming it for the outcome it cannot establish is how a floor gets read
  # as a rate.
  #
  # The three partition `searches` exactly, so `quiet` is computed by subtraction rather than
  # by a third query whose predicate could drift out of agreement with the other two.
  #
  # THE EXCLUSION IS PER SEARCH CALL, NOT PER ROW, and that distinction is the whole
  # correctness of the partition. A search writes one row per surfaced result and an agent
  # typically opens ONE of them, so negating the row-level `follow_through_exists/1` matched
  # the still-unopened rows of a search that WAS followed through — counting it in two
  # buckets at once, and (because `quiet` is the remainder) silently zeroing the bucket the
  # genuinely quiet searches belong to. So the opened SEARCH IDS are subtracted as a set.
  @doc """
  One row PER TENANT for a single day — the cross-tenant BREAKDOWN, never a cross-tenant total.

  Superadmin-only, and the shape is the point. Each tenant's KB is a different corpus with a
  different size, subject mix and traffic profile, so a figure summed or averaged across them
  describes no corpus that exists: a 2% read rate over 79,000 articles and a 40% read rate
  over 30 says nothing when blended, and the blend hides exactly the account you were trying
  to find. This function therefore returns ROWS and deliberately reports no aggregate — the
  operator question it exists to answer is "WHICH tenant's KB is unhealthy", which only a
  breakdown can answer.

  **Do not add a totals row, a mean, or a `summary` key to this payload.** If a caller wants a
  platform-wide number, that is a different question about a different unit (the platform, not
  a KB) and belongs in `Tenants.system_stats/0`, which counts inventory rather than quality.

  Tenants with no snapshot for `day` are INCLUDED with `snapshot: nil` rather than omitted.
  A tenant that recorded nothing is a finding — a KB nobody queried, or a broken ingest — and
  dropping it makes the most interesting row invisible. `active_only: false` additionally
  includes suspended/deactivated tenants.

  Rows carry their own `metric_version`, and they can DIFFER across tenants in the same
  response: a tenant not re-snapshotted since a definition change still carries the older one.
  Compare a column across tenants only where the versions match.

  Opts: `:day` (default: yesterday, the day the nightly worker snapshots),
  `:window_seconds`, `:active_only` (default `true`).
  """
  @spec tenant_breakdown(keyword()) :: %{rows: [map()], meta: map()}
  def tenant_breakdown(opts \\ []) do
    day = Keyword.get(opts, :day) || Date.add(Date.utc_today(), -1)
    window = Keyword.get(opts, :window_seconds, @default_window_seconds)
    active_only = Keyword.get(opts, :active_only, true)

    tenants =
      Tenant
      |> scope_tenants_by_status(active_only)
      |> order_by([t], asc: t.name)
      |> select([t], %{id: t.id, name: t.name, status: t.status})
      |> AdminRepo.all()

    snapshots =
      from(s in RetrievalMetricSnapshot,
        where: s.day == ^day,
        where: s.window_seconds == ^window
      )
      |> AdminRepo.all()
      |> Map.new(fn s -> {s.tenant_id, s} end)

    rows =
      Enum.map(tenants, fn t ->
        %{
          tenant_id: t.id,
          tenant_name: t.name,
          tenant_status: t.status,
          snapshot: snapshots |> Map.get(t.id) |> present_snapshot()
        }
      end)

    %{
      rows: rows,
      meta: %{
        day: day,
        window_seconds: window,
        active_only: active_only,
        tenant_count: length(rows),
        # Stated in the payload, not only in the docs, because the shape is what stops a
        # reader summing it: this is a breakdown, and a cross-tenant total of a per-corpus
        # rate is meaningless.
        aggregation: :none,
        note:
          "One row per tenant. These figures are NOT summable or averageable across " <>
            "tenants — each row describes a different corpus. Compare a column across rows " <>
            "only where metric_version matches."
      }
    }
  end

  defp scope_tenants_by_status(query, true), do: where(query, [t], t.status == :active)
  defp scope_tenants_by_status(query, _), do: query

  defp present_snapshot(nil), do: nil

  defp present_snapshot(%RetrievalMetricSnapshot{} = s) do
    %{
      searched: s.searched,
      followed_through: s.followed_through,
      precision: s.precision,
      searches: s.searches,
      searches_with_follow_through: s.searches_with_follow_through,
      search_follow_through: s.search_follow_through,
      searches_scored: s.searches_scored,
      searches_scored_with_follow_through: s.searches_scored_with_follow_through,
      searches_reformulated: s.searches_reformulated,
      searches_quiet: s.searches_quiet,
      attributed_opens: s.attributed_opens,
      cross_key_opens: s.cross_key_opens,
      direct_opens: s.direct_opens,
      metric_version: s.metric_version,
      computed_at: s.computed_at
    }
  end

  defp compute_dispositions(searched_q, window_seconds) do
    scoreable = reformulation_scoreable(searched_q)

    scored = count_distinct_searches(scoreable)
    scored_with_ft = scoreable |> with_follow_through(window_seconds) |> count_distinct_searches()

    opened_ids =
      scoreable
      |> with_follow_through(window_seconds)
      |> select([s], fragment("?->>'search_id'", s.metadata))

    reformulated =
      scoreable
      |> where(^reformulation_exists(window_seconds))
      |> where([s], fragment("?->>'search_id'", s.metadata) not in subquery(opened_ids))
      |> count_distinct_searches()

    %{
      searches_scored: scored,
      searches_scored_with_follow_through: scored_with_ft,
      searches_reformulated: reformulated,
      searches_quiet: max(scored - scored_with_ft - reformulated, 0)
    }
  end

  # The population the disposition trio partitions: qualifying calls that COULD be OBSERVED
  # reformulating. It is a SUBSET of `compute_call_level/2`'s population, which is why the
  # trio partitions `searches_scored` and NOT `searches` — the remainder is reported as
  # `searches` minus `searches_scored` rather than folded into `searches_quiet`.
  #
  # That distinction is the whole point. `quiet` means "the snippet answered it OR the rows
  # were ignored"; a row with no session identity means "this instrument cannot see". Folding
  # the second into the first publishes a structural `n/a` as a number, which is the failure
  # `Loopctl.Knowledge.RetrievalEval` already names in so many words ("`0.0` is 'it ran and
  # retrieved nothing'; `n/a` is 'there was nothing to score'").
  defp reformulation_scoreable(searched_q) do
    searched_q
    |> qualifying_calls()
    |> where([s], not is_nil(fragment("?->>'session_id'", s.metadata)))
    |> where(
      [s],
      fragment("coalesce(?->>'entrypoint', '')", s.metadata) not in ^@no_reformulation_entrypoints
    )
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
    with_id = qualifying_calls(searched_q)

    searches = count_distinct_searches(with_id)
    with_ft = with_id |> with_follow_through(window_seconds) |> count_distinct_searches()

    %{
      searches: searches,
      searches_with_follow_through: with_ft,
      search_follow_through: safe_precision(with_ft, searches),
      results_returned: sum_results_returned(with_id)
    }
  end

  # The per-CALL population: rows carrying a search identity (#582) that are not
  # query-less enumeration pages. Extracted so `compute_call_level/2` and
  # `compute_dispositions/3` cannot drift apart — a disposition computed over a different
  # population than its own denominator would not partition it, and the `quiet` figure is
  # derived by subtraction, so a drift there would show up as a silent miscount rather than
  # an error.
  defp qualifying_calls(searched_q) do
    searched_q
    |> where([s], not is_nil(fragment("?->>'search_id'", s.metadata)))
    |> where(
      [s],
      fragment("coalesce(?->>'mode', '')", s.metadata) not in ^@enumeration_modes
    )
  end

  # "The SAME SESSION asked a DIFFERENT question inside the window" — the one member of the
  # not-opened bucket that is unambiguously a retrieval failure.
  #
  # TWO PROXIES WERE REPLACED HERE, AND EACH MEASURED SOMETHING OTHER THAN REFORMULATION.
  #
  # 1. THE QUERY TEXT is now compared, not just `search_id`. `search_id` is minted per call,
  #    so an agent re-running the IDENTICAL query (a retry after a degraded response) used to
  #    satisfy this: 142 of the 311 flagged rows on 2026-08-17 had a byte-identical successor.
  #    This module previously permitted that on the condition that the published descriptions
  #    said "a later search call" — but the exported field is `searches_reformulated`, and the
  #    name is what leaves the system and what a reader acts on. The name won; the code moved
  #    to meet it. THE TWO MUST KEEP MOVING TOGETHER: do not relax the query comparison here
  #    without renaming the field and every description in `@disposition_fields`.
  #
  # 2. THE SESSION is now the asker, not `api_key_id`. Only TWO keys search this system — the
  #    recall hook's and the shared MCP key that every session and subagent authenticates
  #    with — and the median gap between consecutive searches on one key is 127 seconds. So
  #    "was there another search on this key inside the window" was true ~97% of the time BY
  #    CONSTRUCTION: it measured search DENSITY and published it as agent frustration. It is
  #    the same shared-key confound that makes the search-to-read join unusable
  #    (`docs/runbooks/search-events-analysis.md` step 2), re-entered one metric later.
  #
  # Rows carrying no session identity are not compared at all — `reformulation_scoreable/1`
  # removes them, because a NULL-matches-NULL join would rebuild the shared-key bug out of
  # exactly the rows that lack the field.
  #
  # Bounded on BOTH sides by the window, and strictly after the surfacing row, so a search
  # is never called a reformulation of one that came later.
  defp reformulation_exists(window_seconds) do
    dynamic(
      [s],
      exists(
        from(r in ArticleAccessEvent,
          where:
            r.tenant_id == parent_as(:s).tenant_id and
              r.access_type == "search" and
              not is_nil(fragment("?->>'search_id'", r.metadata)) and
              fragment("?->>'search_id'", r.metadata) !=
                fragment("?->>'search_id'", parent_as(:s).metadata) and
              not is_nil(fragment("?->>'session_id'", r.metadata)) and
              fragment("?->>'session_id'", r.metadata) ==
                fragment("?->>'session_id'", parent_as(:s).metadata) and
              fragment("coalesce(?->>'query', '')", r.metadata) !=
                fragment("coalesce(?->>'query', '')", parent_as(:s).metadata) and
              r.accessed_at > parent_as(:s).accessed_at and
              fragment(
                "? <= ? + (? * interval '1 second')",
                r.accessed_at,
                parent_as(:s).accessed_at,
                ^window_seconds
              )
        )
      )
    )
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
      attributed_opens: m.attributed_opens,
      cross_key_opens: m.cross_key_opens,
      direct_opens: m.direct_opens,
      searches_scored: m.searches_scored,
      searches_scored_with_follow_through: m.searches_scored_with_follow_through,
      searches_reformulated: m.searches_reformulated,
      searches_quiet: m.searches_quiet,
      metric_version: @metric_version,
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
           :attributed_opens,
           :cross_key_opens,
           :direct_opens,
           :searches_scored,
           :searches_scored_with_follow_through,
           :searches_reformulated,
           :searches_quiet,
           :metric_version,
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

          # Unit: READS. NOT comparable with `followed_through`, which counts surfaced
          # RESULTS that were later opened. `cross_key_opens` is the injected recall hook's
          # population — it searches under one key and the session reads under another, so
          # the key-correlated `followed_through` scores that whole channel a structural
          # zero, and a zero there means unmeasurable rather than unread.
          attributed_opens: s.attributed_opens,
          cross_key_opens: s.cross_key_opens,

          # An agent going straight to an article by link or cited id. Used to be
          # indistinguishable from "surfaced and ignored", which is close to its opposite.
          direct_opens: s.direct_opens,

          # Unit: SEARCH CALLS. These three partition `searches_scored`, NOT `searches` —
          # a search is scoreable only if it carries a session identity and comes from a
          # channel that can react to a result at all. `searches - searches_scored` is
          # unscoreable traffic and is an `n/a`, never a quiet search. `quiet` is "the
          # snippet sufficed OR the rows were ignored" and this instrumentation does NOT
          # separate those — only `reformulated`, the one member of the not-opened bucket
          # that is unambiguously a failure, is peeled out.
          searches_scored: s.searches_scored,
          searches_scored_with_follow_through: s.searches_scored_with_follow_through,
          searches_reformulated: s.searches_reformulated,
          searches_quiet: s.searches_quiet,

          # Which set of definitions produced this row. Rows are comparable only WITHIN a
          # version: a change here means a figure's meaning changed, not that the world did.
          # `0` predates the stamp and its definitions are unknown.
          metric_version: s.metric_version
        }
      )
      |> AdminRepo.all()

    %{data: data, meta: %{limit: limit, offset: offset, total_count: total_count}}
  end
end
