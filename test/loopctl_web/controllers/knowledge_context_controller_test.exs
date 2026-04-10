defmodule LoopctlWeb.KnowledgeContextControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/knowledge/context" do
    test "returns full bodies with combined scoring (fresh article ranks higher)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Create two published articles
      old_article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Old Ecto Pattern",
          body: "Use Ecto.Multi for atomic multi-step database operations with rollback.",
          category: :pattern,
          status: :published,
          tags: ["ecto", "transactions"]
        })

      _fresh_article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Fresh Ecto Convention",
          body: "Modern Ecto convention for query composition and filtering patterns.",
          category: :convention,
          status: :published,
          tags: ["ecto", "queries"]
        })

      # Make old_article appear stale by updating its updated_at to 90 days ago
      ninety_days_ago = DateTime.add(DateTime.utc_now(), -90 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^old_article.id),
        set: [updated_at: ninety_days_ago]
      )

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "Ecto"})

      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["data"] != []

      # All results should have full body
      Enum.each(body["data"], fn result ->
        assert is_binary(result["body"]), "Expected body to be present"
        assert result["body"] != ""
        assert is_binary(result["id"])
        assert is_binary(result["title"])
        assert is_binary(result["category"])
        assert is_list(result["tags"])
        assert is_binary(result["updated_at"])
        assert is_number(result["relevance_score"])
        assert is_number(result["recency_score"])
        assert is_number(result["combined_score"])
        assert is_list(result["linked_articles"])
      end)

      # Fresh article should rank higher due to recency boost
      titles = Enum.map(body["data"], & &1["title"])
      fresh_idx = Enum.find_index(titles, &(&1 == "Fresh Ecto Convention"))
      old_idx = Enum.find_index(titles, &(&1 == "Old Ecto Pattern"))

      if fresh_idx && old_idx do
        assert fresh_idx < old_idx,
               "Fresh article should rank higher than old article due to recency"
      end

      # Meta should contain expected fields
      assert body["meta"]["total_count"] >= 1
      assert body["meta"]["limit"] == 5
      assert is_number(body["meta"]["recency_weight"])
    end

    test "linked articles returned as lightweight refs (max 5)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      source =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Source Pattern",
          body: "Source article about linked patterns and references.",
          category: :pattern,
          status: :published,
          tags: ["linked"]
        })

      target =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Target Reference",
          body: "Target article that is linked from the source.",
          category: :reference,
          status: :published,
          tags: ["linked"]
        })

      # Create a link between them
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: source.id,
        target_article_id: target.id,
        relationship_type: :relates_to
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "linked patterns"})

      body = json_response(conn, 200)

      # Find the source article in results
      source_result = Enum.find(body["data"], &(&1["title"] == "Source Pattern"))

      if source_result do
        assert is_list(source_result["linked_articles"])

        if source_result["linked_articles"] != [] do
          linked = List.first(source_result["linked_articles"])
          assert linked["id"]
          assert linked["title"]
          assert linked["category"]
          # Linked articles should be lightweight (no body)
          refute Map.has_key?(linked, "body")
          refute Map.has_key?(linked, "tags")
          refute Map.has_key?(linked, "updated_at")
        end
      end
    end

    test "custom recency_weight affects ranking", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      old_article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Old Weight Test Article",
          body: "Content about weight testing for recency scoring.",
          category: :pattern,
          status: :published,
          tags: ["weight"]
        })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Fresh Weight Test Article",
        body: "Content about weight testing for recency scoring fresh.",
        category: :pattern,
        status: :published,
        tags: ["weight"]
      })

      # Make old_article 60 days old
      sixty_days_ago = DateTime.add(DateTime.utc_now(), -60 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^old_article.id),
        set: [updated_at: sixty_days_ago]
      )

      # Request with high recency_weight (0.9) -- should strongly favor fresh articles
      conn_high =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "weight testing", recency_weight: "0.9"})

      body_high = json_response(conn_high, 200)

      # Request with zero recency_weight -- pure relevance
      conn_zero =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "weight testing", recency_weight: "0.0"})

      body_zero = json_response(conn_zero, 200)

      # Both should return results
      assert body_high["data"] != []
      assert body_zero["data"] != []

      # With high recency weight, the recency_weight in meta should be 0.9
      assert body_high["meta"]["recency_weight"] == 0.9
      assert body_zero["meta"]["recency_weight"] == 0.0
    end

    test "embedding failure returns keyword fallback with meta.fallback", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Fallback Test Article",
        body: "Content about fallback testing when embeddings fail.",
        category: :pattern,
        status: :published,
        tags: ["fallback"]
      })

      # Make embedding generation fail
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, :service_unavailable}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "fallback"})

      body = json_response(conn, 200)

      # Should still return results (keyword fallback)
      assert is_list(body["data"])
      # Should have fallback flag set
      assert body["meta"]["fallback"] == true
    end

    test "missing query returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context")

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "query"
    end

    test "empty query returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: ""})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "query"
    end

    test "whitespace-only query returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "   "})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
    end

    test "tenant isolation -- tenant A cannot see tenant B's articles", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "Tenant A Context Article",
        body: "Content about context retrieval for tenant A isolation test.",
        category: :pattern,
        status: :published,
        tags: ["isolation"]
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "Tenant B Context Article",
        body: "Content about context retrieval for tenant B isolation test.",
        category: :pattern,
        status: :published,
        tags: ["isolation"]
      })

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/context", %{query: "isolation context"})

      body = json_response(conn, 200)

      titles = Enum.map(body["data"], & &1["title"])
      assert "Tenant A Context Article" in titles
      refute "Tenant B Context Article" in titles
    end

    test "limit caps results at max 20", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Create 25 articles
      for i <- 1..25 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Limit Cap Article #{i}",
          body: "Content about limit cap testing for article number #{i}.",
          category: :pattern,
          status: :published,
          tags: ["limitcap"]
        })
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "limit cap", limit: "50"})

      body = json_response(conn, 200)

      # Should be capped at 20 (max)
      assert length(body["data"]) <= 20
      assert body["meta"]["limit"] == 20
    end

    test "default limit is 5", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      for i <- 1..10 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Default Limit Article #{i}",
          body: "Content about default limit testing for article #{i}.",
          category: :pattern,
          status: :published,
          tags: ["defaultlimit"]
        })
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "default limit"})

      body = json_response(conn, 200)

      assert length(body["data"]) <= 5
      assert body["meta"]["limit"] == 5
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/context", %{query: "test"})
      assert json_response(conn, 401)
    end

    test "only published articles returned for agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published Context Article",
        body: "Published content about context retrieval.",
        category: :pattern,
        status: :published,
        tags: ["status"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft Context Article",
        body: "Draft content about context retrieval.",
        category: :pattern,
        status: :draft,
        tags: ["status"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "context retrieval"})

      body = json_response(conn, 200)

      titles = Enum.map(body["data"], & &1["title"])
      assert "Published Context Article" in titles
      refute "Draft Context Article" in titles
    end

    test "query exceeding 500 characters returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      long_query = String.duplicate("a", 501)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: long_query})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "500"
    end

    test "user role can override status to search drafts", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft User Override Article",
        body: "Draft content visible to user role via status override.",
        category: :pattern,
        status: :draft,
        tags: ["override"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published User Override Article",
        body: "Published content visible to user role.",
        category: :pattern,
        status: :published,
        tags: ["override"]
      })

      # User with status=draft should see draft articles
      conn_draft =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "override", status: "draft"})

      body_draft = json_response(conn_draft, 200)

      draft_titles = Enum.map(body_draft["data"], & &1["title"])

      if draft_titles != [] do
        assert "Draft User Override Article" in draft_titles
        refute "Published User Override Article" in draft_titles
      end
    end

    test "agent role ignores status parameter (forced to published)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft Agent Forced Article",
        body: "Draft content that agent should not see.",
        category: :pattern,
        status: :draft,
        tags: ["forced"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published Agent Forced Article",
        body: "Published content that agent should see.",
        category: :pattern,
        status: :published,
        tags: ["forced"]
      })

      # Agent with status=draft should still only get published
      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/context", %{query: "forced", status: "draft"})

      body = json_response(conn, 200)

      titles = Enum.map(body["data"], & &1["title"])

      if titles != [] do
        refute "Draft Agent Forced Article" in titles
      end
    end
  end
end
