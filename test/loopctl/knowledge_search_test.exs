defmodule Loopctl.KnowledgeSearchTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  defp setup_tenant_with_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project}
  end

  defp create_published_article(tenant_id, attrs) do
    fixture(
      :article,
      Map.merge(
        %{tenant_id: tenant_id, status: :published},
        Enum.into(attrs, %{})
      )
    )
  end

  # --- TC-20.1.1: Ranked results with snippets (title match ranks higher) ---

  describe "search_keyword/3 - ranked results with snippets" do
    test "returns results ranked by relevance with title matches scoring higher" do
      %{tenant: tenant} = setup_tenant()

      # Article with match only in body
      _body_match =
        create_published_article(tenant.id, %{
          title: "General Guidelines",
          body: "When working with PostgreSQL databases, indexing is crucial for performance."
        })

      # Article with match in title (should rank higher due to weight 'A')
      _title_match =
        create_published_article(tenant.id, %{
          title: "PostgreSQL Performance Tuning",
          body: "This article covers various optimization strategies."
        })

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_keyword(tenant.id, "PostgreSQL")

      assert length(results) == 2
      assert meta.total_count == 2

      # Title match should rank higher (weight A > weight B)
      [first, second] = results
      assert first.title == "PostgreSQL Performance Tuning"
      assert second.title == "General Guidelines"

      # Both should have relevance scores
      assert is_float(first.relevance_score)
      assert is_float(second.relevance_score)
      assert first.relevance_score >= second.relevance_score
    end

    test "results include snippet with highlighted terms" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Indexing Strategies",
        body:
          "PostgreSQL provides several indexing strategies for optimizing query performance. GIN indexes are particularly useful for full-text search operations."
      })

      assert {:ok, %{results: [result]}} =
               Knowledge.search_keyword(tenant.id, "indexing")

      assert is_binary(result.snippet)
      # Snippets use ** as start/stop markers
      assert result.snippet =~ "**"
    end
  end

  # --- TC-20.1.2: Filters by project_id, category, tags ---

  describe "search_keyword/3 - filters" do
    test "filters by project_id" do
      %{tenant: tenant, project: project} = setup_tenant_with_project()
      other_project = fixture(:project, %{tenant_id: tenant.id})

      create_published_article(tenant.id, %{
        title: "Ecto Patterns for Project A",
        body: "Use Ecto.Multi for atomic operations.",
        project_id: project.id
      })

      create_published_article(tenant.id, %{
        title: "Ecto Patterns for Project B",
        body: "Use Ecto.Multi for atomic transactions.",
        project_id: other_project.id
      })

      assert {:ok, %{results: results}} =
               Knowledge.search_keyword(tenant.id, "Ecto", project_id: project.id)

      assert length(results) == 1
      assert hd(results).project_id == project.id
    end

    test "filters by category" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Database Convention",
        body: "Always use migrations for schema changes.",
        category: :convention
      })

      create_published_article(tenant.id, %{
        title: "Database Pattern",
        body: "Use database connection pooling for scalability.",
        category: :pattern
      })

      assert {:ok, %{results: results}} =
               Knowledge.search_keyword(tenant.id, "database", category: :convention)

      assert length(results) == 1
      assert hd(results).category == :convention
    end

    test "filters by tags (overlap)" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Elixir Testing Guide",
        body: "Write comprehensive tests for all modules.",
        tags: ["elixir", "testing"]
      })

      create_published_article(tenant.id, %{
        title: "Elixir Deployment Guide",
        body: "Deploy your Elixir application to production.",
        tags: ["elixir", "deployment"]
      })

      assert {:ok, %{results: results}} =
               Knowledge.search_keyword(tenant.id, "Elixir", tags: ["testing"])

      assert length(results) == 1
      assert hd(results).title == "Elixir Testing Guide"
    end
  end

  # --- TC-20.1.3: Default published-only, explicit status override ---

  describe "search_keyword/3 - status filtering" do
    test "defaults to published articles only" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Published GenServer Guide",
        body: "Use GenServer for stateful processes."
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft GenServer Guide",
        body: "Draft content about GenServer patterns.",
        status: :draft
      })

      assert {:ok, %{results: results}} =
               Knowledge.search_keyword(tenant.id, "GenServer")

      assert length(results) == 1
      assert hd(results).status == :published
    end

    test "explicit status override returns matching status" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Published OTP Guide",
        body: "OTP supervision trees for fault tolerance."
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft OTP Guide",
        body: "Draft content about OTP patterns.",
        status: :draft
      })

      assert {:ok, %{results: results}} =
               Knowledge.search_keyword(tenant.id, "OTP", status: :draft)

      assert length(results) == 1
      assert hd(results).status == :draft
    end
  end

  # --- TC-20.1.4: Pagination (limit/offset with total_count) ---

  describe "search_keyword/3 - pagination" do
    test "respects limit and offset with correct total_count" do
      %{tenant: tenant} = setup_tenant()

      for i <- 1..5 do
        create_published_article(tenant.id, %{
          title: "Phoenix LiveView Pattern #{i}",
          body: "LiveView pattern number #{i} for building interactive UIs."
        })
      end

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_keyword(tenant.id, "LiveView", limit: 2, offset: 0)

      assert length(results) == 2
      assert meta.total_count == 5
      assert meta.limit == 2
      assert meta.offset == 0

      # Second page
      assert {:ok, %{results: page2, meta: meta2}} =
               Knowledge.search_keyword(tenant.id, "LiveView", limit: 2, offset: 2)

      assert length(page2) == 2
      assert meta2.total_count == 5
      assert meta2.offset == 2
    end

    test "defaults to limit 20 and offset 0" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Default Pagination Test",
        body: "Testing default pagination values."
      })

      assert {:ok, %{meta: meta}} =
               Knowledge.search_keyword(tenant.id, "pagination")

      assert meta.limit == 20
      assert meta.offset == 0
    end

    test "honors a within-cap relevance limit (#148 A1)" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Limit Cap Test",
        body: "Testing that a within-cap limit is honored, not silently clamped."
      })

      assert {:ok, %{meta: meta}} =
               Knowledge.search_keyword(tenant.id, "limit", limit: 75)

      assert meta.limit == 75
    end

    test "clamps a relevance limit above the relevance cap as an internal safety net (#148 A1)" do
      %{tenant: tenant} = setup_tenant()

      # Relevance modes are ranked top-N, capped well below the enumeration page
      # size. The HTTP layer 400s an over-cap request; the context clamps as a
      # safety net for direct callers.
      assert {:ok, %{meta: meta}} =
               Knowledge.search_keyword(tenant.id, "limit",
                 limit: Knowledge.max_relevance_page_size() + 50
               )

      assert meta.limit == Knowledge.max_relevance_page_size()
    end

    test "floors limit at 1" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Limit Floor Test",
        body: "Testing that limit floors at 1."
      })

      assert {:ok, %{meta: meta}} =
               Knowledge.search_keyword(tenant.id, "limit", limit: 0)

      assert meta.limit == 1
    end
  end

  # --- TC-20.1.5: Empty query returns {:error, :empty_query}; stop-words return empty results ---

  describe "search_keyword/3 - empty and stop-word queries" do
    test "empty string returns {:error, :empty_query}" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :empty_query} = Knowledge.search_keyword(tenant.id, "")
    end

    test "nil returns {:error, :empty_query}" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :empty_query} = Knowledge.search_keyword(tenant.id, nil)
    end

    test "whitespace-only string returns {:error, :empty_query}" do
      %{tenant: tenant} = setup_tenant()

      assert {:error, :empty_query} = Knowledge.search_keyword(tenant.id, "   ")
    end

    test "stop-word-only query returns empty results" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{
        title: "Some Article",
        body: "This is a test article with content."
      })

      # "the" is a common English stop word
      assert {:ok, %{results: results}} =
               Knowledge.search_keyword(tenant.id, "the")

      assert results == []
    end

    test "query exceeding 500 characters returns {:error, :bad_request, message}" do
      %{tenant: tenant} = setup_tenant()

      long_query = String.duplicate("a", 501)

      assert {:error, :bad_request, "Query too long (max 500 characters)"} =
               Knowledge.search_keyword(tenant.id, long_query)
    end
  end

  # --- TC-20.1.6: Tenant isolation ---

  describe "search_keyword/3 - tenant isolation" do
    test "tenant A cannot see tenant B's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      create_published_article(tenant_a.id, %{
        title: "Tenant A Supervision Trees",
        body: "Supervision trees for tenant A applications."
      })

      create_published_article(tenant_b.id, %{
        title: "Tenant B Supervision Trees",
        body: "Supervision trees for tenant B applications."
      })

      # Tenant A only sees their own articles
      assert {:ok, %{results: results_a}} =
               Knowledge.search_keyword(tenant_a.id, "Supervision")

      assert length(results_a) == 1
      assert hd(results_a).tenant_id == tenant_a.id

      # Tenant B only sees their own articles
      assert {:ok, %{results: results_b}} =
               Knowledge.search_keyword(tenant_b.id, "Supervision")

      assert length(results_b) == 1
      assert hd(results_b).tenant_id == tenant_b.id
    end
  end

  # --- TC-20.1.7: search_vector updates when title/body changes ---

  describe "search_keyword/3 - search_vector updates on article change" do
    test "search_vector updates when title changes" do
      %{tenant: tenant} = setup_tenant()

      article =
        create_published_article(tenant.id, %{
          title: "Original Mnesia Guide",
          body: "Content about distributed databases."
        })

      # Should find by original title
      assert {:ok, %{results: [_]}} =
               Knowledge.search_keyword(tenant.id, "Mnesia")

      # Update the title
      assert {:ok, _updated} =
               Knowledge.update_article(tenant.id, article.id, %{
                 title: "Updated ETS Guide"
               })

      # Should no longer match old title
      assert {:ok, %{results: []}} =
               Knowledge.search_keyword(tenant.id, "Mnesia")

      # Should match new title
      assert {:ok, %{results: [result]}} =
               Knowledge.search_keyword(tenant.id, "ETS")

      assert result.title == "Updated ETS Guide"
    end

    test "search_vector updates when body changes" do
      %{tenant: tenant} = setup_tenant()

      article =
        create_published_article(tenant.id, %{
          title: "Architecture Guide",
          body: "Microservices architecture with Kubernetes orchestration."
        })

      # Should find by original body content
      assert {:ok, %{results: [_]}} =
               Knowledge.search_keyword(tenant.id, "Kubernetes")

      # Update the body
      assert {:ok, _updated} =
               Knowledge.update_article(tenant.id, article.id, %{
                 body: "Monolithic architecture with Phoenix framework."
               })

      # Should no longer match old body
      assert {:ok, %{results: []}} =
               Knowledge.search_keyword(tenant.id, "Kubernetes")

      # Should match new body
      assert {:ok, %{results: [result]}} =
               Knowledge.search_keyword(tenant.id, "Phoenix")

      assert result.title == "Architecture Guide"
    end
  end

  describe "list_filtered/2 - query-less enumeration (Issue #108)" do
    test "returns the full set for a tag regardless of keyword content" do
      %{tenant: tenant} = setup_tenant()

      for i <- 1..3 do
        create_published_article(tenant.id, %{
          title: "Hub #{i}",
          body: "entirely unique prose #{i}",
          category: :reference,
          tags: ["hub"]
        })
      end

      create_published_article(tenant.id, %{
        title: "Other",
        body: "x",
        category: :reference,
        tags: ["other"]
      })

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.list_filtered(tenant.id, tags: ["hub"], limit: 50)

      assert meta.total_count == 3
      assert length(results) == 3
      assert Enum.all?(results, &(&1.tags == ["hub"]))
    end

    test "filters by category and respects limit/offset for complete pagination" do
      %{tenant: tenant} = setup_tenant()

      for i <- 1..5 do
        create_published_article(tenant.id, %{
          title: "Ref #{i}",
          body: "b#{i}",
          category: :reference
        })
      end

      assert {:ok, %{meta: %{total_count: 5}}} =
               Knowledge.list_filtered(tenant.id, category: :reference, limit: 2, offset: 0)

      ids =
        [0, 2, 4]
        |> Enum.flat_map(fn off ->
          {:ok, %{results: r}} =
            Knowledge.list_filtered(tenant.id, category: :reference, limit: 2, offset: off)

          Enum.map(r, & &1.id)
        end)

      assert length(Enum.uniq(ids)) == 5
    end

    test "only published articles are returned" do
      %{tenant: tenant} = setup_tenant()

      create_published_article(tenant.id, %{title: "Pub", body: "x", tags: ["hub"]})
      fixture(:article, %{tenant_id: tenant.id, title: "Draft", tags: ["hub"], status: :draft})

      assert {:ok, %{meta: %{total_count: 1}, results: [only]}} =
               Knowledge.list_filtered(tenant.id, tags: ["hub"])

      assert only.title == "Pub"
    end

    test "tenant isolation — tenant A cannot enumerate tenant B's tagged articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      create_published_article(tenant_a.id, %{title: "A", body: "x", tags: ["hub"]})
      create_published_article(tenant_b.id, %{title: "B", body: "x", tags: ["hub"]})

      assert {:ok, %{meta: %{total_count: 1}, results: [only]}} =
               Knowledge.list_filtered(tenant_a.id, tags: ["hub"])

      assert only.title == "A"
    end
  end
end
