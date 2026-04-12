defmodule LoopctlWeb.SystemArticleControllerTest do
  @moduledoc """
  Tests for US-26.0.3 — public system article JSON API.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article

  setup :verify_on_exit!

  defp create_system_article(attrs) do
    base = %{
      title: "API Test #{System.unique_integer([:positive])}",
      body: "Body for testing.",
      category: :pattern,
      scope: :system,
      status: :published
    }

    merged = Map.merge(base, attrs)

    %Article{tenant_id: nil}
    |> Article.create_changeset(merged)
    |> AdminRepo.insert!()
  end

  describe "GET /api/v1/articles/system" do
    test "lists all published system articles without auth", %{conn: _conn} do
      create_system_article(%{slug: "api-a", title: "API Article A"})
      create_system_article(%{slug: "api-b", title: "API Article B"})

      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/api/v1/articles/system")

      resp = json_response(conn, 200)
      titles = Enum.map(resp["data"], & &1["title"])
      assert "API Article A" in titles
      assert "API Article B" in titles
    end

    test "returns single article by slug param", %{conn: _conn} do
      create_system_article(%{slug: "api-slug-test", title: "Slug Test"})

      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/api/v1/articles/system?slug=api-slug-test")

      resp = json_response(conn, 200)
      assert resp["data"]["title"] == "Slug Test"
      assert resp["data"]["scope"] == "system"
    end

    test "returns 404 for unknown slug", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/api/v1/articles/system?slug=nonexistent")

      assert json_response(conn, 404)["error"]["message"] =~ "not found"
    end
  end
end
