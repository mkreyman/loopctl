defmodule Loopctl.Knowledge.VectorSearchTest do
  @moduledoc """
  Unit + integration coverage for the shared index-correct kNN helper (US-27.6a).

  Scale-only assertions (TC-27.6a.3/.4 — plan shape and worst-case timing at prod
  floor) live in `vector_search_scale_test.exs`, tagged `:scale_nightly`.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.VectorSearch

  # --- embedding helpers (directional; cosine measures direction, not magnitude) ---
  #
  # `base`/`near` point the same way (cosine ≈ 1.0). `near_k` adds a small amount of
  # the orthogonal direction so cosine decreases monotonically with k (1/sqrt(1+0.0025k²))
  # — giving a stable similarity ranking. `orthogonal` shares no direction with `base`
  # (cosine ≈ 0).
  #
  # All three are sourced from `Loopctl.DataCase.test_vec/2` so this file's vectors land in
  # THIS test's disjoint window of the shared, cross-tenant pgvector HNSW index — dissolving
  # the all-ties `half_ones` clique that flakes recall (see test_vec/2's @doc). The graded
  # `near_embedding/1` is composed elementwise from the (disjoint) `:primary` and `:orthogonal`
  # windows, so the exact cosine ordering is preserved with NO fixed coordinates.

  defp base_embedding, do: test_vec(1536, :primary)

  # Larger k => more orthogonal-window mass => lower cosine similarity to base.
  defp near_embedding(k) when k >= 0 do
    primary = test_vec(1536, :primary)
    orthogonal = test_vec(1536, :orthogonal)
    Enum.zip_with(primary, orthogonal, fn p, o -> p + k * 0.05 * o end)
  end

  defp orthogonal_embedding, do: test_vec(1536, :orthogonal)

  # Creates a PUBLISHED article with a known embedding, bypassing the Oban cascade.
  defp article_with_embedding(tenant_id, embedding, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Body.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published, embedding: embedding})
    |> AdminRepo.update!()
  end

  defp link!(tenant_id, source_id, target_id) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: source_id,
      target_article_id: target_id,
      relationship_type: :relates_to
    })
  end

  describe "nearest/4 — ranking, self-exclusion, published-only (TC-27.6a.1)" do
    setup do
      tenant = fixture(:tenant)
      target = article_with_embedding(tenant.id, base_embedding())

      # Three neighbors at increasing distance, plus an orthogonal far one.
      n1 = article_with_embedding(tenant.id, near_embedding(1))
      n2 = article_with_embedding(tenant.id, near_embedding(3))
      n3 = article_with_embedding(tenant.id, near_embedding(6))
      far = article_with_embedding(tenant.id, orthogonal_embedding())

      %{tenant: tenant, target: target, n1: n1, n2: n2, n3: n3, far: far}
    end

    test "returns ≤k candidates ranked by similarity desc, self excluded, numeric score",
         %{tenant: tenant, target: target, n1: n1, n2: n2, n3: n3} do
      results =
        VectorSearch.nearest(tenant.id, base_embedding(), 3, exclude_id: target.id)

      assert length(results) <= 3
      ids = Enum.map(results, & &1.id)

      # Self never appears.
      refute target.id in ids

      # Nearest three, in descending-similarity order.
      assert ids == [n1.id, n2.id, n3.id]

      # Every candidate carries a numeric, monotonically-decreasing similarity_score.
      scores = Enum.map(results, & &1.similarity_score)
      assert Enum.all?(scores, &is_float/1)
      assert scores == Enum.sort(scores, :desc)
    end

    test "excludes draft (non-published) articles", %{tenant: tenant, target: target} do
      draft =
        fixture(:article, %{tenant_id: tenant.id, status: :draft})
        |> Ecto.Changeset.change(%{embedding: near_embedding(0)})
        |> AdminRepo.update!()

      results = VectorSearch.nearest(tenant.id, base_embedding(), 10, exclude_id: target.id)
      refute draft.id in Enum.map(results, & &1.id)
    end

    test "excludes null-embedding articles", %{tenant: tenant, target: target} do
      no_embed = fixture(:article, %{tenant_id: tenant.id, status: :published})

      results = VectorSearch.nearest(tenant.id, base_embedding(), 10, exclude_id: target.id)
      refute no_embed.id in Enum.map(results, & &1.id)
    end
  end

  describe "nearest/4 — post-filters over the pool (TC-27.6a.2)" do
    test "returns only unlinked, above-threshold neighbors; linked are excluded" do
      tenant = fixture(:tenant)
      target = article_with_embedding(tenant.id, base_embedding())

      # 6 near-identical neighbors (all high similarity to the target).
      neighbors =
        for k <- 1..6, do: article_with_embedding(tenant.id, near_embedding(k))

      # Pre-link the FIRST four to the target (mix of directions).
      [l1, l2, l3, l4 | rest] = neighbors
      link!(tenant.id, target.id, l1.id)
      link!(tenant.id, target.id, l2.id)
      # reverse direction — the anti-join is bidirectional
      link!(tenant.id, l3.id, target.id)
      link!(tenant.id, l4.id, target.id)

      [unlinked_a, unlinked_b] = rest

      results =
        VectorSearch.nearest(tenant.id, base_embedding(), 2,
          exclude_id: target.id,
          exclude_linked: true,
          threshold: 0.5
        )

      ids = Enum.map(results, & &1.id)

      assert length(results) == 2
      assert MapSet.new(ids) == MapSet.new([unlinked_a.id, unlinked_b.id])

      # None of the four linked neighbors appear.
      for linked <- [l1, l2, l3, l4], do: refute(linked.id in ids)
      # All survivors are above the threshold floor.
      assert Enum.all?(results, &(&1.similarity_score > 0.5))
    end

    test "threshold floor drops below-threshold candidates" do
      tenant = fixture(:tenant)
      target = article_with_embedding(tenant.id, base_embedding())
      near = article_with_embedding(tenant.id, near_embedding(1))
      _far = article_with_embedding(tenant.id, orthogonal_embedding())

      results =
        VectorSearch.nearest(tenant.id, base_embedding(), 10,
          exclude_id: target.id,
          threshold: 0.5
        )

      ids = Enum.map(results, & &1.id)
      assert near.id in ids
      assert Enum.all?(results, &(&1.similarity_score > 0.5))
    end
  end

  describe "nearest/4 — tenant isolation (TC-27.6a.5)" do
    test "tenant A never receives tenant B candidates" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      a1 = article_with_embedding(tenant_a.id, base_embedding())
      b1 = article_with_embedding(tenant_b.id, base_embedding())
      b2 = article_with_embedding(tenant_b.id, near_embedding(1))

      results = VectorSearch.nearest(tenant_a.id, base_embedding(), 10)
      ids = Enum.map(results, & &1.id)

      assert a1.id in ids
      refute b1.id in ids
      refute b2.id in ids
    end
  end

  describe "candidate_query/4 — structural guard (AC-27.6a.2)" do
    test "the index-ordered inner subquery has NO join and NO distance-WHERE" do
      tenant = fixture(:tenant)

      query =
        VectorSearch.candidate_query(tenant.id, base_embedding(), 5,
          exclude_id: Ecto.UUID.generate(),
          exclude_linked: true,
          threshold: 0.5
        )

      # The inner pure-ANN subquery is the `from` source of the outer query.
      %Ecto.Query{from: %{source: %Ecto.SubQuery{query: inner}}} = query

      # No JOIN inside the index-ordered subquery (a join there defeats HNSW).
      assert inner.joins == [],
             "inner index-ordered subquery must have no joins (HNSW-defeating)"

      # The inner ORDER BY is the cosine distance (index-eligible).
      assert [%{expr: [asc: _]}] = inner.order_bys

      # No WHERE inside the inner subquery references the `<=>` distance operator
      # — only equality/membership residual filters are allowed there. We isolate
      # the WHERE substring (between WHERE and ORDER BY) so the SELECT's and ORDER
      # BY's legitimate `<=>` don't false-positive.
      {inner_sql, _params} = SQL.to_sql(:all, AdminRepo, inner)
      where_clause = where_substring(inner_sql)

      refute String.contains?(where_clause, "<=>"),
             "inner WHERE must not contain a distance filter, got: #{where_clause}"

      # The anti-join lives on the OUTER query, not the inner one.
      assert length(query.joins) == 1
    end

    test "no anti-join is emitted unless exclude_linked AND exclude_id are both set" do
      tenant = fixture(:tenant)

      # exclude_linked without an anchor → no join.
      q1 = VectorSearch.candidate_query(tenant.id, base_embedding(), 5, exclude_linked: true)
      assert q1.joins == []

      # anchor without exclude_linked → no join.
      q2 =
        VectorSearch.candidate_query(tenant.id, base_embedding(), 5,
          exclude_id: Ecto.UUID.generate()
        )

      assert q2.joins == []

      # both → exactly one anti-join.
      q3 =
        VectorSearch.candidate_query(tenant.id, base_embedding(), 5,
          exclude_id: Ecto.UUID.generate(),
          exclude_linked: true
        )

      assert length(q3.joins) == 1
    end

    test "accepts a %Pgvector{} target by normalizing to a [float()] param" do
      tenant = fixture(:tenant)
      vec = Pgvector.new(base_embedding())

      # Should not raise — the struct is normalized via to_embedding_list/1.
      assert %Ecto.Query{} = VectorSearch.candidate_query(tenant.id, vec, 5)
    end
  end

  describe "caller-cost bounds (AC-27.6a.4)" do
    test "k above max_k is clamped to max_k" do
      tenant = fixture(:tenant)

      query = VectorSearch.candidate_query(tenant.id, base_embedding(), VectorSearch.max_k() + 50)

      %Ecto.Query{limit: %{expr: limit_expr, params: limit_params}} = query
      assert limit_value(limit_expr, limit_params) == VectorSearch.max_k()
    end

    test "k below 1 is clamped to 1" do
      tenant = fixture(:tenant)
      query = VectorSearch.candidate_query(tenant.id, base_embedding(), 0)
      %Ecto.Query{limit: %{expr: limit_expr, params: limit_params}} = query
      assert limit_value(limit_expr, limit_params) == 1
    end

    test "the over-fetch pool is bounded by max_pool and floored at k" do
      tenant = fixture(:tenant)

      # A huge pool override is capped at max_pool.
      big =
        VectorSearch.candidate_query(tenant.id, base_embedding(), 5, pool: 10_000)

      %Ecto.Query{from: %{source: %Ecto.SubQuery{query: inner}}} = big
      %{expr: pool_expr, params: pool_params} = inner.limit
      assert limit_value(pool_expr, pool_params) == VectorSearch.max_pool()

      # The pool never drops below k even with a tiny override.
      floored =
        VectorSearch.candidate_query(tenant.id, base_embedding(), 5, pool: 1)

      %Ecto.Query{from: %{source: %Ecto.SubQuery{query: floored_inner}}} = floored
      %{expr: fexpr, params: fparams} = floored_inner.limit
      assert limit_value(fexpr, fparams) >= 5
    end

    test "threshold is clamped into [0.0, 1.0]" do
      tenant = fixture(:tenant)
      target = article_with_embedding(tenant.id, base_embedding())
      _near = article_with_embedding(tenant.id, near_embedding(1))

      # An out-of-range high threshold clamps to 1.0 → nothing is strictly > 1.0.
      high =
        VectorSearch.nearest(tenant.id, base_embedding(), 10,
          exclude_id: target.id,
          threshold: 5.0
        )

      assert high == []

      # An out-of-range negative threshold clamps to 0.0 → behaves as no floor.
      low =
        VectorSearch.nearest(tenant.id, base_embedding(), 10,
          exclude_id: target.id,
          threshold: -3.0
        )

      assert low != []
    end

    test "tags list is truncated to max_tags (no unbounded array literal)" do
      tenant = fixture(:tenant)
      tags = for i <- 1..(VectorSearch.max_tags() + 25), do: "t#{i}"

      query = VectorSearch.candidate_query(tenant.id, base_embedding(), 5, tags: tags)

      # tags filter is on the OUTER query (over the pool) — NOT the inner ANN subquery
      # (a tags && on the index-ordered query defeats the HNSW index at scale). The
      # bound tags param is truncated to max_tags.
      bound_tags =
        Enum.find_value(query.wheres, fn %{params: params} ->
          Enum.find_value(params, fn
            {value, :any} when is_list(value) -> value
            _ -> nil
          end)
        end)

      assert is_list(bound_tags)
      assert length(bound_tags) == VectorSearch.max_tags()

      # And the inner ANN subquery must NOT carry the tags filter.
      %Ecto.Query{from: %{source: %Ecto.SubQuery{query: inner}}} = query

      refute Enum.any?(inner.wheres, fn %{params: params} ->
               Enum.any?(params, &match?({v, :any} when is_list(v), &1))
             end)
    end

    test "an unknown category is ignored (not a 500), a known one filters on the OUTER pool" do
      tenant = fixture(:tenant)

      # category lives on the OUTER query (a category= on the index-ordered subquery
      # defeats the HNSW index at scale). Unknown → no predicate anywhere; query runs.
      unknown = VectorSearch.candidate_query(tenant.id, base_embedding(), 5, category: :bogus)
      refute Enum.any?(unknown.wheres, &(&1.expr |> inspect() =~ "category"))
      assert [] = VectorSearch.nearest(tenant.id, base_embedding(), 5, category: :bogus)

      # Known category → the equality predicate is present on the OUTER query, and the
      # inner ANN subquery stays pure (no category predicate).
      known = VectorSearch.candidate_query(tenant.id, base_embedding(), 5, category: :decision)
      assert Enum.any?(known.wheres, &(&1.expr |> inspect() =~ "category"))
      %Ecto.Query{from: %{source: %Ecto.SubQuery{query: inner_k}}} = known
      refute Enum.any?(inner_k.wheres, &(&1.expr |> inspect() =~ "category"))
    end

    test "the OUTER category/tags filters EXECUTE end-to-end (enum/array dump through the subquery)" do
      # Proves in the FAST suite (not just :scale_nightly) that c.category == ^:decision
      # and c.tags && ^[...] actually dump+run through the subquery and return the right
      # rows — guarding the Ecto.Enum/array type-propagation through the subquery select.
      tenant = fixture(:tenant)

      decision =
        article_with_embedding(tenant.id, near_embedding(1), %{
          category: :decision,
          tags: ["alpha"]
        })

      _pattern =
        article_with_embedding(tenant.id, near_embedding(2), %{category: :pattern, tags: ["beta"]})

      assert [%{id: id, category: :decision}] =
               VectorSearch.nearest(tenant.id, base_embedding(), 5, category: :decision)

      assert id == decision.id

      assert [%{id: ^id}] = VectorSearch.nearest(tenant.id, base_embedding(), 5, tags: ["alpha"])
    end
  end

  describe "pool_size/2 — config-driven over-fetch, always floored at k (TC-27.6b.1, AC-27.6b.1)" do
    test "PROD-default sizing is k*factor floored/capped (explicit knobs, env-independent)" do
      # Pin the documented prod defaults explicitly so this is independent of the test
      # config's shrunken pool (config/test.exs lowers the async-suite floor/cap to 6).
      prod = [factor: 5, floor: 100, cap: 500]
      # k=5 → 5*5=25 → max(floor 100)=100 → min(cap 500)=100 → max(k)=100
      assert VectorSearch.pool_size(5, prod) == 100
      # k=40 → 200 → max(100)=200 → min(500)=200 → max(40)=200
      assert VectorSearch.pool_size(40, prod) == 200
      # k=200 → 1000 → max(100)=1000 → min(500)=500 → max(200)=500 (cap wins)
      assert VectorSearch.pool_size(200, prod) == 500
    end

    test "a misconfigured cap BELOW k can never drop the pool below k (the floor-at-k invariant)" do
      # The crux of AC-27.6b.1: k=50 with a configured cap of 10 → the final |> max(k)
      # overrides the too-small cap, so the pool is >= 50, NOT 10. We pass the cap as an
      # explicit arg (no Application.put_env) so the invariant is proven on the pure
      # sizing function directly.
      assert VectorSearch.pool_size(50, cap: 10) == 50
      assert VectorSearch.pool_size(50, cap: 10) >= 50

      # Even with floor + cap both below k, k wins.
      assert VectorSearch.pool_size(50, floor: 5, cap: 10) == 50
    end

    test "explicit factor/floor knobs compose, then k floors" do
      # k=2, factor=3, floor=4, cap=1000 → 6 → max(4)=6 → min(1000)=6 → max(2)=6
      assert VectorSearch.pool_size(2, factor: 3, floor: 4, cap: 1000) == 6
      # k=10, factor=1, floor=1, cap=3 → 10 → max(1)=10 → min(3)=3 → max(10)=10 (k wins)
      assert VectorSearch.pool_size(10, factor: 1, floor: 1, cap: 3) == 10
    end
  end

  # Resolve a `LIMIT $n` expression to its bound integer value.
  defp limit_value({:^, _, [idx]}, params), do: elem(Enum.at(params, idx), 0)
  defp limit_value(value, _params) when is_integer(value), do: value

  # The SQL substring between "WHERE" and the trailing "ORDER BY"/"LIMIT".
  defp where_substring(sql) do
    case Regex.run(~r/\bWHERE\b(.*?)(?:\bORDER BY\b|\bLIMIT\b|$)/si, sql) do
      [_, where] -> where
      _ -> ""
    end
  end
end
