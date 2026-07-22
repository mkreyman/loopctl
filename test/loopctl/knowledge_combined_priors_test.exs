defmodule Loopctl.KnowledgeCombinedPriorsTest do
  # #471 — recency + source-authority priors applied post-fusion in search_combined/3.
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  @now ~U[2026-07-21 00:00:00Z]

  # Two 1536-dim vectors: :query and :close point the same direction (cosine similarity 1),
  # so both near-duplicate articles are exact ties in the semantic lane too. Per-test-unique
  # via `Loopctl.DataCase.test_vec/2` (dissolves the shared-HNSW-index clique; see its @doc).
  defp query_vector, do: test_vec(1536, :primary)

  defp create_article(tenant_id, attrs) do
    article =
      fixture(
        :article,
        Map.merge(%{tenant_id: tenant_id, status: :published}, Map.new(attrs))
      )

    {:ok, embedded} = Knowledge.update_embedding(tenant_id, article.id, query_vector())
    embedded
  end

  # Set updated_at/inserted_at directly (AdminRepo bypasses RLS) so a doc looks aged.
  defp set_age(tenant_id, id, days_old) do
    ts = DateTime.add(@now, -days_old * 86_400, :second)

    {1, _} =
      AdminRepo.update_all(
        from(a in Article, where: a.tenant_id == ^tenant_id and a.id == ^id),
        set: [updated_at: ts, inserted_at: ts]
      )

    :ok
  end

  defp set_category(tenant_id, id, category) do
    {1, _} =
      AdminRepo.update_all(
        from(a in Article, where: a.tenant_id == ^tenant_id and a.id == ^id),
        set: [category: category]
      )

    :ok
  end

  defp set_tags(tenant_id, id, tags) do
    {1, _} =
      AdminRepo.update_all(
        from(a in Article, where: a.tenant_id == ^tenant_id and a.id == ^id),
        set: [tags: tags]
      )

    :ok
  end

  # A pair of near-IDENTICAL articles: same query-matching body, distinct non-query titles
  # (so the FTS rank ties). Both get the query embedding, so they also tie in the semantic
  # lane. The result: an EXACT relevance tie whose fused ordering is decided purely by the
  # deterministic id tiebreak — the clean canvas for isolating a single prior.
  @body "sprocket calibration telemetry across the widget lattice"
  defp near_tie_pair(tenant_id) do
    a = create_article(tenant_id, %{title: "Priors alpha note", body: @body})
    b = create_article(tenant_id, %{title: "Priors beta note", body: @body})
    [smaller, larger] = Enum.sort_by([a, b], & &1.id)
    {smaller, larger}
  end

  defp expect_query_embedding do
    # Capture in THIS process: the embedding is generated in a spawned worker that lacks this
    # process's :test_vec_axis, so a lazy `query_vector()` there would miss the articles' window.
    qv = query_vector()

    Mox.expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      {:ok, qv}
    end)
  end

  defp ids(results), do: Enum.map(results, & &1.id)

  defp search(tenant_id, opts) do
    assert {:ok, %{results: results}} =
             Knowledge.search_combined(tenant_id, "sprocket calibration telemetry", opts)

    results
  end

  describe "recency prior (fused path)" do
    test "a fresh article outranks an OLD near-duplicate that the id tiebreak would rank first" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)

      # Age the RRF-FAVORED doc (smaller id) so recency has to overcome the id tiebreak to
      # move the fresh doc to the top — otherwise the flip could be a fluke of id ordering.
      set_age(tenant.id, smaller.id, 400)
      set_age(tenant.id, larger.id, 0)

      # Control: no recency → the exact tie resolves to the RRF/id order (smaller id first).
      expect_query_embedding()
      neutral = search(tenant.id, now: @now, recency_weight: 0.0)
      assert ids(neutral) == [smaller.id, larger.id]

      # Recency ON → the fresh (larger-id) doc is lifted above the stale one. The FLIP is
      # the recency prior doing work the id tiebreak alone would not.
      expect_query_embedding()
      with_recency = search(tenant.id, now: @now, recency_weight: 0.3)
      assert ids(with_recency) == [larger.id, smaller.id]
    end
  end

  describe "authority prior (fused path)" do
    test "a decision re-ranks above an idea in an exact relevance tie" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)

      # The higher-authority :decision is the RRF-DISADVANTAGED (larger id) doc, so only the
      # authority prior can move it to the top; :idea is the RRF-favored smaller id.
      set_category(tenant.id, smaller.id, :idea)
      set_category(tenant.id, larger.id, :decision)

      # Control: authority OFF → the tie resolves to id/RRF order (idea, the smaller id, first).
      expect_query_embedding()
      neutral = search(tenant.id, now: @now, recency_weight: 0.0, authority_prior: false)
      assert ids(neutral) == [smaller.id, larger.id]

      # Authority ON → the decision (larger id) is re-ranked above the idea.
      expect_query_embedding()
      with_authority = search(tenant.id, now: @now, recency_weight: 0.0, authority_prior: true)
      assert ids(with_authority) == [larger.id, smaller.id]
    end
  end

  describe "dead-doctrine demotion (fused path)" do
    test "a verdict-kill article is demoted below a clean near-tie it would otherwise top" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)

      # The killed doc is the RRF-FAVORED smaller id — demotion must overcome that lead.
      set_tags(tenant.id, smaller.id, ["verdict-kill"])

      expect_query_embedding()
      results = search(tenant.id, now: @now, recency_weight: 0.0)

      assert ids(results) == [larger.id, smaller.id]
    end
  end

  describe "recency-neutral query is unaffected" do
    test "priors ON gives the same order as priors OFF when age and authority are equal" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)
      # Same age, same category, no kill tags → the priors must be inert.
      set_age(tenant.id, smaller.id, 0)
      set_age(tenant.id, larger.id, 0)

      expect_query_embedding()
      priors_off = search(tenant.id, now: @now, recency_weight: 0.0, authority_prior: false)

      expect_query_embedding()
      priors_on = search(tenant.id, now: @now, recency_weight: 0.3, authority_prior: true)

      assert ids(priors_on) == ids(priors_off)
      assert ids(priors_on) == [smaller.id, larger.id]
    end
  end

  describe "public result/meta shape is preserved" do
    test "raw relevance/similarity scores and final_score survive the re-rank; meta keys unchanged" do
      tenant = fixture(:tenant)

      both =
        create_article(tenant.id, %{
          title: "Sprocket calibration guide",
          body: "sprocket calibration telemetry keeps the widget lattice aligned"
        })

      expect_query_embedding()

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "sprocket calibration telemetry", now: @now)

      both_result = Enum.find(results, &(&1.id == both.id))
      assert both_result != nil

      # The re-rank adjusts :final_score but NEVER the raw fields the hybrid resolver reads.
      assert Map.has_key?(both_result, :final_score)
      assert is_number(both_result.relevance_score)
      assert is_number(both_result.similarity_score)

      # Meta shape unchanged from the pre-#471 combined contract.
      assert meta.search_mode == "combined"
      assert Map.has_key?(meta, :total_count)
      assert Map.has_key?(meta, :total_count_scope)
      assert Map.has_key?(meta, :semantic_result_count)
      assert Map.has_key?(meta, :limit)
      assert Map.has_key?(meta, :offset)
    end
  end

  describe "determinism" do
    test "repeated runs return an identical top-k ordering" do
      tenant = fixture(:tenant)
      {smaller, _larger} = near_tie_pair(tenant.id)
      set_age(tenant.id, smaller.id, 200)

      expect_query_embedding()
      first = search(tenant.id, now: @now, recency_weight: 0.3)

      expect_query_embedding()
      second = search(tenant.id, now: @now, recency_weight: 0.3)

      assert ids(first) == ids(second)
    end
  end

  describe "degraded keyword-only fallback still applies the priors it can (AC-5)" do
    test "recency re-ranks in keyword_only, without mutating the raw relevance_score" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)
      set_age(tenant.id, smaller.id, 400)
      set_age(tenant.id, larger.id, 0)

      # No embedding call is expected — the degraded path never reaches the provider.
      opts = [now: @now, embedding: {:error, :no_api_key}]

      assert {:ok, %{results: neutral, meta: meta}} =
               Knowledge.search_combined(
                 tenant.id,
                 "sprocket calibration telemetry",
                 Keyword.put(opts, :recency_weight, 0.0)
               )

      assert meta.search_mode == "keyword_only"
      assert meta.fallback == true
      # Control: the keyword lane's own DB order is ts_rank desc, id ASC → smaller id first.
      assert ids(neutral) == [smaller.id, larger.id]
      # Raw relevance_score is present and untouched (not overwritten by the re-rank).
      assert Enum.all?(neutral, &is_number(&1.relevance_score))

      assert {:ok, %{results: with_recency}} =
               Knowledge.search_combined(
                 tenant.id,
                 "sprocket calibration telemetry",
                 Keyword.put(opts, :recency_weight, 0.3)
               )

      # Recency flips the fresh (larger-id) doc to the top on the degraded path too.
      assert ids(with_recency) == [larger.id, smaller.id]
    end

    test "authority re-ranks in keyword_only" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)
      set_category(tenant.id, smaller.id, :idea)
      set_category(tenant.id, larger.id, :decision)

      opts = [now: @now, embedding: {:error, :no_api_key}, recency_weight: 0.0]

      assert {:ok, %{results: with_authority}} =
               Knowledge.search_combined(
                 tenant.id,
                 "sprocket calibration telemetry",
                 Keyword.put(opts, :authority_prior, true)
               )

      assert ids(with_authority) == [larger.id, smaller.id]
    end
  end

  describe "tenant isolation" do
    test "priors never surface another tenant's article" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      _a = create_article(tenant_a.id, %{title: "Tenant A note", body: @body})
      _b = create_article(tenant_b.id, %{title: "Tenant B note", body: @body})

      expect_query_embedding()
      results = search(tenant_a.id, now: @now)

      assert length(results) == 1
      assert Enum.all?(results, &(&1.tenant_id == tenant_a.id))
    end
  end
end
