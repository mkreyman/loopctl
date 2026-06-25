defmodule LoopctlWeb.KnowledgeIndexKeysetControllerTest do
  @moduledoc """
  HTTP integration tests for the KEYSET cursor on the knowledge index endpoint
  (US-27.9b), exercised through `GET /api/v1/knowledge/index` with `?cursor=`.

  Covers the by-tag/by-source cursor walk to exhaustion under concurrent writes
  (TC-27.9b.1 / AC-27.9b.3), the forged cross-tenant cursor (AC-27.9b.4), tampered/
  garbage cursors → 400, the index_keyset search_mode/meta contract, and the
  back-compat offset path (no cursor → grouped + total_count, unchanged).
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleCursor

  import Ecto.Query

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Flatten the grouped `data` map into a list of article ids across all categories.
  defp page_ids(resp) do
    resp["data"]
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1["id"])
  end

  # Walk the index keyset endpoint to exhaustion, collecting ids. `mutate` runs
  # between pages with the current page response. Returns the ids seen in order.
  defp walk_http(conn, raw_key, base_params, mutate \\ fn _resp -> :ok end) do
    do_walk_http(conn, raw_key, base_params, mutate, "", [], 0)
  end

  defp do_walk_http(_conn, _key, _params, _mutate, _cursor, _acc, n) when n > 1_000 do
    flunk("HTTP index keyset walk did not terminate")
  end

  defp do_walk_http(conn, raw_key, base_params, mutate, cursor, acc, n) do
    params = Map.put(base_params, "cursor", cursor)

    resp =
      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/knowledge/index", params)
      |> json_response(200)

    assert resp["meta"]["limit"]
    assert resp["meta"]["search_mode"] == "index_keyset"

    acc = acc ++ page_ids(resp)
    next = resp["meta"]["next_cursor"]

    if next do
      mutate.(resp)
      do_walk_http(conn, raw_key, base_params, mutate, next, acc, n + 1)
    else
      acc
    end
  end

  describe "cursor walk (TC-27.9b.1 / AC-27.9b.3)" do
    test "walks a tag to exhaustion exactly once, ending with next_cursor null", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      ids =
        for i <- 1..17 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              category: :pattern,
              tags: ["walk"],
              title: "w#{i}"
            })

          a.id
        end

      seen = walk_http(conn, raw_key, %{"tags" => "walk", "limit" => "5"})

      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(seen) == length(Enum.uniq(seen))
    end

    test "by-tag walk is gap-free under concurrent inserts and archives", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      original_ids =
        for i <- 1..16 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              tags: ["mix"],
              title: "orig#{i}"
            })

          a.id
        end

      {:ok, seen_tracker} = Agent.start_link(fn -> [] end)

      mutate = fn resp ->
        first_id = resp |> page_ids() |> List.first()

        Article
        |> where([a], a.id == ^first_id)
        |> AdminRepo.update_all(set: [status: :archived])

        Agent.update(seen_tracker, fn s -> s ++ [first_id] end)

        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          tags: ["mix"],
          title: "new-#{System.unique_integer([:positive])}"
        })
      end

      seen = walk_http(conn, raw_key, %{"tags" => "mix", "limit" => "4"}, mutate)

      assert length(seen) == length(Enum.uniq(seen)), "no duplicates"

      for returned_id <- Agent.get(seen_tracker, & &1) do
        count = Enum.count(seen, &(&1 == returned_id))
        assert count == 1, "row #{returned_id} returned then archived appeared #{count} times"
      end

      assert Enum.any?(original_ids, fn id -> id in seen end)
      Agent.stop(seen_tracker)
    end

    test "by-source walk to exhaustion", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      source = Ecto.UUID.generate()

      ids =
        for i <- 1..9 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              source_type: "ingestion",
              source_id: source,
              title: "s#{i}"
            })

          a.id
        end

      # A different source must not leak in.
      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        source_type: "ingestion",
        source_id: Ecto.UUID.generate()
      })

      seen =
        walk_http(conn, raw_key, %{
          "source_type" => "ingestion",
          "source_id" => source,
          "limit" => "3"
        })

      assert Enum.sort(seen) == Enum.sort(ids)
    end
  end

  describe "forged / tampered cursor → 400 (AC-27.9b.4)" do
    test "tenant A using a cursor forged with tenant B's key is rejected, never crosses",
         %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      b_article =
        fixture(:article, %{tenant_id: tenant_b.id, status: :published, tags: ["x"]})

      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant_a.id,
          status: :published,
          tags: ["x"],
          title: "a#{i}"
        })
      end

      forged = ArticleCursor.encode(tenant_b.id, {b_article.inserted_at, b_article.id})

      resp =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/index", %{"tags" => "x", "cursor" => forged})

      assert resp.status == 400
      body = json_response(resp, 400)

      # Identical to a pure-garbage cursor (no existence oracle for B's row).
      garbage_resp =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/index", %{"tags" => "x", "cursor" => "garbage"})

      assert json_response(garbage_resp, 400) == body
    end

    test "garbage cursor returns 400, not 500 and not page 1", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["g"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index", %{"tags" => "g", "cursor" => "not-a-cursor!!!"})

      assert resp.status == 400
      assert json_response(resp, 400)["error"]["message"] =~ "cursor"
    end

    test "bit-flipped valid cursor returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["g"]})
      valid = ArticleCursor.encode(tenant.id, {article.inserted_at, article.id})

      decoded = Base.url_decode64!(valid, padding: false)
      <<first, rest::binary>> = decoded
      tampered = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index", %{"tags" => "g", "cursor" => tampered})

      assert resp.status == 400
    end

    test "non-string cursor (array form) returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["g"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index?tags=g&cursor[]=malformed", %{})

      assert resp.status == 400
    end
  end

  describe "meta contract (AC-27.9b.1)" do
    test "first page documents next_cursor/has_more/limit/count; final page exhausts",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      for i <- 1..7 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          tags: ["contract"],
          title: "c#{i}"
        })
      end

      page1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index", %{
          "tags" => "contract",
          "limit" => "3",
          "cursor" => ""
        })
        |> json_response(200)

      assert page1["meta"]["next_cursor"]
      assert page1["meta"]["has_more"] == true
      assert page1["meta"]["limit"] == 3
      assert page1["meta"]["count"] == 3
      assert page1["meta"]["count"] == length(page_ids(page1))
      assert page1["meta"]["search_mode"] == "index_keyset"
      # offset-path-only keys are absent on the keyset path.
      refute Map.has_key?(page1["meta"], "total_count")
      refute Map.has_key?(page1["meta"], "offset")
    end
  end

  describe "back-compat offset path (no cursor)" do
    test "index without cursor still offset-paginates (grouped + total_count), unchanged",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          category: :pattern,
          tags: ["bc"],
          title: "bc#{i}"
        })
      end

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index", %{"tags" => "bc"})
        |> json_response(200)

      # Offset path meta is unchanged: total_count/offset/limit/categories, no cursor.
      assert resp["meta"]["offset"] == 0
      assert resp["meta"]["total_count"] == 3
      assert is_map(resp["meta"]["categories"])
      refute Map.has_key?(resp["meta"], "next_cursor")
      # data is grouped by category.
      assert is_map(resp["data"])
      assert length(page_ids(resp)) == 3
    end
  end
end
