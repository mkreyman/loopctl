defmodule LoopctlWeb.WikiLiveTest do
  @moduledoc """
  Tests for US-26.0.3 — wiki LiveViews.
  """

  use LoopctlWeb.ConnCase, async: true

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

    test "groups articles by category", %{conn: conn} do
      create_system_article(%{slug: "cat-pattern", title: "A Pattern", category: :pattern})
      create_system_article(%{slug: "cat-conv", title: "A Convention", category: :convention})

      {:ok, _view, html} = live(conn, ~p"/wiki")
      assert html =~ "pattern"
      assert html =~ "convention"
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

    test "neutralizes executable markup in article body (sanitized render)", %{conn: conn} do
      # A malicious system article body: raw script tag plus an event-handler
      # attribute smuggled through an image. The public render must strip/escape
      # these so no executable markup reaches the visitor.
      create_system_article(%{
        slug: "xss-render-article",
        title: "Untrusted Body",
        body: """
        # Heading

        <script>window.__pwned = true;</script>

        <img src="x" onerror="window.__pwned = true;" />

        Normal paragraph after.
        """
      })

      {:ok, _view, html} = live(conn, ~p"/wiki/xss-render-article")

      refute html =~ "<script>"
      refute html =~ "onerror="
      # Legitimate surrounding content still renders.
      assert html =~ "Normal paragraph after."
    end

    test "renders legitimate markdown (headings, lists, links, code)", %{conn: conn} do
      create_system_article(%{
        slug: "md-features-article",
        title: "Markdown Features",
        body: """
        ## Introduction

        This is the **chain of custody** protocol.

        - first item
        - second item

        See the [audit log](/wiki/md-features-article) for details.

        Inline `mix precommit` command.

        ```elixir
        def hello, do: :world
        ```
        """
      })

      {:ok, _view, html} = live(conn, ~p"/wiki/md-features-article")

      # Bold survives.
      assert html =~ "<strong>chain of custody</strong>"
      # List items survive.
      assert html =~ "<li>first item</li>"
      assert html =~ "<li>second item</li>"
      # Internal link survives with its href and text.
      assert html =~ ~s(href="/wiki/md-features-article")
      assert html =~ "audit log"
      # Inline and fenced code survive.
      assert html =~ "<code"
      assert html =~ "mix precommit"
      assert html =~ "def hello"
    end

    test "renders GitHub-Flavored Markdown (tables, strikethrough, autolinks)", %{conn: conn} do
      create_system_article(%{
        slug: "gfm-features-article",
        title: "GFM Features",
        body: """
        ## Comparison

        | Feature | Status |
        |---------|--------|
        | Tables  | works  |

        ~~deprecated~~ approach; see www.example.com for details.
        """
      })

      {:ok, _view, html} = live(conn, ~p"/wiki/gfm-features-article")

      # GFM pipe table renders as an actual table, not raw pipe text.
      assert html =~ "<table"
      assert html =~ "<td>works</td>"
      # Strikethrough renders.
      assert html =~ "<del>deprecated</del>"
      # Bare-URL autolink becomes an anchor.
      assert html =~ ~s(href="http://www.example.com")
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
