defmodule LoopctlWeb.WikiLiveTest do
  @moduledoc """
  Tests for US-26.0.3 — wiki LiveViews.
  """

  use LoopctlWeb.ConnCase, async: true

  import Loopctl.Fixtures
  import Phoenix.LiveViewTest

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article

  setup :verify_on_exit!

  defp create_system_article(attrs) do
    base = %{
      title: "Test Article #{System.unique_integer([:positive])}",
      body: "Body content for testing.",
      category: :pattern,
      scope: :system,
      status: :published
    }

    merged = Map.merge(base, attrs)

    %Article{tenant_id: nil}
    |> Article.create_changeset(merged)
    |> AdminRepo.insert!()
  end

  describe "GET /wiki (index)" do
    test "renders the wiki index page", %{conn: conn} do
      create_system_article(%{slug: "idx-article-1", title: "Test Article One"})

      {:ok, _view, html} = live(conn, ~p"/wiki")

      assert html =~ "loopctl Wiki"
      assert html =~ "Test Article One"
    end

    test "accessible without authentication", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      {:ok, _view, html} = live(conn, ~p"/wiki")
      assert html =~ "loopctl Wiki"
    end

    # Note: empty state test removed because seed migration installs
    # system articles that are visible via AdminRepo across all tests.

    test "renders category badges in the featured grid", %{conn: conn} do
      create_system_article(%{slug: "cat-pattern", title: "A Pattern", category: :pattern})
      create_system_article(%{slug: "cat-conv", title: "A Convention", category: :convention})

      {:ok, _view, html} = live(conn, ~p"/wiki")
      assert html =~ "Featured articles"
      assert html =~ "pattern"
      assert html =~ "convention"
    end

    test "landing page shows a grid of at least 8 featured articles with view counts",
         %{conn: conn} do
      # 10 freshly-inserted system articles are the newest rows, so they sit
      # at the top of the featured ranking (0-view articles are ordered by
      # inserted_at desc) and all fit within the 16-article grid.
      articles =
        for n <- 1..10 do
          create_system_article(%{
            slug: "featured-#{n}",
            title: "Featured Article #{n}"
          })
        end

      # Give the first article real view events so its count is non-zero and
      # it ranks ahead of the zero-view articles.
      hot = hd(articles)
      for _ <- 1..3, do: fixture(:article_access_event, %{article_id: hot.id})

      {:ok, _view, html} = live(conn, ~p"/wiki")

      # At least 8 of the 10 titles render in the grid.
      present = Enum.count(articles, fn a -> html =~ a.title end)
      assert present >= 8

      # View counts render, including the hot article's non-zero count.
      assert html =~ "3 views"
      assert html =~ "0 views"
    end
  end

  describe "GET /wiki/:slug (show)" do
    test "renders a system article", %{conn: conn} do
      create_system_article(%{
        slug: "test-render-article",
        title: "Chain of Custody Test",
        body: "## Introduction\n\nThis is the **chain of custody** protocol."
      })

      {:ok, _view, html} = live(conn, ~p"/wiki/test-render-article")

      assert html =~ "Chain of Custody Test"
      assert html =~ "<strong>chain of custody</strong>"
    end

    test "renders 404 for unknown slug", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/wiki/does-not-exist")

      assert html =~ "not found"
      assert html =~ "Browse all articles"
    end

    test "includes sidebar with all system articles", %{conn: conn} do
      create_system_article(%{slug: "sidebar-a", title: "Sidebar A"})
      art = create_system_article(%{slug: "sidebar-b", title: "Sidebar B"})

      {:ok, _view, html} = live(conn, ~p"/wiki/#{art.slug}")

      assert html =~ "Sidebar A"
      assert html =~ "Sidebar B"
      assert html =~ "wiki-sidebar"
    end

    test "follows design system (dark mode, slate palette)", %{conn: conn} do
      create_system_article(%{slug: "ds-test", title: "Design Test", body: "Hello"})

      {:ok, _view, html} = live(conn, ~p"/wiki/ds-test")

      assert html =~ "slate-"
      refute html =~ "rounded-xl"
      refute html =~ "gradient-"
    end
  end
end
