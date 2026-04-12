defmodule Loopctl.Knowledge.BootstrapArticlesTest do
  @moduledoc """
  Tests for US-26.0.5 — verifies the bootstrap system article set exists
  and renders correctly after the seed migration.
  """

  use LoopctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  setup :verify_on_exit!

  @expected_slugs ~w(chain-of-custody agent-bootstrap agent-pattern tenant-signup discovery)

  describe "seeded articles" do
    test "all five bootstrap articles exist as published system articles" do
      import Ecto.Query

      articles =
        from(a in Article,
          where: a.scope == :system and a.status == :published and a.slug in ^@expected_slugs,
          select: %{slug: a.slug, title: a.title, body: a.body, category: a.category}
        )
        |> AdminRepo.all()

      found_slugs = Enum.map(articles, & &1.slug) |> MapSet.new()

      for slug <- @expected_slugs do
        assert slug in found_slugs, "Missing system article: #{slug}"
      end

      # Each article has substantial content
      for article <- articles do
        assert String.length(article.body) > 500,
               "Article #{article.slug} body too short: #{String.length(article.body)} chars"

        assert article.category == :reference
      end
    end
  end

  describe "wiki rendering" do
    test "all bootstrap articles render at /wiki/:slug", %{conn: conn} do
      for slug <- @expected_slugs do
        {:ok, _view, html} = live(conn, "/wiki/#{slug}")
        assert html =~ "wiki-article", "Article #{slug} did not render"
      end
    end

    test "cross-links between articles resolve", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/wiki/chain-of-custody")

      # The chain-of-custody article links to other articles
      assert html =~ "/wiki/agent-bootstrap"
      assert html =~ "/wiki/agent-pattern"
      assert html =~ "/wiki/tenant-signup"
      assert html =~ "/wiki/discovery"
    end
  end

  describe "idempotent seed" do
    test "articles count doesn't change on second migration run" do
      import Ecto.Query

      count_before =
        from(a in Article, where: a.scope == :system and a.slug in ^@expected_slugs)
        |> AdminRepo.aggregate(:count, :id)

      assert count_before >= 5

      # Re-running the seed would use ON CONFLICT ... DO UPDATE,
      # so count stays the same. We can't re-run migrations in a test,
      # but we verify the uniqueness constraint holds.
      for slug <- @expected_slugs do
        result =
          %Article{tenant_id: nil}
          |> Article.create_changeset(%{
            title: "Duplicate #{slug}",
            body: "Body",
            category: :reference,
            scope: :system,
            slug: slug
          })
          |> AdminRepo.insert()

        assert {:error, changeset} = result
        assert {"has already been taken", _} = changeset.errors[:slug]
      end
    end
  end

  describe "link-check mix task" do
    test "check_wiki_links passes with all valid links" do
      # The mix task is tested by running it directly. Since we're in a test,
      # we just verify the articles exist and cross-reference correctly.
      system_articles = Knowledge.list_system_articles()
      valid_slugs = MapSet.new(system_articles, & &1.slug)

      broken =
        Enum.flat_map(system_articles, fn article ->
          Regex.scan(~r|/wiki/([a-z0-9][a-z0-9-]*[a-z0-9])|, article.body || "")
          |> Enum.map(fn [_full, slug] -> slug end)
          |> Enum.reject(&MapSet.member?(valid_slugs, &1))
          |> Enum.map(&{article.slug, &1})
        end)

      assert broken == [], "Broken links: #{inspect(broken)}"
    end
  end
end
