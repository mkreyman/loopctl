defmodule Loopctl.KnowledgeSemanticSearchTest do
  # Defined HERE rather than borrowed from `Loopctl.Knowledge.RerankerTest`: `mix test
  # <one file>` loads only that file, so a stub living in a sibling test module is
  # undefined, `Reranker` rescues the UndefinedFunctionError, and the test passes VACUOUSLY
  # by observing the un-reranked order it was checking against.
  defmodule ReversingReranker do
    @moduledoc false
    @behaviour Loopctl.Knowledge.Reranker
    @impl true
    def rerank(_scope, _query, candidates, _opts),
      do: {:ok, candidates |> Enum.map(& &1.id) |> Enum.reverse()}
  end

  defmodule RaisingReranker do
    @moduledoc false
    @behaviour Loopctl.Knowledge.Reranker
    @impl true
    def rerank(_scope, _query, _candidates, _opts), do: raise("boom")
  end

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.HeavyRead.TenantGate
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.EmbeddingConcurrency

  # Embedding dimensions configured as 1536.
  # We use small deterministic vectors for predictable cosine distances.
  # Vectors pointing in the same direction have cosine distance 0 (similarity 1).
  # Orthogonal vectors have cosine distance 1 (similarity 0).

  # Per-test-unique vectors via `Loopctl.DataCase.test_vec/2` (see its @doc): each test's
  # vectors land in a DISJOINT window of the shared, cross-tenant pgvector HNSW index, so the
  # `half_ones`/orthogonal/constant vectors these tests share no longer form the all-ties
  # clique that flakes recall. Within a test the geometry is preserved: `:close`==`:query`
  # (cosine 1.0), `:far`⊥query (cosine 0), `:medium` ~0.71.
  defp make_embedding(:close), do: test_vec(1536, :primary)
  defp make_embedding(:far), do: test_vec(1536, :orthogonal)
  defp make_embedding(:query), do: test_vec(1536, :primary)
  defp make_embedding(:medium), do: test_vec(1536, :near)

  # The identical-score test seeds many rows with THIS one vector and queries it; keeping them
  # all identical (now per-test-unique) preserves the equal-scores semantics while de-cliquing
  # the old degenerate constant (`List.duplicate(0.1, 1536)` — the KB-0bdadd52 anti-pattern).
  defp make_embedding(:uniform), do: test_vec(1536, :primary)

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  defp setup_tenant_with_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project}
  end

  defp create_article_with_embedding(tenant_id, attrs, embedding_type) do
    article = fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))
    embedding = make_embedding(embedding_type)
    {:ok, updated} = Knowledge.update_embedding(tenant_id, article.id, embedding)
    updated
  end

  # --- TC-20.4.1: Semantic search ordered by cosine similarity, excludes nil embeddings ---

  describe "search_semantic/3 - ranked results and nil embedding exclusion" do
    test "returns results ordered by cosine similarity, excludes nil embeddings" do
      %{tenant: tenant} = setup_tenant()

      # Article with embedding close to query
      close_article =
        create_article_with_embedding(
          tenant.id,
          %{title: "Close Match Article"},
          :close
        )

      # Article with embedding far from query
      far_article =
        create_article_with_embedding(
          tenant.id,
          %{title: "Far Match Article"},
          :far
        )

      # Article with no embedding (should be excluded)
      _no_embedding =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "No Embedding Article",
          status: :published
        })

      query_vector = make_embedding(:query)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, query_vector)

      # Only 2 results (nil embedding excluded)
      assert length(results) == 2
      assert meta.total_count == 2
      assert meta.search_mode == "semantic_only"
      # total_count is the ranked embedded corpus, not a relevance-match count.
      assert meta.total_count_scope == "ranked_corpus"

      # Close article should rank first
      [first, second] = results
      assert first.id == close_article.id
      assert second.id == far_article.id

      # Similarity scores should be between 0 and 1
      assert is_float(first.similarity_score)
      assert is_float(second.similarity_score)
      assert first.similarity_score >= 0.0
      assert first.similarity_score <= 1.0
      assert first.similarity_score > second.similarity_score
    end

    test "returns empty results when no articles have embeddings" do
      %{tenant: tenant} = setup_tenant()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft No Embedding",
        status: :published
      })

      query_vector = make_embedding(:query)

      assert {:ok, %{results: [], meta: %{total_count: 0}}} =
               Knowledge.search_semantic(tenant.id, query_vector)
    end
  end

  # --- TC-20.4.5: Semantic search filters by project_id, category ---

  describe "search_semantic/3 - filters" do
    test "filters by project_id" do
      %{tenant: tenant, project: project} = setup_tenant_with_project()

      _in_project =
        create_article_with_embedding(
          tenant.id,
          %{title: "In Project", project_id: project.id},
          :close
        )

      _no_project =
        create_article_with_embedding(
          tenant.id,
          %{title: "No Project"},
          :close
        )

      query_vector = make_embedding(:query)

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, query_vector, project_id: project.id)

      assert length(results) == 1
      assert hd(results).project_id == project.id
    end

    test "filters by category" do
      %{tenant: tenant} = setup_tenant()

      _pattern =
        create_article_with_embedding(
          tenant.id,
          %{title: "Pattern Article", category: :pattern},
          :close
        )

      _reference =
        create_article_with_embedding(
          tenant.id,
          %{title: "Reference Article", category: :reference},
          :close
        )

      query_vector = make_embedding(:query)

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, query_vector, category: :pattern)

      assert length(results) == 1
      assert hd(results).category == :pattern
    end

    test "filters by tags" do
      %{tenant: tenant} = setup_tenant()

      _tagged =
        create_article_with_embedding(
          tenant.id,
          %{title: "Tagged Article", tags: ["elixir", "testing"]},
          :close
        )

      _untagged =
        create_article_with_embedding(
          tenant.id,
          %{title: "Other Article", tags: ["deployment"]},
          :close
        )

      query_vector = make_embedding(:query)

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, query_vector, tags: ["elixir"])

      assert length(results) == 1
      assert hd(results).title == "Tagged Article"
    end

    test "defaults to published status" do
      %{tenant: tenant} = setup_tenant()

      _published =
        create_article_with_embedding(
          tenant.id,
          %{title: "Published Semantic", status: :published},
          :close
        )

      # Create a draft article with embedding
      draft = fixture(:article, %{tenant_id: tenant.id, title: "Draft Semantic", status: :draft})
      {:ok, _} = Knowledge.update_embedding(tenant.id, draft.id, make_embedding(:close))

      query_vector = make_embedding(:query)

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, query_vector)

      assert length(results) == 1
      assert hd(results).status == :published
    end
  end

  # --- TC-20.4.6: Tenant isolation in semantic search ---

  describe "search_semantic/3 - tenant isolation" do
    test "tenant A cannot see tenant B's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      _article_a =
        create_article_with_embedding(
          tenant_a.id,
          %{title: "Tenant A Semantic Article"},
          :close
        )

      query_vector = make_embedding(:query)

      # Tenant B sees nothing
      assert {:ok, %{results: []}} =
               Knowledge.search_semantic(tenant_b.id, query_vector)

      # Tenant A sees their article
      assert {:ok, %{results: [result]}} =
               Knowledge.search_semantic(tenant_a.id, query_vector)

      assert result.tenant_id == tenant_a.id
    end
  end

  # --- Pagination ---

  describe "search_semantic/3 - pagination" do
    test "respects limit and offset" do
      %{tenant: tenant} = setup_tenant()

      for i <- 1..5 do
        create_article_with_embedding(
          tenant.id,
          %{title: "Semantic Article #{i}"},
          :uniform
        )
      end

      query_vector = make_embedding(:query)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, query_vector, limit: 2, offset: 0)

      assert length(results) == 2
      assert meta.total_count == 5
      assert meta.limit == 2
      assert meta.offset == 0

      # Second page
      assert {:ok, %{results: page2, meta: meta2}} =
               Knowledge.search_semantic(tenant.id, query_vector, limit: 2, offset: 2)

      assert length(page2) == 2
      assert meta2.total_count == 5
      assert meta2.offset == 2
    end

    test "defaults to limit 10, caps at the relevance page size (#148 A1)" do
      %{tenant: tenant} = setup_tenant()

      query_vector = make_embedding(:query)

      assert {:ok, %{meta: meta}} =
               Knowledge.search_semantic(tenant.id, query_vector)

      assert meta.limit == 10
      assert meta.offset == 0

      # Relevance modes cap at max_relevance_page_size (a ranked top-N), well below
      # the enumeration page size. The context clamps as a safety net; the HTTP
      # layer 400s an over-cap request.
      cap = Knowledge.max_relevance_page_size()

      assert {:ok, %{meta: capped_meta}} =
               Knowledge.search_semantic(tenant.id, query_vector, limit: cap + 50)

      assert capped_meta.limit == cap
    end
  end

  # --- TC-20.4.2: Combined search merges keyword + semantic with deduplication ---

  describe "search_combined/3 - merged results" do
    test "merges keyword and semantic results with deduplication" do
      %{tenant: tenant} = setup_tenant()

      # Article that matches BOTH keyword and semantic
      both_match =
        create_article_with_embedding(
          tenant.id,
          %{
            title: "Error Handling Patterns",
            body: "Try rescue patterns for error handling in Elixir."
          },
          :close
        )

      # Article that matches semantic only (no keyword match on "error")
      _semantic_only =
        create_article_with_embedding(
          tenant.id,
          %{
            title: "Fault Tolerance Guide",
            body: "Supervisor trees prevent cascading failures."
          },
          :close
        )

      # Article that matches keyword only (has "error" in text but far embedding)
      _keyword_only =
        create_article_with_embedding(
          tenant.id,
          %{
            title: "Deployment Errors",
            body: "Common error messages during deployment."
          },
          :far
        )

      query_embedding = make_embedding(:query)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, query_embedding}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "error")

      assert meta.search_mode == "combined"

      # No duplicate article IDs
      ids = Enum.map(results, & &1.id)
      assert ids == Enum.uniq(ids)

      # All results have final_score
      assert Enum.all?(results, &Map.has_key?(&1, :final_score))

      # Results sorted by final_score descending
      scores = Enum.map(results, & &1.final_score)
      assert scores == Enum.sort(scores, :desc)

      # The article matching both should have a high score
      both_result = Enum.find(results, &(&1.id == both_match.id))
      assert both_result != nil
      assert both_result.final_score > 0
    end
  end

  # --- TC-20.4.3: Combined search falls back to keyword-only on embedding failure ---

  describe "search_combined/3 - fallback on embedding failure" do
    test "falls back to keyword-only when embedding generation fails" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Testing Guide",
        body: "Unit test patterns for testing Elixir applications.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :service_unavailable}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "testing")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      # The fallback ran keyword-only, so total_count is the keyword match count.
      assert meta.total_count_scope == "keyword_matches"

      # Should still find via keyword match
      assert results != []
      assert Enum.any?(results, &(&1.title == "Testing Guide"))
    end
  end

  # Finding #4 (US-37.5 review): the user-facing keyword-fallback-on-overload degrade
  # (search_semantic → {:error, :heavy_read_overloaded} → combined_keyword_fallback)
  # had no coverage. Here the embedding SUCCEEDS but the semantic heavy read is SHED
  # over the per-tenant cap, so combined search must degrade to keyword_only and
  # surface `meta.fallback_reason == "heavy_read_overloaded"` — the SAME graceful path
  # as an embedding failure, keeping other tenants' access to the shared pool.
  describe "search_combined/3 - keyword fallback on over-cap semantic shed (US-37.5)" do
    test "an over-cap semantic shed → keyword_only + fallback_reason heavy_read_overloaded" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Testing Guide",
        body: "Unit test patterns for testing Elixir applications.",
        status: :published
      })

      # Embedding SUCCEEDS (so the semantic branch is attempted); the semantic HeavyRead
      # (search_semantic, on_overload: :tag) then sheds because the tenant is over-cap.
      # Keyword search runs on AdminRepo (ungated), so it still returns matches.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      cap = TenantGate.cap()
      assert TenantGate.acquire(tenant.id, cap, cap) == :ok

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "testing")

      assert meta.search_mode == "keyword_only"
      assert meta.fallback == true
      assert meta.fallback_reason == "heavy_read_overloaded"
      assert Enum.any?(results, &(&1.title == "Testing Guide"))

      TenantGate.release(tenant.id, cap)
    end
  end

  # --- US-37.2: per-node embedding concurrency cap gates the interactive path ---
  #
  # The cap is enforced inside `run_embedding_task/3` (the single guarded entry
  # point). In :test the gate is the config-DI mock (`Loopctl.MockEmbeddingConcurrency`,
  # default-stubbed to grant every slot) so we can force saturation deterministically
  # WITHOUT holding the real, VM-wide global counter saturated (which would starve
  # unrelated async searches). The real GenServer's cap/reclaim behavior is unit-tested
  # in `Loopctl.Knowledge.EmbeddingConcurrencyTest`.
  describe "search_combined/3 - per-node embedding concurrency cap (US-37.2)" do
    # TC-37.2.2 / AC-37.2.3: at the cap, the interactive path degrades to keyword
    # search (same fallback as :circuit_open / :rate_limited_local) — never a 500,
    # never an unbounded wait. AC-37.2.2: the acquire gates the query path, so the
    # embedding CLIENT is never reached when the cap is saturated.
    test "saturated cap → keyword-only fallback (never a 500), client never called" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Testing Guide",
        body: "Unit test patterns for testing Elixir applications.",
        status: :published
      })

      # Saturate the gate: every acquire is refused.
      Mox.stub(Loopctl.MockEmbeddingConcurrency, :acquire, fn _tenant_id ->
        {:error, :rate_limited_local}
      end)

      # The interactive path never reaches the paid client when the cap is full
      # (acquire fails first) — proving the query path is genuinely gated (AC-37.2.2).
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "testing")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      # Reuses the US-37.1 breaker-exempt reason → the existing stable fallback tag.
      assert meta.fallback_reason == "embedding_rate_limited_local"

      # Keyword search still returns results — the request survived and degraded.
      assert results != []
      assert Enum.any?(results, &(&1.title == "Testing Guide"))
    end

    # TC-37.2.3 / AC-37.2.5: an embedding task crash is isolated — the request
    # process survives and returns a keyword fallback, not a caller crash. The inner
    # rescue turns the raise into {:error, {:embedding_crash, ...}}.
    @tag :capture_log
    test "embedding task raise is isolated → request survives with keyword fallback" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Testing Guide",
        body: "Unit test patterns for testing Elixir applications.",
        status: :published
      })

      # Under the cap (default :ok), but the embedding client raises inside the
      # supervised task. `Mox.stub` (not expect) because the call runs OFF the test
      # process in the async_nolink task.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        raise "boom"
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "testing")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.fallback_reason == "embedding_crash"
      assert Enum.any?(results, &(&1.title == "Testing Guide"))
    end

    # AC-37.2.5: an embedding task EXIT (which the inner rescue cannot catch) is
    # isolated by Task.Supervisor.async_nolink — it surfaces as a yield {:exit, _}
    # → {:error, :timeout}, NOT a crash of the request process.
    @tag :capture_log
    test "embedding task exit is isolated by async_nolink → request survives" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Testing Guide",
        body: "Unit test patterns for testing Elixir applications.",
        status: :published
      })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        exit(:boom)
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "testing")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.fallback_reason == "embedding_timeout"
      assert Enum.any?(results, &(&1.title == "Testing Guide"))
    end

    # TC-37.2.4 / AC-37.2.5: happy path under the cap is UNCHANGED — a normal search
    # still returns merged semantic results (no fallback), adding only slot-acquire.
    test "under the cap, a combined search returns semantic results as today" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      both_match =
        create_article_with_embedding(
          tenant.id,
          %{title: "Error Handling Patterns", body: "Try rescue patterns for error handling."},
          :close
        )

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        make_embedding(:query) |> then(&{:ok, &1})
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "error")

      assert meta.search_mode == "combined"
      refute Map.get(meta, :fallback)
      assert Enum.any?(results, &(&1.id == both_match.id))
    end

    # AC-37.2.2 wiring: prove search_combined -> run_embedding_task actually routes
    # through the REAL Loopctl.Knowledge.EmbeddingConcurrency GenServer's counter, not
    # just the permissive DI mock. Every OTHER search test resolves the gate to the
    # mock, so a production wiring regression (run_embedding_task not calling acquire,
    # threading the wrong tenant, or the real gate mishandling the search path) could
    # pass unseen. Here the DI mock DELEGATES to the real gate — Mox.expect verifies
    # acquire/1 + release/1 each fire exactly once with the request's tenant — and we
    # assert the real PER-TENANT counter round-trips back to 0. The tenant is unique
    # (fixture), so the per-tenant counter never collides with any other test.
    test "search_combined routes through the REAL concurrency gate (acquire+release wired)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      both_match =
        create_article_with_embedding(
          tenant.id,
          %{title: "Error Handling Patterns", body: "Try rescue patterns for error handling."},
          :close
        )

      # Delegate the DI mock to the REAL gate for THIS tenant and verify each callback
      # fires exactly once with the right tenant. acquire/release run in the test
      # process (before/after the async_nolink task), so no $callers allowance is needed.
      Mox.expect(Loopctl.MockEmbeddingConcurrency, :acquire, fn tid ->
        assert tid == tenant.id
        EmbeddingConcurrency.acquire(tid)
      end)

      Mox.expect(Loopctl.MockEmbeddingConcurrency, :release, fn tid ->
        assert tid == tenant.id
        EmbeddingConcurrency.release(tid)
      end)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "error")

      # Happy path preserved through the REAL gate...
      assert meta.search_mode == "combined"
      refute Map.get(meta, :fallback)
      assert Enum.any?(results, &(&1.id == both_match.id))

      # ...and the real gate's per-tenant slot was acquired AND released (the round-trip
      # is wired end-to-end): the counter is back to 0 for this tenant.
      assert EmbeddingConcurrency.tenant_count(tenant.id) == 0
    end
  end

  # --- #297: fallback_reason + telemetry observability for the silent semantic→
  # keyword degradation. Each fallback CAUSE must map to the right stable tag,
  # NEVER leak the api key / provider body, fire the telemetry event, and the
  # "embed worked but recall empty" case must be distinguishable from an embed
  # failure. A successful semantic must set neither fallback nor fallback_reason.

  describe "search_combined/3 - fallback_reason observability (#297)" do
    # Attach a telemetry handler SCOPED to this test's tenant_id (unique UUID) so a
    # parallel async test emitting the same global event can never leak into this
    # one — the handler branches on tenant_id and NEVER raises (a raising handler
    # would be auto-detached by :telemetry, breaking isolation the other way).
    defp attach_fallback_handler(tenant_id) do
      test_pid = self()
      handler_id = "semfb-#{System.unique_integer([:positive])}"
      event = [:loopctl, :knowledge, :semantic_fallback]

      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, _config ->
          if metadata.tenant_id == tenant_id do
            send(test_pid, {:semantic_fallback, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    defp keyword_article(tenant_id) do
      fixture(:article, %{
        tenant_id: tenant_id,
        title: "Testing Guide",
        body: "Unit test patterns for testing Elixir applications.",
        status: :published
      })
    end

    test ":no_api_key -> \"no_embedding_key\" in meta + telemetry" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      keyword_article(tenant.id)
      attach_fallback_handler(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")
      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.fallback_reason == "no_embedding_key"

      assert_receive {:semantic_fallback, measurements, metadata}
      assert metadata.reason == "no_embedding_key"
      assert metadata.tenant_id == tenant.id
      assert measurements.query_len == byte_size("testing")
      assert measurements.count == 1
    end

    test ":timeout -> \"embedding_timeout\" in meta + telemetry" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      keyword_article(tenant.id)
      attach_fallback_handler(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :timeout}
      end)

      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")
      assert meta.fallback_reason == "embedding_timeout"

      assert_receive {:semantic_fallback, _m, %{reason: "embedding_timeout"}}
    end

    test "{:api_error, 401, body-with-a-fake-key} -> status-only tag, NEVER leaks the key/body" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      keyword_article(tenant.id)
      attach_fallback_handler(tenant.id)

      fake_key = "sk-SECRET-DEADBEEF-must-not-leak"
      provider_body = "Incorrect API key provided: #{fake_key}"

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, provider_body}}
      end)

      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")
      assert meta.fallback_reason == "embedding_provider_error_401"

      # The sanitizer (ProviderError) drops the body — neither the key nor the
      # provider message survives into the response meta.
      refute inspect(meta) =~ fake_key
      refute inspect(meta) =~ "Incorrect API key"

      assert_receive {:semantic_fallback, _m, metadata}
      assert metadata.reason == "embedding_provider_error_401"
      refute inspect(metadata) =~ fake_key
      refute inspect(metadata) =~ "Incorrect API key"
    end

    test "US-37.1: :rate_limited_local -> \"embedding_rate_limited_local\", keyword fallback, no 500" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      keyword_article(tenant.id)
      attach_fallback_handler(tenant.id)

      # An empty node-local admission bucket surfaces as {:error, :rate_limited_local}
      # from the embedding client — the SAME keyword-fallback path as :circuit_open.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :rate_limited_local}
      end)

      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")
      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.fallback_reason == "embedding_rate_limited_local"

      assert_receive {:semantic_fallback, _m, %{reason: "embedding_rate_limited_local"}}
    end

    test "US-37.1 (AC-37.1.3): repeated :rate_limited_local does NOT trip the circuit breaker" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      keyword_article(tenant.id)

      # Far more than the breaker threshold (3): every call returns a node-local
      # admission rate-limit.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :rate_limited_local}
      end)

      for _ <- 1..10, do: Knowledge.search_combined(tenant.id, "testing")

      attach_fallback_handler(tenant.id)

      # If the breaker had tripped, generate_embedding would short-circuit to
      # :circuit_open WITHOUT calling the client, tagging "embedding_circuit_open".
      # Because :rate_limited_local is breaker-exempt, the client is still consulted
      # and the tag stays "embedding_rate_limited_local".
      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")
      assert meta.fallback_reason == "embedding_rate_limited_local"

      assert_receive {:semantic_fallback, _m, %{reason: "embedding_rate_limited_local"}}
    end

    test "a genuinely OPEN circuit breaker surfaces \"embedding_circuit_open\"" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      keyword_article(tenant.id)

      # 5xx is a COUNTABLE failure; three trip the tenant-scoped breaker.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, "upstream boom"}}
      end)

      for _ <- 1..3, do: Knowledge.search_combined(tenant.id, "testing")

      # Attach only now so we observe the circuit-open call specifically.
      attach_fallback_handler(tenant.id)

      # The breaker is now open: generate_embedding short-circuits to :circuit_open
      # WITHOUT calling the client.
      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")
      assert meta.fallback_reason == "embedding_circuit_open"

      assert_receive {:semantic_fallback, _m, %{reason: "embedding_circuit_open"}}
    end

    test "US-37.3 (AC-37.3.5): a 429 throttle storm trips the breaker → keyword fallback, never a 500" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      keyword_article(tenant.id)

      # US-37.3: 429 is now a COUNTABLE (throttle) failure — three trip the breaker.
      # Before the split it was breaker-exempt, so a 429 storm never opened it.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 429, :provider_error, 30}}
      end)

      # Each call degrades to keyword-only (never a 500) — tagged by the provider
      # status while the breaker is still closed.
      for _ <- 1..3 do
        assert {:ok, %{meta: _}} = Knowledge.search_combined(tenant.id, "testing")
      end

      attach_fallback_handler(tenant.id)

      # Breaker now open: generate_embedding short-circuits to :circuit_open (no
      # client call, no hot retry into the throttling provider) and combined search
      # still returns {:ok, ...} keyword results — the fail-safe.
      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")
      assert meta.fallback_reason == "embedding_circuit_open"
      assert_receive {:semantic_fallback, _m, %{reason: "embedding_circuit_open"}}
    end

    test "embedding OK but semantic EMPTY -> semantic_result_count: 0, no fallback, distinct telemetry" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      # Keyword-findable but NOT embedded, so the semantic half (which excludes nil
      # embeddings) contributes zero rows even though the default stub embeds OK.
      keyword_article(tenant.id)
      attach_fallback_handler(tenant.id)

      assert {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "testing")

      # NOT a keyword_only fallback — combined still ran, keyword merged.
      refute Map.get(meta, :fallback)
      refute Map.has_key?(meta, :fallback_reason)
      assert meta.search_mode == "combined"
      assert meta.semantic_result_count == 0

      assert_receive {:semantic_fallback, measurements, metadata}
      assert metadata.reason == "semantic_empty"
      assert measurements.semantic_result_count == 0
    end

    test "successful semantic (embedding ok + non-empty) sets NO fallback/fallback_reason and fires NO telemetry" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      create_article_with_embedding(
        tenant.id,
        %{title: "Deployment Guide", body: "How to deploy an Elixir app for testing."},
        :close
      )

      attach_fallback_handler(tenant.id)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "testing")

      refute Map.get(meta, :fallback)
      refute Map.has_key?(meta, :fallback_reason)
      assert meta.semantic_result_count >= 1
      assert results != []

      refute_receive {:semantic_fallback, _m, _metadata}
    end
  end

  # --- TC-20.4.4: Invalid weights return {:error, :invalid_weights} ---

  describe "search_combined/3 - weight validation" do
    test "returns {:error, :invalid_weights} when weights don't sum to 1.0" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :invalid_weights} =
               Knowledge.search_combined(tenant.id, "test",
                 keyword_weight: 0.7,
                 semantic_weight: 0.7
               )
    end

    test "returns {:error, :invalid_weights} for zero weights" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :invalid_weights} =
               Knowledge.search_combined(tenant.id, "test",
                 keyword_weight: 0.0,
                 semantic_weight: 0.0
               )
    end

    test "returns {:error, :invalid_weights} for negative weights" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :invalid_weights} =
               Knowledge.search_combined(tenant.id, "test",
                 keyword_weight: -0.5,
                 semantic_weight: 1.5
               )
    end

    test "accepts weights that sum to 1.0 within tolerance" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tolerance Check",
        body: "Testing weight tolerance.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      # 0.3 + 0.7 = 1.0 exactly
      assert {:ok, _} =
               Knowledge.search_combined(tenant.id, "tolerance",
                 keyword_weight: 0.3,
                 semantic_weight: 0.7
               )
    end

    test "returns {:error, :empty_query} for empty query string" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :empty_query} =
               Knowledge.search_combined(tenant.id, "")
    end

    test "returns {:error, :empty_query} for nil query string" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :empty_query} =
               Knowledge.search_combined(tenant.id, nil)
    end
  end

  # --- TC-20.4.7: Combined search with custom weights affects ranking ---

  describe "search_combined/3 - custom weights affect ranking" do
    test "semantic-heavy weight favors semantically close results" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      # "Exact Match" has keyword match on "deployment" + far embedding
      _exact_match =
        create_article_with_embedding(
          tenant.id,
          %{
            title: "Deployment Pipeline Guide",
            body: "Complete deployment pipeline for production systems."
          },
          :far
        )

      # "Conceptual Match" has no keyword match but close embedding
      _conceptual_match =
        create_article_with_embedding(
          tenant.id,
          %{
            title: "CI CD Workflow",
            body: "Continuous integration and continuous delivery workflow patterns."
          },
          :close
        )

      query_embedding = make_embedding(:query)

      # With semantic_weight=0.8, conceptual match should rank higher
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, query_embedding}
      end)

      assert {:ok, %{results: semantic_heavy}} =
               Knowledge.search_combined(tenant.id, "deployment",
                 keyword_weight: 0.2,
                 semantic_weight: 0.8
               )

      # With keyword_weight=0.8, exact match should rank higher
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, query_embedding}
      end)

      assert {:ok, %{results: keyword_heavy}} =
               Knowledge.search_combined(tenant.id, "deployment",
                 keyword_weight: 0.8,
                 semantic_weight: 0.2
               )

      # Verify we got results from both
      assert semantic_heavy != []
      assert keyword_heavy != []

      # In semantic-heavy mode, the conceptually close article should score higher
      semantic_scores = Map.new(semantic_heavy, fn r -> {r.title, r.final_score} end)
      keyword_scores = Map.new(keyword_heavy, fn r -> {r.title, r.final_score} end)

      # The CI CD article should have a higher relative score with semantic weight
      cicd_semantic = Map.get(semantic_scores, "CI CD Workflow", 0)
      cicd_keyword = Map.get(keyword_scores, "CI CD Workflow", 0)

      deploy_semantic = Map.get(semantic_scores, "Deployment Pipeline Guide", 0)
      deploy_keyword = Map.get(keyword_scores, "Deployment Pipeline Guide", 0)

      # With semantic=0.8, CI CD should rank relatively better than with keyword=0.8
      if cicd_semantic > 0 and deploy_keyword > 0 do
        assert cicd_semantic / max(deploy_semantic, 0.001) >
                 cicd_keyword / max(deploy_keyword, 0.001)
      end
    end
  end

  # --- Circuit breaker ---

  describe "search_combined/3 - circuit breaker" do
    test "falls back after 3 consecutive failures within 60 seconds" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Circuit Breaker Test",
        body: "Testing circuit breaker fallback behavior.",
        status: :published
      })

      # Fail 3 times to trip the circuit breaker
      for _i <- 1..3 do
        expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
          {:error, :service_unavailable}
        end)

        assert {:ok, %{meta: %{fallback: true, search_mode: "keyword_only"}}} =
                 Knowledge.search_combined(tenant.id, "circuit")
      end

      # 4th call should NOT call generate_embedding (circuit is open)
      # The stub from DataCase handles the case but the circuit breaker
      # should prevent the call entirely
      assert {:ok, %{meta: %{fallback: true, search_mode: "keyword_only"}}} =
               Knowledge.search_combined(tenant.id, "circuit")
    end

    test "circuit breaker resets after success" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Recovery Test Article",
        body: "Testing recovery after circuit breaker reset.",
        status: :published
      })

      # One failure
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :temporary_failure}
      end)

      assert {:ok, %{meta: %{fallback: true}}} =
               Knowledge.search_combined(tenant.id, "recovery")

      # Then a success (resets failure count)
      query_embedding = make_embedding(:query)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, query_embedding}
      end)

      assert {:ok, %{meta: %{search_mode: "combined"}}} =
               Knowledge.search_combined(tenant.id, "recovery")

      # Another failure should not trip the breaker (counter was reset)
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :temporary_failure}
      end)

      assert {:ok, %{meta: %{fallback: true, search_mode: "keyword_only"}}} =
               Knowledge.search_combined(tenant.id, "recovery")
    end
  end

  # --- Per-tenant circuit breaker + error classification (BYO review #1/#6) ---

  describe "generate_embedding/3 - per-tenant circuit breaker" do
    test "a keyless tenant's :no_api_key NEVER trips the breaker" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      for _i <- 1..5 do
        assert {:error, :no_api_key} = Knowledge.generate_embedding(tenant.id, "q")
      end

      # A subsequent successful call still reaches the client — proving the breaker
      # was never opened by the config-gap errors (an open breaker would short-circuit
      # to {:error, :circuit_open} WITHOUT calling the client).
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:ok, _vec} = Knowledge.generate_embedding(tenant.id, "q")
    end

    test "a 4xx (per-tenant credential/quota) NEVER trips the breaker" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      for _i <- 1..5 do
        assert {:error, {:api_error, 401, _}} = Knowledge.generate_embedding(tenant.id, "q")
      end

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:ok, _vec} = Knowledge.generate_embedding(tenant.id, "q")
    end

    test "5xx failures DO open the breaker (and short-circuit further calls)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      for _i <- 1..3 do
        assert {:error, {:api_error, 500, _}} = Knowledge.generate_embedding(tenant.id, "q")
      end

      # Breaker is now open for THIS tenant: the next call short-circuits without
      # touching the client (which would otherwise return {:ok, _}).
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "q")
    end

    test "tenant A's 5xx failures do NOT degrade tenant B's search (the #1 repro)" do
      %{tenant: a} = setup_tenant()
      %{tenant: b} = setup_tenant()
      Knowledge.reset_circuit_breaker(a.id)
      Knowledge.reset_circuit_breaker(b.id)

      # A always 5xx-fails; B always succeeds.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn scope, _text ->
        if EgressScope.coerce(scope).tenant_id == a.id do
          {:error, {:api_error, 500, :provider_error}}
        else
          {:ok, make_embedding(:query)}
        end
      end)

      # Trip A's breaker.
      for _i <- 1..3 do
        assert {:error, {:api_error, 500, _}} = Knowledge.generate_embedding(a.id, "q")
      end

      # A is now circuit-open...
      assert {:error, :circuit_open} = Knowledge.generate_embedding(a.id, "q")

      # ...but B is completely unaffected — its breaker is independent.
      assert {:ok, _vec} = Knowledge.generate_embedding(b.id, "q")
    end

    test "concurrent failures for one tenant reliably open the breaker (atomic window #2)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      # Fire many failures for the SAME tenant CONCURRENTLY. With a non-atomic
      # window reset (the pre-fix TOCTOU) a parallel reset-to-0 could wipe an
      # increment and delay the breaker; the period-keyed atomic counter must count
      # them all and open reliably.
      1..12
      |> Task.async_stream(fn _ -> Knowledge.generate_embedding(tenant.id, "q") end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Stream.run()

      # Even a single successful call now must be short-circuited — the breaker is open.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "q")
    end
  end

  # NOTE: the `generate_embedding/3 - provider_error telemetry (US-34.3 review fix
  # MED #1)` describe block was EXTRACTED to the sibling module
  # `test/loopctl/knowledge_semantic_search_provider_error_test.exs`, which runs
  # `async: false`. Those tests attach a handler on the VM-global
  # `[:loopctl, :llm, :provider_error]` telemetry event, whose metadata carries no
  # `tenant_id` (see `Loopctl.LLM.record_provider_error/2`), so the handler cannot
  # be tenant-scoped and a concurrent embedding emitter would leak into its mailbox
  # and trip `refute_received`. Keeping this file `async: true` requires them to
  # live in the non-async sibling.

  # --- Score normalization edge case ---

  describe "score normalization" do
    test "all equal scores normalize to 1.0" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      # Create multiple articles with identical embeddings
      for i <- 1..3 do
        create_article_with_embedding(
          tenant.id,
          %{
            title: "Identical Score Article #{i}",
            body: "Content about normalization testing #{i}."
          },
          :uniform
        )
      end

      query_embedding = make_embedding(:uniform)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, query_embedding}
      end)

      assert {:ok, %{results: results}} =
               Knowledge.search_combined(tenant.id, "normalization")

      # When results exist with equal scores, normalization should set all to 1.0
      # The final_score should be sum of both weights (0.5 * 1.0 + 0.5 * 1.0 = 1.0)
      # for items appearing in both result sets
      assert Enum.all?(results, fn r ->
               is_float(r.final_score) and r.final_score > 0
             end)
    end
  end

  # --- search_mode in meta ---

  describe "search_mode in response meta" do
    test "semantic search includes search_mode: semantic_only" do
      %{tenant: tenant} = setup_tenant()

      query_vector = make_embedding(:query)

      assert {:ok, %{meta: %{search_mode: "semantic_only"}}} =
               Knowledge.search_semantic(tenant.id, query_vector)
    end

    test "combined search includes search_mode: combined on success" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Search Mode Test",
        body: "Content for search mode verification.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:ok, %{meta: %{search_mode: "combined"}}} =
               Knowledge.search_combined(tenant.id, "search")
    end

    test "combined search includes search_mode: keyword_only on fallback" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Fallback Mode Test",
        body: "Content for fallback mode verification.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :unavailable}
      end)

      assert {:ok, %{meta: %{search_mode: "keyword_only", fallback: true}}} =
               Knowledge.search_combined(tenant.id, "fallback")
    end
  end

  describe "search_semantic/3 - relevance-pool meta + truncation signal (US-27.7a, TC-27.7a.2)" do
    test "small corpus: ranked results + full meta shape, pool_capped false" do
      %{tenant: tenant} = setup_tenant()

      a = create_article_with_embedding(tenant.id, %{title: "Aligned"}, :query)
      _b = create_article_with_embedding(tenant.id, %{title: "Medium"}, :medium)
      _c = create_article_with_embedding(tenant.id, %{title: "Far"}, :far)

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query))

      # Ranked by similarity desc — the :query-aligned article is most similar.
      assert length(results) == 3
      assert hd(results).id == a.id

      # Full meta contract preserved (TC-27.7a.2) + the additive truncation signal.
      assert meta.total_count == 3
      assert meta.limit == 10
      assert meta.offset == 0
      assert meta.search_mode == "semantic_only"
      assert meta.total_count_scope == "ranked_corpus"
      # 3 ranked rows, well under the relevance-pool cap → fully reachable, not capped.
      assert meta.pool_capped == false
    end

    test "corpus larger than the relevance-pool cap: pool_capped true + deep offset truncates" do
      %{tenant: tenant} = setup_tenant()

      # Every number below is DERIVED from the enforced cap, never hardcoded. A literal
      # here is what decoupled this test from `config/test.exs` last time: the cap moved
      # and nothing pointed at it, so the wide-page remedy elsewhere in the suite was
      # silently clamped for months. `semantic_result_pool/1` is
      # `min(max(offset + limit, floor), cap)`, so ANY page at least as wide as the cap
      # resolves to a pool of exactly `cap` — that is the relationship the two assertions
      # below need, and it holds for every floor <= cap without restating the formula.
      cap = Knowledge.semantic_result_pool_cap()
      wide = cap + 5

      # The derivation has ONE precondition, asserted BEFORE the seed loop so it fails in a
      # line instead of after seeding a thousand embedded articles: a page can never be
      # requested wider than `max_relevance_page_size`, so a cap above it can never be
      # reached and `length(results) == cap` becomes unsatisfiable. That is the state under
      # the SCALE gate (`SCALE_NIGHTLY`/`SCALE_TESTS`), where `config/test.exs` deliberately
      # keeps the PROD cap — these pool_capped tests only mean anything under the shrunk one.
      assert cap <= Knowledge.max_relevance_page_size(),
             "semantic_result_pool_cap (#{cap}) exceeds max_relevance_page_size " <>
               "(#{Knowledge.max_relevance_page_size()}); the shrunk test cap is required here"

      # Seed cap+2 near-identical embedded articles: the smallest corpus that exceeds the
      # reachable pool, so this stays linear in the cap and no more expensive than it must be.
      for i <- 1..(cap + 2),
          do: create_article_with_embedding(tenant.id, %{title: "Hub #{i}"}, :query)

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query), limit: wide)

      # total_count is the FULL ranked corpus (a SEPARATE count, NOT pool-bounded) ...
      assert meta.total_count == cap + 2
      # ... but the relevance pool only surfaces up to the cap, so the tail is unreachable
      # by a deeper offset — and the signal flags it (not silent).
      assert length(results) == cap
      assert meta.pool_capped == true

      # A page past the cap returns empty (documented relevance tradeoff); the signal
      # still flags it so the consumer knows to switch to list mode for full enumeration.
      {:ok, %{results: deep, meta: deep_meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query), limit: wide, offset: cap)

      assert deep == []
      assert deep_meta.total_count == cap + 2
      assert deep_meta.pool_capped == true

      # ...and the CAP arm of the signal specifically, isolated from the pool/filter
      # starvation arm. Both assertions above are ALSO satisfied by starvation (a short
      # page with more filtered results behind it), so neither one alone proves
      # `total_count > cap` is live: deleting that clause from `semantic_pool_capped?/5`
      # left the whole suite green. A page NARROWER than the cap comes back FULL
      # (`returned == limit`, so the starvation arm is false by construction) while the
      # corpus still exceeds the reachable pool — which is exactly the "true regardless of
      # offset, even on a full page" case the signal documents. This narrow page carries a
      # precondition the wide ones do not: `floor <= cap - 1`, or `semantic_result_pool/1`
      # floors it back up to the cap and returns `cap` rows.
      {:ok, %{results: full, meta: full_meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query), limit: cap - 1)

      assert length(full) == cap - 1
      assert full_meta.total_count == cap + 2
      assert full_meta.pool_capped == true
    end
  end

  describe "search_semantic/3 - relevance-pool R2 edges (filter starvation, status:nil)" do
    test "selective filter whose matches fall outside the pool: pool_capped true (not a false negative)" do
      %{tenant: tenant} = setup_tenant()

      # Fill the relevance pool with near-identical :reference articles, and put the ONLY
      # :pattern match far away (orthogonal → similarity 0, ranked last) so it sits OUTSIDE
      # the top-`pool` nearest. A category:pattern search then starves the page. The honest
      # signal must flag this — `total_count > cap` ALONE would miss it.
      #
      # Both numbers derive from the enforced cap (see the sibling test above, which also
      # carries the `cap <= max_relevance_page_size` precondition): a page at least as wide
      # as the cap pins the pool to exactly `cap`. Seed `cap + 3` filler rows, not exactly
      # `cap`: at zero margin one ANN recall miss among a clique of identical vectors frees
      # a pool slot, the orthogonal row lands in it, and this fails as `1 < 1`.
      cap = Knowledge.semantic_result_pool_cap()
      assert cap <= Knowledge.max_relevance_page_size()

      for i <- 1..(cap + 3),
          do:
            create_article_with_embedding(
              tenant.id,
              %{title: "Ref #{i}", category: :reference},
              :query
            )

      create_article_with_embedding(tenant.id, %{title: "Lone Pattern", category: :pattern}, :far)

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query),
          category: :pattern,
          limit: cap + 5
        )

      # total_count is the full filtered corpus (1 :pattern article)...
      assert meta.total_count == 1
      # ...but it fell outside the top-`cap` nearest, so the page is starved (< total_count)
      # and the signal flags incompleteness rather than lying "reachable".
      assert length(results) < meta.total_count
      assert meta.pool_capped == true
    end

    test "status: nil ('all statuses') ranks every status — results and count stay consistent" do
      %{tenant: tenant} = setup_tenant()

      _pub = create_article_with_embedding(tenant.id, %{title: "Pub", status: :published}, :query)
      _draft = create_article_with_embedding(tenant.id, %{title: "Draft", status: :draft}, :query)

      # status: nil must NOT force `status == NULL` on the inner (which would return empty
      # against a non-zero count) — it means "all statuses", matching the count path.
      {:ok, %{results: all_results, meta: all_meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query), status: nil)

      assert all_meta.total_count == 2
      assert length(all_results) == 2
      assert Enum.sort(Enum.map(all_results, & &1.status)) == [:draft, :published]

      # Default (published) still excludes the draft — proving the nil-skip is scoped.
      {:ok, %{results: pub_results}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query))

      assert length(pub_results) == 1
      assert hd(pub_results).status == :published
    end
  end

  describe "search_combined/3 - relevance-pool truncation propagation (US-27.7a)" do
    test "combined carries the semantic half's pool_capped (default mode is not silent)" do
      %{tenant: tenant} = setup_tenant()

      # cap+2 embedded articles → the semantic sub-search is pool-capped; combined must
      # surface that, not drop it (combined is the DEFAULT search mode). Derived from the
      # enforced cap, never hardcoded — see the truncation test above for why, and for the
      # `cap <= max_relevance_page_size` precondition this shares with it.
      cap = Knowledge.semantic_result_pool_cap()
      assert cap <= Knowledge.max_relevance_page_size()

      for i <- 1..(cap + 2),
          do: create_article_with_embedding(tenant.id, %{title: "Hub #{i}"}, :query)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      Knowledge.reset_circuit_breaker(tenant.id)

      {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "hub")

      assert meta.search_mode == "combined"
      assert meta.pool_capped == true
    end
  end

  # --- #470: Reciprocal Rank Fusion (RRF) scoring ------------------------------

  describe "search_combined/3 - RRF fusion (#470)" do
    test "a keyword-only candidate scores exactly keyword_weight / (k + rank)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      # No embedding → excluded from the semantic lane, so this is a PURE keyword-lane
      # rank-1 candidate. Unique token keeps it the only keyword match.
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Zzquux Reference",
        body: "The zzquux token appears only here.",
        status: :published
      })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: [result]}} =
        Knowledge.search_combined(tenant.id, "zzquux",
          keyword_weight: 0.5,
          semantic_weight: 0.5,
          # Isolate the PURE RRF score — the #471 recency/authority priors multiply
          # :final_score post-fusion and are tested separately.
          recency_weight: 0.0,
          authority_prior: false
        )

      # RRF: weight / (k + rank), default k = 60, rank 1 → 0.5 / 61.
      assert_in_delta result.final_score, 0.5 / 61, 1.0e-9
    end

    test "the smoothing constant k is configurable per call" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Zzquux Reference",
        body: "The zzquux token appears only here.",
        status: :published
      })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: [result]}} =
        Knowledge.search_combined(tenant.id, "zzquux",
          keyword_weight: 0.5,
          semantic_weight: 0.5,
          rrf_k: 10,
          # Isolate the PURE RRF score (see the sibling k-default test).
          recency_weight: 0.0,
          authority_prior: false
        )

      # weight / (k + rank) with k = 10, rank 1 → 0.5 / 11.
      assert_in_delta result.final_score, 0.5 / 11, 1.0e-9
    end

    test "a cross-lane consensus doc outranks a doc that is #1 in a single lane" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      # Appears in BOTH lanes (keyword match on "consensus" + close embedding), but is
      # unlikely to be strictly #1 in either.
      consensus =
        create_article_with_embedding(
          tenant.id,
          %{title: "Consensus Overview", body: "A consensus across retrieval lanes."},
          :close
        )

      # Strong keyword-only spike: matches "consensus" but far embedding.
      _kw_spike =
        create_article_with_embedding(
          tenant.id,
          %{title: "Consensus Consensus Consensus", body: "consensus consensus consensus"},
          :far
        )

      # Semantic-only: a MEDIUM (not :close) embedding, no keyword match on "consensus".
      # Deliberately less similar than `consensus` so `consensus` is unambiguously
      # semantic rank 1. With two identical :close vectors the semantic tie was broken
      # only by the now-deterministic id secondary sort, and in the branch where
      # `consensus` fell to semantic rank 2 the keyword spike edged it out by a ~4e-6
      # RRF margin — a real, seed-dependent flake. Widening the semantic gap makes the
      # cross-lane advantage unconditional (#470 review).
      _sem_spike =
        create_article_with_embedding(
          tenant.id,
          %{title: "Fault Tolerance", body: "Supervisor trees prevent cascading failures."},
          :medium
        )

      # Pin the query vector to THIS process's axis (the semantic lane's embedding is
      # generated in a spawned worker without this process's :test_vec_axis).
      query_embedding = make_embedding(:query)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, query_embedding}
      end)

      {:ok, %{results: results}} =
        Knowledge.search_combined(tenant.id, "consensus",
          keyword_weight: 0.5,
          semantic_weight: 0.5
        )

      # The consensus doc, present in both lanes, wins the top slot over either
      # single-lane spike — the smoothing constant makes agreement beat one strong vote.
      assert hd(results).id == consensus.id
    end

    test "the min-max path is available behind the :min_max A/B flag" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      create_article_with_embedding(
        tenant.id,
        %{title: "Alpha Guide", body: "alpha content for fusion ab test"},
        :close
      )

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_combined(tenant.id, "alpha",
          fusion_strategy: :min_max,
          # The <= 1.0 property is a min-max normalization invariant; the #471 priors would
          # scale it past 1.0, so isolate the pure fusion score here (priors tested apart).
          recency_weight: 0.0,
          authority_prior: false
        )

      # Same public shape; min-max produces normalized 0..1 weighted-sum scores (a lone
      # both-lane hit normalizes to 1.0 per lane → 0.5 + 0.5 = 1.0), unlike RRF's
      # ~1/(k+rank) magnitudes.
      assert meta.search_mode == "combined"
      assert Enum.all?(results, &Map.has_key?(&1, :final_score))
      assert Enum.all?(results, &(&1.final_score <= 1.0))
    end

    test "meta shape is preserved (MCP contract)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      create_article_with_embedding(
        tenant.id,
        %{title: "Shape Guide", body: "shape preservation content"},
        :close
      )

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "shape")

      assert meta.search_mode == "combined"
      assert meta.total_count_scope == "merged_candidates"
      assert is_integer(meta.total_count)
      assert meta.limit == 10
      assert meta.offset == 0
      assert meta.pool_capped == false
      assert is_integer(meta.semantic_result_count)
    end
  end

  # --- #470: optional graph-neighbor lane -------------------------------------

  describe "search_combined/3 - graph-neighbor lane (#470)" do
    # A seed that matches the query so it enters the merged pool, plus a linked
    # neighbor that matches NEITHER lane (no keyword hit, no embedding) so it can only
    # surface through the graph lane.
    defp seed_and_neighbor(tenant_id) do
      seed =
        fixture(:article, %{
          tenant_id: tenant_id,
          title: "Graphlane Seed",
          body: "The graphlane token appears here.",
          status: :published
        })

      neighbor =
        fixture(:article, %{
          tenant_id: tenant_id,
          title: "Orphan Neighbor",
          body: "Completely unrelated wording with no shared token.",
          status: :published
        })

      fixture(:article_link, %{
        tenant_id: tenant_id,
        source_article_id: seed.id,
        target_article_id: neighbor.id,
        relationship_type: :relates_to
      })

      %{seed: seed, neighbor: neighbor}
    end

    test "a reranker reaches the combined-search page, and cannot break it" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      %{seed: seed, neighbor: neighbor} = seed_and_neighbor(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: fused}} = Knowledge.search_combined(tenant.id, "graphlane")
      assert length(fused) > 1
      assert seed.id in Enum.map(fused, & &1.id)
      assert neighbor.id in Enum.map(fused, & &1.id)

      # The seam is wired into the real search path, not just unit-tested in isolation.
      {:ok, %{results: reranked}} =
        Knowledge.search_combined(tenant.id, "graphlane",
          rerank: true,
          reranker: __MODULE__.ReversingReranker
        )

      assert Enum.map(reranked, & &1.id) == fused |> Enum.map(& &1.id) |> Enum.reverse()

      # And a reranker that blows up degrades the ORDER, never the search — the whole
      # reason `search_combined/3` has no error branch for it.
      {:ok, %{results: survived}} =
        Knowledge.search_combined(tenant.id, "graphlane",
          rerank: true,
          reranker: __MODULE__.RaisingReranker
        )

      assert Enum.map(survived, & &1.id) == Enum.map(fused, & &1.id)
    end

    test "is ON by default, and `graph_lane: false` still turns it off" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      %{neighbor: neighbor} = seed_and_neighbor(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      # The lane shipped OFF and was flipped ON once golden_v4 gave the eval edges to
      # traverse and the weight sweep settled at 0.15 (see the Phase 5 section of
      # docs/research/kb-retrieval-improvement-plan.md). A link-only-reachable neighbor is
      # now retrieved by an unadorned call — which is the whole point, since agents are only
      # ever told about plain search.
      {:ok, %{results: on}} = Knowledge.search_combined(tenant.id, "graphlane")
      assert Enum.any?(on, &(&1.id == neighbor.id))

      # The per-call escape hatch is what a lane-off eval arm and an operator rollback both
      # depend on, so it is asserted here rather than assumed from the config default.
      {:ok, %{results: off}} =
        Knowledge.search_combined(tenant.id, "graphlane", graph_lane: false)

      refute Enum.any?(off, &(&1.id == neighbor.id))
    end

    test "when ON, one-hop neighbors join the fusion" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      %{seed: seed, neighbor: neighbor} = seed_and_neighbor(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_combined(tenant.id, "graphlane", graph_lane: true)

      ids = Enum.map(results, & &1.id)
      assert seed.id in ids
      assert neighbor.id in ids

      neighbor_result = Enum.find(results, &(&1.id == neighbor.id))

      # A graph-only hit carries neither raw score → its hybrid-resolver absolute_score
      # is 0.0, and it must NOT inflate the semantic lane's row count.
      refute Map.has_key?(neighbor_result, :relevance_score)
      refute Map.has_key?(neighbor_result, :similarity_score)
      assert Map.has_key?(neighbor_result, :final_score)
      # The seed matched keyword only; nothing was embedded for the query direction, so
      # the semantic lane contributed zero rows — the graph neighbor did not change that.
      assert meta.semantic_result_count == 0
    end

    test "graph lane is tenant-scoped — tenant B neighbors never surface for tenant A" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_a.id)

      %{neighbor: neighbor_a} = seed_and_neighbor(tenant_a.id)
      %{neighbor: neighbor_b} = seed_and_neighbor(tenant_b.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results}} =
        Knowledge.search_combined(tenant_a.id, "graphlane", graph_lane: true)

      ids = Enum.map(results, & &1.id)
      assert neighbor_a.id in ids
      refute neighbor_b.id in ids
    end

    test "a zero-signal graph neighbor never outranks a genuine single-lane top hit — score AND position" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      %{seed: seed, neighbor: neighbor} = seed_and_neighbor(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results}} =
        Knowledge.search_combined(tenant.id, "graphlane",
          graph_lane: true,
          # Assert the PURE graph-lane RRF magnitude; #471 priors (tested apart) would
          # scale :final_score by the docs' authority factor.
          recency_weight: 0.0,
          authority_prior: false
        )

      seed_result = Enum.find(results, &(&1.id == seed.id))
      neighbor_result = Enum.find(results, &(&1.id == neighbor.id))

      # The seed is keyword rank 1 (0.5/(k+1)); the graph-only neighbor is graph rank 1, so
      # it scores `graph_weight/(k+1)`. The INVARIANT under test is that the graph weight is
      # STRICTLY BELOW the 0.5 primary per-lane weight, so a zero-signal neighbor can neither
      # tie NOR (via the deterministic {final_score, id} desc tiebreak, which a larger
      # neighbor id would otherwise win) float ABOVE the genuine top hit in POSITION. At a
      # 0.5 tie-weight a larger-id neighbor could sort above the seed (#470 review).
      #
      # Read from config rather than hardcoded: the weight is a TUNING value the retrieval
      # eval's sweep is expected to move (0.25 -> 0.15 in the Phase 5 experiment), while the
      # ceiling below is the invariant that must not move. Pinning the tuning value here made
      # this test fail for a reason it does not test.
      graph_weight = Application.get_env(:loopctl, :knowledge_rrf_graph_weight)

      assert graph_weight < 0.5,
             "the graph lane must stay strictly below the primary per-lane weight, or a " <>
               "zero-signal neighbor can tie and then win the id tiebreak"

      assert_in_delta neighbor_result.final_score, graph_weight / 61, 1.0e-9
      assert neighbor_result.final_score < seed_result.final_score

      seed_pos = Enum.find_index(results, &(&1.id == seed.id))
      neighbor_pos = Enum.find_index(results, &(&1.id == neighbor.id))

      assert seed_pos < neighbor_pos,
             "a zero-signal graph neighbor must never sort above a genuine single-lane top hit"
    end

    test "a neighbor linked from TWO seeds outranks one linked from a single seed" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      # Two seeds that both match the keyword query.
      seed1 =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Multiseed One",
          body: "The multiseed token appears here first.",
          status: :published
        })

      seed2 =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Multiseed Two",
          body: "The multiseed token appears here again.",
          status: :published
        })

      # Shared neighbor: linked from BOTH seeds (cross-seed consensus = 2).
      shared =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Shared Neighbor",
          body: "Unrelated wording, no shared query token.",
          status: :published
        })

      # Lonely neighbor: linked from ONE seed only (consensus = 1).
      lonely =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Lonely Neighbor",
          body: "Also unrelated wording, no shared query token.",
          status: :published
        })

      for {src, tgt} <- [{seed1, shared}, {seed2, shared}, {seed1, lonely}] do
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: src.id,
          target_article_id: tgt.id,
          relationship_type: :relates_to
        })
      end

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results}} =
        Knowledge.search_combined(tenant.id, "multiseed", graph_lane: true)

      shared_result = Enum.find(results, &(&1.id == shared.id))
      lonely_result = Enum.find(results, &(&1.id == lonely.id))

      # Both surface via the graph lane, but the two-seed consensus neighbor ranks
      # ahead of the one-seed neighbor (graph rank 1 vs 2) — the core `tally` signal
      # that was previously untested (#470 review).
      assert shared_result
      assert lonely_result
      assert shared_result.final_score > lonely_result.final_score

      shared_pos = Enum.find_index(results, &(&1.id == shared.id))
      lonely_pos = Enum.find_index(results, &(&1.id == lonely.id))
      assert shared_pos < lonely_pos
    end

    test "total_count_scope is labelled 'merged_candidates_with_graph' when the lane contributes" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      seed_and_neighbor(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{meta: meta}} =
        Knowledge.search_combined(tenant.id, "graphlane", graph_lane: true)

      # When one-hop neighbors are folded into total_count, the scope label changes so a
      # client isn't misled that the documented `merged_candidates` (keyword ∪ semantic)
      # invariant still describes the count (#470 review).
      assert meta.total_count_scope == "merged_candidates_with_graph"
    end

    test "consensus counts DISTINCT seeds, not link rows — one seed via many links != multi-seed" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      seed1 =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Distinctseed One",
          body: "The distinctseed token appears here first.",
          status: :published
        })

      seed2 =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Distinctseed Two",
          body: "The distinctseed token appears here again.",
          status: :published
        })

      # single_seed_multi_link: linked from ONE seed (seed1) via TWO distinct link ROWS
      # (different relationship_types). Row-counting would score its consensus as 2.
      single_seed_multi_link =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Single Seed Multi Link",
          body: "Unrelated wording, no shared query token.",
          status: :published
        })

      # two_distinct_seeds: linked from seed1 AND seed2 via one row each — genuine
      # cross-seed consensus of 2.
      two_distinct_seeds =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Two Distinct Seeds",
          body: "Also unrelated wording, no shared query token.",
          status: :published
        })

      for {src, tgt, rel} <- [
            {seed1, single_seed_multi_link, :relates_to},
            {seed1, single_seed_multi_link, :derived_from},
            {seed1, two_distinct_seeds, :relates_to},
            {seed2, two_distinct_seeds, :relates_to}
          ] do
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: src.id,
          target_article_id: tgt.id,
          relationship_type: rel
        })
      end

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results}} =
        Knowledge.search_combined(tenant.id, "distinctseed", graph_lane: true)

      multi_link = Enum.find(results, &(&1.id == single_seed_multi_link.id))
      distinct = Enum.find(results, &(&1.id == two_distinct_seeds.id))

      assert multi_link
      assert distinct

      # Two link rows from ONE seed must NOT tie a genuine two-DISTINCT-seed neighbor. The
      # distinct-seed neighbor (consensus 2 → graph rank 1) strictly outranks the
      # multi-link single-seed neighbor (consensus 1 → graph rank 2). Row-counting (the bug)
      # gave both consensus 2 and let the single-seed neighbor tie/outrank (#470 review).
      assert distinct.final_score > multi_link.final_score

      distinct_pos = Enum.find_index(results, &(&1.id == two_distinct_seeds.id))
      multi_link_pos = Enum.find_index(results, &(&1.id == single_seed_multi_link.id))
      assert distinct_pos < multi_link_pos
    end

    test "graph lane honors the caller status opt (not hardcoded :published)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      # A DRAFT seed that matches the keyword lane under a :draft-status search, plus a DRAFT
      # neighbor reachable only via the graph lane. Under the old hardcoded `status ==
      # :published` the draft neighbor was silently dropped even though the primary lanes
      # returned draft rows — an inconsistent lane (#470 review).
      seed =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Draftlane Seed",
          body: "The draftlane token appears here.",
          status: :draft
        })

      neighbor =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Draft Neighbor",
          body: "Unrelated wording, no shared query token.",
          status: :draft
        })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: seed.id,
        target_article_id: neighbor.id,
        relationship_type: :relates_to
      })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results}} =
        Knowledge.search_combined(tenant.id, "draftlane", graph_lane: true, status: :draft)

      ids = Enum.map(results, & &1.id)
      assert seed.id in ids

      assert neighbor.id in ids,
             "a draft graph neighbor must surface under a :draft-status search"
    end

    test "graph lane never leaks another agent's private memory to an agent caller (#163)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      seed =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Visibilitylane Seed",
          body: "The visibilitylane token appears here.",
          status: :published,
          metadata: %{"visibility" => "shared"}
        })

      # A neighbor that is ANOTHER agent's PRIVATE memory — a one-hop link from a shared
      # seed must not surface it (or leak its id/title) to a different agent caller.
      private_neighbor =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Other Agent Private Memory",
          body: "Unrelated wording, no shared query token.",
          status: :published,
          metadata: %{"visibility" => "private", "agent_id" => "agent-owner"}
        })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: seed.id,
        target_article_id: private_neighbor.id,
        relationship_type: :relates_to
      })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      # A DIFFERENT agent must NOT see the private neighbor.
      {:ok, %{results: stranger_results}} =
        Knowledge.search_combined(tenant.id, "visibilitylane",
          graph_lane: true,
          visibility_agent_id: "agent-stranger"
        )

      refute Enum.any?(stranger_results, &(&1.id == private_neighbor.id)),
             "the graph lane must not leak another agent's private memory"

      # The OWNER agent still reaches its own private memory via the same lane.
      {:ok, %{results: owner_results}} =
        Knowledge.search_combined(tenant.id, "visibilitylane",
          graph_lane: true,
          visibility_agent_id: "agent-owner"
        )

      assert Enum.any?(owner_results, &(&1.id == private_neighbor.id))
    end

    test "graph_lane: true + fusion_strategy: :min_max injects no neighbors (lane skipped, no wasted read)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      %{neighbor: neighbor} = seed_and_neighbor(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, make_embedding(:query)}
      end)

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_combined(tenant.id, "graphlane",
          graph_lane: true,
          fusion_strategy: :min_max
        )

      # min_max fusion ignores graph results entirely, so the lane is not built at all
      # (no wasted DB read) and no neighbor leaks into the min_max output. The scope
      # label stays the plain merged label since nothing was folded in (#470 review).
      refute Enum.any?(results, &(&1.id == neighbor.id))
      assert meta.total_count_scope == "merged_candidates"
    end
  end

  # --- #470: get_context relevance must read the ABSOLUTE score, not RRF final_score -----

  describe "get_context/3 relevance uses the absolute per-row score (#470)" do
    test "relevance_score is on the 0..1 absolute scale, not the ~0.008 RRF final_score" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      create_article_with_embedding(
        tenant.id,
        %{title: "Absolute Relevance", body: "content about absolute relevance scoring"},
        :close
      )

      # Bind the query vector in THIS process: the embedding stub is invoked from a
      # spawned worker (Mox $callers allowance, but NOT this process's :test_vec_axis),
      # so `make_embedding(:query)` computed lazily there would use axis 0 and miss the
      # article's per-test window. Capturing it here pins it to the same axis.
      query_embedding = make_embedding(:query)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, query_embedding}
      end)

      {:ok, %{results: [first | _]}} = Knowledge.get_context(tenant.id, "absolute relevance")

      # The article is a strong semantic match (query == :close), so its ABSOLUTE relevance
      # (cosine similarity_score) is ~1.0. Post-#470 the fused RRF final_score for a rank-1
      # hit is only ~0.5/61 ≈ 0.008; if get_context read THAT, relevance would collapse ~60x.
      assert first.relevance_score > 0.5
    end

    test "a highly-relevant OLD article outranks an irrelevant FRESH one (recency can't dominate)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      # Strong semantic match, but stale (90 days old → recency ≈ exp(-3) ≈ 0.05).
      relevant_old =
        create_article_with_embedding(
          tenant.id,
          %{title: "Relevant Old", body: "content about ranking relevance and recency"},
          :close
        )

      # Poor semantic match (orthogonal embedding → similarity ≈ 0), but brand new (recency 1.0).
      _fresh_irrelevant =
        create_article_with_embedding(
          tenant.id,
          %{title: "Fresh Irrelevant", body: "content about ranking relevance and recency"},
          :far
        )

      import Ecto.Query

      ninety_days_ago = DateTime.add(DateTime.utc_now(), -90 * 86_400, :second)

      Loopctl.AdminRepo.update_all(
        from(a in Knowledge.Article, where: a.id == ^relevant_old.id),
        set: [updated_at: ninety_days_ago]
      )

      # See the note above: pin the query vector to THIS process's axis so the
      # spawned embedding worker returns a vector in the articles' window.
      query_embedding = make_embedding(:query)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, query_embedding}
      end)

      {:ok, %{results: results}} =
        Knowledge.get_context(tenant.id, "ranking relevance recency", recency_weight: 0.3)

      # With the fix (0.7*abs_relevance + 0.3*recency): relevant_old ≈ 0.7*1.0 + 0.3*0.05 =
      # 0.715 beats fresh_irrelevant ≈ 0.7*0.0 + 0.3*1.0 = 0.3. With the bug (relevance =
      # ~0.008 RRF final_score) the fresh article's recency (0.3) swamped relevance and won.
      relevant_pos = Enum.find_index(results, &(&1.id == relevant_old.id))

      assert relevant_pos == 0,
             "a highly-relevant old article must outrank an irrelevant fresh one"
    end
  end
end
