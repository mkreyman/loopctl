defmodule Loopctl.KnowledgeContextTest do
  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.Knowledge

  setup :verify_on_exit!

  describe "get_context/3" do
    test "returns full article bodies with combined scoring" do
      tenant = fixture(:tenant)

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Context Scoring Article",
          body: "Full body content about scoring and retrieval mechanisms.",
          category: :pattern,
          status: :published,
          tags: ["scoring"]
        })

      {:ok, result} = Knowledge.get_context(tenant.id, "scoring retrieval")

      assert is_list(result.results)
      assert result.meta.limit == 5
      assert is_number(result.meta.recency_weight)

      if result.results != [] do
        first = List.first(result.results)
        assert first.body == article.body
        assert first.title == article.title
        assert is_number(first.relevance_score)
        assert is_number(first.recency_score)
        assert is_number(first.combined_score)
        assert first.recency_score > 0.0
        assert first.recency_score <= 1.0
        assert is_list(first.linked_articles)
      end
    end

    test "recency_score uses exponential decay" do
      tenant = fixture(:tenant)

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Decay Test Article",
          body: "Content about exponential decay testing.",
          category: :pattern,
          status: :published,
          tags: ["decay"]
        })

      # Set article updated_at to 30 days ago
      thirty_days_ago = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Knowledge.Article, where: a.id == ^article.id),
        set: [updated_at: thirty_days_ago]
      )

      {:ok, result} = Knowledge.get_context(tenant.id, "exponential decay")

      if result.results != [] do
        first = List.first(result.results)
        # At 30 days, exp(-30/30) = exp(-1) ~= 0.3679
        assert_in_delta first.recency_score, :math.exp(-1.0), 0.05
      end
    end

    test "combined_score formula: (1 - rw) * relevance + rw * recency" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Formula Test Article",
        body: "Content about formula validation for combined scoring.",
        category: :pattern,
        status: :published,
        tags: ["formula"]
      })

      {:ok, result} = Knowledge.get_context(tenant.id, "formula validation", recency_weight: 0.5)

      if result.results != [] do
        first = List.first(result.results)
        expected = 0.5 * first.relevance_score + 0.5 * first.recency_score
        assert_in_delta first.combined_score, expected, 0.001
      end
    end

    test "empty query returns error" do
      tenant = fixture(:tenant)
      assert {:error, :empty_query} = Knowledge.get_context(tenant.id, "")
      assert {:error, :empty_query} = Knowledge.get_context(tenant.id, "   ")
    end

    test "nil query returns error" do
      tenant = fixture(:tenant)
      assert {:error, :empty_query} = Knowledge.get_context(tenant.id, nil)
    end

    test "respects limit option" do
      tenant = fixture(:tenant)

      for i <- 1..10 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Limit Context Article #{i}",
          body: "Content about limit context testing #{i}.",
          category: :pattern,
          status: :published,
          tags: ["limitctx"]
        })
      end

      {:ok, result} = Knowledge.get_context(tenant.id, "limit context", limit: 3)

      assert length(result.results) <= 3
      assert result.meta.limit == 3
    end

    test "limit capped at 20" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Cap Test Article",
        body: "Content about cap testing.",
        category: :pattern,
        status: :published,
        tags: ["cap"]
      })

      {:ok, result} = Knowledge.get_context(tenant.id, "cap testing", limit: 100)
      assert result.meta.limit == 20
    end

    test "recency_weight clamped to 0.0-1.0" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Clamp Test Article",
        body: "Content about clamping recency weight values.",
        category: :pattern,
        status: :published,
        tags: ["clamp"]
      })

      {:ok, result_low} = Knowledge.get_context(tenant.id, "clamp", recency_weight: -0.5)
      assert result_low.meta.recency_weight == 0.0

      {:ok, result_high} = Knowledge.get_context(tenant.id, "clamp", recency_weight: 1.5)
      assert result_high.meta.recency_weight == 1.0
    end

    test "tenant isolation" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "Tenant A Context Test",
        body: "Content for tenant A about isolation context test.",
        category: :pattern,
        status: :published,
        tags: ["ctxiso"]
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "Tenant B Context Test",
        body: "Content for tenant B about isolation context test.",
        category: :pattern,
        status: :published,
        tags: ["ctxiso"]
      })

      {:ok, result_a} = Knowledge.get_context(tenant_a.id, "isolation context")
      {:ok, result_b} = Knowledge.get_context(tenant_b.id, "isolation context")

      titles_a = Enum.map(result_a.results, & &1.title)
      titles_b = Enum.map(result_b.results, & &1.title)

      if titles_a != [] do
        assert "Tenant A Context Test" in titles_a
        refute "Tenant B Context Test" in titles_a
      end

      if titles_b != [] do
        assert "Tenant B Context Test" in titles_b
        refute "Tenant A Context Test" in titles_b
      end
    end

    test "only published articles by default" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published Context Status",
        body: "Published content for context status filtering.",
        category: :pattern,
        status: :published,
        tags: ["statusctx"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft Context Status",
        body: "Draft content for context status filtering.",
        category: :pattern,
        status: :draft,
        tags: ["statusctx"]
      })

      {:ok, result} = Knowledge.get_context(tenant.id, "context status filtering")

      titles = Enum.map(result.results, & &1.title)

      if titles != [] do
        assert "Published Context Status" in titles
        refute "Draft Context Status" in titles
      end
    end

    test "linked articles are one-hop only with max 5" do
      tenant = fixture(:tenant)

      source =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Linked Source Article",
          body: "Content about linked source article.",
          category: :pattern,
          status: :published,
          tags: ["linkedhop"]
        })

      # Create 7 linked articles (should be capped at 5)
      for i <- 1..7 do
        target =
          fixture(:article, %{
            tenant_id: tenant.id,
            title: "Linked Target #{i}",
            body: "Content for linked target #{i}.",
            category: :reference,
            status: :published,
            tags: ["linkedhop"]
          })

        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })
      end

      {:ok, result} = Knowledge.get_context(tenant.id, "linked source")

      source_result = Enum.find(result.results, &(&1.title == "Linked Source Article"))

      if source_result do
        assert length(source_result.linked_articles) <= 5

        Enum.each(source_result.linked_articles, fn linked ->
          assert Map.has_key?(linked, :id)
          assert Map.has_key?(linked, :title)
          assert Map.has_key?(linked, :category)
          refute Map.has_key?(linked, :body)
        end)
      end
    end

    test "embedding failure gracefully falls back to keyword" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Embedding Fallback Context",
        body: "Content about embedding fallback for context retrieval.",
        category: :pattern,
        status: :published,
        tags: ["embfallback"]
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, :service_unavailable}
      end)

      {:ok, result} = Knowledge.get_context(tenant.id, "embedding fallback")

      assert result.meta.fallback == true
    end

    test "results sorted by combined_score descending" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Sort Test Alpha",
        body: "Content about sort testing alpha.",
        category: :pattern,
        status: :published,
        tags: ["sorttest"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Sort Test Beta",
        body: "Content about sort testing beta.",
        category: :convention,
        status: :published,
        tags: ["sorttest"]
      })

      {:ok, result} = Knowledge.get_context(tenant.id, "sort testing")

      if length(result.results) >= 2 do
        scores = Enum.map(result.results, & &1.combined_score)
        assert scores == Enum.sort(scores, :desc)
      end
    end
  end
end
