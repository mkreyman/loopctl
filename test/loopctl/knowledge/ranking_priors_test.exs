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

  describe "authority_factor/4 (data-driven from category, bounded)" do
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

    test "source_type does NOT lift an article — that prior was removed (2026-08-21)" do
      # It was the same provenance question as the capture-tag prior, keyed on a column
      # instead of a tag: "human/reviewed provenance over raw automated ingests". Both are
      # gone; see the note above `@kill_tag` in RankingPriors.
      reviewed = %{category: :finding, source_type: "review_finding"}
      raw_ingest = %{category: :finding, source_type: "ingestion"}
      none = %{category: :finding, source_type: nil}

      assert RankingPriors.authority_factor(reviewed, 0.05, @floor, @ceiling) ==
               RankingPriors.authority_factor(raw_ingest, 0.05, @floor, @ceiling)

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

  describe "#654 MOC hubs are demoted: navigation must not outrank an answer" do
    alias Loopctl.Knowledge.RankingPriors

    test "hub-ness comes from the worker's idempotency_key, never from tags" do
      # The security property, not a naming preference. `tags` is in Article's
      # @cast_fields AND update_changeset/2, and knowledge_update is agent-role, so a
      # tag-derived penalty let any agent halve ANOTHER agent's article. idempotency_key
      # is cast on CREATE only, so the worst an agent can do is demote its own new row.
      refute RankingPriors.moc_hub?(%{tags: ["hub", "moc", "deployment"]})
      refute RankingPriors.moc_hub?(%{tags: ["moc", "finance", "trading"]})
      refute RankingPriors.moc_hub?(%{})
      refute RankingPriors.moc_hub?(nil)

      assert RankingPriors.moc_hub?(%{idempotency_key: "moc:deployment"})
    end

    test "a non-hub idempotency_key is not a hub" do
      refute RankingPriors.moc_hub?(%{idempotency_key: "session:abc"})
      refute RankingPriors.moc_hub?(%{idempotency_key: ""})
      refute RankingPriors.moc_hub?(%{idempotency_key: nil})
    end

    test "a result map that does not project idempotency_key fails OPEN (no demotion)" do
      # A lane that forgets the projection must under-demote, never mis-demote.
      assert mult(%{category: :reference, updated_at: @now, tags: [], status: :published}, []) ==
               mult(%{category: :reference, updated_at: @now, status: :published}, [])
    end

    test "a hub is demoted below an ordinary article of the SAME category" do
      assert mult(answer(), []) > mult(hub(), [])
    end

    test "a hub loses to a real article the CATEGORY TIER would have ranked below it" do
      # Non-vacuous by construction: a `reference` hub (category weight 0.8) outranks a
      # `pattern` (0.7) on authority alone, so this ordering can ONLY come from the
      # demotion. Comparing a hub against a higher-tier `finding` would pass with the
      # demotion disabled and prove nothing — that is the failure this test shape avoids.
      pattern = %{category: :pattern, updated_at: @now, tags: [], status: :published}

      assert mult(pattern, []) > mult(hub(), [])
    end

    test "demotion is independent of the authority toggle, like dead doctrine" do
      assert mult(answer(), authority?: false) > mult(hub(), authority?: false)
    end

    test "the hub factor is sized for RRF: a two-lane rank-1 hub loses to a one-lane rank-1 answer" do
      # The #654 regression this follow-up exists for. A fused score is
      # `Σ_lane weight/(60 + rank)`. At the dead-doctrine 0.5 the arithmetic below is an
      # exact TIE, decided by the UUID tiebreak — a coin flip, not a demotion.
      two_lane_rank1 = 1.0 / 61.0 + 1.0 / 61.0
      one_lane_rank1 = 1.0 / 61.0

      demoted_hub = two_lane_rank1 * RankingPriors.demotion_factor(hub())

      assert demoted_hub < one_lane_rank1,
             "a hub topping BOTH lanes must lose to an answer topping one"
    end

    test "the kill switch disables hub demotion without touching dead doctrine" do
      killed = %{
        category: :reference,
        updated_at: @now,
        tags: ["verdict-kill"],
        status: :published
      }

      assert RankingPriors.demotion_factor(hub(), hub_demotion?: false) == 1.0
      assert RankingPriors.demotion_factor(killed, hub_demotion?: false) < 1.0
    end

    defp hub,
      do: %{
        category: :reference,
        updated_at: @now,
        tags: ["hub", "moc", "deployment"],
        status: :published,
        idempotency_key: "moc:deployment"
      }

    defp answer,
      do: %{category: :reference, updated_at: @now, tags: ["deployment"], status: :published}
  end

  describe "provenance priors are GONE — ranking must not key on how a document got in" do
    alias Loopctl.Knowledge.RankingPriors

    # Owner decision, 2026-08-21: "if we heavily favor the internally produced knowledge,
    # we would never learn anything new and unexpectedly useful... I want the decision of
    # what knowledge to use and how to combine it to be done on the receiving side."
    #
    # The evidence that justified the removed prior was a 26.7x reads-per-article gap,
    # which carries the harvest's own volume in its denominator. Rank-stratified conversion
    # — the measure that actually answers "is this worse?" — converged by rank 3 and
    # inverted by rank 4. These tests are what stops it coming back by accident.

    test "a harvested doc and a first-party doc rank IDENTICALLY when all else is equal" do
      for marker <- [
            "book-0be008289fe8",
            "url-d046e10f48b3",
            "yt-eCx3SSCcISo",
            "doc-3941363c04b3",
            "web-article",
            "newsletter",
            "inbox-harvest",
            "youtube",
            "document",
            "book"
          ] do
        harvested = %{category: :finding, updated_at: @now, tags: [marker], status: :published}

        first_party = %{
          category: :finding,
          updated_at: @now,
          tags: ["elixir"],
          status: :published
        }

        assert mult(harvested, []) == mult(first_party, []),
               "#{marker} still changes the ranking — a provenance prior has come back"
      end
    end

    test "source_type does not move the ranking either" do
      # The other provenance prior: "human/reviewed provenance over raw automated ingests".
      # It keyed on `source_type`, which is the same question wearing a different column.
      reviewed = %{
        category: :finding,
        updated_at: @now,
        tags: [],
        status: :published,
        source_type: "review_finding"
      }

      ingested = %{
        category: :finding,
        updated_at: @now,
        tags: [],
        status: :published,
        source_type: "ingestion"
      }

      assert mult(reviewed, []) == mult(ingested, [])
    end

    test "authority now keys on CATEGORY and nothing else" do
      # Kept by explicit owner decision on the same date: a category is an editorial
      # classification, not a statement about how the document was ingested.
      decision = %{
        category: :decision,
        updated_at: @now,
        tags: ["web-article"],
        status: :published
      }

      raw = %{category: nil, updated_at: @now, tags: [], status: :published}

      assert mult(decision, []) > mult(raw, []),
             "category authority was removed too — only the PROVENANCE priors should be gone"
    end

    test "deliberate editorial acts still demote — this is not a ban on all re-ranking" do
      # Dead doctrine and navigation stubs are judged on their merits and their FORM, not
      # on where they came from, so they are untouched by the provenance decision.
      live = %{category: :finding, updated_at: @now, tags: [], status: :published}
      killed = %{category: :finding, updated_at: @now, tags: ["verdict-kill"], status: :published}

      hub = %{
        category: :reference,
        updated_at: @now,
        tags: [],
        status: :published,
        idempotency_key: "moc:deployment"
      }

      assert mult(killed, []) < mult(live, [])
      assert mult(hub, []) < mult(live, [])
    end

    test "the removed functions are gone, not merely unused" do
      refute function_exported?(RankingPriors, :provenance_authority, 1),
             "provenance_authority/1 is back — the prior it computes is the one that was removed"
    end
  end
end
