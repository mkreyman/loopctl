defmodule Loopctl.HeavyReadTest do
  @moduledoc """
  The structural tenant guard (AC-27.11.4) on `Loopctl.HeavyRead`: every heavy read
  requires a binary `tenant_id` AND a query that filters by `tenant_id` (incl. in a
  from/join subquery), and a tenant-isolation case (TC-27.11.2) proving tenant A
  cannot read tenant B's rows through the wrapper.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article

  import Ecto.Query

  describe "filters_by_tenant?/1 (structural predicate detection)" do
    test "true for a direct where on tenant_id" do
      assert HeavyRead.filters_by_tenant?(from(a in Article, where: a.tenant_id == ^"t"))
    end

    test "false for a query with no tenant_id filter" do
      refute HeavyRead.filters_by_tenant?(from(a in Article, where: a.status == :published))
      refute HeavyRead.filters_by_tenant?(Article)
    end

    test "true when the tenant_id filter is inside a FROM subquery (e.g. the count query)" do
      inner = from(a in Article, where: a.tenant_id == ^"t", where: not is_nil(a.embedding))
      assert HeavyRead.filters_by_tenant?(from(q in subquery(inner), select: count()))
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

    test "false when tenant_id only appears in select/order, not a filter" do
      # Selecting tenant_id is NOT filtering by it — must still be rejected.
      refute HeavyRead.filters_by_tenant?(from(a in Article, select: %{t: a.tenant_id}))
    end
  end

  describe "all/3 + one/3 guard" do
    test "raise ArgumentError when tenant_id is not a binary" do
      q = from(a in Article, where: a.tenant_id == ^"t")
      assert_raise ArgumentError, ~r/requires a binary tenant_id/, fn -> HeavyRead.all(nil, q) end
      assert_raise ArgumentError, ~r/requires a binary tenant_id/, fn -> HeavyRead.one(123, q) end
    end

    test "raise ArgumentError when the query has no tenant_id filter" do
      q = from(a in Article, where: a.status == :published)

      assert_raise ArgumentError, ~r/no tenant_id filter/, fn ->
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
  end
end
