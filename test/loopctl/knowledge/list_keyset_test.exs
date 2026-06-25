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
  end
end
