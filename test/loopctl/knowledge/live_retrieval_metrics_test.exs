defmodule Loopctl.Knowledge.LiveRetrievalMetricsTest do
  @moduledoc """
  The definitions this module fixes produced three different wrong answers to one question on
  2026-08-25, each from hand-written SQL. These tests stop them drifting back.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.LiveRetrievalMetrics, as: Live

  @from ~U[2026-08-01 00:00:00.000000Z]
  @to ~U[2026-09-01 00:00:00.000000Z]
  @at ~U[2026-08-10 10:00:00.000000Z]
  @then ~U[2026-08-10 10:01:00.000000Z]

  # Returns the `search_id`, the only thing that can link a read back to this search.
  defp surfaced(tenant_id, article_id, query, rank, at \\ @at, extra \\ %{}) do
    id = Ecto.UUID.generate()
    md = %{"query" => query, "rank" => rank, "mode" => "combined_retrieved", "search_id" => id}
    attrs = %{access_type: "search", accessed_at: at, metadata: Map.merge(md, extra)}
    event(tenant_id, article_id, attrs)
    id
  end

  # `origin_search_id` is resolved server-side and not castable, so the fixture seeds it past
  # the changeset. `cross_key` on purpose: the recall hook searches under one key and the
  # session reads under another, so a same-key rule reports that whole channel at 0%.
  defp read(tenant_id, article_id, search_id, type \\ "get", at \\ @then) do
    origin = %{origin_search_id: search_id, origin_attribution: "cross_key"}
    event(tenant_id, article_id, Map.merge(origin, %{access_type: type, accessed_at: at}))
  end

  defp event(tid, aid, attrs),
    do: fixture(:article_access_event, Map.merge(%{tenant_id: tid, article_id: aid}, attrs))

  defp article(tenant_id), do: fixture(:article, %{tenant_id: tenant_id}).id

  defp sample(rank, n \\ 30, at \\ @from),
    do: for(_ <- 1..n, do: %{query: "q", at: at, rank: rank})

  describe "pairs/3 — what counts as a confirmed hit" do
    test "a surfaced result the agent then reads is a pair, at the rank it was shown" do
      t = fixture(:tenant)
      a = article(t.id)

      read(t.id, a, surfaced(t.id, a, "advisory lock", 3))

      assert [%{query: "advisory lock", rank: 3}] = Live.pairs(t.id, @from, @to)
    end

    test "a search is a pair only when a read NAMES it" do
      # The link is the recorded `origin_search_id`, never "a read landed nearby": inferring it
      # would credit one read to every search that had surfaced the article, and let an agent
      # manufacture follow-through for its own. Unread, unattributed, and attributed elsewhere
      # all score the same — nothing.
      t = fixture(:tenant)
      a = article(t.id)

      surfaced(t.id, a, "unattributed", 1)
      read(t.id, a, nil)
      read(t.id, a, Ecto.UUID.generate())
      surfaced(t.id, article(t.id), "never opened", 1)

      assert Live.pairs(t.id, @from, @to) == []
    end

    test "a drill counts as a read and a context pack does not" do
      # A drill is the documented way to follow an index, so dropping it scores every agent
      # following the docs at zero. A `context` row is one per article the RANKER put in a
      # pack: the caller asked one question and chose nothing.
      t = fixture(:tenant)
      drilled = article(t.id)
      packed = article(t.id)

      read(t.id, drilled, surfaced(t.id, drilled, "drilled", 1), "drill")
      read(t.id, packed, surfaced(t.id, packed, "packed", 1), "context")

      assert [%{query: "drilled"}] = Live.pairs(t.id, @from, @to)
    end

    test "one search read twice is ONE pair, not two" do
      # `n` is MRR's denominator, so an inflated count does not cancel as it would in a rate.
      t = fixture(:tenant)
      a = article(t.id)
      sid = surfaced(t.id, a, "read twice", 2)

      read(t.id, a, sid)
      read(t.id, a, sid, "drill", ~U[2026-08-10 10:02:00.000000Z])

      assert [%{rank: 2}] = Live.pairs(t.id, @from, @to)
    end

    test "every combined label is ONE population, and other modes are excluded" do
      # 2026-08-12 SPLIT `combined` three ways; never a rename. Taking only
      # `combined_retrieved` after the split against everything before it drops the
      # curated-led searches from one side, which reads as a regression.
      t = fixture(:tenant)

      for mode <- ["combined", "combined_curated", "combined_retrieved", "keyword"] do
        a = article(t.id)
        read(t.id, a, surfaced(t.id, a, mode, 1, @at, %{"mode" => mode}))
      end

      queries = t.id |> Live.pairs(@from, @to) |> Enum.map(& &1.query) |> Enum.sort()
      assert queries == ["combined", "combined_curated", "combined_retrieved"]
    end

    test "an unscorable row costs its own observation, never the whole read" do
      # `metadata` is free-form jsonb with no CHECK, so one malformed rank must not 22P02 the
      # month. Smoke traffic is dropped the same way, or a release week with more deploys
      # reads as a retrieval change.
      t = fixture(:tenant)
      good = article(t.id)
      bad = article(t.id)
      smoke = article(t.id)

      read(t.id, good, surfaced(t.id, good, "good", 1))
      read(t.id, bad, surfaced(t.id, bad, "bad", "n/a"))
      read(t.id, smoke, surfaced(t.id, smoke, "smoke", 1, @at, %{"entrypoint" => "smoke"}))

      assert [%{query: "good"}] = Live.pairs(t.id, @from, @to)
    end

    test "is tenant-isolated" do
      mine = fixture(:tenant)
      theirs = fixture(:tenant)
      a = article(theirs.id)

      read(theirs.id, a, surfaced(theirs.id, a, "theirs", 1))

      assert Live.pairs(mine.id, @from, @to) == []
    end
  end

  describe "summarise/1" do
    test "an empty window scores n/a, never 0.0" do
      # `0.0` means "it ran and retrieved nothing"; `nil` means "there was nothing to score".
      assert %{n: 0, mrr: nil, mean_rank: nil, at_rank_1_count: nil, top5_count: nil} =
               Live.summarise([])
    end

    test "MRR is the mean reciprocal rank of what was read, and the hit fields are COUNTS" do
      s = Live.summarise([%{query: "a", at: @from, rank: 1}, %{query: "b", at: @from, rank: 4}])

      assert s.n == 2
      assert s.at_rank_1_count == 1
      assert s.top5_count == 2
      assert_in_delta s.mrr, (1.0 + 0.25) / 2, 0.0001
      assert_in_delta s.mean_rank, 2.5, 0.0001
    end
  end

  describe "compare/3 — the rule that would have caught all three wrong answers" do
    test "a sample under min_pairs gets no verdict at all" do
      # A weekly sigma is the spread of WEEK-sized means. Against one observation a side any
      # delta clears it, which is the shape of the -4%-from-68-pairs claim.
      assert Live.compare(sample(10, 1), sample(1, 1), 0.045).verdict == :underpowered
    end

    test "a difference SMALLER than the noise is within_noise, not a change" do
      cmp = Live.compare(sample(2), sample(2, 29) ++ [%{query: "q", at: @from, rank: 3}], 0.5)

      assert cmp.verdict == :within_noise
    end

    test "a difference inside the samples' OWN standard error is within_noise" do
      # Sigma alone is blind to how spread the windows are: these differ by more than any
      # plausible weekly sigma and by far less than their own spread.
      noisy = fn tail -> Enum.take(Stream.cycle(sample(1, 1) ++ sample(tail, 1)), 30) end
      cmp = Live.compare(noisy.(40), noisy.(20), 0.001)

      assert cmp.verdict == :within_noise
      assert cmp.stderr > abs(cmp.delta)
    end

    test "a difference LARGER than both the noise and the standard error is resolvable" do
      cmp = Live.compare(sample(10), sample(1), 0.05)

      assert cmp.verdict == :resolvable
      assert cmp.delta > 0
    end

    test "no noise baseline is its own verdict, never a silent pass" do
      # Comparing without a sigma is exactly the mistake that produced the -4% claim.
      assert Live.compare(sample(4), sample(1), nil).verdict == :no_noise_baseline
    end

    test "an empty side is not comparable rather than a 100% collapse" do
      cmp = Live.compare([], sample(1), 0.05)

      assert cmp.verdict == :not_comparable
      assert cmp.delta == nil
    end
  end

  describe "weekly_noise/1" do
    test "a thin week stays in the series and out of the sigma" do
      # An unweighted sigma is inflated by the weeks saying least, and an inflated yardstick
      # calls real changes noise.
      thin = [%{query: "a", at: @at, rank: 1}]

      assert %{sigma: nil, week_count: 1, scored_week_count: 0} = Live.weekly_noise(thin)
    end

    test "sigma is computed across the weeks that clear the floor" do
      noise =
        Live.weekly_noise(sample(1, 30, ~U[2026-08-03 10:00:00.000000Z]) ++ sample(4, 30, @at))

      assert noise.scored_week_count == 2
      assert noise.sigma > 0
    end

    test "the weekly series is chronological across a month boundary" do
      # `Enum.sort/1` on a `Date` falls back to Erlang term order, comparing struct keys
      # alphabetically — DAY before MONTH — so September sorts between two August weeks.
      pairs =
        for at <- [~U[2026-08-03 10:00:00Z], ~U[2026-08-31 10:00:00Z], ~U[2026-09-07 10:00:00Z]],
            do: %{query: "q", at: at, rank: 1}

      assert Enum.map(Live.weekly_noise(pairs).weeks, & &1.week) ==
               [~D[2026-08-03], ~D[2026-08-31], ~D[2026-09-07]]
    end
  end

  describe "matched_pairs/5" do
    @mid ~U[2026-08-10 00:00:00.000000Z]

    test "the same query on the same article reports its rank movement" do
      t = fixture(:tenant)
      a = article(t.id)

      surfaced(t.id, a, "same q", 5, ~U[2026-08-02 10:00:00.000000Z])
      surfaced(t.id, a, "same q", 1, ~U[2026-08-20 10:00:00.000000Z])

      assert %{matched: 1, mean_rank_before: 5.0, mean_rank_after: 1.0} =
               Live.matched_pairs(t.id, @from, @mid, @mid, @to)
    end

    test "overlapping windows raise rather than join every row in the overlap to itself" do
      # A self-join reports a row's rank unchanged, indistinguishable from a real no-change,
      # and nothing in the return shape would show the caller why.
      t = fixture(:tenant)

      assert_raise ArgumentError, ~r/must not overlap/, fn ->
        Live.matched_pairs(t.id, @from, ~U[2026-08-20 00:00:00.000000Z], @mid, @to)
      end
    end
  end
end
