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
