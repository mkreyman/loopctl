defmodule Loopctl.Knowledge.LiveRetrievalMetricsTest do
  @moduledoc """
  The definitions this module fixes are the ones that produced three different wrong
  answers to one question on 2026-08-25, each from hand-written SQL. These tests are what
  stop the definitions drifting back.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.LiveRetrievalMetrics, as: Live

  @from ~U[2026-08-01 00:00:00.000000Z]
  @to ~U[2026-09-01 00:00:00.000000Z]

  defp surfaced(tenant_id, article_id, query, rank, at, mode \\ "combined_retrieved") do
    event(tenant_id, article_id, "search", at, %{
      "query" => query,
      "rank" => rank,
      "mode" => mode
    })
  end

  # Deliberately a DIFFERENT api key from the one that surfaced the result. In production
  # the recall hook searches under its own key and never reads; the follow-through happens
  # in the session under the MCP key, so a same-key rule reports that whole channel at 0%.
  defp opened(tenant_id, article_id, at), do: event(tenant_id, article_id, "get", at, %{})

  defp event(tenant_id, article_id, type, at, metadata) do
    {_plaintext, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent})

    AdminRepo.insert!(%ArticleAccessEvent{
      tenant_id: tenant_id,
      article_id: article_id,
      api_key_id: key.id,
      access_type: type,
      accessed_at: at,
      metadata: metadata
    })
  end

  defp article(tenant_id), do: fixture(:article, %{tenant_id: tenant_id}).id

  describe "pairs/4 — what counts as a confirmed hit" do
    test "a surfaced result that is later OPENED is a pair, at the rank it was shown" do
      t = fixture(:tenant)
      a = article(t.id)

      surfaced(t.id, a, "advisory lock", 3, ~U[2026-08-10 10:00:00.000000Z])
      opened(t.id, a, ~U[2026-08-10 10:05:00.000000Z])

      assert [%{query: "advisory lock", rank: 3}] = Live.pairs(t.id, @from, @to)
    end

    test "a surfaced result nobody opened is NOT a pair" do
      # This is the whole point of the metric: it scores what was USED, not what was shown.
      t = fixture(:tenant)
      surfaced(t.id, article(t.id), "never opened", 1, ~U[2026-08-10 10:00:00.000000Z])

      assert Live.pairs(t.id, @from, @to) == []
    end

    test "an open OUTSIDE the window does not count" do
      t = fixture(:tenant)
      a = article(t.id)

      surfaced(t.id, a, "stale", 1, ~U[2026-08-10 10:00:00.000000Z])
      opened(t.id, a, ~U[2026-08-10 11:30:00.000000Z])

      assert Live.pairs(t.id, @from, @to) == []
      # ... and is included when the window is widened, so the bound is the window and not
      # some other accident of the join.
      assert [%{rank: 1}] = Live.pairs(t.id, @from, @to, window_minutes: 120)
    end

    test "an open BEFORE the search does not count" do
      # Without the direction check a read would justify a search that happened after it,
      # which inverts cause and effect and inflates every number.
      t = fixture(:tenant)
      a = article(t.id)

      opened(t.id, a, ~U[2026-08-10 09:00:00.000000Z])
      surfaced(t.id, a, "after the read", 1, ~U[2026-08-10 10:00:00.000000Z])

      assert Live.pairs(t.id, @from, @to) == []
    end

    test "the open may come from a DIFFERENT api key than the search" do
      # The recall hook searches and never reads; the follow-through happens in the session
      # under the MCP key. A same-key rule reports the injected channel at exactly 0%.
      t = fixture(:tenant)
      a = article(t.id)

      surfaced(t.id, a, "cross key", 2, ~U[2026-08-10 10:00:00.000000Z])
      opened(t.id, a, ~U[2026-08-10 10:01:00.000000Z])

      assert [%{rank: 2}] = Live.pairs(t.id, @from, @to)
    end

    test "both mode labels are ONE population, and other modes are excluded" do
      # `combined` was renamed `combined_retrieved` on 2026-08-12. Treating them as two
      # populations is what manufactured a +19% improvement out of a rename.
      t = fixture(:tenant)
      old = article(t.id)
      new = article(t.id)
      other = article(t.id)

      surfaced(t.id, old, "old label", 1, ~U[2026-08-10 10:00:00.000000Z], "combined")
      opened(t.id, old, ~U[2026-08-10 10:01:00.000000Z])
      surfaced(t.id, new, "new label", 1, ~U[2026-08-14 10:00:00.000000Z], "combined_retrieved")
      opened(t.id, new, ~U[2026-08-14 10:01:00.000000Z])
      surfaced(t.id, other, "keyword only", 1, ~U[2026-08-14 11:00:00.000000Z], "keyword")
      opened(t.id, other, ~U[2026-08-14 11:01:00.000000Z])

      queries = t.id |> Live.pairs(@from, @to) |> Enum.map(& &1.query) |> Enum.sort()
      assert queries == ["new label", "old label"]
    end

    test "is tenant-isolated" do
      mine = fixture(:tenant)
      theirs = fixture(:tenant)
      a = article(theirs.id)

      surfaced(theirs.id, a, "theirs", 1, ~U[2026-08-10 10:00:00.000000Z])
      opened(theirs.id, a, ~U[2026-08-10 10:01:00.000000Z])

      assert Live.pairs(mine.id, @from, @to) == []
    end
  end

  describe "summarise/1" do
    test "an empty window scores n/a, never 0.0" do
      # `0.0` means "it ran and retrieved nothing"; `nil` means "there was nothing to
      # score". Reporting an empty window as 0 invents a collapse that never happened.
      assert %{n: 0, mrr: nil, mean_rank: nil, at_rank_1: nil} = Live.summarise([])
    end

    test "MRR is the mean reciprocal rank of what was opened" do
      pairs = [%{query: "a", at: @from, rank: 1}, %{query: "b", at: @from, rank: 4}]
      s = Live.summarise(pairs)

      assert s.n == 2
      assert s.at_rank_1 == 1
      assert_in_delta s.mrr, (1.0 + 0.25) / 2, 0.0001
      assert_in_delta s.mean_rank, 2.5, 0.0001
    end
  end

  describe "compare/3 — the rule that would have caught all three wrong answers" do
    test "a difference SMALLER than the noise is reported as within_noise, not as a change" do
      before_pairs = [%{query: "a", at: @from, rank: 2}]
      after_pairs = [%{query: "a", at: @from, rank: 2}]
      # A real gap, far under a realistic sigma.
      cmp = Live.compare(before_pairs, [%{query: "a", at: @from, rank: 3} | after_pairs], 0.5)

      assert cmp.verdict == :within_noise
    end

    test "a difference LARGER than the noise is resolvable" do
      cmp =
        Live.compare(
          [%{query: "a", at: @from, rank: 10}],
          [%{query: "a", at: @from, rank: 1}],
          0.05
        )

      assert cmp.verdict == :resolvable
      assert cmp.delta > 0
    end

    test "no noise baseline is its own verdict, never a silent pass" do
      # Comparing without a sigma is exactly the mistake that produced the -4% claim.
      cmp =
        Live.compare(
          [%{query: "a", at: @from, rank: 4}],
          [%{query: "a", at: @from, rank: 1}],
          nil
        )

      assert cmp.verdict == :no_noise_baseline
    end

    test "an empty side is not comparable rather than a 100% collapse" do
      cmp = Live.compare([], [%{query: "a", at: @from, rank: 1}], 0.05)
      assert cmp.verdict == :not_comparable
      assert cmp.delta == nil
    end
  end

  describe "weekly_noise/1" do
    test "sigma needs at least two weeks, and says so rather than returning 0.0" do
      one_week = [%{query: "a", at: ~U[2026-08-10 10:00:00.000000Z], rank: 1}]
      assert %{sigma: nil, week_count: 1} = Live.weekly_noise(one_week)
    end

    test "sigma is computed across weeks" do
      pairs = [
        %{query: "a", at: ~U[2026-08-03 10:00:00.000000Z], rank: 1},
        %{query: "b", at: ~U[2026-08-10 10:00:00.000000Z], rank: 4}
      ]

      noise = Live.weekly_noise(pairs)
      assert noise.week_count == 2
      assert noise.sigma > 0
    end
  end
end
