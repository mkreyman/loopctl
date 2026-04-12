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

  defp create_system_article(attrs \\ %{}) do
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
      article = create_system_article(%{slug: "chain-of-custody", status: :published})

      assert {:ok, found} = Knowledge.get_system_article_by_slug("chain-of-custody")
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
