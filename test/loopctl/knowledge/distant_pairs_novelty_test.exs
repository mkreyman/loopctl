defmodule Loopctl.Knowledge.DistantPairsNoveltyTest do
  @moduledoc """
  US-27.7b TC-27.7b.1 / TC-27.7b.2: behavior-preservation coverage for the two cosine
  shapes that are NOT (and must not become) `VectorSearch.nearest/4` — `distant_pairs`
  (column-to-column self-join) and `novelty_scores` (`MIN(<=>)` aggregate).

  The 27.7b change is limited to routing `nearest_prior_distance`'s const through
  `to_embedding_list/1` (so the bound `^param` is a `[float()]`, exactly like `nearest/4`).
  That is behavior-preserving, so the outputs here pin the EXACT post-change values at
  known cosine distances — a regression that altered the distance computation or the
  bounds (sample cap / prior-tag scoping) would change them.
  """
  use Loopctl.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.PlanAssertions

  # Cosine measures DIRECTION. Two halves: a "base" axis and an "orthogonal" axis. A unit
  # vector at angle θ from base is `[cos θ on base-half, sin θ on orth-half]`. Cosine
  # distance between two such vectors is `1 - cos(θ_a - θ_b)`.
  # The `articles.embedding` column is a fixed 1536-dim pgvector, so each half is 768.
  @half 768

  # Unit vector at `theta` radians from the base axis (distributed across each half so the
  # vector norm is independent of θ — keeps `<=>` a pure function of the angle).
  defp embedding_at(theta) do
    base = :math.cos(theta) / :math.sqrt(@half)
    orth = :math.sin(theta) / :math.sqrt(@half)
    List.duplicate(base, @half) ++ List.duplicate(orth, @half)
  end

  # PUBLISHED article with a known embedding, written directly (bypasses the Oban cascade).
  defp article_with_embedding(tenant_id, embedding, attrs) do
    base = %{title: "A#{System.unique_integer([:positive])}", body: "b", category: :pattern}

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published, embedding: embedding})
    |> AdminRepo.update!()
  end

  describe "distant_pairs — output unchanged after sharing helpers (TC-27.7b.1)" do
    setup do
      tenant = fixture(:tenant)

      # Three articles at 0, 60°, 90° from base.
      #   cos-dist(0, 60°)  = 1 - cos(60°) = 0.5   → in the default [0.3, 0.7] band
      #   cos-dist(0, 90°)  = 1 - cos(90°) = 1.0   → OUTSIDE the band
      #   cos-dist(60°, 90°) = 1 - cos(30°) ≈ 0.134 → OUTSIDE the band
      a0 = article_with_embedding(tenant.id, embedding_at(0.0), %{})
      a60 = article_with_embedding(tenant.id, embedding_at(:math.pi() / 3), %{})
      a90 = article_with_embedding(tenant.id, embedding_at(:math.pi() / 2), %{})

      {:ok, tenant: tenant, a0: a0, a60: a60, a90: a90}
    end

    test "returns exactly the in-band pair with the correct distance and meta", ctx do
      assert {:ok, %{pairs: [pair], has_more: false} = result} =
               Knowledge.distant_pairs(ctx.tenant.id)

      # #202/#203: no exact total-pair count is computed anymore (it was the O(n²)
      # cost) — pagination is driven by `has_more` alone.
      refute Map.has_key?(result, :total_count)

      # The single in-band pair is {a0, a60} (cos-dist 0.5). Ordered a.id < b.id.
      {lo, hi} = Enum.min_max([ctx.a0.id, ctx.a60.id])
      assert pair.a.id == lo
      assert pair.b.id == hi
      assert_in_delta pair.distance, 0.5, 1.0e-4
    end

    test "is tenant-scoped — never sees another tenant's pairs (AC-27.7b.4)", ctx do
      other = fixture(:tenant)
      article_with_embedding(other.id, embedding_at(0.0), %{})
      article_with_embedding(other.id, embedding_at(:math.pi() / 3), %{})

      assert {:ok, %{pairs: pairs, has_more: false}} =
               Knowledge.distant_pairs(ctx.tenant.id)

      # Still exactly this tenant's single in-band pair, never the other tenant's.
      assert length(pairs) == 1
      ids = Enum.flat_map(pairs, &[&1.a.id, &1.b.id])
      assert Enum.sort(ids) == Enum.sort([ctx.a0.id, ctx.a60.id])
    end

    test "honors a tightened band (no in-band pair → empty)", ctx do
      assert {:ok, %{pairs: [], has_more: false}} =
               Knowledge.distant_pairs(ctx.tenant.id, min_distance: 0.8, max_distance: 0.9)
    end

    test "invalid band is rejected (unchanged contract)", ctx do
      assert {:error, :invalid_distance} =
               Knowledge.distant_pairs(ctx.tenant.id, min_distance: 0.7, max_distance: 0.3)
    end

    # #202/#203 regression guard: the request path must emit exactly ONE query that
    # runs the `<=>` band filter over the candidate cross-join. The old shape ran a
    # SECOND, count(*) query over the same O(candidates²) cross-join — a full pass
    # that could not early-terminate and was the entire prod-scale latency cost. A
    # reintroduction of any companion count/aggregate pass would push this back to 2.
    test "computes the pair set in a SINGLE band pass (no companion count query)", ctx do
      captured =
        PlanAssertions.capture_repo_queries(fn ->
          {:ok, _} = Knowledge.distant_pairs(ctx.tenant.id)
        end)

      band_queries = Enum.filter(captured, fn {sql, _} -> sql =~ ~r/BETWEEN/i end)
      assert length(band_queries) == 1
    end

    # #202/#203 MED-5: an unbounded offset defeats the page's early termination (Postgres must
    # produce offset+limit+1 matching pairs before returning), so a huge offset could force
    # near-full O(candidates²) evaluation. The offset is clamped to an operator-tunable ceiling.
    test "clamps an out-of-range offset to the ceiling", ctx do
      huge = 10_000_000
      ceiling = Application.get_env(:loopctl, :max_pair_offset, 10_000)

      captured =
        PlanAssertions.capture_repo_queries(fn ->
          {:ok, _} = Knowledge.distant_pairs(ctx.tenant.id, offset: huge)
        end)

      {_sql, params} = Enum.find(captured, fn {sql, _} -> sql =~ ~r/BETWEEN/i end)

      # The emitted OFFSET is the clamped ceiling, never the caller's out-of-range value.
      assert ceiling in params
      refute huge in params
    end
  end

  describe "candidate-cap invariant (#202/#203 MED-7)" do
    test "effective bridge cap never exceeds the general cap (clamps a misconfig)" do
      # A bridge cap larger than the general cap must clamp DOWN — a bigger bridge sample
      # would make bridge_path SLOWER than the non-bridge path it is meant to bound.
      assert Knowledge.effective_bridge_candidate_cap(700, 500) == 500
      # A bridge cap already smaller than the general cap passes through unchanged.
      assert Knowledge.effective_bridge_candidate_cap(300, 500) == 300
      assert Knowledge.effective_bridge_candidate_cap(500, 500) == 500
    end
  end

  describe "novelty_scores — scores unchanged after to_embedding_list normalization (TC-27.7b.2)" do
    setup do
      tenant = fixture(:tenant)

      # Two embedded priors tagged "proposal": at base (0) and at 90°.
      article_with_embedding(tenant.id, embedding_at(0.0), %{tags: ["proposal"]})
      article_with_embedding(tenant.id, embedding_at(:math.pi() / 2), %{tags: ["proposal"]})

      {:ok, tenant: tenant}
    end

    test "novelty_score is the MIN cosine distance to any prior; prior_count is correct",
         %{tenant: tenant} do
      # The idea embeds (mock) to a vector 30° from base:
      #   dist to base-prior  = 1 - cos(30°) ≈ 0.1340
      #   dist to 90°-prior   = 1 - cos(60°) = 0.5
      # MIN ⇒ ≈ 0.1340 (this is the aggregate that must NOT degrade to top-k-then-min).
      idea_vec = embedding_at(:math.pi() / 6)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text -> {:ok, idea_vec} end)

      assert {:ok, [scored], prior_count} =
               Knowledge.novelty_scores(tenant.id, [%{text: "an idea"}])

      assert prior_count == 2
      assert_in_delta scored.novelty_score, 1.0 - :math.cos(:math.pi() / 6), 1.0e-4
    end

    test "nil score (no embedded priors) when prior_tag matches nothing", %{tenant: tenant} do
      # No priors tagged "nonesuch": novelty_scores short-circuits, no embedding call.
      assert {:ok, [scored], 0} =
               Knowledge.novelty_scores(tenant.id, [%{text: "x"}], prior_tag: "nonesuch")

      assert scored.novelty_score == nil
    end

    test "is tenant-scoped — another tenant's priors don't count (AC-27.7b.4)", %{tenant: tenant} do
      other = fixture(:tenant)
      article_with_embedding(other.id, embedding_at(0.0), %{tags: ["proposal"]})

      # This tenant still has exactly its own 2 priors, not the other tenant's.
      idea_vec = embedding_at(0.0)
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text -> {:ok, idea_vec} end)

      assert {:ok, [scored], prior_count} =
               Knowledge.novelty_scores(tenant.id, [%{text: "y"}])

      assert prior_count == 2
      # Idea identical to the base-prior ⇒ MIN distance ≈ 0.
      assert_in_delta scored.novelty_score, 0.0, 1.0e-4
    end
  end
end
