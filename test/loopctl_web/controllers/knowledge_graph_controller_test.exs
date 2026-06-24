defmodule LoopctlWeb.KnowledgeGraphControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp setup_tenant_key do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, raw_key}
  end

  defp pub(tenant_id, title),
    do: fixture(:article, %{tenant_id: tenant_id, title: title, status: :published})

  defp link(tenant_id, src, tgt, rel \\ :relates_to) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: src.id,
      target_article_id: tgt.id,
      relationship_type: rel
    })
  end

  defp graph(conn, raw_key, query) do
    conn |> auth_conn(raw_key) |> get(~p"/api/v1/knowledge/graph?#{query}") |> json_response(200)
  end

  defp ids(body), do: body["nodes"] |> Enum.map(& &1["id"]) |> Enum.sort()

  describe "GET /api/v1/knowledge/graph (#149)" do
    test "depth 1 returns immediate neighbors, bidirectionally", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      a = pub(tenant.id, "A")
      b = pub(tenant.id, "B")
      c = pub(tenant.id, "C")
      # A→B (forward) and C→A (backward) — both must be reachable from A at depth 1.
      link(tenant.id, a, b)
      link(tenant.id, c, a)

      body = graph(conn, key, %{article_id: a.id, depth: 1})

      assert ids(body) == Enum.sort([a.id, b.id, c.id])
      assert body["node_count"] == 3
      assert body["truncated"] == false
      # depth labels: A=0, neighbors=1
      depths = Map.new(body["nodes"], &{&1["id"], &1["depth"]})
      assert depths[a.id] == 0
      assert depths[b.id] == 1
      assert depths[c.id] == 1
      # nodes carry title + category
      a_node = Enum.find(body["nodes"], &(&1["id"] == a.id))
      assert a_node["title"] == "A"
      assert a_node["category"]
      # edges carry the typed link
      assert Enum.any?(
               body["edges"],
               &(&1["source_article_id"] == a.id and &1["target_article_id"] == b.id)
             )
    end

    test "depth 2 reaches two hops but not three", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      [a, b, c, d] = for t <- ~w(A B C D), do: pub(tenant.id, t)
      link(tenant.id, a, b)
      link(tenant.id, b, c)
      link(tenant.id, c, d)

      body = graph(conn, key, %{article_id: a.id, depth: 2})

      assert ids(body) == Enum.sort([a.id, b.id, c.id])
      refute d.id in ids(body)
    end

    test "depth 3 reaches three hops", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      [a, b, c, d] = for t <- ~w(A B C D), do: pub(tenant.id, t)
      link(tenant.id, a, b)
      link(tenant.id, b, c)
      link(tenant.id, c, d)

      body = graph(conn, key, %{article_id: a.id, depth: 3})

      assert ids(body) == Enum.sort([a.id, b.id, c.id, d.id])
      assert body["node_count"] == 4
    end

    test "a cyclic graph terminates with no node visited twice", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      [a, b, c] = for t <- ~w(A B C), do: pub(tenant.id, t)
      # Triangle A→B→C→A
      link(tenant.id, a, b)
      link(tenant.id, b, c)
      link(tenant.id, c, a)

      body = graph(conn, key, %{article_id: a.id, depth: 3})

      node_ids = Enum.map(body["nodes"], & &1["id"])
      assert Enum.sort(node_ids) == Enum.sort([a.id, b.id, c.id])
      # No node appears twice.
      assert length(node_ids) == length(Enum.uniq(node_ids))
    end

    test "caps the result and sets truncated when the node limit is hit", %{conn: conn} do
      # config/test.exs sets max_graph_nodes: 10.
      {tenant, key} = setup_tenant_key()
      hub = pub(tenant.id, "Hub")

      for i <- 1..11 do
        n = pub(tenant.id, "N#{i}")
        link(tenant.id, hub, n)
      end

      body = graph(conn, key, %{article_id: hub.id, depth: 1})

      assert body["truncated"] == true
      assert body["node_count"] == 10
      assert length(body["nodes"]) == 10
    end

    test "depth out of range returns 400", %{conn: _conn} do
      {tenant, key} = setup_tenant_key()
      a = pub(tenant.id, "A")

      for d <- ["0", "4", "abc"] do
        resp =
          build_conn()
          |> auth_conn(key)
          |> get(~p"/api/v1/knowledge/graph?#{%{article_id: a.id, depth: d}}")
          |> json_response(400)

        assert resp["error"]["status"] == 400
      end
    end

    test "missing article_id returns 400", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()

      resp =
        conn |> auth_conn(key) |> get(~p"/api/v1/knowledge/graph") |> json_response(400)

      assert resp["error"]["message"] =~ "article_id"
    end

    test "nonexistent article returns 404", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()

      conn
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/graph?#{%{article_id: Ecto.UUID.generate()}}")
      |> json_response(404)
    end

    test "a draft start article returns 404 (published-only)", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      draft = fixture(:article, %{tenant_id: tenant.id, title: "Draft", status: :draft})

      conn
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/graph?#{%{article_id: draft.id}}")
      |> json_response(404)
    end

    test "draft neighbors are excluded from traversal (published-only)", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      a = pub(tenant.id, "A")
      draft = fixture(:article, %{tenant_id: tenant.id, title: "Draft", status: :draft})
      link(tenant.id, a, draft)

      body = graph(conn, key, %{article_id: a.id, depth: 2})

      assert ids(body) == [a.id]
      assert body["node_count"] == 1
    end

    test "tenant isolation: another tenant's article is not found", %{conn: conn} do
      {_tenant_a, key_a} = setup_tenant_key()
      tenant_b = fixture(:tenant)
      b_article = pub(tenant_b.id, "B-owned")

      conn
      |> auth_conn(key_a)
      |> get(~p"/api/v1/knowledge/graph?#{%{article_id: b_article.id}}")
      |> json_response(404)
    end
  end
end
