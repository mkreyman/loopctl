defmodule Loopctl.E2E.KnowledgeRetrievalJourneyTest do
  @moduledoc """
  End-to-end journey for the crown-jewel KB retrieval path.

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e`
  or `mix test --only e2e`. Unlike the focused controller/context unit tests,
  this exercises the FULL cross-context journey a live agent takes — seed an
  article, then retrieve it both through the `Loopctl.Knowledge` context path
  AND through the HTTP `/api/v1/knowledge/search` endpoint — and asserts tenant
  isolation (tenant A's article is invisible to tenant B).

  This is the regression net for the exact capability the production system is
  serving right now: agents retrieving knowledge.
  """
  use LoopctlWeb.ConnCase, async: true

  @moduletag :e2e

  alias Loopctl.Knowledge

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "knowledge retrieval journey" do
    test "a seeded published article is retrievable via the context and the HTTP endpoint",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # A distinctive term so the match is unambiguous within the test tenant.
      marker = "zorptango#{System.unique_integer([:positive])}"

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "#{marker} retrieval pattern",
          body: "The #{marker} pattern documents how agents retrieve knowledge.",
          category: :pattern,
          status: :published,
          tags: ["retrieval", marker]
        })

      # 1) Context path — the actual retrieval function the controller calls.
      assert {:ok, %{results: results}} = Knowledge.search_keyword(tenant.id, marker, limit: 5)
      assert Enum.any?(results, fn r -> r.id == article.id end)

      # 2) HTTP path — the full stack an agent hits (auth + visibility + RLS).
      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: marker, mode: "keyword", limit: 3})

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert article.id in ids

      hit = Enum.find(body["data"], &(&1["id"] == article.id))
      assert hit["title"] == "#{marker} retrieval pattern"
      assert hit["category"] == "pattern"
      # Search returns snippets/metadata, never the full body.
      refute Map.has_key?(hit, "body")
    end

    test "tenant isolation: tenant B cannot retrieve tenant A's article", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      {raw_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      marker = "isolationkw#{System.unique_integer([:positive])}"

      article_a =
        fixture(:article, %{
          tenant_id: tenant_a.id,
          title: "#{marker} tenant-A secret",
          body: "Tenant A's private #{marker} knowledge.",
          category: :pattern,
          status: :published,
          tags: [marker]
        })

      # POSITIVE CONTROL: tenant A's OWN key finds the article — proves the marker
      # is genuinely retrievable, so a green isolation result below means "isolation
      # works", not "search regressed to returning nothing for everyone".
      assert {:ok, %{results: results_a}} =
               Knowledge.search_keyword(tenant_a.id, marker, limit: 5)

      assert Enum.any?(results_a, fn r -> r.id == article_a.id end)

      conn_a =
        build_conn()
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/search", %{q: marker, mode: "keyword", limit: 3})

      assert article_a.id in Enum.map(json_response(conn_a, 200)["data"], & &1["id"])

      # ISOLATION — context path: a tenant-B-scoped search never sees tenant A's row.
      assert {:ok, %{results: results_b}} =
               Knowledge.search_keyword(tenant_b.id, marker, limit: 5)

      refute Enum.any?(results_b, fn r -> r.id == article_a.id end)

      # ISOLATION — HTTP path: tenant B's agent key gets no such row for the query.
      conn =
        conn
        |> auth_conn(raw_key_b)
        |> get(~p"/api/v1/knowledge/search", %{q: marker, mode: "keyword", limit: 3})

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute article_a.id in ids
    end
  end
end
