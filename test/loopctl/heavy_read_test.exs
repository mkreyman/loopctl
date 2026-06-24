defmodule Loopctl.HeavyReadTest do
  @moduledoc """
  The structural tenant guard (AC-27.11.4) on `Loopctl.HeavyRead`: every heavy read
  requires a binary `tenant_id` AND a query containing a `tenant_id == ^tenant_id`
  equality (incl. in a from/join/where-in subquery) bound to the caller's tenant_id;
  plus tenant-isolation (TC-27.11.2) and the stream/transaction paths.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article

  import Ecto.Query

  describe "filters_by_tenant?/1 (structural equality detection)" do
    test "true for a direct `tenant_id == ^x` equality" do
      assert HeavyRead.filters_by_tenant?(from(a in Article, where: a.tenant_id == ^"t"))
    end

    test "false for non-equality tenant predicates (!=, is_nil) — not scoping" do
      refute HeavyRead.filters_by_tenant?(from(a in Article, where: a.tenant_id != ^"t"))
      refute HeavyRead.filters_by_tenant?(from(a in Article, where: is_nil(a.tenant_id)))
    end

    test "false for a query with no tenant_id filter" do
      refute HeavyRead.filters_by_tenant?(from(a in Article, where: a.status == :published))
      refute HeavyRead.filters_by_tenant?(Article)
    end

    test "false when tenant_id only appears in select, not a filter" do
      refute HeavyRead.filters_by_tenant?(from(a in Article, select: %{t: a.tenant_id}))
    end

    test "true when the tenant_id equality is inside a FROM subquery (search count shape)" do
      inner = from(a in Article, where: a.tenant_id == ^"t", where: not is_nil(a.embedding))
      assert HeavyRead.filters_by_tenant?(from(q in subquery(inner), select: count()))
    end

    test "true when the tenant_id equality is only inside a JOIN subquery (distant_pairs shape)" do
      cand =
        from(a in Article,
          where: a.tenant_id == ^"t",
          select: %{id: a.id, embedding: a.embedding}
        )

      pairs =
        from(a in subquery(cand),
          join: b in subquery(cand),
          on: a.id < b.id,
          where: fragment("(? <=> ?) BETWEEN ? AND ?", a.embedding, b.embedding, ^0.3, ^0.7),
          select: count()
        )

      assert HeavyRead.filters_by_tenant?(pairs)
    end

    test "true when the tenant_id equality is inside a WHERE ... IN (subquery)" do
      sub = from(x in Article, where: x.tenant_id == ^"t", select: x.id)
      assert HeavyRead.filters_by_tenant?(from(a in Article, where: a.id in subquery(sub)))
    end

    test "true for the production suggested-links candidate query (subquery + anti-join)" do
      query =
        Loopctl.Knowledge.suggestion_candidates_query(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          List.duplicate(0.1, 1536),
          0.5,
          5,
          nil
        )

      assert HeavyRead.filters_by_tenant?(query)
    end
  end

  describe "all/3 + one/3 guard" do
    test "raise ArgumentError when tenant_id is not a binary" do
      q = from(a in Article, where: a.tenant_id == ^"t")
      assert_raise ArgumentError, ~r/requires a binary tenant_id/, fn -> HeavyRead.all(nil, q) end
      assert_raise ArgumentError, ~r/requires a binary tenant_id/, fn -> HeavyRead.one(123, q) end
    end

    test "raise ArgumentError when the query has no tenant_id equality" do
      q = from(a in Article, where: a.status == :published)

      assert_raise ArgumentError, ~r/not scoped to the given tenant/, fn ->
        HeavyRead.all(Ecto.UUID.generate(), q)
      end
    end

    test "raise when the tenant_id equality is bound to a DIFFERENT tenant than the caller" do
      other = Ecto.UUID.generate()
      q = from(a in Article, where: a.tenant_id == ^other)

      assert_raise ArgumentError, ~r/not scoped to the given tenant/, fn ->
        HeavyRead.all(Ecto.UUID.generate(), q)
      end
    end
  end

  describe "tenant isolation through the heavy-read wrapper (TC-27.11.2)" do
    test "a heavy read for tenant A returns no tenant B rows" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      a1 = fixture(:article, %{tenant_id: tenant_a.id, title: "A-only"})
      _b1 = fixture(:article, %{tenant_id: tenant_b.id, title: "B-only"})

      query =
        from(a in Article,
          where: a.tenant_id == ^tenant_a.id,
          select: %{id: a.id, title: a.title}
        )

      results = HeavyRead.all(tenant_a.id, query)

      assert Enum.map(results, & &1.id) == [a1.id]
      refute Enum.any?(results, &(&1.title == "B-only"))
    end

    test "the guard is load-bearing: an unscoped query cannot reach the BYPASSRLS pool" do
      tenant = fixture(:tenant)
      _ = fixture(:article, %{tenant_id: tenant.id})

      # Even with valid data present, an unscoped query is refused before the repo runs.
      assert_raise ArgumentError, ~r/not scoped to the given tenant/, fn ->
        HeavyRead.all(tenant.id, from(a in Article, where: a.status == :draft))
      end
    end
  end

  describe "stream/3 + transaction/2" do
    test "stream/3 applies the same guard (raises on an unscoped query)" do
      assert_raise ArgumentError, ~r/not scoped to the given tenant/, fn ->
        HeavyRead.stream(Ecto.UUID.generate(), from(a in Article, where: a.status == :draft))
      end
    end

    test "stream/3 inside transaction/2 yields the tenant's rows" do
      tenant = fixture(:tenant)
      art = fixture(:article, %{tenant_id: tenant.id, title: "streamed"})

      query = from(a in Article, where: a.tenant_id == ^tenant.id, select: a.id)

      {:ok, ids} =
        HeavyRead.transaction(fn ->
          tenant.id |> HeavyRead.stream(query) |> Enum.to_list()
        end)

      assert ids == [art.id]
    end

    test "transaction/2 with :statement_timeout runs the body and returns its value" do
      # The opt is threaded and the body runs (SET LOCAL is harmless on the test repo);
      # the pool-level interaction is proven against the real pool in heavy_read_repo_test.
      assert {:ok, 42} = HeavyRead.transaction(fn -> 42 end, statement_timeout: 5_000)
    end

    test "transaction/2 rejects :statement_timeout with a non-integer or a Multi" do
      assert_raise ArgumentError, ~r/statement_timeout/, fn ->
        HeavyRead.transaction(fn -> :ok end, statement_timeout: "nope")
      end

      assert_raise ArgumentError, ~r/statement_timeout/, fn ->
        HeavyRead.transaction(Ecto.Multi.new(), statement_timeout: 1_000)
      end
    end
  end
end
