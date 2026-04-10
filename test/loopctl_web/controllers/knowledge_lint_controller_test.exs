defmodule LoopctlWeb.KnowledgeLintControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/knowledge/lint" do
    test "returns lint report with all sections and summary", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Create a few published articles so we get some coverage gaps
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern A",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)

      # Verify structure
      assert is_map(body["data"])
      assert is_list(body["data"]["stale_articles"])
      assert is_list(body["data"]["orphan_articles"])
      assert is_list(body["data"]["contradiction_clusters"])
      assert is_list(body["data"]["coverage_gaps"])
      assert is_list(body["data"]["broken_sources"])

      # Verify summary
      assert is_map(body["summary"])
      assert body["summary"]["total_articles"] == 1
      assert is_integer(body["summary"]["total_issues"])
      assert is_map(body["summary"]["issues_by_severity"])
      assert is_binary(body["summary"]["generated_at"])
    end

    test "returns empty report (except coverage gaps) when no published articles exist",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)

      assert body["data"]["stale_articles"] == []
      assert body["data"]["orphan_articles"] == []
      assert body["data"]["contradiction_clusters"] == []
      assert body["data"]["broken_sources"] == []
      assert body["summary"]["total_articles"] == 0

      # All 5 categories are below default min_coverage=3, so 5 coverage gaps exist
      assert length(body["data"]["coverage_gaps"]) == 5
      assert body["summary"]["total_issues"] == 5
    end

    test "requires user role (agent gets 403)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      assert json_response(conn, 403)
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/lint")
      assert json_response(conn, 401)
    end
  end

  describe "stale articles (AC-21.5.3)" do
    test "reports articles not updated within stale_days threshold", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Stale Pattern",
          category: :pattern,
          status: :published
        })

      # Make the article appear stale (100 days old)
      past = DateTime.utc_now() |> DateTime.add(-100 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^article.id),
        set: [updated_at: past]
      )

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      stale = body["data"]["stale_articles"]
      assert length(stale) == 1
      [entry] = stale
      assert entry["article_id"] == article.id
      assert entry["title"] == "Stale Pattern"
      assert entry["days_since_update"] >= 100
      assert entry["severity"] == "warning"
      assert entry["suggested_action"] =~ "Review and update"
      assert entry["last_updated"]
    end

    test "configurable stale_days via query param", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Recent Article",
          category: :pattern,
          status: :published
        })

      # Make the article 10 days old -- stale if stale_days=5, not stale if stale_days=90
      past = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^article.id),
        set: [updated_at: past]
      )

      # Default stale_days=90 → not stale
      conn1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body1 = json_response(conn1, 200)
      assert body1["data"]["stale_articles"] == []

      # stale_days=5 → stale
      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?stale_days=5")

      body2 = json_response(conn2, 200)
      assert length(body2["data"]["stale_articles"]) == 1
    end
  end

  describe "orphan articles (AC-21.5.4)" do
    test "reports published articles with zero links", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      orphan =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Orphan Article",
          category: :finding,
          status: :published
        })

      linked_source =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Linked Source",
          category: :pattern,
          status: :published
        })

      linked_target =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Linked Target",
          category: :convention,
          status: :published
        })

      # Create a link between linked_source and linked_target
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: linked_source.id,
        target_article_id: linked_target.id,
        relationship_type: :relates_to
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      orphans = body["data"]["orphan_articles"]

      # Only the orphan should appear -- linked_source and linked_target are linked
      orphan_ids = Enum.map(orphans, & &1["article_id"])
      assert orphan.id in orphan_ids
      refute linked_source.id in orphan_ids
      refute linked_target.id in orphan_ids

      orphan_entry = Enum.find(orphans, &(&1["article_id"] == orphan.id))
      assert orphan_entry["title"] == "Orphan Article"
      assert orphan_entry["category"] == "finding"
      assert orphan_entry["severity"] == "info"
      assert orphan_entry["suggested_action"] =~ "linking"
    end
  end

  describe "contradiction clusters (AC-21.5.5)" do
    test "groups articles linked with contradicts relationship", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      art_a =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Approach A",
          category: :decision,
          status: :published
        })

      art_b =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Approach B",
          category: :decision,
          status: :published
        })

      link =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: art_a.id,
          target_article_id: art_b.id,
          relationship_type: :contradicts
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      clusters = body["data"]["contradiction_clusters"]
      assert length(clusters) == 1
      [cluster] = clusters
      assert art_a.id in cluster["article_ids"]
      assert art_b.id in cluster["article_ids"]
      assert link.id in cluster["link_ids"]
      assert cluster["severity"] == "warning"
      assert cluster["suggested_action"] =~ "Resolve contradiction"
      assert "Approach A" in cluster["titles"]
      assert "Approach B" in cluster["titles"]
    end

    test "no contradictions returns empty array", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "No Conflicts",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      assert body["data"]["contradiction_clusters"] == []
    end
  end

  describe "coverage gaps (AC-21.5.6)" do
    test "reports categories with fewer than min_coverage published articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Create 3 pattern articles (meets default min_coverage=3)
      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Pattern #{i}",
          category: :pattern,
          status: :published
        })
      end

      # Only 1 convention article (below default min_coverage=3)
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Convention 1",
        category: :convention,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      gaps = body["data"]["coverage_gaps"]

      # convention (1), decision (0), finding (0), reference (0) should be gaps
      # pattern (3) should NOT be a gap
      gap_categories = Enum.map(gaps, & &1["category"])
      refute "pattern" in gap_categories
      assert "convention" in gap_categories
      assert "decision" in gap_categories
      assert "finding" in gap_categories
      assert "reference" in gap_categories

      convention_gap = Enum.find(gaps, &(&1["category"] == "convention"))
      assert convention_gap["current_count"] == 1
      assert convention_gap["threshold"] == 3
      assert convention_gap["severity"] == "info"
      assert convention_gap["suggested_action"] =~ "Add more articles"
    end

    test "configurable min_coverage via query param", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Single Pattern",
        category: :pattern,
        status: :published
      })

      # min_coverage=1 → pattern is not a gap
      conn1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?min_coverage=1")

      body1 = json_response(conn1, 200)
      gap_categories = Enum.map(body1["data"]["coverage_gaps"], & &1["category"])
      refute "pattern" in gap_categories

      # min_coverage=2 → pattern IS a gap
      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?min_coverage=2")

      body2 = json_response(conn2, 200)
      gap_categories2 = Enum.map(body2["data"]["coverage_gaps"], & &1["category"])
      assert "pattern" in gap_categories2
    end
  end

  describe "broken sources (AC-21.5.7)" do
    test "reports articles with source_id referencing deleted entity", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Create an article with a non-existent source_id
      broken_source_id = Ecto.UUID.generate()

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Broken Source Article",
          category: :finding,
          status: :published,
          source_type: "review_finding",
          source_id: broken_source_id
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      broken = body["data"]["broken_sources"]
      assert length(broken) == 1
      [entry] = broken
      assert entry["article_id"] == article.id
      assert entry["title"] == "Broken Source Article"
      assert entry["source_type"] == "review_finding"
      assert entry["source_id"] == broken_source_id
      assert entry["severity"] == "warning"
      assert entry["suggested_action"] =~ "Source entity was deleted"
    end

    test "articles with valid source_id are not reported", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Create a real review record
      review_record =
        fixture(:review_record, %{
          tenant_id: tenant.id,
          story_id: story.id
        })

      # Create an article pointing to a valid review record
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Valid Source Article",
        category: :finding,
        status: :published,
        source_type: "review_finding",
        source_id: review_record.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      assert body["data"]["broken_sources"] == []
    end

    test "articles with other source_types are not checked", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Create an article with source_type "manual" and a random source_id
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Manual Source Article",
        category: :finding,
        status: :published,
        source_type: "manual",
        source_id: Ecto.UUID.generate()
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      # Manual source articles should not appear in broken_sources
      assert body["data"]["broken_sources"] == []
    end
  end

  describe "project-scoped lint (AC-21.5.1)" do
    test "GET /api/v1/projects/:project_id/knowledge/lint scopes to project", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Tenant-wide article (nil project_id) — should be included
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide",
        category: :pattern,
        status: :published
      })

      # Project-specific article — should be included
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Project Specific",
        category: :convention,
        status: :published
      })

      # Other project's article — should be excluded
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        title: "Other Project",
        category: :decision,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/knowledge/lint")

      body = json_response(conn, 200)

      # Should include tenant-wide + project-specific = 2 total
      assert body["summary"]["total_articles"] == 2
    end
  end

  describe "parameter validation (AC-21.5.11)" do
    test "invalid stale_days returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?stale_days=abc")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "stale_days must be a positive integer"
    end

    test "zero stale_days returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?stale_days=0")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "stale_days must be a positive integer"
    end

    test "negative stale_days returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?stale_days=-5")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "stale_days must be a positive integer"
    end

    test "invalid min_coverage returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?min_coverage=xyz")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "min_coverage must be a positive integer"
    end

    test "zero min_coverage returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint?min_coverage=0")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "min_coverage must be a positive integer"
    end
  end

  describe "summary (AC-21.5.8)" do
    test "summary includes correct issue counts by severity", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Create a stale article (warning)
      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Old Pattern",
          category: :pattern,
          status: :published
        })

      past = DateTime.utc_now() |> DateTime.add(-100 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^article.id),
        set: [updated_at: past]
      )

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)
      summary = body["summary"]

      assert summary["total_articles"] == 1

      # At minimum: 1 stale (warning) + orphan (info, since no links) + coverage gaps (info)
      assert summary["total_issues"] > 0
      assert is_map(summary["issues_by_severity"])

      # The stale article is a warning
      assert summary["issues_by_severity"]["warning"] >= 1
    end
  end

  describe "tenant isolation (AC-21.5.10)" do
    test "tenant A cannot see tenant B's articles in lint report", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})

      # Create articles for both tenants
      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "Tenant A Article",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "Tenant B Article",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/lint")

      body = json_response(conn, 200)

      # Only tenant A's article should count
      assert body["summary"]["total_articles"] == 1

      # If orphan articles show up, they should only be tenant A's
      orphan_titles =
        body["data"]["orphan_articles"]
        |> Enum.map(& &1["title"])

      if orphan_titles != [] do
        assert "Tenant A Article" in orphan_titles
        refute "Tenant B Article" in orphan_titles
      end
    end
  end

  describe "read-only operation (AC-21.5.9)" do
    test "lint does not modify any articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Immutable Article",
          category: :pattern,
          status: :published
        })

      original_updated_at = article.updated_at

      _conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/lint")

      # Re-fetch the article and verify it's unchanged
      {:ok, refetched} = Loopctl.Knowledge.get_article(tenant.id, article.id)
      assert refetched.updated_at == original_updated_at
      assert refetched.title == "Immutable Article"
      assert refetched.status == :published
    end
  end
end
