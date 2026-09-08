defmodule Loopctl.KnowledgeCombinedPriorsTest do
  # #471 — recency + category-authority priors applied post-fusion in search_combined/3.
  # The source_type/provenance half of the authority prior was removed 2026-08-21 (owner
  # decision: ranking must not key on how a document got in).
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.RankingPriors

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
        # `content_changed_at` is what the recency prior actually reads (#791);
        # `updated_at`/`inserted_at` are aged with it so the row is coherent.
        set: [updated_at: ts, inserted_at: ts, content_changed_at: ts]
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

  # The usage signal the importance prior reads (#790). Set directly, exactly as the age and
  # category helpers above do: the column is in no cast list and is written only by the
  # nightly `Loopctl.Knowledge.Importance` stamp, so there is no API through which a test
  # (or a caller) could set it.
  defp set_read_days(tenant_id, id, days) do
    {1, _} =
      AdminRepo.update_all(
        from(a in Article, where: a.tenant_id == ^tenant_id and a.id == ^id),
        set: [read_day_count: days]
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

      priors_off =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_prior: false
        )

      expect_query_embedding()

      priors_on =
        search(tenant.id,
          now: @now,
          recency_weight: 0.3,
          authority_prior: true,
          importance_strength: 0.1
        )

      assert ids(priors_on) == ids(priors_off)
      assert ids(priors_on) == [smaller.id, larger.id]
    end

    test "an importance weight of 0 reproduces the priors-off ordering EXACTLY (#790)" do
      # The #471 property, extended to the third prior rather than replaced: with the weight
      # at 0 the ordering must be byte-for-byte what it was before the prior existed, even
      # when the two documents differ in the one input the prior reads.
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)
      set_age(tenant.id, smaller.id, 0)
      set_age(tenant.id, larger.id, 0)

      # The RRF-DISADVANTAGED doc is the heavily-used one, so a live prior WOULD move it.
      set_read_days(tenant.id, larger.id, 90)

      expect_query_embedding()

      priors_off =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_prior: false
        )

      expect_query_embedding()

      zero_weight =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_strength: 0.0
        )

      assert ids(zero_weight) == ids(priors_off)
      assert ids(zero_weight) == [smaller.id, larger.id]

      # Positive control: the SAME corpus reorders once the weight is live, so the equality
      # above is the weight being zero and not the usage being unreadable.
      expect_query_embedding()

      live =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_strength: 0.1
        )

      assert ids(live) == [larger.id, smaller.id]
    end
  end

  describe "#790 importance prior (fused path)" do
    test "a heavily-used article re-ranks above an unread near-tie the id tiebreak favours" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)
      set_age(tenant.id, smaller.id, 0)
      set_age(tenant.id, larger.id, 0)

      # The USED doc is the RRF-disadvantaged larger id, so only the importance prior can
      # move it to the top -- a flip here cannot be a fluke of id ordering.
      set_read_days(tenant.id, larger.id, 30)

      expect_query_embedding()

      neutral =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_prior: false
        )

      assert ids(neutral) == [smaller.id, larger.id]

      expect_query_embedding()

      with_importance =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_strength: 0.1
        )

      assert ids(with_importance) == [larger.id, smaller.id]
    end

    test "an UNREAD article is never pushed below where it ranks with the prior off" do
      # The one-sided guarantee at the fused level. Both documents are unread, so the prior
      # must be inert -- if it could demote on absent usage, the 2026-08-21 closed loop is
      # back and ~96% of this corpus is on the wrong side of it.
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)
      set_age(tenant.id, smaller.id, 0)
      set_age(tenant.id, larger.id, 0)

      expect_query_embedding()

      off =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_prior: false
        )

      expect_query_embedding()

      on =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_strength: 0.1
        )

      assert ids(on) == ids(off)
    end

    test "usage cannot flip a cross-lane consensus winner" do
      # The bound, at the fused level rather than in the factor arithmetic. `both` is found
      # by the keyword AND semantic lanes; `keyword_only` has no embedding, so it scores one
      # lane. Maximum usage on the single-lane doc must not be enough.
      tenant = fixture(:tenant)

      both =
        create_article(tenant.id, %{title: "Consensus alpha note", body: @body})

      keyword_only =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "Single lane beta note",
          body: @body
        })

      set_read_days(tenant.id, keyword_only.id, 10_000)

      expect_query_embedding()

      results =
        search(tenant.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_strength: 0.1
        )

      # Precondition: both documents are actually in the pool, or "the winner won" is vacuous.
      assert both.id in ids(results)
      assert keyword_only.id in ids(results)

      assert List.first(ids(results)) == both.id,
             "importance flipped a cross-lane consensus winner -- it is dominating " <>
               "relevance rather than breaking ties"
    end
  end

  describe "#790 meta states the importance weight in force" do
    test "the fused path reports the effective strength" do
      tenant = fixture(:tenant)
      create_article(tenant.id, %{title: "Meta note", body: @body})

      expect_query_embedding()

      assert {:ok, %{meta: meta}} =
               Knowledge.search_combined(tenant.id, "sprocket calibration telemetry",
                 now: @now,
                 importance_strength: 0.25
               )

      assert meta.importance_strength == 0.25
    end

    test "a disabled prior reports 0.0, not an absent key" do
      # `0.0` is the answer to "why did this rank" when importance played no part. An ABSENT
      # key reads as "this build has no importance prior", which is a different claim.
      tenant = fixture(:tenant)
      create_article(tenant.id, %{title: "Meta note", body: @body})

      expect_query_embedding()

      assert {:ok, %{meta: meta}} =
               Knowledge.search_combined(tenant.id, "sprocket calibration telemetry",
                 now: @now,
                 importance_prior: false
               )

      assert meta.importance_strength == 0.0
    end
  end

  describe "#790 tenant isolation" do
    test "the importance prior orders tenant A's own rows and never pools tenant B's" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      mine = create_article(tenant_a.id, %{title: "Mine importance note", body: @body})

      theirs =
        create_article(tenant_b.id, %{title: "Theirs importance note", body: @body})

      # Tenant B's article is the heavily-used one. If usage ever leaked across the tenant
      # boundary it would be the top result here.
      set_read_days(tenant_b.id, theirs.id, 90)

      expect_query_embedding()

      results =
        search(tenant_a.id,
          now: @now,
          recency_weight: 0.0,
          authority_prior: false,
          importance_strength: 0.1
        )

      assert ids(results) == [mine.id]
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

    test "the recency prior orders tenant A's own rows and never pools tenant B's" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      # A near-tie INSIDE tenant A, so the assertion below is decided by the recency prior
      # (the aged RRF-favoured row must lose its id tiebreak) and not by the tenant
      # predicate alone — which is all the isolation test above can distinguish.
      {smaller, larger} = near_tie_pair(tenant_a.id)
      set_age(tenant_a.id, smaller.id, 400)
      set_age(tenant_a.id, larger.id, 0)

      b = create_article(tenant_b.id, %{title: "Tenant B fresh note", body: @body})
      set_age(tenant_b.id, b.id, 0)

      expect_query_embedding()
      results = search(tenant_a.id, now: @now, recency_weight: 0.3)

      assert ids(results) == [larger.id, smaller.id]
      refute b.id in ids(results)
    end
  end

  describe "#791 recency measures AUTHORED age, so a re-embed cannot refresh a document" do
    test "a re-embed does not move the recency factor" do
      tenant = fixture(:tenant)
      article = create_article(tenant.id, %{title: "Authored age note", body: @body})

      # Age the CONTENT by 400 days. Without this the factor is ~1.0 on either field and
      # the equality below would hold vacuously — the aging is what gives it something to
      # be wrong about.
      set_age(tenant.id, article.id, 400)
      before = AdminRepo.get!(Article, article.id)

      factor_before =
        RankingPriors.recency_factor(RankingPriors.recency_timestamp(before), @now, 0.3)

      {:ok, _} = Knowledge.update_embedding(tenant.id, article.id, query_vector())

      reloaded = AdminRepo.get!(Article, article.id)

      # Precondition, not decoration: the re-embed must genuinely have bumped `updated_at`,
      # or this test proves nothing about the field the prior stopped reading.
      assert DateTime.compare(reloaded.updated_at, before.updated_at) == :gt
      assert reloaded.content_changed_at == before.content_changed_at

      factor_after =
        RankingPriors.recency_factor(RankingPriors.recency_timestamp(reloaded), @now, 0.3)

      assert factor_after == factor_before

      # Positive control: had the prior stayed on `updated_at`, the re-embed WOULD have
      # moved it — by a lot. This is the defect #791 closes, measured.
      on_updated_at = RankingPriors.recency_factor(reloaded.updated_at, @now, 0.3)
      refute_in_delta on_updated_at, factor_before, 0.1
    end

    test "a re-embed of the stale doc does not flip the fused order back" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)

      # The STALE doc is the one the id tiebreak favours, so recency is the only thing
      # holding the fresh doc on top — exactly the ordering a re-embed used to undo.
      set_age(tenant.id, smaller.id, 400)
      set_age(tenant.id, larger.id, 0)

      expect_query_embedding()
      assert ids(search(tenant.id, now: @now, recency_weight: 0.3)) == [larger.id, smaller.id]

      {:ok, _} = Knowledge.update_embedding(tenant.id, smaller.id, query_vector())

      expect_query_embedding()
      assert ids(search(tenant.id, now: @now, recency_weight: 0.3)) == [larger.id, smaller.id]
    end

    test "a null content_changed_at falls back to updated_at, exactly as before #791" do
      tenant = fixture(:tenant)
      {smaller, larger} = near_tie_pair(tenant.id)

      set_age(tenant.id, smaller.id, 400)
      set_age(tenant.id, larger.id, 0)

      # A row the backfill could not establish an authored date for. It must keep the
      # pre-#791 behaviour — ranked on `updated_at` — never lose its recency prior.
      {1, _} =
        AdminRepo.update_all(
          from(a in Article, where: a.tenant_id == ^tenant.id and a.id == ^smaller.id),
          set: [content_changed_at: nil]
        )

      expect_query_embedding()
      assert ids(search(tenant.id, now: @now, recency_weight: 0.3)) == [larger.id, smaller.id]
    end
  end
end
