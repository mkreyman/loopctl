defmodule Loopctl.Knowledge.LiveRetrievalMetrics do
  @moduledoc """
  Retrieval quality measured on REAL logged traffic, with the definitions fixed in code.

  ## Why this exists

  The golden-question eval scores a synthetic fixture — invented prose, synthetic embeddings
  — and is honest only as a regression signal between two of its own runs. When the question
  is "is retrieval actually working on my corpus?", the answer has to come from traffic.

  It is a MODULE and not a paragraph of SQL in a runbook because the same question got three
  hand-written answers in one afternoon (2026-08-25), each wrong differently: `+6.5%` quoted
  from the synthetic eval; `+19%`, a four-month "before" bucket against a fifth of today's
  corpus with `mode` split mid-window; `-4%`, 68 pairs, inside week-to-week noise. The truth
  was "no resolvable change" — weekly MRR sigma 0.045, gap 0.022. Each error is a definition
  someone had to remember; here they are decisions the code made.

  ## The definitions, fixed

  * **A confirmed pair** — an `access_type: "search"` row carrying a `rank`, and a later read
    whose SERVER-RESOLVED `origin_search_id` names that search. Read here, never re-derived,
    which buys no CALLER-ASSERTED origin (#567/#569) and ONE search per read — re-deriving
    from "a read landed within N minutes" credits one read to EVERY search that surfaced the
    article, inflation that unlike a rate does not cancel in a mean. It does NOT buy forgery
    resistance: `Analytics.resolve_origins/5` is a lookback PREFERRING the reader's own key,
    so an agent looping search + get on its own article is credited with its own search
    (`same_key`), scored here like any `cross_key`. MRR is follow-through rank, not proof a
    third party chose it.
  * **A read is `get` or `drill`** — the body fetches a reader NAMES. `context` is EXCLUDED:
    one row per article the RANKER put in a pack, so the caller chose nothing
    (`Knowledge.@heat_read_access_types`' list-shape argument). `drill` is INCLUDED: a genuine
    single-article read and the documented way to follow an index, kept out of heat only so
    heat cannot rank on reads it caused. Narrower than
    `RetrievalMetrics.compute_followed_through/2` (was a body DELIVERED at all), wider than
    `@heat_read_access_types` — three questions, three sets, never unified.
  * **Rank** is `metadata->>'rank'` on the surfaced row; nothing is re-executed, so measuring
    records no new events. **MRR** is `avg(1/rank)` over confirmed pairs — "how near the top was
    the thing the agent used", NOT "did we return everything relevant": hit-rank, not recall.
  * **One mode family**: every `combined*` label, `combined_fallback` included — a degraded
    semantic lane is still a combined search (`Knowledge.requested_mode/1` normalises it for
    that reason), so a week of embedding timeouts must not leave the population. 2026-08-12
    SPLIT `combined` into
    `combined_curated`/`combined_retrieved` and still emits the bare `combined` where the
    curated lane did not run. Never a rename — so taking only `combined_retrieved` after it
    against everything before drops the curated-led searches from one side, the mismatch that
    manufactured the `+19%`.
  * **History starts 2026-08-17** (#689), when `origin_search_id` was first recorded: earlier
    traffic is a different instrument, not a smaller sample. And **the right edge is censored**
    — a read is attributed only within `Analytics.origin_window_seconds/0` of its surfacing, so
    a `to` nearer than that to now understates the recent side. `pairs/3` RAISES on both: an
    unmeasurable window must not look like an uninformative one.
  """

  import Ecto.Query

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.RetrievalMetrics

  @mode_family ["combined", "combined_curated", "combined_retrieved", "combined_fallback"]
  @chosen_read_types ["get", "drill"]
  # Traffic loopctl generates about itself: a release week of deploys must not read as a
  # retrieval change. Kept in step with `RetrievalMetrics`' own private list (which carries the
  # rationale) by a test reading that module's SOURCE — nothing else binds them.
  # No `heavy_read_statement_timeout_overrides` entry, and that is measured rather than
  # assumed: against a copy of production traffic (27,177 access-event rows, 151 confirmed
  # pairs) `pairs/3` runs in 62 ms and `matched_pairs/5` in 20 ms, against the 10,000 ms
  # default — three orders of magnitude of headroom. The `@max_pairs` cap plus the join on
  # `article_access_events_origin_search_idx` is what keeps it there. Add an override only
  # when a measurement says the budget is tight, not on the shape of the query.
  @max_pairs 50_000
  @min_pairs 30
  # A week is a far smaller sample than a comparison window, so it gets its own floor: at this
  # corpus's volume (weekly pairs in the tens) 30 scored NO week, leaving sigma nil and every
  # comparison `:no_noise_baseline` — a module that never answers.
  @min_week_pairs 10
  # `origin_search_id` did not exist before this (#689).
  @history_starts ~U[2026-08-17 00:00:00.000000Z]

  @typedoc "One confirmed (query surfaced an article, agent read it) observation."
  @type pair :: %{query: String.t(), at: DateTime.t(), rank: pos_integer()}

  @doc "The mode labels treated as one population, and why."
  @spec mode_family() :: [String.t()]
  def mode_family, do: @mode_family

  @doc "Floor for a `compare/3` verdict, per side."
  @spec min_pairs() :: pos_integer()
  def min_pairs, do: @min_pairs

  @doc "Floor for a week to enter `weekly_noise/1`'s sigma; below `min_pairs/0` by design."
  @spec min_week_pairs() :: pos_integer()
  def min_week_pairs, do: @min_week_pairs

  @doc "Row cap. `length(pairs) == max_pairs()` means truncated, not measured — narrow it."
  @spec max_pairs() :: pos_integer()
  def max_pairs, do: @max_pairs

  @doc "Entrypoints excluded as loopctl's own traffic, kept in step with `RetrievalMetrics`."
  @spec infra_entrypoints() :: [String.t()]
  def infra_entrypoints, do: RetrievalMetrics.infra_entrypoints()

  @doc "Pairs whose SEARCH is in `[from, to)`, oldest first, newest kept at `max_pairs/0`."
  @spec pairs(Ecto.UUID.t(), DateTime.t(), DateTime.t()) :: [pair()]
  def pairs(tenant_id, from, to) do
    measurable_window!(from, to)

    query =
      from(s in ArticleAccessEvent,
        join: r in ArticleAccessEvent,
        on:
          r.tenant_id == ^tenant_id and r.article_id == s.article_id and
            fragment("?::text = lower(?->>'search_id')", r.origin_search_id, s.metadata),
        where: s.tenant_id == ^tenant_id,
        where: s.access_type == "search",
        where: r.access_type in ^@chosen_read_types,
        where: s.accessed_at >= ^from and s.accessed_at < ^to,
        # A shape test, not `IS NOT NULL`: `metadata` is free-form jsonb written by `insert_all`
        # with no CHECK and no changeset, so an unguarded cast lets ONE malformed row abort the
        # whole read — hence no `::uuid` on `search_id` above. 1..9 digits, not `[0-9]+`: `0`
        # kills the summariser on `1 / rank`, 10 overflow int4. (`->>`, not jsonb `?`.)
        where: fragment("?->>'rank' ~ '^[1-9][0-9]{0,8}$'", s.metadata),
        where: fragment("coalesce(?->>'query', '')", s.metadata) != "",
        where: fragment("?->>'mode'", s.metadata) in ^@mode_family,
        where: fragment("coalesce(?->>'entrypoint', '')", s.metadata) not in ^infra_entrypoints(),
        # The search CALL is the observation and `search_id` is its only reliable identity (#582):
        # the proxy it replaced — a key plus a truncated `accessed_at` — collides across concurrent
        # searches by one key, merging two calls and keeping the better rank. Collapsing re-reads
        # of one article from one search into ONE pair is deliberate: `n` is MRR's denominator.
        group_by: [
          fragment("?->>'search_id'", s.metadata),
          fragment("?->>'query'", s.metadata),
          s.article_id
        ],
        # Newest-first at the LIMIT so truncation drops the OLDEST; reversed below.
        order_by: [desc: min(s.accessed_at)],
        limit: @max_pairs,
        select: %{
          query: fragment("?->>'query'", s.metadata),
          at: min(s.accessed_at),
          # One call can surface a result via several lanes; the agent saw one list, so best rank wins.
          rank: min(fragment("(?->>'rank')::int", s.metadata))
        }
      )

    tenant_id |> HeavyRead.all(query) |> Enum.reverse()
  end

  defp measurable_window!(from, to) do
    window = Analytics.origin_window_seconds()
    censored_from = DateTime.add(DateTime.utc_now(), -window, :second)

    cond do
      DateTime.compare(from, @history_starts) == :lt ->
        raise ArgumentError,
              "pairs/3 from #{from}: origin_search_id starts #{@history_starts}, so earlier " <>
                "traffic is a different instrument, not a smaller sample"

      DateTime.compare(to, censored_from) == :gt ->
        raise ArgumentError,
              "pairs/3 to #{to} is inside the censoring window: attribution reaches only " <>
                "#{window}s past a surfacing, so end no later than #{censored_from}"

      true ->
        :ok
    end
  end

  @doc """
  `n`, mean rank, MRR and the rank-1 / top-5 COUNTS — `_count` suffixed because a bare `top5`
  beside a 0..1 `mrr` reads as a rate. Every field is `nil` on an empty list, never `0.0`:
  `RetrievalEval`'s distinction between "retrieved nothing" and "nothing to score".
  """
  @spec summarise([pair()]) :: map()
  def summarise([]),
    do: %{n: 0, mean_rank: nil, at_rank_1_count: nil, mrr: nil, top5_count: nil}

  def summarise(pairs) do
    n = length(pairs)
    ranks = Enum.map(pairs, & &1.rank)

    %{
      n: n,
      mean_rank: Enum.sum(ranks) / n,
      at_rank_1_count: Enum.count(ranks, &(&1 == 1)),
      top5_count: Enum.count(ranks, &(&1 <= 5)),
      mrr: Enum.sum(Enum.map(ranks, &(1 / &1))) / n
    }
  end

  @doc """
  Weekly MRR series and the sigma any claimed change must clear, computed over `pairs`' own
  history — the only defence against reading week-to-week movement as an effect. Weeks under
  `min_week_pairs/0` stay in the series and out of the sigma: a partial boundary week's MRR swings
  on a handful of reads, so an unweighted sigma is inflated by the weeks saying least, and an
  inflated yardstick calls real changes noise.
  """
  @spec weekly_noise([pair()]) :: map()
  def weekly_noise(pairs) do
    by_week =
      pairs
      |> Enum.group_by(fn p -> p.at |> DateTime.to_date() |> Date.beginning_of_week() end)
      |> Enum.map(fn {wk, ps} -> %{week: wk, n: length(ps), mrr: summarise(ps).mrr} end)
      # NOT `Enum.sort/1`: on a `Date` that falls back to Erlang term order, comparing a struct's
      # keys alphabetically — DAY before MONTH — so a series crossing a month boundary comes out
      # scrambled and reads as a trend that is not in the data.
      |> Enum.sort_by(& &1.week, Date)

    values = by_week |> Enum.filter(&(&1.n >= @min_week_pairs)) |> Enum.map(& &1.mrr)

    %{
      weeks: by_week,
      sigma: stddev(values),
      mean: mean(values),
      week_count: length(by_week),
      scored_week_count: length(values)
    }
  end

  @doc """
  Compare two pair sets and REFUSE to call a difference a change it cannot resolve. Pass
  `sigma` from `weekly_noise/1` over the SURROUNDING history — computing it from the compared
  windows shrinks the yardstick with the sample.

  Three refusals, in order, failing for different reasons:

    * `:underpowered` — under `min_pairs/0` observations a side. A weekly sigma is the spread
      of WEEK-sized means; against a two-observation window any delta clears it trivially.
    * `:no_noise_baseline` — no sigma. Comparing without one is the -4% mistake.
    * `:within_noise` — inside the weekly sigma OR twice the standard error of these two
      samples' difference: sigma is blind to how thin the windows are, the standard error to
      how much a week normally moves.
  """
  @spec compare([pair()], [pair()], float() | nil) :: map()
  def compare(before_pairs, after_pairs, sigma) do
    b = summarise(before_pairs)
    a = summarise(after_pairs)
    delta = if is_number(b.mrr) and is_number(a.mrr), do: a.mrr - b.mrr
    stderr = stderr_of_difference(before_pairs, after_pairs)
    verdict = verdict(b, a, delta, sigma, stderr)
    %{before: b, after: a, delta: delta, sigma: sigma, stderr: stderr, verdict: verdict}
  end

  defp verdict(b, a, delta, sigma, stderr) do
    cond do
      is_nil(delta) -> :not_comparable
      b.n < @min_pairs or a.n < @min_pairs -> :underpowered
      is_nil(sigma) or sigma == 0.0 -> :no_noise_baseline
      abs(delta) < max(sigma, 2 * stderr) -> :within_noise
      true -> :resolvable
    end
  end

  @doc """
  Rank movement for the SAME query surfacing the SAME article on both sides of a boundary,
  holding query difficulty and corpus composition constant — which neither a period average
  nor a two-window comparison can claim.

  It is NOT a follow-through measure and `matched` is NOT a count of confirmed pairs: no read
  side appears in this query, so it reports where the ranker PUT things, not what an agent
  used. Quote it beside `pairs/3`, never instead. Raises unless the windows are chronological
  and disjoint, since an overlap joins a row to ITSELF and reports its rank unchanged.
  """
  @spec matched_pairs(Ecto.UUID.t(), DateTime.t(), DateTime.t(), DateTime.t(), DateTime.t()) ::
          map()
  def matched_pairs(tenant_id, before_from, before_to, after_from, after_to) do
    if DateTime.compare(before_to, after_from) == :gt do
      raise ArgumentError,
            "matched_pairs/5 windows must be chronological and disjoint: before_to " <>
              "#{before_to} is later than after_from #{after_from}"
    end

    query =
      from(b in ArticleAccessEvent,
        join: a in ArticleAccessEvent,
        # No `a.id != b.id`: the guard above makes the windows disjoint, so no row is on both
        # sides. Delete that guard and this becomes a self-join again.
        on:
          a.tenant_id == ^tenant_id and a.article_id == b.article_id and
            fragment("?->>'query'", a.metadata) == fragment("?->>'query'", b.metadata),
        where: b.tenant_id == ^tenant_id,
        where: b.access_type == "search" and a.access_type == "search",
        # Shape-tested rather than null-tested, for the reason given in `pairs/3`.
        where: fragment("?->>'rank' ~ '^[1-9][0-9]{0,8}$'", b.metadata),
        where: fragment("?->>'rank' ~ '^[1-9][0-9]{0,8}$'", a.metadata),
        where: fragment("coalesce(?->>'query', '')", b.metadata) != "",
        where: fragment("?->>'mode'", b.metadata) in ^@mode_family,
        where: fragment("?->>'mode'", a.metadata) in ^@mode_family,
        where: fragment("coalesce(?->>'entrypoint', '')", b.metadata) not in ^infra_entrypoints(),
        where: fragment("coalesce(?->>'entrypoint', '')", a.metadata) not in ^infra_entrypoints(),
        where: b.accessed_at >= ^before_from and b.accessed_at < ^before_to,
        where: a.accessed_at >= ^after_from and a.accessed_at < ^after_to,
        group_by: [fragment("?->>'query'", b.metadata), b.article_id],
        # LIMIT without ORDER BY has no defined row set in SQL: two runs over one corpus could
        # report different means. `matched == max_pairs()` says truncated.
        order_by: [fragment("?->>'query'", b.metadata), b.article_id],
        limit: @max_pairs,
        select: %{
          before_rank: avg(fragment("(?->>'rank')::int", b.metadata)),
          after_rank: avg(fragment("(?->>'rank')::int", a.metadata))
        }
      )

    rows = HeavyRead.all(tenant_id, query)

    %{
      matched: length(rows),
      mean_rank_before: mean(Enum.map(rows, &to_float(&1.before_rank))),
      mean_rank_after: mean(Enum.map(rows, &to_float(&1.after_rank)))
    }
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp stddev(values) when length(values) < 2, do: nil

  defp stddev(values) do
    m = mean(values)
    :math.sqrt(Enum.sum(Enum.map(values, &((&1 - m) * (&1 - m)))) / (length(values) - 1))
  end

  # Standard error of the difference of two mean reciprocal ranks; a side with under two rows
  # contributes 0.0, since `:underpowered` already caught that case.
  defp stderr_of_difference(before_pairs, after_pairs) do
    :math.sqrt(variance_of_mean(before_pairs) + variance_of_mean(after_pairs))
  end

  defp variance_of_mean(pairs) do
    reciprocals = Enum.map(pairs, &(1 / &1.rank))
    sd = stddev(reciprocals)
    if sd, do: sd * sd / length(reciprocals), else: 0.0
  end
end
