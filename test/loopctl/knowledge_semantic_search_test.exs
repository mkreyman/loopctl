defmodule Loopctl.KnowledgeSemanticSearchTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.EmbeddingConcurrency

  # Embedding dimensions configured as 1536.
  # We use small deterministic vectors for predictable cosine distances.
  # Vectors pointing in the same direction have cosine distance 0 (similarity 1).
  # Orthogonal vectors have cosine distance 1 (similarity 0).

  # A helper that creates a 1536-dim vector with a known pattern.
  # `direction` controls which "axis group" the vector points toward.
  defp make_embedding(:close) do
    # Close to query: mostly 1s in the first half, 0s elsewhere
    List.duplicate(1.0, 768) ++ List.duplicate(0.0, 768)
  end

  defp make_embedding(:far) do
    # Far from query: mostly 0s in the first half, 1s elsewhere
    List.duplicate(0.0, 768) ++ List.duplicate(1.0, 768)
  end

  defp make_embedding(:query) do
    # Query vector: same direction as :close
    List.duplicate(1.0, 768) ++ List.duplicate(0.0, 768)
  end

  defp make_embedding(:medium) do
    # In between — equal parts of both
    List.duplicate(0.5, 768) ++ List.duplicate(0.5, 768)
  end

  defp make_embedding(:uniform) do
    List.duplicate(0.1, 1536)
  end

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
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn tenant_id, _text ->
        if tenant_id == a.id do
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

  # US-34.3 review fix (MED #1): `run_embedding_task/3` is the single choke point
  # for the `[:loopctl, :llm, :provider_error]` signal's embedding half — it must
  # fire for EVERY embedding call site (not just the two Oban workers), including
  # `Knowledge.generate_embedding/3` called directly, which is what every
  # query-time caller (combined/semantic search, novelty scoring, `Memory.recall/2`,
  # promotion) ultimately does. Prior to the fix, none of these calls emitted the
  # signal at all — only the workers did.
  describe "generate_embedding/3 - provider_error telemetry (US-34.3 review fix MED #1)" do
    defp attach_provider_error_listener(test_pid) do
      handler_id = {:generate_embedding_provider_error_test, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:loopctl, :llm, :provider_error],
        fn
          # Forward ONLY embedding-provider events. `[:loopctl, :llm, :provider_error]`
          # is a VM-GLOBAL telemetry event, so under `async: true` a concurrent
          # Anthropic-path test emitting it with provider="anthropic" would otherwise
          # leak into this test's mailbox — failing the `assert_received`/
          # `refute_received` assertions below non-deterministically.
          _event, measurements, %{provider: "embedding"} = metadata, _config ->
            send(test_pid, {:provider_error_emitted, measurements, metadata})

          _event, _measurements, _metadata, _config ->
            :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "a genuine 5xx failure emits provider=embedding class=:transient" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_provider_error_listener(self())

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      assert {:error, {:api_error, 500, _}} = Knowledge.generate_embedding(tenant.id, "q")

      assert_received {:provider_error_emitted, %{count: 1}, metadata}
      assert metadata == %{provider: "embedding", class: :transient}
    end

    test "a per-tenant 4xx (credential/quota) NEVER emits provider_error (gated by breaker_countable?/1, mirrors the circuit breaker exemption)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_provider_error_listener(self())

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, :provider_error}}
      end)

      assert {:error, {:api_error, 401, _}} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {:provider_error_emitted, _measurements, _metadata}
    end

    test "a keyless tenant's :no_api_key never emits provider_error (a config gap, not a provider incident)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_provider_error_listener(self())

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      assert {:error, :no_api_key} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {:provider_error_emitted, _measurements, _metadata}
    end

    test "the circuit breaker's own :circuit_open short-circuit never emits provider_error (a derived, already-counted consequence)" do
      %{tenant: tenant} = setup_tenant()
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 500, :provider_error}}
      end)

      # Trip the breaker first (3 failures).
      for _i <- 1..3 do
        Knowledge.generate_embedding(tenant.id, "q")
      end

      attach_provider_error_listener(self())
      assert {:error, :circuit_open} = Knowledge.generate_embedding(tenant.id, "q")

      refute_received {:provider_error_emitted, _measurements, _metadata}
    end
  end

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
      # 3 ranked rows <= the (test) relevance-pool cap of 5 → fully reachable, not capped.
      assert meta.pool_capped == false
    end

    test "corpus larger than the relevance-pool cap: pool_capped true + deep offset truncates" do
      %{tenant: tenant} = setup_tenant()

      # Seed cap+2 near-identical embedded articles (test cap = 5, see config/test.exs).
      for i <- 1..7, do: create_article_with_embedding(tenant.id, %{title: "Hub #{i}"}, :query)

      {:ok, %{results: results, meta: meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query), limit: 10)

      # total_count is the FULL ranked corpus (a SEPARATE count, NOT pool-bounded) ...
      assert meta.total_count == 7
      # ... but the relevance pool only surfaces up to the cap, so the tail is unreachable
      # by a deeper offset — and the signal flags it (not silent).
      assert length(results) == 5
      assert meta.pool_capped == true

      # A page past the cap returns empty (documented relevance tradeoff); the signal
      # still flags it so the consumer knows to switch to list mode for full enumeration.
      {:ok, %{results: deep, meta: deep_meta}} =
        Knowledge.search_semantic(tenant.id, make_embedding(:query), limit: 10, offset: 5)

      assert deep == []
      assert deep_meta.total_count == 7
      assert deep_meta.pool_capped == true
    end
  end

  describe "search_semantic/3 - relevance-pool R2 edges (filter starvation, status:nil)" do
    test "selective filter whose matches fall outside the pool: pool_capped true (not a false negative)" do
      %{tenant: tenant} = setup_tenant()

      # Fill the (test) relevance pool (cap 5) with near-identical :reference articles, and
      # put the ONLY :pattern match far away (orthogonal → similarity 0, ranked last), so it
      # sits OUTSIDE the top-5 nearest. A category:pattern search then starves the pool below
      # the cap. The honest signal must flag this — `total_count > cap` ALONE would miss it.
      for i <- 1..5,
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
          limit: 10
        )

      # total_count is the full filtered corpus (1 :pattern article)...
      assert meta.total_count == 1
      # ...but it fell outside the top-5 nearest, so the page is starved (< total_count)
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
      # surface that, not drop it (combined is the DEFAULT search mode).
      for i <- 1..7, do: create_article_with_embedding(tenant.id, %{title: "Hub #{i}"}, :query)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, make_embedding(:query)}
      end)

      Knowledge.reset_circuit_breaker(tenant.id)

      {:ok, %{meta: meta}} = Knowledge.search_combined(tenant.id, "hub")

      assert meta.search_mode == "combined"
      assert meta.pool_capped == true
    end
  end
end
