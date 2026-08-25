defmodule Loopctl.Knowledge.LiveRetrievalMetrics do
  @moduledoc """
  Retrieval quality measured on REAL logged traffic, with the definitions fixed in code.

  ## Why this exists

  The golden-question eval scores a synthetic fixture — invented prose, synthetic
  embeddings — and is honest only as a regression signal between two of its own runs. When
  the question is "is retrieval actually working on my corpus?", the answer has to come
  from traffic.

  It is a MODULE and not a paragraph of SQL in a runbook because the same question got
  three different answers in one afternoon (2026-08-25), each from hand-written SQL, each
  plausible, each wrong in a different way:

    * `+6.5% MRR` — quoted from the synthetic eval as though it described production.
    * `+19%` — a composition artifact: the "before" bucket averaged four months against a
      corpus a fifth of the current size, and `mode` was renamed `combined` ->
      `combined_retrieved` on 2026-08-12 mid-window.
    * `-4%` — a two-window comparison of 68 pairs, well inside week-to-week noise.

  The measured truth was "no resolvable change": weekly MRR sigma is 0.045 and the observed
  gap was 0.022. Every one of those errors is a definition someone has to remember. Here
  they are decisions the code already made.

  ## The definitions, fixed

  * **A confirmed pair** is a surfaced result that was then OPENED: an
    `access_type: "search"` row carrying a `rank`, followed within `window_minutes` by a
    `get`/`context` on the SAME article. Follow-through cannot be joined — `get` rows carry
    no `search_id` before #689, and the recall hook and the session hold different
    `api_key_id`s — so it is inferred, cross-key, exactly as the wiki article "Measuring KB
    search follow-through" prescribes.
  * **Rank** is `metadata->>'rank'` on the surfaced row, recorded since 2026-04-10. Nothing
    is re-executed, so measuring costs no provider calls and records no new events (running
    a search to measure searching would pollute the next measurement).
  * **MRR** is `avg(1/rank)` over confirmed pairs. It answers "how near the top was the
    thing the agent actually used", NOT "did we return everything relevant" — the label is
    one confirmed hit, never an exhaustive relevance set. Call it hit-rank, not recall.
  * **One mode family only** (`combined` + `combined_retrieved`, a pure rename). Mixing
    label populations is what manufactured the `+19%`.

  ## The rule this module enforces

  `compare/2` will NOT call a difference a change when it is inside the historical
  week-to-week sigma. That is not conservatism, it is the only thing separating the three
  wrong answers above from the right one.
  """

  import Ecto.Query

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.ArticleAccessEvent

  @default_window_minutes 30
  @mode_family ["combined", "combined_retrieved"]

  @typedoc "One confirmed (query surfaced an article, agent opened it) observation."
  @type pair :: %{query: String.t(), at: DateTime.t(), rank: pos_integer()}

  @doc "The mode labels treated as one population, and why."
  @spec mode_family() :: [String.t()]
  def mode_family, do: @mode_family

  @doc """
  Confirmed pairs between `from` and `to` (exclusive), oldest first.

  Read-only. `HeavyRead` because this scans two large event tables and must never contend
  with the request-path pool.
  """
  @spec pairs(Ecto.UUID.t(), DateTime.t(), DateTime.t(), keyword()) :: [pair()]
  def pairs(tenant_id, from, to, opts \\ []) do
    window = opts |> Keyword.get(:window_minutes, @default_window_minutes) |> Integer.to_string()

    query =
      from(s in ArticleAccessEvent,
        join: r in ArticleAccessEvent,
        on:
          r.article_id == s.article_id and r.tenant_id == ^tenant_id and
            r.accessed_at >= s.accessed_at and
            r.accessed_at <
              fragment("? + (? || ' minutes')::interval", s.accessed_at, ^window),
        where: s.tenant_id == ^tenant_id,
        where: s.access_type == "search",
        where: r.access_type in ["get", "context"],
        where: s.accessed_at >= ^from and s.accessed_at < ^to,
        # `metadata->>'rank'` rather than the jsonb `?` existence operator: `?` collides
        # with Ecto's own parameter placeholder and has to be escaped, which is a foot-gun
        # every future editor of this query would have to remember.
        where: not is_nil(fragment("?->>'rank'", s.metadata)),
        where: fragment("coalesce(?->>'query', '')", s.metadata) != "",
        where: fragment("?->>'mode'", s.metadata) in ^@mode_family,
        group_by: [
          fragment("?->>'query'", s.metadata),
          fragment("date_trunc('second', ?)", s.accessed_at),
          s.article_id
        ],
        order_by: min(s.accessed_at),
        select: %{
          query: fragment("?->>'query'", s.metadata),
          at: min(s.accessed_at),
          # A result can be surfaced by several lanes in one call; the agent saw one list,
          # so the best rank is the rank it was shown at.
          rank: min(fragment("(?->>'rank')::int", s.metadata))
        }
      )

    HeavyRead.all(tenant_id, query)
  end

  @doc """
  Summarise a pair list: n, mean rank, rank-1 count, hit-rate@k and MRR.

  Every field is `nil` when there are no pairs — never `0.0`. The distinction is the one
  this repo already draws in `RetrievalEval`: `0.0` is "it ran and retrieved nothing",
  `nil` is "there was nothing to score", and reporting an empty window as 0 invents a
  collapse that never happened.
  """
  @spec summarise([pair()]) :: map()
  def summarise([]), do: %{n: 0, mean_rank: nil, at_rank_1: nil, mrr: nil, top5: nil}

  def summarise(pairs) do
    n = length(pairs)
    ranks = Enum.map(pairs, & &1.rank)

    %{
      n: n,
      mean_rank: Enum.sum(ranks) / n,
      at_rank_1: Enum.count(ranks, &(&1 == 1)),
      top5: Enum.count(ranks, &(&1 <= 5)),
      mrr: Enum.sum(Enum.map(ranks, &(1 / &1))) / n
    }
  end

  @doc """
  Weekly MRR series, and the sigma that any claimed change must clear.

  The sigma is computed over `pairs`' own history rather than assumed, because it is the
  only defence against reading ordinary week-to-week movement as an effect.
  """
  @spec weekly_noise([pair()]) :: map()
  def weekly_noise(pairs) do
    by_week =
      pairs
      |> Enum.group_by(fn p -> p.at |> DateTime.to_date() |> Date.beginning_of_week() end)
      |> Enum.map(fn {wk, ps} -> {wk, summarise(ps).mrr} end)
      |> Enum.sort()

    values = Enum.map(by_week, &elem(&1, 1))

    %{weeks: by_week, sigma: stddev(values), mean: mean(values), week_count: length(values)}
  end

  @doc """
  Compare two pair sets and REFUSE to call an inside-sigma difference a change.

  `sigma` comes from `weekly_noise/1` over the surrounding history. Pass it explicitly:
  a comparison that computes its own noise from the two windows being compared would
  shrink the yardstick with the sample.
  """
  @spec compare([pair()], [pair()], float() | nil) :: map()
  def compare(before_pairs, after_pairs, sigma) do
    b = summarise(before_pairs)
    a = summarise(after_pairs)

    delta =
      if is_number(b.mrr) and is_number(a.mrr), do: a.mrr - b.mrr, else: nil

    verdict =
      cond do
        is_nil(delta) -> :not_comparable
        is_nil(sigma) or sigma == 0.0 -> :no_noise_baseline
        abs(delta) < sigma -> :within_noise
        true -> :resolvable
      end

    %{before: b, after: a, delta: delta, sigma: sigma, verdict: verdict}
  end

  @doc """
  The strongest comparison available: the SAME query surfacing the SAME article on both
  sides of a boundary.

  Query difficulty and corpus composition are then held constant by construction, which is
  what neither a period average nor a two-window comparison can claim.
  """
  @spec matched_pairs(Ecto.UUID.t(), DateTime.t(), DateTime.t(), DateTime.t(), DateTime.t()) ::
          map()
  def matched_pairs(tenant_id, before_from, before_to, after_from, after_to) do
    query =
      from(b in ArticleAccessEvent,
        join: a in ArticleAccessEvent,
        on:
          a.tenant_id == ^tenant_id and a.article_id == b.article_id and
            fragment("?->>'query'", a.metadata) == fragment("?->>'query'", b.metadata),
        where: b.tenant_id == ^tenant_id,
        where: b.access_type == "search" and a.access_type == "search",
        where: not is_nil(fragment("?->>'rank'", b.metadata)),
        where: not is_nil(fragment("?->>'rank'", a.metadata)),
        where: fragment("coalesce(?->>'query', '')", b.metadata) != "",
        where: fragment("?->>'mode'", b.metadata) in ^@mode_family,
        where: fragment("?->>'mode'", a.metadata) in ^@mode_family,
        where: b.accessed_at >= ^before_from and b.accessed_at < ^before_to,
        where: a.accessed_at >= ^after_from and a.accessed_at < ^after_to,
        group_by: [fragment("?->>'query'", b.metadata), b.article_id],
        select: %{
          before_rank: avg(fragment("(?->>'rank')::int", b.metadata)),
          after_rank: avg(fragment("(?->>'rank')::int", a.metadata))
        }
      )

    rows = HeavyRead.all(tenant_id, query)

    %{
      n: length(rows),
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
end
