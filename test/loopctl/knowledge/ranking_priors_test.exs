defmodule Loopctl.Knowledge.RankingPriorsTest do
  # Pure, DB-free re-ranking priors (#471) — no Repo, no Mox.
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.RankingPriors

  @now ~U[2026-07-21 00:00:00Z]

  defp days_ago(n), do: DateTime.add(@now, -n * 86_400, :second)

  # The narrow authority band search_combined/3 uses (knowledge.ex @authority_floor/ceiling).
  @floor 0.9
  @ceiling 1.1

  defp mult(result, opts) do
    RankingPriors.multiplier(
      result,
      Keyword.merge(
        [
          now: @now,
          recency_weight: 0.3,
          authority?: true,
          strength: 0.05,
          floor: @floor,
          ceiling: @ceiling
        ],
        opts
      )
    )
  end

  describe "recency_decay/2 (single source of truth, shared with knowledge_context)" do
    test "is 1.0 for a doc updated exactly now" do
      assert RankingPriors.recency_decay(@now, @now) == 1.0
    end

    test "matches the inline exp(-age_days/30) build_context_results used verbatim" do
      for days <- [0, 1, 7, 15, 30, 45, 90, 400] do
        updated_at = days_ago(days)
        age_days = DateTime.diff(@now, updated_at, :second) / 86_400.0
        expected = :math.exp(-age_days / 30.0)

        assert_in_delta RankingPriors.recency_decay(updated_at, @now), expected, 1.0e-12
      end
    end

    test "a 30-day-old doc decays to exp(-1)" do
      assert_in_delta RankingPriors.recency_decay(days_ago(30), @now), :math.exp(-1), 1.0e-9
    end
  end

  describe "recency_factor/3 (bounded, applied as a multiplier)" do
    test "a zero weight makes recency a no-op regardless of age" do
      assert RankingPriors.recency_factor(days_ago(999), @now, 0.0) == 1.0
    end

    test "a nil updated_at is inert (factor 1.0)" do
      assert RankingPriors.recency_factor(nil, @now, 0.3) == 1.0
    end

    test "a fresh doc is 1.0 and a very old doc floors at 1 - weight" do
      w = 0.3
      assert RankingPriors.recency_factor(@now, @now, w) == 1.0
      # exp(-400/30) ~ 1.6e-6, so the factor is ~ (1 - w).
      assert_in_delta RankingPriors.recency_factor(days_ago(400), @now, w), 1.0 - w, 1.0e-4
    end

    test "is always within [1 - weight, 1]" do
      w = 0.3

      for days <- 0..120 do
        f = RankingPriors.recency_factor(days_ago(days), @now, w)
        assert f <= 1.0 + 1.0e-12
        assert f >= 1.0 - w - 1.0e-12
      end
    end
  end

  describe "authority_factor/4 (data-driven from category + source_type, bounded)" do
    test "a zero strength makes authority a no-op" do
      assert RankingPriors.authority_factor(%{category: :decision}, 0.0, @floor, @ceiling) == 1.0
    end

    test "category ordering: decision/playbook/finding > idea > raw atomic note" do
      f = fn category ->
        RankingPriors.authority_factor(%{category: category}, 0.05, @floor, @ceiling)
      end

      raw_note = RankingPriors.authority_factor(%{}, 0.05, @floor, @ceiling)

      assert f.(:decision) > f.(:idea)
      assert f.(:playbook) > f.(:idea)
      assert f.(:finding) > f.(:idea)
      # The speculative idea still ranks strictly ABOVE an uncategorized raw note.
      assert f.(:idea) > raw_note
      assert f.(:decision) > raw_note
    end

    test "finding is in the top authority tier, at or above reference (#471 spec + regression)" do
      # Issue #471's literal top tier is "decision / playbook / finding". A grade-3
      # `finding` answer near-tying a grade-2 `reference` distractor in RRF must NOT be
      # reordered below it by authority — the regression the #471 review caught on
      # q-keyword-fallback (nDCG@10 0.86034 -> 0.85196). finding >= reference is the fix.
      f = fn category ->
        RankingPriors.authority_factor(%{category: category}, 0.05, @floor, @ceiling)
      end

      assert f.(:finding) >= f.(:reference)
      assert f.(:finding) > f.(:pattern)
    end

    test "accepts a stringified category the same as the atom" do
      assert RankingPriors.authority_factor(%{category: "decision"}, 0.05, @floor, @ceiling) ==
               RankingPriors.authority_factor(%{category: :decision}, 0.05, @floor, @ceiling)
    end

    test "an unknown category falls back to the raw-note floor" do
      assert RankingPriors.authority_factor(%{category: :bogus}, 0.05, @floor, @ceiling) ==
               RankingPriors.authority_factor(%{category: nil}, 0.05, @floor, @ceiling)
    end

    test "source_type lifts an otherwise identical article" do
      reviewed = %{category: :finding, source_type: "review_finding"}
      raw_ingest = %{category: :finding, source_type: "ingestion"}
      none = %{category: :finding, source_type: nil}

      assert RankingPriors.authority_factor(reviewed, 0.05, @floor, @ceiling) >
               RankingPriors.authority_factor(raw_ingest, 0.05, @floor, @ceiling)

      # ingestion is weighted 0.0, so it ties the nil (unknown) source.
      assert RankingPriors.authority_factor(raw_ingest, 0.05, @floor, @ceiling) ==
               RankingPriors.authority_factor(none, 0.05, @floor, @ceiling)
    end

    test "is always clamped inside the [floor, ceiling] band" do
      candidates = [
        %{category: :decision, source_type: "review_finding"},
        %{category: :idea, source_type: nil},
        %{category: nil, source_type: nil},
        %{category: :reference, source_type: "manual"}
      ]

      for c <- candidates do
        f = RankingPriors.authority_factor(c, 0.05, @floor, @ceiling)
        assert f >= @floor
        assert f <= @ceiling
      end
    end
  end

  describe "demotion_factor/1 (dead doctrine)" do
    test "a verdict-kill tag demotes regardless of category" do
      assert RankingPriors.demotion_factor(%{tags: ["verdict-kill"], category: :decision}) == 0.5
    end

    test "a superseded article is demoted (atom or string status)" do
      assert RankingPriors.demotion_factor(%{status: :superseded}) == 0.5
      assert RankingPriors.demotion_factor(%{status: "superseded"}) == 0.5
    end

    test "a clean, published article is not demoted" do
      assert RankingPriors.demotion_factor(%{status: :published, tags: ["search"]}) == 1.0
      assert RankingPriors.demotion_factor(%{}) == 1.0
    end
  end

  describe "multiplier/2 (recency * authority * demotion) — breaks ties, never dominates" do
    test "a fresh authoritative doc beats an old low-authority near-duplicate" do
      fresh_decision = %{category: :decision, updated_at: @now, tags: [], status: :published}
      old_idea = %{category: :idea, updated_at: days_ago(400), tags: [], status: :published}

      assert mult(fresh_decision, []) > mult(old_idea, [])
    end

    test "the bounded priors cannot flip a materially stronger (2x) relevance winner" do
      # Worst case FOR the strong doc: it is the least-favored by the priors (old + idea),
      # the weak doc is the most-favored (fresh + decision). A 2x fused-score lead must
      # still survive — this is the "break ties, do not dominate strong relevance" invariant.
      strong = %{category: :idea, updated_at: days_ago(400), tags: [], status: :published}
      weak = %{category: :decision, updated_at: @now, tags: [], status: :published}

      strong_base = 0.016_393
      weak_base = strong_base / 2.0

      assert strong_base * mult(strong, []) > weak_base * mult(weak, [])
    end

    test "a verdict-kill doc is demoted below a clean near-tie even when fresher" do
      killed_fresh = %{
        category: :decision,
        updated_at: @now,
        tags: ["verdict-kill"],
        status: :published
      }

      clean_fresh = %{category: :pattern, updated_at: @now, tags: [], status: :published}

      assert mult(clean_fresh, []) > mult(killed_fresh, [])
    end

    test "with every prior disabled the multiplier is exactly 1.0 (fused order preserved)" do
      any = %{category: :idea, updated_at: days_ago(400), tags: [], status: :published}

      assert mult(any, recency_weight: 0.0, authority?: false) == 1.0
    end
  end
end
