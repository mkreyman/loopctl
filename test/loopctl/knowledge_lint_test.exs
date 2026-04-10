defmodule Loopctl.KnowledgeLintTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  describe "lint/2" do
    test "returns all five analysis categories" do
      tenant = fixture(:tenant)

      {:ok, result} = Knowledge.lint(tenant.id)

      assert is_list(result.stale_articles)
      assert is_list(result.orphan_articles)
      assert is_list(result.contradiction_clusters)
      assert is_list(result.coverage_gaps)
      assert is_list(result.broken_sources)
      assert is_map(result.summary)
    end

    test "stale_articles finds articles older than stale_days" do
      tenant = fixture(:tenant)

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Stale Article",
          category: :pattern,
          status: :published
        })

      # Make the article 200 days old
      past = DateTime.utc_now() |> DateTime.add(-200 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^article.id),
        set: [updated_at: past]
      )

      {:ok, result} = Knowledge.lint(tenant.id)

      assert length(result.stale_articles) == 1
      [stale] = result.stale_articles
      assert stale.article_id == article.id
      assert stale.days_since_update >= 200
    end

    test "stale_articles respects custom stale_days threshold" do
      tenant = fixture(:tenant)

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Somewhat Old",
          category: :pattern,
          status: :published
        })

      # Make the article 30 days old
      past = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^article.id),
        set: [updated_at: past]
      )

      # Default 90 days: not stale
      {:ok, result} = Knowledge.lint(tenant.id)
      assert result.stale_articles == []

      # 20 days: stale
      {:ok, result} = Knowledge.lint(tenant.id, stale_days: 20)
      assert length(result.stale_articles) == 1
    end

    test "orphan_articles finds articles with no links" do
      tenant = fixture(:tenant)

      orphan =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Orphan",
          category: :pattern,
          status: :published
        })

      connected =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Connected",
          category: :convention,
          status: :published
        })

      other =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Other",
          category: :finding,
          status: :published
        })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: connected.id,
        target_article_id: other.id,
        relationship_type: :relates_to
      })

      {:ok, result} = Knowledge.lint(tenant.id)
      orphan_ids = Enum.map(result.orphan_articles, & &1.article_id)

      assert orphan.id in orphan_ids
      refute connected.id in orphan_ids
      refute other.id in orphan_ids
    end

    test "orphan_articles excludes draft articles" do
      tenant = fixture(:tenant)

      _draft =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Draft No Links",
          category: :pattern,
          status: :draft
        })

      {:ok, result} = Knowledge.lint(tenant.id)
      # Draft should not appear as orphan because lint only looks at published articles
      assert Enum.all?(result.orphan_articles, &(&1.title != "Draft No Links"))
    end

    test "contradiction_clusters groups contradicting articles" do
      tenant = fixture(:tenant)

      a =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "View A",
          category: :decision,
          status: :published
        })

      b =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "View B",
          category: :decision,
          status: :published
        })

      c =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "View C",
          category: :decision,
          status: :published
        })

      # A contradicts B, B contradicts C → one cluster of {A, B, C}
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: a.id,
        target_article_id: b.id,
        relationship_type: :contradicts
      })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: b.id,
        target_article_id: c.id,
        relationship_type: :contradicts
      })

      {:ok, result} = Knowledge.lint(tenant.id)

      assert length(result.contradiction_clusters) == 1
      [cluster] = result.contradiction_clusters
      assert a.id in cluster.article_ids
      assert b.id in cluster.article_ids
      assert c.id in cluster.article_ids
      assert length(cluster.link_ids) == 2
    end

    test "contradiction_clusters ignores non-published articles" do
      tenant = fixture(:tenant)

      published =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Published",
          category: :decision,
          status: :published
        })

      draft =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Draft",
          category: :decision,
          status: :draft
        })

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: published.id,
        target_article_id: draft.id,
        relationship_type: :contradicts
      })

      {:ok, result} = Knowledge.lint(tenant.id)
      assert result.contradiction_clusters == []
    end

    test "coverage_gaps reports categories below min_coverage" do
      tenant = fixture(:tenant)

      # Create 5 pattern articles
      for i <- 1..5 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Pattern #{i}",
          category: :pattern,
          status: :published
        })
      end

      {:ok, result} = Knowledge.lint(tenant.id, min_coverage: 3)

      gap_cats = Enum.map(result.coverage_gaps, & &1.category)
      refute "pattern" in gap_cats
      assert "convention" in gap_cats
      assert "decision" in gap_cats
      assert "finding" in gap_cats
      assert "reference" in gap_cats

      # Each gap entry has correct threshold
      Enum.each(result.coverage_gaps, fn gap ->
        assert gap.threshold == 3
        assert gap.current_count < 3
      end)
    end

    test "broken_sources finds articles with deleted source entities" do
      tenant = fixture(:tenant)

      broken_id = Ecto.UUID.generate()

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Broken Ref",
          category: :finding,
          status: :published,
          source_type: "review_finding",
          source_id: broken_id
        })

      {:ok, result} = Knowledge.lint(tenant.id)

      assert length(result.broken_sources) == 1
      [broken] = result.broken_sources
      assert broken.article_id == article.id
      assert broken.source_id == broken_id
      assert broken.source_type == "review_finding"
    end

    test "broken_sources excludes valid review_finding references" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      review_record =
        fixture(:review_record, %{
          tenant_id: tenant.id,
          story_id: story.id
        })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Valid Ref",
        category: :finding,
        status: :published,
        source_type: "review_finding",
        source_id: review_record.id
      })

      {:ok, result} = Knowledge.lint(tenant.id)
      assert result.broken_sources == []
    end

    test "summary contains correct totals" do
      tenant = fixture(:tenant)

      for i <- 1..4 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Article #{i}",
          category: :pattern,
          status: :published
        })
      end

      {:ok, result} = Knowledge.lint(tenant.id)

      assert result.summary.total_articles == 4
      assert is_integer(result.summary.total_issues)
      assert is_map(result.summary.issues_by_severity)
      assert is_binary(result.summary.generated_at)
    end

    test "project_id scopes to project-specific and tenant-wide articles" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})

      # Tenant-wide article
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide",
        category: :pattern,
        status: :published
      })

      # Project-specific article
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Project Art",
        category: :pattern,
        status: :published
      })

      # Other project's article
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        title: "Other Project Art",
        category: :pattern,
        status: :published
      })

      {:ok, result} = Knowledge.lint(tenant.id, project_id: project.id)

      # Should include tenant-wide + project-specific = 2
      assert result.summary.total_articles == 2
    end

    test "tenant isolation: tenant A's lint does not include tenant B's data" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "A's Article",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "B's Article",
        category: :pattern,
        status: :published
      })

      {:ok, result_a} = Knowledge.lint(tenant_a.id)

      assert result_a.summary.total_articles == 1

      orphan_titles = Enum.map(result_a.orphan_articles, & &1.title)

      if orphan_titles != [] do
        assert "A's Article" in orphan_titles
        refute "B's Article" in orphan_titles
      end
    end
  end
end
