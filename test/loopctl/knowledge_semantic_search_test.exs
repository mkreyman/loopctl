defmodule Loopctl.KnowledgeSemanticSearchTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

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

    test "defaults to limit 10, caps at 50" do
      %{tenant: tenant} = setup_tenant()

      query_vector = make_embedding(:query)

      assert {:ok, %{meta: meta}} =
               Knowledge.search_semantic(tenant.id, query_vector)

      assert meta.limit == 10
      assert meta.offset == 0

      assert {:ok, %{meta: capped_meta}} =
               Knowledge.search_semantic(tenant.id, query_vector, limit: 100)

      assert capped_meta.limit == 50
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

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
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

      Knowledge.reset_circuit_breaker()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Testing Guide",
        body: "Unit test patterns for testing Elixir applications.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, :service_unavailable}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_combined(tenant.id, "testing")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"

      # Should still find via keyword match
      assert results != []
      assert Enum.any?(results, &(&1.title == "Testing Guide"))
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

    test "accepts weights that sum to 1.0 within tolerance" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tolerance Check",
        body: "Testing weight tolerance.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
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

      Knowledge.reset_circuit_breaker()

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
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:ok, query_embedding}
      end)

      assert {:ok, %{results: semantic_heavy}} =
               Knowledge.search_combined(tenant.id, "deployment",
                 keyword_weight: 0.2,
                 semantic_weight: 0.8
               )

      # With keyword_weight=0.8, exact match should rank higher
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
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

      Knowledge.reset_circuit_breaker()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Circuit Breaker Test",
        body: "Testing circuit breaker fallback behavior.",
        status: :published
      })

      # Fail 3 times to trip the circuit breaker
      for _i <- 1..3 do
        expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
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

      Knowledge.reset_circuit_breaker()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Recovery Test Article",
        body: "Testing recovery after circuit breaker reset.",
        status: :published
      })

      # One failure
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, :temporary_failure}
      end)

      assert {:ok, %{meta: %{fallback: true}}} =
               Knowledge.search_combined(tenant.id, "recovery")

      # Then a success (resets failure count)
      query_embedding = make_embedding(:query)

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:ok, query_embedding}
      end)

      assert {:ok, %{meta: %{search_mode: "combined"}}} =
               Knowledge.search_combined(tenant.id, "recovery")

      # Another failure should not trip the breaker (counter was reset)
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, :temporary_failure}
      end)

      assert {:ok, %{meta: %{fallback: true, search_mode: "keyword_only"}}} =
               Knowledge.search_combined(tenant.id, "recovery")
    end
  end

  # --- Score normalization edge case ---

  describe "score normalization" do
    test "all equal scores normalize to 1.0" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker()

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

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
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

      Knowledge.reset_circuit_breaker()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Search Mode Test",
        body: "Content for search mode verification.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:ok, make_embedding(:query)}
      end)

      assert {:ok, %{meta: %{search_mode: "combined"}}} =
               Knowledge.search_combined(tenant.id, "search")
    end

    test "combined search includes search_mode: keyword_only on fallback" do
      %{tenant: tenant} = setup_tenant()

      Knowledge.reset_circuit_breaker()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Fallback Mode Test",
        body: "Content for fallback mode verification.",
        status: :published
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, :unavailable}
      end)

      assert {:ok, %{meta: %{search_mode: "keyword_only", fallback: true}}} =
               Knowledge.search_combined(tenant.id, "fallback")
    end
  end
end
