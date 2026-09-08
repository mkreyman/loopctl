defmodule Loopctl.Knowledge.DiversityTest do
  @moduledoc """
  #792 — redundancy removal + MMR selection over a ranked candidate set.

  Pure, DB-free: no Repo, no Mox, no `Application.put_env` (every knob arrives through
  `Diversity.config/1`'s per-call overrides, which is the config-DI seam this module
  exists to provide).

  The load-bearing assertion is the REFILL one: removing a near-duplicate is only half
  the fix, and a version that dropped the duplicate without pulling the next distinct
  candidate up into the freed slot would satisfy every other test here.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.Diversity

  # Three mutually orthogonal unit vectors plus a near-copy of the first. Cosine is
  # computed for real (not stubbed), so these are the actual geometry the selector sees:
  # `@a` vs `@a_twin` is ~0.9994, well above the 0.95 threshold; every other pair is 0.0.
  @a [1.0, 0.0, 0.0]
  @a_twin [1.0, 0.035, 0.0]
  @b [0.0, 1.0, 0.0]
  @c [0.0, 0.0, 1.0]

  defp candidate(id, score, opts \\ []) do
    %{
      id: id,
      score: score,
      embedding: Keyword.get(opts, :embedding),
      content_hash: Keyword.get(opts, :content_hash)
    }
  end

  defp ids(selected), do: Enum.map(selected, & &1.id)

  describe "cosine/2" do
    test "is the real cosine, not a dot product — magnitude does not change it" do
      assert_in_delta Diversity.cosine([1.0, 0.0], [1.0, 0.0]), 1.0, 1.0e-9
      assert_in_delta Diversity.cosine([1.0, 0.0], [7.0, 0.0]), 1.0, 1.0e-9
      assert_in_delta Diversity.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-9
      assert_in_delta Diversity.cosine(@a, @a_twin), 0.9994, 1.0e-3
    end

    test "an absent, empty, zero-norm or mismatched-length vector scores 0.0, never a crash" do
      assert Diversity.cosine(nil, @a) == 0.0
      assert Diversity.cosine(@a, nil) == 0.0
      assert Diversity.cosine([], @a) == 0.0
      assert Diversity.cosine([0.0, 0.0, 0.0], @a) == 0.0
      assert Diversity.cosine([1.0, 0.0], @a) == 0.0
    end
  end

  describe "near-duplicate removal REFILLS the freed slot" do
    test "two candidates above the threshold yield one of them PLUS the next distinct candidate" do
      candidates = [
        candidate("a", 0.90, embedding: @a),
        candidate("a-twin", 0.89, embedding: @a_twin),
        candidate("b", 0.50, embedding: @b)
      ]

      {selected, stats} = Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0))

      # The refill is the point: without it this is ["a"] and the second slot is wasted.
      assert ids(selected) == ["a", "b"]
      assert stats.dropped_near_duplicates == 1
      assert stats.selected == 2
    end

    test "the near-dup is measured against the SELECTED set, not against the query" do
      # "b" and "c" are orthogonal to everything, so neither can be a duplicate of the
      # other however relevant both are. Only the twin of an already-selected item goes.
      candidates = [
        candidate("a", 0.99, embedding: @a),
        candidate("b", 0.98, embedding: @b),
        candidate("a-twin", 0.97, embedding: @a_twin),
        candidate("c", 0.96, embedding: @c)
      ]

      {selected, stats} = Diversity.select(candidates, 3, Diversity.config(diversity_lambda: 1.0))

      assert ids(selected) == ["a", "b", "c"]
      assert stats.dropped_near_duplicates == 1
    end

    test "a candidate with no embedding is never removed as a near-duplicate" do
      candidates = [
        candidate("a", 0.90, embedding: @a),
        candidate("unmeasurable", 0.89),
        candidate("a-twin", 0.88, embedding: @a_twin)
      ]

      {selected, stats} = Diversity.select(candidates, 3, Diversity.config(diversity_lambda: 1.0))

      assert ids(selected) == ["a", "unmeasurable"]
      assert stats.dropped_near_duplicates == 1
      assert stats.vectors_available == 2
    end

    test "a threshold above 1.0 disables the stage — cosine cannot reach it" do
      candidates = [
        candidate("a", 0.90, embedding: @a),
        candidate("a-twin", 0.89, embedding: @a_twin)
      ]

      opts = Diversity.config(diversity_lambda: 1.0, diversity_near_dup_threshold: 2.0)
      {selected, stats} = Diversity.select(candidates, 2, opts)

      assert ids(selected) == ["a", "a-twin"]
      assert stats.dropped_near_duplicates == 0
    end
  end

  describe "exact-fingerprint dedup" do
    test "a shared content hash collapses to the highest-ranked member and refills" do
      candidates = [
        candidate("a", 0.90, embedding: @a, content_hash: "sha-1"),
        candidate("a-copy", 0.89, embedding: @b, content_hash: "sha-1"),
        candidate("c", 0.10, embedding: @c, content_hash: "sha-2")
      ]

      {selected, stats} = Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0))

      assert ids(selected) == ["a", "c"]
      assert stats.dropped_exact_duplicates == 1
    end

    test "a nil or blank hash is not a fingerprint — unhashed rows never collapse" do
      candidates = [
        candidate("a", 0.90, embedding: @a),
        candidate("b", 0.89, embedding: @b, content_hash: ""),
        candidate("c", 0.88, embedding: @c)
      ]

      {selected, stats} = Diversity.select(candidates, 3, Diversity.config(diversity_lambda: 1.0))

      assert ids(selected) == ["a", "b", "c"]
      assert stats.dropped_exact_duplicates == 0
    end
  end

  describe "containment in history" do
    test "an already-shown id is skipped and its slot REFILLED from the pool" do
      candidates = [
        candidate("seen", 0.99, embedding: @a),
        candidate("b", 0.50, embedding: @b),
        candidate("c", 0.40, embedding: @c)
      ]

      {selected, stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          exclude_ids: MapSet.new(["seen"])
        )

      assert ids(selected) == ["b", "c"]
      assert stats.dropped_already_seen == 1
      assert stats.selected == 2
    end

    test "the floor: when the shown-set has swallowed the pool, repeats come BACK" do
      # An empty knowledge half is read as "the KB has nothing on this" while the articles
      # still exist — a worse answer than a repeat. Containment may only spend a slot it
      # can refill.
      candidates = [
        candidate("a", 0.99, embedding: @a),
        candidate("b", 0.98, embedding: @b),
        candidate("c", 0.97, embedding: @c)
      ]

      {selected, stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          exclude_ids: ["a", "b", "c"]
        )

      assert ids(selected) == ["a", "b"]
      assert stats.readmitted_already_seen == 2
      assert stats.dropped_already_seen == 1
    end

    test "the floor re-admits only the SHORTFALL, never the whole shown-set" do
      candidates = [
        candidate("seen-1", 0.99, embedding: @a),
        candidate("seen-2", 0.98, embedding: @b),
        candidate("fresh", 0.97, embedding: @c)
      ]

      {selected, stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          exclude_ids: ["seen-1", "seen-2"]
        )

      # One slot could not be filled from the unseen pool, so exactly ONE repeat returns —
      # and it is the highest-ranked one.
      assert ids(selected) == ["seen-1", "fresh"]
      assert stats.readmitted_already_seen == 1
      assert stats.dropped_already_seen == 1
    end

    test "an empty exclude set changes nothing" do
      candidates = [candidate("a", 0.9, embedding: @a), candidate("b", 0.8, embedding: @b)]

      {selected, stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0), exclude_ids: [])

      assert ids(selected) == ["a", "b"]
      assert stats.dropped_already_seen == 0
    end
  end

  describe "lambda 1.0 reproduces today's selection exactly" do
    test "pure relevance takes the top-N in the order given, byte for byte" do
      # Deliberately includes mildly-similar-but-under-threshold pairs: at any lambda
      # below 1.0 the diversity term would reorder these, which is what makes the
      # assertion falsifiable rather than vacuous.
      candidates = [
        candidate("a", 0.90, embedding: [1.0, 0.0, 0.0]),
        candidate("a-ish", 0.80, embedding: [0.8, 0.6, 0.0]),
        candidate("b", 0.70, embedding: [0.0, 1.0, 0.0]),
        candidate("c", 0.60, embedding: [0.0, 0.0, 1.0])
      ]

      opts = Diversity.config(diversity_lambda: 1.0, diversity_near_dup_threshold: 2.0)
      {selected, stats} = Diversity.select(candidates, 3, opts)

      assert selected == Enum.take(candidates, 3)
      assert stats.dropped_near_duplicates == 0
      assert stats.dropped_exact_duplicates == 0
      assert stats.dropped_already_seen == 0
    end

    test "lambda 1.0 takes the top-N BY SCORE when input order disagrees with score order" do
      # The fixture above ranks in score order, so it cannot tell "preserve the order you
      # were given" apart from "take the highest score" — and the two differ the moment a
      # caller ranks on one scale and fills `:score` from another (the hybrid path's
      # RRF-order-vs-absolute-score defect). Pure relevance means SCORE, and the caller's
      # documented obligation is to supply candidates in `:score` order.
      candidates = [
        candidate("first-but-weak", 0.55, embedding: @a),
        candidate("third-but-strong", 0.75, embedding: @b),
        candidate("middle", 0.60, embedding: @c)
      ]

      opts = Diversity.config(diversity_lambda: 1.0, diversity_near_dup_threshold: 2.0)
      {selected, _stats} = Diversity.select(candidates, 2, opts)

      assert ids(selected) == ["third-but-strong", "middle"]
    end

    test "a lambda below 1.0 DOES reorder the same set — the 1.0 case is not vacuous" do
      candidates = [
        candidate("a", 0.90, embedding: [1.0, 0.0, 0.0]),
        candidate("a-ish", 0.80, embedding: [0.8, 0.6, 0.0]),
        candidate("b", 0.70, embedding: [0.0, 1.0, 0.0]),
        candidate("c", 0.60, embedding: [0.0, 0.0, 1.0])
      ]

      opts = Diversity.config(diversity_lambda: 0.5, diversity_near_dup_threshold: 2.0)
      {selected, _stats} = Diversity.select(candidates, 3, opts)

      refute selected == Enum.take(candidates, 3)
      assert hd(ids(selected)) == "a"
    end
  end

  describe "config/1" do
    test "per-call overrides beat config, and the defaults are relevance-weighted" do
      assert Diversity.config().lambda == 0.7
      assert Diversity.config().near_dup_threshold == 0.95
      assert Diversity.config().enabled? == true

      overridden = Diversity.config(diversity_lambda: 0.25, diversity_enabled: false)
      assert overridden.lambda == 0.25
      assert overridden.enabled? == false
    end

    test "a nonsense value falls back to the default rather than reshaping retrieval" do
      assert Diversity.config(diversity_lambda: "0.5").lambda == 0.7
      assert Diversity.config(diversity_lambda: -1).lambda == 0.7
      assert Diversity.config(diversity_over_fetch: 0).over_fetch == 3
      assert Diversity.config(diversity_max_pool: nil).max_pool == 30
    end

    test "a zero near-dup threshold falls back to the default rather than emptying retrieval" do
      # `0` is inside [0.0, 1.0] and would make EVERY candidate a duplicate of the first
      # pick — including every unmeasurable one, whose similarity is 0.0 by definition. One
      # config typo would return nothing for every query on the node.
      assert Diversity.config(diversity_near_dup_threshold: 0).near_dup_threshold == 0.95
      assert Diversity.config(diversity_near_dup_threshold: 0.0).near_dup_threshold == 0.95

      candidates = [
        candidate("a", 0.90, embedding: @a),
        candidate("b", 0.80, embedding: @b),
        candidate("unmeasurable", 0.70)
      ]

      {selected, _stats} =
        Diversity.select(candidates, 3, Diversity.config(diversity_near_dup_threshold: 0))

      assert ids(selected) == ["a", "b", "unmeasurable"]
    end

    test "a hand-built zero threshold still cannot drop an unmeasurable candidate" do
      # `config/1` refuses a non-positive threshold, but `select/4` takes a plain opts MAP
      # that any caller can build. The second lock is in the split itself: a candidate with
      # no loadable vector scores exactly 0.0, and `0.0 >= 0.0` would classify every one of
      # them as a duplicate of the first pick — the one thing this module promises never to
      # do.
      opts = %{Diversity.config([]) | near_dup_threshold: 0.0}

      candidates = [
        candidate("a", 0.90, embedding: @a),
        candidate("unmeasurable-1", 0.80),
        candidate("unmeasurable-2", 0.70)
      ]

      {selected, stats} = Diversity.select(candidates, 3, opts)

      assert ids(selected) == ["a", "unmeasurable-1", "unmeasurable-2"]
      assert stats.dropped_near_duplicates == 0
    end

    test "lambda is clamped into [0.0, 1.0] and always a float" do
      assert Diversity.config(diversity_lambda: 5).lambda == 1.0
      assert Diversity.config(diversity_lambda: 0).lambda == 0.0
      assert Diversity.config(diversity_lambda: 1).lambda == 1.0
    end
  end

  describe "pool_size/2" do
    test "over-fetches so drops can be refilled, never below limit, never above max_pool" do
      opts = Diversity.config(diversity_over_fetch: 3, diversity_max_pool: 30)

      assert Diversity.pool_size(5, opts) == 15
      assert Diversity.pool_size(1, opts) == 3
      # `max_pool` caps the OVER-fetch, never the base: a caller asking for 50 rows must
      # still get 50 candidates, or the cap becomes a recall regression.
      assert Diversity.pool_size(20, opts) == 30
      assert Diversity.pool_size(50, opts) == 50
    end

    test "a max_pool below limit still yields limit — an over-fetch must never shrink the pool" do
      opts = Diversity.config(diversity_over_fetch: 3, diversity_max_pool: 2)
      assert Diversity.pool_size(10, opts) == 10
    end

    test "disabled, the pool is exactly the limit" do
      assert Diversity.pool_size(5, Diversity.config(diversity_enabled: false)) == 5
    end

    test "a non-positive or non-integer limit yields a pool, never a FunctionClauseError" do
      # `Knowledge.hybrid_search/3` is a public context function whose `:limit` used to be
      # clamped only by `paginate_results/2`, so a crash here would be a NEW 500 on it.
      opts = Diversity.config([])

      assert Diversity.pool_size(0, opts) == 3
      assert Diversity.pool_size(-5, opts) == 3
      assert Diversity.pool_size(nil, opts) == 3
    end
  end

  describe "disabled" do
    test "select/3 is Enum.take/2 and reports it, dropping nothing" do
      candidates = [
        candidate("a", 0.90, embedding: @a, content_hash: "same"),
        candidate("a-twin", 0.89, embedding: @a_twin, content_hash: "same"),
        candidate("b", 0.50, embedding: @b)
      ]

      {selected, stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_enabled: false),
          exclude_ids: MapSet.new(["a"])
        )

      assert selected == Enum.take(candidates, 2)
      assert stats.enabled == false
      assert stats.dropped_near_duplicates == 0
      assert stats.dropped_exact_duplicates == 0
      assert stats.dropped_already_seen == 0
    end
  end

  describe "edges" do
    test "an empty candidate list selects nothing and counts nothing" do
      {selected, stats} = Diversity.select([], 5, Diversity.config())

      assert selected == []
      assert stats.candidates == 0
      assert stats.selected == 0
    end

    test "fewer candidates than the limit returns them all" do
      candidates = [candidate("a", 0.9, embedding: @a)]
      {selected, _stats} = Diversity.select(candidates, 10, Diversity.config())
      assert ids(selected) == ["a"]
    end

    test "a pool that is ENTIRELY near-duplicates of the first pick returns just the first" do
      candidates = [
        candidate("a", 0.90, embedding: @a),
        candidate("a-twin", 0.89, embedding: @a_twin),
        candidate("a-twin-2", 0.88, embedding: @a_twin)
      ]

      {selected, stats} = Diversity.select(candidates, 3, Diversity.config())

      assert ids(selected) == ["a"]
      assert stats.dropped_near_duplicates == 2
    end

    test "a non-positive limit selects nothing rather than raising" do
      candidates = [candidate("a", 0.9, embedding: @a), candidate("b", 0.8, embedding: @b)]

      for limit <- [0, -3, nil] do
        {selected, stats} = Diversity.select(candidates, limit, Diversity.config())

        assert selected == []
        assert stats.selected == 0
      end
    end

    test "a non-numeric score ranks as 0.0 without crashing the loop" do
      candidates = [
        %{id: "broken", score: nil, embedding: @a, content_hash: nil},
        candidate("b", 0.5, embedding: @b)
      ]

      {selected, _stats} = Diversity.select(candidates, 2, Diversity.config())
      assert Enum.sort(ids(selected)) == ["b", "broken"]
    end
  end

  describe "preselected pinning" do
    test "a pinned candidate is returned FIRST even when relevance would not pick it" do
      candidates = [
        candidate("top", 0.99, embedding: @b),
        candidate("pinned", 0.10, embedding: @a),
        candidate("c", 0.50, embedding: @c)
      ]

      {selected, _stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          preselected: ["pinned"]
        )

      assert ids(selected) == ["pinned", "top"]
    end

    test "a pinned candidate SUPPRESSES its own near-copies" do
      # This is why pinning is an option on the selector rather than the caller
      # prepending afterwards: prepended, the near-copy would take the next slot.
      candidates = [
        candidate("pinned", 0.99, embedding: @a),
        candidate("echo", 0.98, embedding: @a_twin),
        candidate("b", 0.10, embedding: @b)
      ]

      {selected, stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          preselected: ["pinned"]
        )

      assert ids(selected) == ["pinned", "b"]
      assert stats.dropped_near_duplicates == 1
    end

    test "a pinned candidate counts against the limit" do
      candidates = [
        candidate("pinned", 0.10, embedding: @a),
        candidate("b", 0.99, embedding: @b),
        candidate("c", 0.98, embedding: @c)
      ]

      {selected, stats} =
        Diversity.select(candidates, 1, Diversity.config(diversity_lambda: 1.0),
          preselected: ["pinned"]
        )

      assert ids(selected) == ["pinned"]
      assert stats.selected == 1
    end

    test "a pinned candidate survives an exact-fingerprint collision it would LOSE" do
      # `Knowledge.hybrid_search/3` pins the curated winner and then publishes
      # `meta.provenance: :curated` plus `meta.curated_article_id`. Dropping the pin as the
      # lower-ranked member of its own content-hash group would leave a caller reading
      # `List.first(results)` an UNGOVERNED article as the governed answer.
      candidates = [
        candidate("dup", 0.90, embedding: @b, content_hash: "same"),
        candidate("pinned", 0.80, embedding: @a, content_hash: "same"),
        candidate("c", 0.70, embedding: @c)
      ]

      {selected, stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          preselected: ["pinned"]
        )

      assert ids(selected) == ["pinned", "c"]
      # The pin wins its OWN fingerprint group: the higher-ranked copy is the one dropped.
      assert stats.dropped_exact_duplicates == 1
    end

    test "a pinned candidate survives being in :exclude_ids" do
      candidates = [
        candidate("pinned", 0.90, embedding: @a),
        candidate("b", 0.80, embedding: @b)
      ]

      {selected, _stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          preselected: ["pinned"],
          exclude_ids: ["pinned"]
        )

      assert ids(selected) == ["pinned", "b"]
    end

    test "pinning an id that is not in the pool is inert, never a crash" do
      candidates = [candidate("a", 0.9, embedding: @a), candidate("b", 0.8, embedding: @b)]

      {selected, _stats} =
        Diversity.select(candidates, 2, Diversity.config(diversity_lambda: 1.0),
          preselected: ["absent"]
        )

      assert ids(selected) == ["a", "b"]
    end
  end
end
