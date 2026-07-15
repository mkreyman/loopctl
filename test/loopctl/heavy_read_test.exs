defmodule Loopctl.HeavyReadTest do
  @moduledoc """
  The structural tenant guard (AC-27.11.4) on `Loopctl.HeavyRead`: every heavy read
  requires a binary `tenant_id` AND a query whose every base-table source (the FROM
  table and each joined table, incl. inside from/join subqueries) is scoped by a
  conjunctive `tenant_id == ^tenant_id` equality bound to the caller's tenant_id —
  rejecting an unscoped FROM, an unscoped join, and an OR-bypass; plus tenant
  isolation (TC-27.11.2) and the stream/transaction paths.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.HeavyRead
  alias Loopctl.HeavyRead.OverloadedError
  alias Loopctl.HeavyRead.TenantGate
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

    test "FALSE when the FROM table is unscoped and only a WHERE-IN subquery is tenant-filtered" do
      # The outer `articles` source itself carries no tenant equality — indirect scoping
      # via a WHERE-IN subquery is rejected (fail-closed); scope the FROM table directly.
      sub = from(x in Article, where: x.tenant_id == ^"t", select: x.id)
      refute HeavyRead.filters_by_tenant?(from(a in Article, where: a.id in subquery(sub)))
    end

    test "FALSE when the FROM table is unscoped even if a JOINED table is scoped" do
      # Attack: primary table `a` returns all tenants; only `b` is scoped.
      refute HeavyRead.filters_by_tenant?(
               from(a in Article, join: b in Article, on: b.tenant_id == ^"t" and b.id != a.id)
             )
    end

    test "FALSE when a joined table has no tenant filter on it" do
      refute HeavyRead.filters_by_tenant?(
               from(a in Article,
                 where: a.tenant_id == ^"t",
                 join: l in Loopctl.Knowledge.ArticleLink,
                 on: l.source_article_id == a.id
               )
             )
    end

    test "FALSE when the tenant predicate is OR-ed with a broadening condition" do
      refute HeavyRead.filters_by_tenant?(
               from(a in Article, where: a.tenant_id == ^"t" or a.status == :published)
             )
    end

    test "TRUE when a joined table IS tenant-scoped in its ON (suggested-links anti-join shape)" do
      assert HeavyRead.filters_by_tenant?(
               from(a in Article,
                 where: a.tenant_id == ^"t",
                 join: l in Loopctl.Knowledge.ArticleLink,
                 on: l.tenant_id == ^"t" and l.source_article_id == a.id
               )
             )
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

  describe "filters_by_subject?/1 + all_memory/4 guard (US-28.2)" do
    alias Loopctl.Memory.Memory, as: MemorySchema

    test "true when the outermost query carries a conjunctive subject_id equality" do
      assert HeavyRead.filters_by_subject?(from(m in MemorySchema, where: m.subject_id == ^"s"))
    end

    test "true when subject_id is on the OUTER query over a from-subquery (recall shape)" do
      inner =
        from(m in MemorySchema, where: m.tenant_id == ^"t", select: %{subject_id: m.subject_id})

      assert HeavyRead.filters_by_subject?(
               from(c in subquery(inner), where: c.subject_id == ^"s")
             )
    end

    test "false when subject_id only appears inside an inner subquery, not the outer" do
      inner = from(m in MemorySchema, where: m.subject_id == ^"s", select: %{id: m.id})
      refute HeavyRead.filters_by_subject?(from(c in subquery(inner), select: count()))
    end

    test "false when subject_id equality is OR-ed with a broadening condition" do
      refute HeavyRead.filters_by_subject?(
               from(m in MemorySchema, where: m.subject_id == ^"s" or m.confidence > 0.0)
             )
    end

    test "false when subject_id scopes only a JOINED source, not the primary from binding" do
      # The returned `from` rows are only tenant-scoped; a JOINED table carries the
      # subject predicate. The output could still surface cross-subject rows from the
      # unscoped `from` binding, so the guard must reject — matching the tenant guard's
      # every-output-source strength (the subject predicate must sit on binding 0).
      refute HeavyRead.filters_by_subject?(
               from(m in MemorySchema,
                 join: m2 in MemorySchema,
                 on: m2.tenant_id == m.tenant_id and m2.subject_id == ^"s",
                 where: m.tenant_id == ^"t"
               )
             )
    end

    test "all_memory/4 raises when subject_id is only on a joined source, not the from" do
      tenant = Ecto.UUID.generate()

      q =
        from(m in MemorySchema,
          join: m2 in MemorySchema,
          on: m2.tenant_id == ^tenant and m2.subject_id == ^"subj",
          where: m.tenant_id == ^tenant
        )

      assert_raise ArgumentError, ~r/subject/, fn ->
        HeavyRead.all_memory(tenant, "subj", q, [])
      end
    end

    test "all_memory/4 raises when the query lacks a subject_id predicate" do
      tenant = Ecto.UUID.generate()
      q = from(m in MemorySchema, where: m.tenant_id == ^tenant)

      assert_raise ArgumentError, ~r/subject/, fn ->
        HeavyRead.all_memory(tenant, "subj", q, [])
      end
    end

    test "all_memory/4 raises when the subject predicate is bound to a DIFFERENT subject" do
      tenant = Ecto.UUID.generate()
      q = from(m in MemorySchema, where: m.tenant_id == ^tenant and m.subject_id == ^"other")

      assert_raise ArgumentError, ~r/subject/, fn ->
        HeavyRead.all_memory(tenant, "subj", q, [])
      end
    end

    test "all_memory/4 still enforces the tenant guard on every base-table source" do
      q = from(m in MemorySchema, where: m.subject_id == ^"subj")

      assert_raise ArgumentError, ~r/scoped to the given tenant/, fn ->
        HeavyRead.all_memory(Ecto.UUID.generate(), "subj", q, [])
      end
    end

    test "all_memory/4 requires binary tenant_id AND subject_id" do
      q = from(m in MemorySchema, where: m.tenant_id == ^"t" and m.subject_id == ^"s")
      assert_raise ArgumentError, fn -> HeavyRead.all_memory(nil, "s", q, []) end
      assert_raise ArgumentError, fn -> HeavyRead.all_memory("t", nil, q, []) end
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

      assert_raise ArgumentError, ~r/scoped to the given tenant/, fn ->
        HeavyRead.all(Ecto.UUID.generate(), q)
      end
    end

    test "raise when the tenant_id equality is bound to a DIFFERENT tenant than the caller" do
      other = Ecto.UUID.generate()
      q = from(a in Article, where: a.tenant_id == ^other)

      assert_raise ArgumentError, ~r/scoped to the given tenant/, fn ->
        HeavyRead.all(Ecto.UUID.generate(), q)
      end
    end
  end

  describe "per-tenant in-flight gate wired into the wrapper (US-37.5, AC-37.5.3)" do
    # Force over-cap deterministically for a FRESH random tenant WITHOUT global config
    # mutation: pre-fill its in-flight counter to exactly the configured cap with one
    # high-weight acquire, so the very next wired heavy read (adding weight >= 1)
    # exceeds the cap and is shed. Another tenant's counter is untouched, so it is
    # served — the isolation the gate guarantees.
    setup do
      cap = TenantGate.cap()
      {:ok, cap: cap}
    end

    test "an over-cap tenant's API read RAISES OverloadedError while another tenant is served",
         %{cap: cap} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      a1 = fixture(:article, %{tenant_id: tenant_a.id, title: "A-only"})
      b1 = fixture(:article, %{tenant_id: tenant_b.id, title: "B-only"})

      query_for = fn tid ->
        from(a in Article, where: a.tenant_id == ^tid, select: %{id: a.id})
      end

      # Saturate A's slice exactly.
      assert TenantGate.acquire(tenant_a.id, cap, cap) == :ok

      # A's next heavy read (default on_overload: :raise → API path) is SHED as a 429.
      assert_raise OverloadedError, fn ->
        HeavyRead.all(tenant_a.id, query_for.(tenant_a.id), HeavyRead.opts(:enumeration))
      end

      # B — sharing the same node-local gate — is unaffected: it gets real rows, not a
      # pool-exhaustion crash. Isolation: A's saturation never touched B's counter.
      results_b =
        HeavyRead.all(tenant_b.id, query_for.(tenant_b.id), HeavyRead.opts(:enumeration))

      assert Enum.map(results_b, & &1.id) == [b1.id]

      # Cleanup the pre-filled budget so the shared VM-wide counter doesn't leak.
      TenantGate.release(tenant_a.id, cap)
      assert a1.id
    end

    test "on_overload: :tag returns {:error, :heavy_read_overloaded} (search keyword-fallback path)",
         %{cap: cap} do
      tenant = fixture(:tenant)
      _ = fixture(:article, %{tenant_id: tenant.id})
      query = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      assert TenantGate.acquire(tenant.id, cap, cap) == :ok

      # With :tag, an over-cap shed returns the tagged tuple (search degrades to keyword
      # fallback) instead of raising — the graceful path for the semantic search caller.
      assert HeavyRead.all(tenant.id, query, [
               {:on_overload, :tag} | HeavyRead.opts(:semantic_search)
             ]) ==
               {:error, :heavy_read_overloaded}

      TenantGate.release(tenant.id, cap)
    end

    test "under cap, the wired gate is transparent — a normal read returns rows and frees its slot" do
      tenant = fixture(:tenant)
      a1 = fixture(:article, %{tenant_id: tenant.id})
      query = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      results = HeavyRead.all(tenant.id, query, HeavyRead.opts(:enumeration))
      assert Enum.map(results, & &1.id) == [a1.id]

      # The slot was released in the `after` — the tenant holds zero budget afterward.
      assert TenantGate.count(tenant.id) == 0
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
      assert_raise ArgumentError, ~r/scoped to the given tenant/, fn ->
        HeavyRead.all(tenant.id, from(a in Article, where: a.status == :draft))
      end
    end

    test "value-bound scoping holds THROUGH a from-subquery (not just structurally)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      a1 = fixture(:article, %{tenant_id: tenant_a.id})
      _b1 = fixture(:article, %{tenant_id: tenant_b.id})

      inner = from(a in Article, where: a.tenant_id == ^tenant_a.id, select: %{id: a.id})
      count_query = from(s in subquery(inner), select: count())

      # Runs (no false-reject) AND is scoped: counts only tenant A's row.
      assert HeavyRead.one(tenant_a.id, count_query) == 1

      # A from-subquery scoped to a DIFFERENT tenant is rejected for caller A.
      other_inner = from(a in Article, where: a.tenant_id == ^tenant_b.id, select: %{id: a.id})

      assert_raise ArgumentError, ~r/scoped to the given tenant/, fn ->
        HeavyRead.one(tenant_a.id, from(s in subquery(other_inner), select: count()))
      end

      assert a1.tenant_id == tenant_a.id
    end
  end

  describe "stream/3 + transaction/2" do
    test "stream/3 applies the same guard (raises on an unscoped query)" do
      assert_raise ArgumentError, ~r/scoped to the given tenant/, fn ->
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

    test "transaction/2 :statement_timeout issues SET LOCAL on the txn connection (end-to-end)" do
      # Exercise the REAL wrapper path: HeavyRead.transaction -> resolved repo -> SET LOCAL,
      # observed from inside the body via SHOW (proves the override is live on this txn's
      # connection — the mechanism US-27.16's export depends on).
      {:ok, shown} =
        HeavyRead.transaction(
          fn ->
            %{rows: [[v]]} = HeavyRead.repo().query!("SHOW statement_timeout")
            v
          end,
          statement_timeout: 5_000
        )

      assert shown == "5s"
    end

    test "transaction/2 with :statement_timeout runs the body and returns its value" do
      assert {:ok, 42} = HeavyRead.transaction(fn -> 42 end, statement_timeout: 5_000)
    end

    test "transaction/2 rejects :statement_timeout that is non-integer, zero, or a Multi" do
      for bad <- ["nope", 0, -1] do
        assert_raise ArgumentError, ~r/statement_timeout/, fn ->
          HeavyRead.transaction(fn -> :ok end, statement_timeout: bad)
        end
      end

      assert_raise ArgumentError, ~r/statement_timeout/, fn ->
        HeavyRead.transaction(Ecto.Multi.new(), statement_timeout: 1_000)
      end
    end
  end

  # NOTE (US-38.4): the per-query `hnsw.ef_search` tests that PRIME the VM-global
  # `SystemConfig "hnsw_ef_search"` persistent_term key live in the sibling `async: false`
  # `Loopctl.HeavyReadHnswEfSearchTest` (test/loopctl/heavy_read_hnsw_ef_search_test.exs).
  # They were split out because that key is also read by real ANN reads in other `async: true`
  # files (dual_index_recall_test, vector_search_test), so priming it from an async module
  # would let a concurrent cross-file reader observe the primed value. This file stays
  # `async: true` — it mutates no global state.
end
