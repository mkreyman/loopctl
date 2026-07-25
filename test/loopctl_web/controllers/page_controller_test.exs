defmodule LoopctlWeb.PageControllerTest do
  use LoopctlWeb.ConnCase, async: true

  # TC-18.1.1: GET / returns 200 HTML with key content and dark class
  describe "GET /" do
    test "returns 200 with HTML content", %{conn: conn} do
      conn = get(conn, "/")

      assert conn.status == 200
      assert response_content_type(conn, :html)
    end

    test "contains loopctl branding", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "loopctl"
      assert body =~ "Get Started"
    end

    test "has dark class on html element", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ ~r/<html[^>]*class="dark"/
    end

    test "contains nav links", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "Features"
      assert body =~ "GitHub"
    end
  end

  describe "GET /docs" do
    test "returns 200 with HTML content", %{conn: conn} do
      conn = get(conn, "/docs")

      assert conn.status == 200
      assert response_content_type(conn, :html)
    end

    test "contains all section headings", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      assert body =~ ~s(id="overview")
      assert body =~ ~s(id="orchestrator")
      assert body =~ ~s(id="agents")
      assert body =~ ~s(id="review")
      assert body =~ ~s(id="hooks")
      assert body =~ ~s(id="setup")
    end

    test "contains page title and dark class", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      assert body =~ "Configuration Guide"
      assert body =~ ~r/<html[^>]*class="dark"/
    end

    test "contains nav with Docs link highlighted", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      assert body =~ "<nav"
      assert body =~ "Docs"
      assert body =~ "loopctl"
    end

    test "contains code blocks for all config sections", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      assert body =~ "orchestrator-command"
      assert body =~ "implementation-agent"
      assert body =~ "security-adversary"
      assert body =~ "review-pipeline-flow"
      assert body =~ "keep-working"
      assert body =~ ".mcp.json"
      assert body =~ "CLAUDE.md"
    end

    test "contains TOC sidebar", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      assert body =~ "On this page"
    end

    test "does not contain forbidden project-specific strings", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      # Strip GitHub URLs before checking — the repo URL legitimately contains the author name
      body_without_github = String.replace(body, ~r|https://github\.com/[^\s"<]+|, "")

      refute body_without_github =~ "freight"
      refute body_without_github =~ "pilot"
      refute body_without_github =~ "billing"
      refute body_without_github =~ "reportex"
      refute body_without_github =~ "beelink"
      refute body_without_github =~ "192.168"
      refute body_without_github =~ "kreyman"
      refute body_without_github =~ "open.brain"
      refute body_without_github =~ "blockit"
      refute body_without_github =~ "mac-mini"
      refute body_without_github =~ "caregiver"
      refute body_without_github =~ "timesheet"
      refute body_without_github =~ "trucking"
    end
  end

  # TC-18.1.2: API routes still return JSON
  describe "API routes unaffected" do
    test "GET /api/v1/ returns JSON", %{conn: conn} do
      conn = get(conn, "/api/v1/")

      assert json_response(conn, 200)
      content_type = conn |> get_resp_header("content-type") |> hd()
      assert content_type =~ "application/json"
      refute content_type =~ "text/html"
    end
  end

  # TC-18.1.3: Landing page has semantic HTML elements
  describe "landing page structure" do
    test "contains nav, features, footer, code block, and viewport meta", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "<nav"
      assert body =~ ~s(id="features")
      assert body =~ "<footer"
      assert body =~ "<code"
      assert body =~ ~s(name="viewport")
    end
  end

  # TC-18.1.4: Root layout has charset, viewport, Geist font link, app CSS, dark class
  describe "root layout elements" do
    test "has charset, viewport, Geist font, app.css, and dark class", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ ~s(charset="utf-8")
      assert body =~ ~s(name="viewport")
      assert body =~ "Geist"
      assert body =~ "app.css"
      assert body =~ ~r/<html[^>]*class="dark"/
    end
  end

  # #516 regression guard: PageController pages render self-contained full HTML
  # documents with `layout: false`. A pipeline-wide root layout would double-wrap
  # them (two <!DOCTYPE>, two <html>, two <head>, assets loaded twice). The existing
  # `=~` assertions all survive a double-wrapped document, so these count occurrences
  # to fail if the root layout ever leaks back onto the shared :browser pipeline.
  describe "single HTML document (no root-layout double-wrap)" do
    for path <- ["/", "/docs", "/terms", "/privacy"] do
      test "GET #{path} returns exactly one HTML document", %{conn: conn} do
        body = conn |> get(unquote(path)) |> html_response(200)

        assert count_occurrences(body, "<!DOCTYPE html>") == 1
        assert count_occurrences(body, "<html") == 1
        assert count_occurrences(body, "<head>") == 1
        assert count_occurrences(body, "<body") == 1
      end
    end
  end

  defp count_occurrences(string, substring) do
    string |> String.split(substring) |> length() |> Kernel.-(1)
  end

  # TC-18.1.5: GET /nonexistent-page returns 404 HTML
  describe "error pages" do
    test "GET /nonexistent-page returns 404 HTML", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/nonexistent-page")

      assert conn.status == 404
    end
  end
end
