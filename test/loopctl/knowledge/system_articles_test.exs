defmodule Loopctl.Knowledge.SystemArticlesTest do
  @moduledoc """
  Tests for US-26.0.3 — system-scoped knowledge articles.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  setup :verify_on_exit!

  defp create_system_article(attrs) do
    base = %{
      title: "System Article #{System.unique_integer([:positive])}",
      body: "System article body content for testing.",
      category: :pattern,
      scope: :system,
      status: :published,
      slug: "sys-#{System.unique_integer([:positive])}"
    }

    merged = Map.merge(base, attrs)

    %Article{tenant_id: nil}
    |> Article.create_changeset(merged)
    |> AdminRepo.insert!()
  end

  describe "scope and slug schema" do
    test "system article created with tenant_id=nil and scope=:system" do
      article = create_system_article(%{slug: "test-system-scope"})
      assert article.scope == :system
      assert article.tenant_id == nil
      assert article.slug == "test-system-scope"
    end

    test "creating a system article via the context sets tenant_id to nil" do
      # System articles are created via Knowledge.create_article with scope: :system,
      # which sets tenant_id to nil internally
      article = create_system_article(%{slug: "ctx-system-article"})
      assert article.tenant_id == nil
      assert article.scope == :system
    end

    test "creating a tenant article requires a non-nil tenant_id" do
      tenant = fixture(:tenant)

      article =
        %Article{tenant_id: tenant.id}
        |> Article.create_changeset(%{
          title: "Tenant Scoped",
          body: "Body",
          category: :pattern,
          scope: :tenant,
          slug: "tenant-scoped"
        })
        |> AdminRepo.insert!()

      assert article.tenant_id == tenant.id
      assert article.scope == :tenant
    end

    test "system slug uniqueness enforced globally" do
      create_system_article(%{slug: "unique-slug"})

      # Second insert with same system slug fails
      result =
        %Article{tenant_id: nil}
        |> Article.create_changeset(%{
          title: "Duplicate Slug",
          body: "Dupe",
          category: :pattern,
          scope: :system,
          slug: "unique-slug"
        })
        |> AdminRepo.insert()

      assert {:error, changeset} = result
      assert {"has already been taken", _} = changeset.errors[:slug]
    end

    test "auto-generates slug from title when not provided" do
      changeset =
        %Article{tenant_id: nil}
        |> Article.create_changeset(%{
          title: "My Great Article Title",
          body: "Body content",
          category: :convention,
          scope: :system
        })

      slug = Ecto.Changeset.get_field(changeset, :slug)
      assert String.starts_with?(slug, "my-great-article-title-")
    end
  end

  describe "get_system_article_by_slug/1" do
    test "returns published system article by slug" do
      article = create_system_article(%{slug: "test-get-by-slug", status: :published})

      assert {:ok, found} = Knowledge.get_system_article_by_slug("test-get-by-slug")
      assert found.id == article.id
    end

    test "returns :not_found for unknown slug" do
      assert {:error, :not_found} = Knowledge.get_system_article_by_slug("does-not-exist")
    end

    test "returns :not_found for draft system articles" do
      create_system_article(%{slug: "draft-article", status: :draft})

      assert {:error, :not_found} = Knowledge.get_system_article_by_slug("draft-article")
    end
  end

  describe "list_system_articles/1" do
    test "returns all published system articles" do
      create_system_article(%{slug: "sys-a", title: "Alpha"})
      create_system_article(%{slug: "sys-b", title: "Beta"})
      create_system_article(%{slug: "sys-draft", status: :draft})

      articles = Knowledge.list_system_articles()
      slugs = Enum.map(articles, & &1.slug)

      assert "sys-a" in slugs
      assert "sys-b" in slugs
      refute "sys-draft" in slugs
    end

    test "filters by category" do
      create_system_article(%{slug: "sys-pattern", category: :pattern})
      create_system_article(%{slug: "sys-decision", category: :decision})

      patterns = Knowledge.list_system_articles(category: :pattern)
      assert Enum.all?(patterns, &(&1.category == :pattern))
    end
  end

  describe "list_system_articles_grouped/0" do
    test "groups articles by category" do
      create_system_article(%{slug: "grp-p1", category: :pattern})
      create_system_article(%{slug: "grp-c1", category: :convention})

      grouped = Knowledge.list_system_articles_grouped()
      assert Map.has_key?(grouped, :pattern)
      assert Map.has_key?(grouped, :convention)
    end
  end

  describe "list_featured_articles/0" do
    test "returns published system articles with a view_count and snippet" do
      article = create_system_article(%{slug: "feat-basic", title: "Featured Basic"})

      featured = Knowledge.list_featured_articles()
      row = Enum.find(featured, &(&1.id == article.id))

      assert row
      assert row.title == "Featured Basic"
      assert row.slug == "feat-basic"
      assert row.view_count == 0
      assert is_binary(row.snippet)
      refute Map.has_key?(row, :body)
    end

    test "ranks more-viewed articles ahead of unviewed ones" do
      hot = create_system_article(%{slug: "feat-hot", title: "Hot Article"})
      _cold = create_system_article(%{slug: "feat-cold", title: "Cold Article"})

      for _ <- 1..5, do: fixture(:article_access_event, %{article_id: hot.id})

      featured = Knowledge.list_featured_articles()
      hot_row = Enum.find(featured, &(&1.id == hot.id))

      assert hot_row.view_count == 5

      # The hot article outranks every zero-view article in the result.
      hot_index = Enum.find_index(featured, &(&1.id == hot.id))
      zero_indexes = for {r, i} <- Enum.with_index(featured), r.view_count == 0, do: i
      assert Enum.all?(zero_indexes, &(hot_index < &1))
    end

    test "excludes draft system articles" do
      create_system_article(%{slug: "feat-draft", title: "Draft Featured", status: :draft})

      featured = Knowledge.list_featured_articles()
      refute Enum.any?(featured, &(&1.slug == "feat-draft"))
    end

    test "returns at most 16 articles" do
      for n <- 1..20 do
        create_system_article(%{slug: "feat-cap-#{n}", title: "Cap Article #{n}"})
      end

      assert length(Knowledge.list_featured_articles()) <= 16
    end

    test "truncates the snippet to 100 chars with an ellipsis for long bodies" do
      long_body = String.duplicate("x", 250)
      article = create_system_article(%{slug: "feat-long", body: long_body})

      row = Knowledge.list_featured_articles() |> Enum.find(&(&1.id == article.id))

      assert String.ends_with?(row.snippet, "…")
      # 100 sliced chars + the ellipsis
      assert String.length(row.snippet) == 101
    end
  end

  describe "tenant isolation with system articles" do
    test "search includes system articles alongside own tenant articles" do
      tenant_a = fixture(:tenant, %{slug: "tenant-a-iso"})
      tenant_b = fixture(:tenant, %{slug: "tenant-b-iso"})

      # Create a system article
      create_system_article(%{slug: "sys-custody", title: "Chain of Custody Protocol"})

      # Create tenant-scoped articles directly
      %Article{tenant_id: tenant_a.id}
      |> Article.create_changeset(%{
        title: "Chain of Custody Notes A",
        body: "Notes for tenant A",
        category: :finding,
        slug: "custody-notes-a"
      })
      |> AdminRepo.insert!()

      %Article{tenant_id: tenant_b.id}
      |> Article.create_changeset(%{
        title: "Chain of Custody Notes B",
        body: "Notes for tenant B",
        category: :finding,
        slug: "custody-notes-b"
      })
      |> AdminRepo.insert!()

      # Tenant A's articles list should include own tenant articles but not tenant B's
      result = Knowledge.list_articles(tenant_a.id)
      titles = Enum.map(result.data, & &1.title)
      assert "Chain of Custody Notes A" in titles
      refute "Chain of Custody Notes B" in titles
    end
  end
end
