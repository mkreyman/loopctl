defmodule Loopctl.Knowledge.ListIndexKeysetTest do
  @moduledoc """
  Context-level tests for `Loopctl.Knowledge.list_index_keyset/2` (US-27.9b).

  Proves the by-tag / by-source index keyset walk is gap-free, duplicate-free, and
  drift-free under concurrent inserts/archives (AC-27.9b.1 / .3 / TC-27.9b.1), that
  the `(inserted_at, id)` TUPLE tie-break walks batch-tied timestamps correctly, and
  that every query is tenant-scoped (AC-27.9b.4).
  """
  use Loopctl.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  # Walk the index keyset page-by-page, collecting ids across all categories. The
  # `mutate` callback runs BETWEEN pages so we can prove stability under concurrent
  # writes. Returns the ordered list of ids seen across the walk.
  defp walk(tenant_id, page_limit, opts, mutate \\ fn _page -> :ok end) do
    do_walk(tenant_id, page_limit, opts, mutate, nil, [], 0)
  end

  defp do_walk(_tid, _limit, _opts, _mutate, _cursor, _acc, n) when n > 10_000 do
    flunk("index keyset walk did not terminate — possible infinite loop")
  end

  defp do_walk(tenant_id, page_limit, opts, mutate, cursor, acc, n) do
    walk_opts =
      opts
      |> Keyword.put(:limit, page_limit)
      |> Keyword.put(:cursor, cursor)

    {:ok, %{results: results, next_cursor: next_cursor, limit: limit}} =
      Knowledge.list_index_keyset(tenant_id, walk_opts)

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

  describe "list_index_keyset/2 — ordering and shape" do
    test "orders by (inserted_at ASC, id ASC), published only" do
      tenant = fixture(:tenant)

      published =
        for i <- 1..5 do
          a = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "A#{i}"})
          a.id
        end

      # Draft excluded (the index is published-only).
      fixture(:article, %{tenant_id: tenant.id, status: :draft, title: "draft"})

      {:ok, %{results: results, next_cursor: next_cursor}} =
        Knowledge.list_index_keyset(tenant.id, limit: 20)

      assert is_nil(next_cursor)
      assert Enum.sort(Enum.map(results, & &1.id)) == Enum.sort(published)

      inserted_ats = Enum.map(results, & &1.inserted_at)
      assert inserted_ats == Enum.sort(inserted_ats, DateTime)
    end
  end

  describe "list_index_keyset/2 — by-tag gap-free walk (TC-27.9b.1)" do
    test "walks a tag to exhaustion exactly once" do
      tenant = fixture(:tenant)

      tagged =
        for i <- 1..23 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              tags: ["walk"],
              title: "n#{i}"
            })

          a.id
        end

      # An article with a different tag must not appear.
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["other"]})

      seen = walk(tenant.id, 5, tags: ["walk"])

      assert Enum.sort(seen) == Enum.sort(tagged)
      assert length(seen) == length(Enum.uniq(seen)), "no duplicates across pages"
      assert length(seen) == 23
    end

    test "by-tag walk is stable under concurrent inserts AND archives (the #175 incident)" do
      tenant = fixture(:tenant)

      original_ids =
        for i <- 1..20 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              tags: ["incident"],
              title: "orig#{i}"
            })

          a.id
        end

      mutate = fn page ->
        first = List.first(page)

        Article
        |> where([a], a.id == ^first.id)
        |> AdminRepo.update_all(set: [status: :archived])

        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          tags: ["incident"],
          title: "late-#{System.unique_integer([:positive])}"
        })
      end

      seen = walk(tenant.id, 4, [tags: ["incident"]], mutate)

      # Every ORIGINAL row appears exactly once — no offset drift, no skip from
      # archiving an already-seen row.
      for id <- original_ids do
        count = Enum.count(seen, &(&1 == id))
        assert count == 1, "original id #{id} seen #{count} times (expected exactly 1)"
      end

      assert length(seen) == length(Enum.uniq(seen)), "no duplicates in the whole walk"
    end
  end

  describe "list_index_keyset/2 — by-source filter" do
    test "filters by source_type and source_id" do
      tenant = fixture(:tenant)
      source = Ecto.UUID.generate()

      matching =
        for i <- 1..6 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              source_type: "ingestion",
              source_id: source,
              title: "src#{i}"
            })

          a.id
        end

      # Same source_type, different source_id → excluded.
      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        source_type: "ingestion",
        source_id: Ecto.UUID.generate()
      })

      seen = walk(tenant.id, 2, source_type: "ingestion", source_id: source)

      assert Enum.sort(seen) == Enum.sort(matching)
      assert length(seen) == 6
    end

    test "a malformed source_id matches nothing (no 500)" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published, source_type: "ingestion"})

      {:ok, %{results: results}} =
        Knowledge.list_index_keyset(tenant.id, source_id: "not-a-uuid", limit: 50)

      assert results == []
    end
  end

  describe "list_index_keyset/2 — batch-tied timestamps (TUPLE tie-break)" do
    test "walks rows sharing an identical inserted_at via the id tie-break" do
      tenant = fixture(:tenant)

      ids =
        for i <- 1..10 do
          a =
            fixture(:article, %{
              tenant_id: tenant.id,
              status: :published,
              tags: ["tie"],
              title: "tie#{i}"
            })

          a.id
        end

      tied = ~U[2026-06-24 09:00:00.000000Z]

      Article
      |> where([a], a.id in ^ids)
      |> AdminRepo.update_all(set: [inserted_at: tied])

      # Page size 3 forces boundaries WITHIN the tied batch.
      seen = walk(tenant.id, 3, tags: ["tie"])

      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(seen) == 10
      assert length(seen) == length(Enum.uniq(seen))
    end
  end

  describe "list_index_keyset/2 — tenant isolation (AC-27.9b.4)" do
    test "only returns the caller-tenant's rows" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      a_ids =
        for _ <- 1..4 do
          a = fixture(:article, %{tenant_id: tenant_a.id, status: :published, tags: ["x"]})
          a.id
        end

      for _ <- 1..4 do
        fixture(:article, %{tenant_id: tenant_b.id, status: :published, tags: ["x"]})
      end

      seen = walk(tenant_a.id, 2, tags: ["x"])

      assert Enum.sort(seen) == Enum.sort(a_ids)
      assert length(seen) == 4
    end

    test "project scope includes tenant-wide + project rows" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})

      tenant_wide =
        fixture(:article, %{tenant_id: tenant.id, status: :published, project_id: nil})

      project_specific =
        fixture(:article, %{tenant_id: tenant.id, status: :published, project_id: project.id})

      # An article in a DIFFERENT project must not appear.
      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        project_id: other_project.id
      })

      {:ok, %{results: results}} =
        Knowledge.list_index_keyset(tenant.id, project_id: project.id, limit: 50)

      ids = Enum.map(results, & &1.id)
      assert tenant_wide.id in ids
      assert project_specific.id in ids
      assert length(ids) == 2
    end
  end

  describe "index_keyset_query/2 — request-path query shape" do
    test "is tenant-scoped, published-only, ordered (inserted_at, id)" do
      tenant = fixture(:tenant)
      fixture(:article, %{tenant_id: tenant.id, status: :published})

      query = Knowledge.index_keyset_query(tenant.id, limit: 21)
      {sql, _params} = SQL.to_sql(:all, AdminRepo, query)

      assert sql =~ "tenant_id"
      assert sql =~ ~r/order by.*inserted_at.*id/i
      assert sql =~ ~r/limit/i
    end
  end
end
