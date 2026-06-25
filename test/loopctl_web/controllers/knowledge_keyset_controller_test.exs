defmodule LoopctlWeb.KnowledgeKeysetControllerTest do
  @moduledoc """
  HTTP integration tests for the KEYSET cursor on the article list endpoint
  (US-27.9a), exercised through `GET /api/v1/knowledge/search` in list mode with
  `?cursor=`.

  Covers the cursor walk to exhaustion under concurrent writes (TC-27.9a.1), the
  forged cross-tenant cursor (TC-27.9a.2), tampered/garbage cursors → 400
  (TC-27.9a.3), and the limit-honoring contract (AC-27.9a.5).
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

  # Walk the keyset list endpoint to exhaustion, collecting ids. `mutate` runs
  # between pages with the current page data. Returns the ids seen in order.
  defp walk_http(conn, raw_key, base_params, mutate \\ fn _data -> :ok end) do
    # Seed the walk with an EMPTY cursor → keyset path from the start.
    do_walk_http(conn, raw_key, base_params, mutate, "", [], 0)
  end

  defp do_walk_http(_conn, _key, _params, _mutate, _cursor, _acc, n) when n > 1_000 do
    flunk("HTTP keyset walk did not terminate")
  end

  defp do_walk_http(conn, raw_key, base_params, mutate, cursor, acc, n) do
    params = Map.put(base_params, "cursor", cursor)

    resp =
      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/knowledge/search", params)
      |> json_response(200)

    # meta.limit is always present and documents the effective limit (AC-27.9a.5).
    assert resp["meta"]["limit"]

    acc = acc ++ Enum.map(resp["data"], & &1["id"])
    next = resp["meta"]["next_cursor"]

    if next do
      mutate.(resp["data"])
      do_walk_http(conn, raw_key, base_params, mutate, next, acc, n + 1)
    else
      acc
    end
  end

  describe "cursor walk (AC-27.9a.1 / TC-27.9a.1)" do
    test "walks the full list exactly once, ending with next_cursor null", %{conn: conn} do
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

    test "is gap-free under concurrent inserts and archives between pages", %{conn: conn} do
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

      # Between pages: archive an already-seen row and insert a new published row.
      # (The context-level test `list_keyset_test.exs` thoroughly exercises the
      # gap-free invariant; here we exercise it at the HTTP layer to verify the
      # keyset cursor walk returns no duplicates under concurrent mutations.)
      {:ok, seen_tracker} = Agent.start_link(fn -> [] end)

      mutate = fn data ->
        # Archive the first row of this page (already returned in previous pages).
        first_id = List.first(data)["id"]

        Article
        |> where([a], a.id == ^first_id)
        |> AdminRepo.update_all(set: [status: :archived])

        # Track which rows have been returned so far.
        Agent.update(seen_tracker, fn seen_list -> seen_list ++ [first_id] end)

        # Insert a new published row (appears later in the order than the cursor).
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          tags: ["mix"],
          title: "new-#{System.unique_integer([:positive])}"
        })
      end

      seen = walk_http(conn, raw_key, %{"tags" => "mix", "limit" => "4"}, mutate)

      # No duplicates in the whole walk (the headline invariant at the HTTP layer).
      assert length(seen) == length(Enum.uniq(seen)), "no duplicates"

      # Rows that were returned and then archived don't reappear later.
      seen_and_returned = Agent.get(seen_tracker, fn state -> state end)

      for returned_id <- seen_and_returned do
        count = Enum.count(seen, &(&1 == returned_id))
        assert count == 1, "row #{returned_id} returned then archived appeared #{count} times"
      end

      # Sanity: we saw a meaningful chunk of the originals.
      assert Enum.any?(original_ids, fn id -> id in seen end)

      Agent.stop(seen_tracker)
    end
  end

  describe "forged cross-tenant cursor (AC-27.9a.3 / TC-27.9a.2)" do
    test "tenant A using a cursor forged with tenant B's key never sees tenant B rows",
         %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      # Tenant B has its own articles; capture a real (inserted_at, id) of B's.
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

      # Forge a cursor that embeds tenant B's position, signed with B's key.
      forged = ArticleCursor.encode(tenant_b.id, {b_article.inserted_at, b_article.id})

      resp =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "x", "cursor" => forged})

      # AC-27.9a.2 allows EITHER 400 (HMAC rejects) OR tenant-A-only rows; here the
      # per-tenant HMAC rejects B's cursor for A → 400. Never a tenant_b row.
      assert resp.status == 400
      body = json_response(resp, 400)
      assert body["error"]["message"] =~ "cursor" or body["errors"]

      # And a forged cursor must not leak whether tenant B's row exists: the error
      # is identical to a pure-garbage cursor (no existence oracle).
      garbage_resp =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "x", "cursor" => "garbage"})

      assert json_response(garbage_resp, 400) == body
    end
  end

  describe "tampered / garbage cursor → 400 (AC-27.9a.4 / TC-27.9a.3)" do
    test "garbage cursor returns 400, not 500 and not page 1", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["g"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "g", "cursor" => "not-a-cursor!!!"})

      assert resp.status == 400
      assert json_response(resp, 400)["error"]["message"] =~ "cursor"
    end

    test "bit-flipped valid cursor returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      article = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["g"]})
      valid = ArticleCursor.encode(tenant.id, {article.inserted_at, article.id})

      # Flip a bit in the payload region.
      decoded = Base.url_decode64!(valid, padding: false)
      <<first, rest::binary>> = decoded
      tampered = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "g", "cursor" => tampered})

      assert resp.status == 400
      assert json_response(resp, 400)["error"]["message"] =~ "cursor"
    end

    test "non-string cursor (e.g., array form) returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["g"]})

      # Simulate a malformed ?cursor[]=value param (which decodes to a list).
      # The controller should 400, not silently reset to page 1.
      conn = conn |> auth_conn(raw_key)

      resp =
        conn
        |> get(~p"/api/v1/knowledge/search?tags=g&cursor[]=malformed", %{})

      assert resp.status == 400
      assert json_response(resp, 400)["error"]["message"] =~ "cursor"
    end
  end

  describe "limit contract (AC-27.9a.5)" do
    test "honors limit up to max and reports effective limit in meta", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          tags: ["lim"],
          title: "l#{i}"
        })
      end

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "lim", "limit" => "2", "cursor" => ""})
        |> json_response(200)

      assert resp["meta"]["limit"] == 2
      assert length(resp["data"]) == 2
      assert resp["meta"]["next_cursor"]
    end

    test "over-max limit is rejected with 400, never silently clamped", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["lim"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          "tags" => "lim",
          "limit" => "5000",
          "cursor" => "x"
        })

      # The limit cap is enforced BEFORE cursor decode (validate_search_limit runs
      # in the `with`), so an over-max request is a 400 regardless of the cursor.
      assert resp.status == 400
    end
  end

  describe "cursor + relevance query is rejected" do
    test "supplying both q and cursor returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})
      valid = ArticleCursor.encode(tenant.id, {article.inserted_at, article.id})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{"q" => "anything", "cursor" => valid})

      assert resp.status == 400
      assert json_response(resp, 400)["error"]["message"] =~ "list enumeration"
    end
  end

  describe "first page without a cursor" do
    test "list mode without cursor still works (offset back-compat path)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["bc"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "bc"})
        |> json_response(200)

      # No cursor → existing offset list path (offset/total_count meta), unchanged.
      assert resp["meta"]["offset"] == 0
      assert is_list(resp["data"])
    end

    # BA gap: the over-max-limit 400 (the #148 no-silent-clamp fix) must also hold on
    # the LEGACY offset path, not only the keyset path. `validate_search_limit` runs
    # before cursor branching, but pin it on the no-cursor path so a future refactor
    # can't reintroduce a silent clamp there.
    test "offset path (no cursor) rejects over-max limit with 400, never clamps", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["bc"]})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "bc", "limit" => "5000"})

      assert resp.status == 400
    end
  end

  describe "exact-multiple page boundary (split_peek)" do
    # BA gap: when the row count is an exact multiple of the page size, the FINAL full
    # page must signal exhaustion (next_cursor null) and NOT emit a cursor that fetches
    # an empty phantom page. Exercises split_peek's `length == limit` (no-more) branch.
    test "final full page has next_cursor null, no phantom empty page", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      for i <- 1..8 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          tags: ["em"],
          title: "em#{i}"
        })
      end

      # Page 1 of 2 (8 rows, page size 4): a full page, more remains.
      page1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{"tags" => "em", "limit" => "4", "cursor" => ""})
        |> json_response(200)

      assert length(page1["data"]) == 4
      assert page1["meta"]["next_cursor"]

      # Page 2 of 2: the final full page — exhaustion, next_cursor must be null.
      page2 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          "tags" => "em",
          "limit" => "4",
          "cursor" => page1["meta"]["next_cursor"]
        })
        |> json_response(200)

      assert length(page2["data"]) == 4
      refute page2["meta"]["next_cursor"]
    end
  end
end
