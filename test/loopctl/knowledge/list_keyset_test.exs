defmodule Loopctl.Knowledge.ListKeysetTest do
  @moduledoc """
  Context-level tests for `Loopctl.Knowledge.list_keyset/2` (US-27.9a).

  Proves the keyset walk is gap-free, duplicate-free, and drift-free under
  concurrent inserts/archives (AC-27.9a.1), that the `(inserted_at, id)` TUPLE
  tie-break walks batch-tied timestamps correctly, and that every query is
  tenant-scoped (the cross-tenant isolation case).
  """
  use Loopctl.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  # Walk a tenant's articles page-by-page via list_keyset, collecting ids. The
  # `mutate` callback runs BETWEEN pages so we can prove stability under
  # concurrent writes. Returns the ordered list of ids seen across the walk.
  defp walk(tenant_id, page_limit, opts, mutate \\ fn _page -> :ok end) do
    do_walk(tenant_id, page_limit, opts, mutate, nil, [], 0)
  end

  defp do_walk(_tid, _limit, _opts, _mutate, _cursor, _acc, n) when n > 10_000 do
    flunk("keyset walk did not terminate — possible infinite loop")
  end

  defp do_walk(tenant_id, page_limit, opts, mutate, cursor, acc, n) do
    walk_opts =
      opts
      |> Keyword.put(:limit, page_limit)
      |> Keyword.put(:cursor, cursor)

    {:ok, %{results: results, next_cursor: next_cursor, limit: limit}} =
      Knowledge.list_keyset(tenant_id, walk_opts)

    assert limit == page_limit
    assert length(results) <= page_limit

    acc = acc ++ Enum.map(results, & &1.id)

    if next_cursor do
      mutate.(results)
      do_walk(tenant_id, page_limit, opts, mutate, next_cursor, acc, n + 1)
    else
      acc
    end
  end

  describe "list_keyset/2 — ordering and shape" do
    test "orders by (inserted_at ASC, id ASC) and returns the metadata shape" do
      tenant = fixture(:tenant)

      for i <- 1..5 do
        fixture(:article, %{tenant_id: tenant.id, status: :published, title: "A#{i}"})
      end

      {:ok, %{results: results, next_cursor: next_cursor, limit: limit}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 20)

      assert limit == 20
      assert is_nil(next_cursor)
      assert length(results) == 5

      inserted_ats = Enum.map(results, & &1.inserted_at)
      assert inserted_ats == Enum.sort(inserted_ats, DateTime)
    end

    test "limit is clamped to max_page_size as an internal safety net" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, %{limit: limit}} =
        Knowledge.list_keyset(tenant.id, limit: 10_000)

      assert limit == Knowledge.max_page_size()
    end
  end

  describe "list_keyset/2 — gap-free walk (AC-27.9a.1 / TC-27.9a.1)" do
    test "walks all rows exactly once with next_cursor null at the end" do
      tenant = fixture(:tenant)

      ids =
        for i <- 1..23 do
          a = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "n#{i}"})
          a.id
        end

      seen = walk(tenant.id, 5, status: :published)

      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(seen) == length(Enum.uniq(seen)), "no duplicates across pages"
      assert length(seen) == 23
    end

    test "is stable under concurrent inserts AND archives between pages" do
      tenant = fixture(:tenant)

      original_ids =
        for i <- 1..20 do
          a = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "orig#{i}"})
          a.id
        end

      # Between every page: archive one already-seen row (must still not reappear)
      # and insert a brand-new published row AT THE END of the order (a fresh
      # inserted_at, so it sorts after the cursor — it may or may not be seen,
      # which is fine; what matters is no dup and no gap for rows present the
      # whole walk).
      mutate = fn page ->
        # Archive the first row of this page (already returned → must not recur).
        first = List.first(page)

        Article
        |> where([a], a.id == ^first.id)
        |> AdminRepo.update_all(set: [status: :archived])

        # Insert a new published row (appears later in the order than the cursor).
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "late-#{System.unique_integer([:positive])}"
        })
      end

      seen = walk(tenant.id, 4, [status: :published], mutate)

      # Every ORIGINAL row appears exactly once (no offset drift skipped any, and
      # archiving an already-seen row did not duplicate or skip a neighbor).
      for id <- original_ids do
        count = Enum.count(seen, &(&1 == id))
        assert count == 1, "original id #{id} seen #{count} times (expected exactly 1)"
      end

      assert length(seen) == length(Enum.uniq(seen)), "no duplicates in the whole walk"
    end

    # BA gap: the symmetric drift case — a row that sorts AFTER the cursor is archived
    # BEFORE the walk reaches it. A forward-only keyset walk must then simply not
    # return it (it correctly vanishes), with no error and no gap for its neighbors.
    test "a row archived before the walk reaches it vanishes, leaving no gap" do
      tenant = fixture(:tenant)

      ids =
        for i <- 1..20 do
          a = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "orig#{i}"})
          a.id
        end

      # The last-inserted row has the latest inserted_at, so it sorts LAST. Archiving
      # it after every page (idempotent) removes it after page 1 — long before the
      # cursor (page size 4) reaches it near page 5.
      future_id = List.last(ids)

      mutate = fn _page ->
        Article
        |> where([a], a.id == ^future_id)
        |> AdminRepo.update_all(set: [status: :archived])
      end

      seen = walk(tenant.id, 4, [status: :published], mutate)

      refute future_id in seen, "a row archived before being reached must not appear"

      # Its disappearance created no gap: every other original is still seen once.
      for id <- List.delete(ids, future_id) do
        assert Enum.count(seen, &(&1 == id)) == 1,
               "neighbor #{id} should appear exactly once after a future row was archived"
      end
    end
  end

  describe "list_keyset/2 — batch-tied timestamps (TUPLE tie-break, AC-27.9a.2)" do
    test "walks rows that share an identical inserted_at via the id tie-break" do
      tenant = fixture(:tenant)

      ids =
        for i <- 1..10 do
          a = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "tie#{i}"})
          a.id
        end

      # Force ALL ten rows to the SAME inserted_at (what bulk insert_all does per
      # batch). Now inserted_at alone is non-unique; only the (inserted_at, id)
      # tuple keyset can walk them gap-free.
      tied = ~U[2026-06-24 09:00:00.000000Z]

      Article
      |> where([a], a.id in ^ids)
      |> AdminRepo.update_all(set: [inserted_at: tied])

      # Page size 3 forces multiple page boundaries to land WITHIN the tied batch.
      seen = walk(tenant.id, 3, status: :published)

      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(seen) == 10
      assert length(seen) == length(Enum.uniq(seen))
    end
  end

  describe "list_keyset/2 — tenant isolation" do
    test "only returns the caller-tenant's rows" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      a_ids =
        for _ <- 1..4 do
          a = fixture(:article, %{tenant_id: tenant_a.id, status: :published})
          a.id
        end

      for _ <- 1..4 do
        fixture(:article, %{tenant_id: tenant_b.id, status: :published})
      end

      seen = walk(tenant_a.id, 2, status: :published)

      assert Enum.sort(seen) == Enum.sort(a_ids)
      assert length(seen) == 4
    end

    test "applies status/category/tags filters like list_filtered" do
      tenant = fixture(:tenant)

      published =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          category: :pattern,
          tags: ["keep"]
        })

      # Drafts and non-matching category/tags are excluded.
      fixture(:article, %{
        tenant_id: tenant.id,
        status: :draft,
        category: :pattern,
        tags: ["keep"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        category: :decision,
        tags: ["other"]
      })

      {:ok, %{results: results}} =
        Knowledge.list_keyset(tenant.id,
          status: :published,
          category: :pattern,
          tags: ["keep"],
          limit: 50
        )

      assert Enum.map(results, & &1.id) == [published.id]
    end
  end

  describe "list_keyset/2 — include_body + has_more (US-27.10)" do
    test "body-less is the default: no :body key on any row" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published, body: "secret body"})

      {:ok, %{results: [row], include_body: include_body}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 20)

      refute include_body
      refute Map.has_key?(row, :body)
    end

    test "include_body: true threads :body into each row's select" do
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        body: "the full body content"
      })

      {:ok, %{results: [row], include_body: include_body}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 20, include_body: true)

      assert include_body
      assert row.body == "the full body content"
    end

    test "has_more mirrors the keyset peek (next_cursor != nil), not a COUNT" do
      tenant = fixture(:tenant)

      for i <- 1..5 do
        fixture(:article, %{tenant_id: tenant.id, status: :published, title: "h#{i}"})
      end

      # Page of 2 over 5 rows: more remains.
      {:ok, %{next_cursor: next_cursor, has_more: has_more}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 2)

      assert has_more
      refute is_nil(next_cursor)

      # A page large enough to exhaust the set: has_more false, next_cursor nil.
      {:ok, %{next_cursor: last_cursor, has_more: last_has_more}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 50)

      refute last_has_more
      assert is_nil(last_cursor)
    end

    test "body-less default is never byte_truncated" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published, body: "x"})

      {:ok, %{byte_truncated: byte_truncated}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 20)

      refute byte_truncated
    end

    # The test budget is 100_000 bytes (config/test.exs). Two 40 KB bodies fit
    # (80 KB); the 3rd would exceed it, so the page trims to 2, sets byte_truncated,
    # and recomputes next_cursor from the LAST KEPT row so the walk resumes over the
    # dropped row with no gap.
    test "include_body trims the page by the byte budget and resumes drift-free" do
      tenant = fixture(:tenant)
      big = String.duplicate("x", 40_000)

      ids =
        for i <- 1..3 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              title: "bt#{i}",
              body: big
            })

          a.id
        end

      {:ok, %{results: page1, next_cursor: cursor1, has_more: more1, byte_truncated: trunc1}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 25, include_body: true)

      assert trunc1
      assert length(page1) == 2
      assert more1
      refute is_nil(cursor1)

      {:ok, %{results: page2, next_cursor: cursor2, byte_truncated: trunc2}} =
        Knowledge.list_keyset(tenant.id,
          status: :published,
          limit: 25,
          include_body: true,
          cursor: cursor1
        )

      assert length(page2) == 1
      refute trunc2
      assert is_nil(cursor2)

      seen = Enum.map(page1 ++ page2, & &1.id)
      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(seen) == length(Enum.uniq(seen)), "no duplicate across the trim boundary"
    end

    test "always keeps ≥1 row even if a single body alone exceeds the budget" do
      tenant = fixture(:tenant)
      # One body alone (120 KB) exceeds the 100 KB test budget; progress requires
      # keeping it anyway (the always-take-≥1 rule).
      huge = String.duplicate("y", 120_000)

      a = fixture(:article, %{tenant_id: tenant.id, status: :published, body: huge})

      {:ok, %{results: results, byte_truncated: byte_truncated}} =
        Knowledge.list_keyset(tenant.id, status: :published, limit: 25, include_body: true)

      assert length(results) == 1
      assert hd(results).id == a.id
      # A single over-budget row is not a truncation of OTHER rows — nothing was dropped.
      refute byte_truncated
    end

    # Scenario B (peek=true AND byte-trim drops rows): a page that has MORE matching
    # rows than `limit` (so the peek says has_more) AND is byte-trimmed below `limit`.
    # The recomputed cursor must walk over the dropped rows with no gap/dup and the walk
    # must end on a real (non-phantom) page. Also pins the invariant
    # `byte_truncated == true ⟹ next_cursor != nil` on every page.
    test "byte-trimmed multi-page walk (peek + trim) is gap-free and never strands a row" do
      tenant = fixture(:tenant)
      big = String.duplicate("z", 40_000)

      ids =
        for i <- 1..12 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              tags: ["sb"],
              title: "sb#{i}",
              body: big
            })

          a.id
        end

      # limit 5 ⇒ early pages have a peek row (has_more), and the 100 KB budget trims
      # each page to 2 rows (2×40 KB ≤ 100 KB; the 3rd would exceed) ⇒ byte_truncated.
      seen = scenario_b_walk(tenant.id, nil, [])

      assert Enum.sort(seen) == Enum.sort(ids), "every row served exactly across the walk"
      assert length(seen) == length(Enum.uniq(seen)), "no duplicate across trim+peek seams"
      assert length(seen) == 12
    end
  end

  # Walk include_body pages, asserting per-page that a byte-truncated page always
  # carries a continuation cursor (never strands the dropped rows) and never returns
  # an empty page while claiming more remains.
  defp scenario_b_walk(_tid, _cursor, acc) when length(acc) > 1_000,
    do: flunk("scenario B walk did not terminate")

  defp scenario_b_walk(tenant_id, cursor, acc) do
    {:ok, %{results: page, next_cursor: next, byte_truncated: trunc?, has_more: more?}} =
      Knowledge.list_keyset(tenant_id,
        status: :published,
        tags: ["sb"],
        limit: 5,
        include_body: true,
        cursor: cursor
      )

    if trunc?, do: assert(next, "byte_truncated page must carry a next_cursor")
    if more?, do: assert(page != [], "has_more must not be signalled on an empty page")

    acc = acc ++ Enum.map(page, & &1.id)
    if next, do: scenario_b_walk(tenant_id, next, acc), else: acc
  end

  describe "list_keyset/2 — include_body respects visibility scope (AC-27.10.5)" do
    test "a private memory's body never leaks to a non-owning agent" do
      tenant = fixture(:tenant)
      owner_agent = fixture(:agent, %{tenant_id: tenant.id})
      other_agent = fixture(:agent, %{tenant_id: tenant.id})

      private =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          body: "PRIVATE BODY — must not leak",
          metadata: %{"visibility" => "private", "agent_id" => to_string(owner_agent.id)}
        })

      # The non-owning agent enumerates WITH include_body. The visibility filter
      # is applied before the projection, so the private row is excluded entirely
      # — its body is never selected, let alone returned.
      {:ok, %{results: results}} =
        Knowledge.list_keyset(tenant.id,
          status: :published,
          include_body: true,
          limit: 50,
          visibility_agent_id: to_string(other_agent.id)
        )

      refute Enum.any?(results, &(&1.id == private.id))
      refute Enum.any?(results, fn r -> Map.get(r, :body) == "PRIVATE BODY — must not leak" end)

      # The OWNER, by contrast, does see its own private memory's body.
      {:ok, %{results: owner_results}} =
        Knowledge.list_keyset(tenant.id,
          status: :published,
          include_body: true,
          limit: 50,
          visibility_agent_id: to_string(owner_agent.id)
        )

      owner_row = Enum.find(owner_results, &(&1.id == private.id))
      assert owner_row.body == "PRIVATE BODY — must not leak"
    end

    test "include_body never returns a body across tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant_b.id,
        status: :published,
        body: "TENANT B BODY"
      })

      {:ok, %{results: results}} =
        Knowledge.list_keyset(tenant_a.id, status: :published, include_body: true, limit: 50)

      assert results == []
    end
  end

  describe "keyset_query/2 — request-path query shape" do
    test "is the query list_keyset runs, and is tenant-scoped" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published})

      query = Knowledge.keyset_query(tenant.id, status: :published, limit: 21)
      {sql, _params} = SQL.to_sql(:all, AdminRepo, query)

      assert sql =~ "tenant_id"
      assert sql =~ ~r/order by.*inserted_at.*id/i
      assert sql =~ ~r/limit/i
    end

    test "body-less by default; include_body: true selects the body column (US-27.10)" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published})

      {bodyless_sql, _} =
        :all
        |> SQL.to_sql(AdminRepo, Knowledge.keyset_query(tenant.id, status: :published))

      refute bodyless_sql =~ ~r/\bbody\b/i

      {full_sql, _} =
        :all
        |> SQL.to_sql(
          AdminRepo,
          Knowledge.keyset_query(tenant.id, status: :published, include_body: true)
        )

      assert full_sql =~ ~r/\bbody\b/i
    end
  end
end
