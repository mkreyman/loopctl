defmodule LoopctlWeb.KnowledgeFacetsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_tenant_key do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, raw_key}
  end

  describe "GET /api/v1/knowledge/count (#148 A2/A4)" do
    test "counts articles matching status + AND-tags without returning rows", %{conn: conn} do
      {tenant, raw_key} = setup_tenant_key()

      # Two articles tagged both book+hub (one draft), one tagged only book.
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "BH1",
        status: :published,
        tags: ["book", "hub"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "BH2",
        status: :draft,
        tags: ["book", "hub"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "B only",
        status: :published,
        tags: ["book"]
      })

      # AND-tag: both book and hub → 2 (any status)
      both =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/count?tags=book,hub&match=all")
        |> json_response(200)

      assert both["count"] == 2

      # status + AND-tag: published AND tagged both → 1
      pub_both =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/count?tags=book,hub&match=all&status=published")
        |> json_response(200)

      assert pub_both["count"] == 1

      # OR (default) tags=book,hub → all 3 (union)
      union =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/count?tags=book,hub")
        |> json_response(200)

      assert union["count"] == 3
    end

    test "rejects an invalid match with 400", %{conn: conn} do
      {_tenant, raw_key} = setup_tenant_key()

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/count?tags=book&match=bogus")
        |> json_response(400)

      assert resp["error"]["status"] == 400
      assert resp["error"]["message"] =~ "match"
    end

    test "tenant isolation: count only sees the caller's tenant", %{conn: conn} do
      {tenant_a, raw_key_a} = setup_tenant_key()
      tenant_b = fixture(:tenant)

      fixture(:article, %{tenant_id: tenant_a.id, title: "A", tags: ["shared"]})
      fixture(:article, %{tenant_id: tenant_b.id, title: "B", tags: ["shared"]})

      resp =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/count?tags=shared")
        |> json_response(200)

      assert resp["count"] == 1
    end
  end

  describe "GET /api/v1/knowledge/facets (#148 A3)" do
    test "counts distinct tags with a prefix filter, no rows", %{conn: conn} do
      {tenant, raw_key} = setup_tenant_key()

      fixture(:article, %{tenant_id: tenant.id, title: "b1", tags: ["book-aaa", "hub"]})
      fixture(:article, %{tenant_id: tenant.id, title: "b2", tags: ["book-aaa"]})
      fixture(:article, %{tenant_id: tenant.id, title: "b3", tags: ["book-bbb"]})
      fixture(:article, %{tenant_id: tenant.id, title: "n1", tags: ["notabook"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/facets?group_by=tag&tag_prefix=book-")
        |> json_response(200)

      # Two distinct book-* tags; book-aaa carried by 2 articles, book-bbb by 1.
      assert resp["meta"]["distinct_count"] == 2
      assert resp["meta"]["group_by"] == "tag"
      assert resp["data"]["book-aaa"] == 2
      assert resp["data"]["book-bbb"] == 1
      refute Map.has_key?(resp["data"], "hub")
      refute Map.has_key?(resp["data"], "notabook")
    end

    test "prefix is matched literally (LIKE wildcards escaped)", %{conn: conn} do
      {tenant, raw_key} = setup_tenant_key()

      fixture(:article, %{tenant_id: tenant.id, title: "p", tags: ["a_b"]})
      fixture(:article, %{tenant_id: tenant.id, title: "q", tags: ["axb"]})

      # "a_" must match only the literal "a_b", not "axb" (underscore is a LIKE wildcard).
      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/facets?group_by=tag&tag_prefix=a_")
        |> json_response(200)

      assert Map.has_key?(resp["data"], "a_b")
      refute Map.has_key?(resp["data"], "axb")
    end

    test "rejects an invalid group_by with 400", %{conn: conn} do
      {_tenant, raw_key} = setup_tenant_key()

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/facets?group_by=author")
        |> json_response(400)

      assert resp["error"]["status"] == 400
      assert resp["error"]["message"] =~ "group_by"
    end

    test "counts distinct articles, not tag occurrences (duplicate tags in an array)", %{
      conn: conn
    } do
      {tenant, raw_key} = setup_tenant_key()

      # A single article whose array stores the same tag twice must count once.
      fixture(:article, %{tenant_id: tenant.id, title: "dup", tags: ["dup", "dup"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/facets?group_by=tag&tag_prefix=dup")
        |> json_response(200)

      assert resp["data"]["dup"] == 1
      assert resp["meta"]["distinct_count"] == 1
    end

    test "limit caps facet rows; distinct_count stays true and truncated flags it", %{conn: conn} do
      {tenant, raw_key} = setup_tenant_key()

      for t <- ["t-a", "t-b", "t-c"] do
        fixture(:article, %{tenant_id: tenant.id, title: t, tags: [t]})
      end

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/facets?group_by=tag&tag_prefix=t-&limit=2")
        |> json_response(200)

      # Only 2 facet rows returned, but distinct_count reflects the true 3, and
      # truncated tells the caller the family was capped.
      assert map_size(resp["data"]) == 2
      assert resp["meta"]["distinct_count"] == 3
      assert resp["meta"]["truncated"] == true
    end

    test "rejects a non-UUID project_id with 400 (not a 500)", %{conn: conn} do
      {_tenant, raw_key} = setup_tenant_key()

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/facets?group_by=tag&project_id=not-a-uuid")
        |> json_response(400)

      assert resp["error"]["status"] == 400
      assert resp["error"]["message"] =~ "project_id"
    end
  end

  describe "GET /api/v1/knowledge/count — project_id validation (#148)" do
    test "rejects a non-UUID project_id with 400 (not a 500)", %{conn: conn} do
      {_tenant, raw_key} = setup_tenant_key()

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/count?project_id=not-a-uuid")
        |> json_response(400)

      assert resp["error"]["status"] == 400
      assert resp["error"]["message"] =~ "project_id"
    end
  end
end
