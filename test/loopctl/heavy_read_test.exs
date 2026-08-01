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

    test "the semantic side-table COUNT query passes the guard via its OUTER binding, not its WHERE subquery" do
      # Review, finding 4: `Knowledge.semantic_side_table_count_query/4` embeds an
      # OR-broadened `a.tenant_id == ^t or a.scope == :system` subquery in a WHERE
      # `ae.article_id in subquery(...)`. The guard does NOT inspect where-clause
      # subquery sources — it accepts the query ONLY because the OUTER `article_embeddings`
      # binding carries a conjunctive `ae.tenant_id == ^t`. Pin BOTH halves so the
      # reliance is enforced, not incidental:
      #
      #   (a) the real query passes;
      assert HeavyRead.filters_by_tenant?(
               Loopctl.Knowledge.semantic_side_table_count_query("t", 768, :published, [])
             )

      #   (b) the SAME shape with the outer tenant scope removed (leaning ONLY on the
      #       OR-broadened WHERE-IN subquery) is REJECTED — proving a future edit that
      #       placed a genuinely unscoped subquery in the WHERE cannot slip past.
      or_broadened_sub =
        from(a in Article, where: a.tenant_id == ^"t" or a.scope == :system, select: a.id)

      unscoped_variant =
        from(ae in Loopctl.Knowledge.ArticleEmbedding,
          where: ae.dim == 768,
          where: ae.live_denorm,
          where: ae.article_id in subquery(or_broadened_sub),
          select: count()
        )

      refute HeavyRead.filters_by_tenant?(unscoped_variant)
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

    test "a nested heavy read does NOT leak its statement_timeout to the enclosing txn" do
      # `SET LOCAL` scopes to the TOP-LEVEL transaction: a savepoint that COMMITS merges
      # the override into the enclosing transaction, arming this read's aggressive deadline
      # over every later statement there. Under Sandbox that is EVERY heavy read. Deleting
      # the `Loopctl.LocalGuc` restore must fail here.
      repo = HeavyRead.repo()
      before = show_statement_timeout(repo)
      tenant = fixture(:tenant)

      HeavyRead.all(tenant.id, from(a in Article, where: a.tenant_id == ^tenant.id),
        statement_timeout: 1_234
      )

      assert show_statement_timeout(repo) == before
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

  # A repo whose round trip EXITS, which is how DBConnection/Postgrex report a pool that
  # is not started (`:noproc`) or wedged — they do not raise, so a `rescue` alone misses
  # them and the exit escapes `scoped/3`'s `after`.
  defmodule ExitingRepo do
    # The REAL shape DBConnection/Postgrex exits with when the pool is not started: a
    # `{reason, call}` TUPLE, not a bare atom. A fake that exits with `:noproc` would let a
    # tagger that only handles atoms look correct while degrading every production exit to
    # "unknown".
    def query!(_sql, _params \\ [], _opts \\ []),
      do: exit({:noproc, {DBConnection, :execute, []}})
  end

  # Only the CAPTURE round trip fails; the body's `SET LOCAL` and restore's `set_config` go
  # to the real Repo. That split is what makes the capture-failure FALLBACK observable — with
  # a repo that fails everything, restore fails too and the reset can never be asserted.
  defmodule CaptureFailingRepo do
    def query!(sql, params \\ [], opts \\ [])

    def query!("SELECT current_setting" <> _, _params, _opts),
      do: exit({:noproc, {DBConnection, :execute, []}})

    def query!(sql, params, opts), do: Loopctl.Repo.query!(sql, params, opts)
  end

  defmodule AbortedTxnRepo do
    # What Postgres answers once the CALLER's transaction is already aborted: the body
    # raised (most often a 57014 cancel), so every later statement — including restore's —
    # comes back 25P02.
    def query!(_sql, _params \\ [], _opts \\ []) do
      raise %Postgrex.Error{postgres: %{code: :in_failed_sql_transaction}}
    end
  end

  # Records the opts each statement was issued with, then delegates to the real Repo so the
  # queries still behave. Asserting on `mode:` needs the call itself, not its result.
  defmodule OptsRecordingRepo do
    def query!(sql, params \\ [], opts \\ []) do
      send(self(), {:issued, sql, opts})
      Loopctl.Repo.query!(sql, params, opts)
    end
  end

  describe "LocalGuc best-effort bookkeeping" do
    test "capture degrades to [] instead of aborting the caller's read" do
      assert Loopctl.LocalGuc.capture(ExitingRepo, ["statement_timeout"]) == []
    end

    test "capture runs under mode: :savepoint, like restore" do
      # Without it, a failure on the capture round trip aborts the ENCLOSING transaction
      # (25P02) before the caller's work has run at all — so every later statement in the
      # caller's Multi fails citing a query it never issued, and `capture_failed/2` returns
      # its tidy `:error` into a transaction that is already unusable. restore/2 has always
      # passed it; capture is the side that runs first and needs it more.
      Loopctl.Repo.transaction(fn ->
        assert [{"statement_timeout", _}] =
                 Loopctl.LocalGuc.capture(OptsRecordingRepo, ["statement_timeout"])
      end)

      assert_received {:issued, "SELECT current_setting" <> _, opts}

      assert Keyword.get(opts, :mode) == :savepoint,
             "the capture SELECT must be savepoint-scoped so its failure cannot poison " <>
               "the caller's transaction"
    end

    test "restore swallows an exit, so it cannot destroy a successful result" do
      assert Loopctl.LocalGuc.restore(ExitingRepo, [{"statement_timeout", "1234ms"}]) == :ok

      assert Loopctl.LocalGuc.scoped(ExitingRepo, ["statement_timeout"], fn -> :the_result end) ==
               :the_result
    end

    test "restore logs a STABLE TAG on failure — never the raw error, which carries the backend host/database/role" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Loopctl.LocalGuc.restore(ExitingRepo, [{"statement_timeout", "1234ms"}]) == :ok
        end)

      assert log =~ "LocalGuc: restore failed"
      assert log =~ "noproc"
      # The whole point of swallowing it loudly rather than silently: a reopened leak has
      # to be diagnosable from the logs, not only from a distant 57014 in another query.
      assert log =~ "leak"
    end

    test "an ALREADY-ABORTED (25P02) transaction is NOT reported as a leak" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Loopctl.LocalGuc.restore(AbortedTxnRepo, [{"statement_timeout", "1234ms"}]) ==
                   :ok
        end)

      # The enclosing rollback discards the body's `SET LOCAL` anyway, so nothing can leak.
      # Warning here fires once per failed read during exactly the 57014 storm an operator
      # is triaging, and points at the wrong subsystem.
      refute log =~ "leak"
    end
  end

  # The defect these cover: a GUC captured as NULL used to be SKIPPED by `restore/2`, so
  # the body's `SET LOCAL` survived the enclosing transaction. NULL from
  # `current_setting(name, true)` means the GUC is UNKNOWN to the backend — which is
  # exactly the state of the pgvector `hnsw.*` knobs until the extension loads — so in
  # practice every `hnsw` override leaked. A synthetic namespaced GUC is used rather than
  # `hnsw.ef_search` so the test does not depend on whether pgvector happens to be loaded
  # into this backend yet.
  describe "LocalGuc restores a GUC that had NO prior value" do
    @probe "loopctl_test.leak_probe"

    defp current_probe do
      %{rows: [[v]]} = Repo.query!("SELECT current_setting($1, true)", [@probe])
      v
    end

    test "an unset GUC does not leak out of scoped/3" do
      # The sandbox already has us inside a transaction, which IS the savepoint-commit
      # situation this module exists for.
      assert current_probe() in [nil, ""], "precondition: the probe GUC is unset"

      Loopctl.LocalGuc.scoped(Repo, [@probe], fn ->
        Repo.query!("SET LOCAL #{@probe} = 'inner'")
        assert current_probe() == "inner"
      end)

      refute current_probe() == "inner",
             "the override survived scoped/3 — this is the leak LocalGuc exists to prevent"
    end

    test "a GUC that DID have a prior value is put back to that value, not to the default" do
      Repo.query!("SET LOCAL #{@probe} = 'outer'")
      assert current_probe() == "outer"

      Loopctl.LocalGuc.scoped(Repo, [@probe], fn ->
        Repo.query!("SET LOCAL #{@probe} = 'inner'")
      end)

      assert current_probe() == "outer",
             "restore must not clobber a deliberate outer SET LOCAL"
    end

    test "a FAILED capture still resets the GUCs the body is about to set" do
      # The fallback branch: with no captured values we cannot restore, but leaving the
      # body's override in the enclosing transaction is the leak this module exists to
      # prevent. Degrading to `[]` here (which `restore/2` treats as a no-op) is the
      # regression this asserts against.
      Loopctl.LocalGuc.scoped(CaptureFailingRepo, [@probe], fn ->
        Repo.query!("SET LOCAL #{@probe} = 'inner'")
      end)

      refute current_probe() == "inner",
             "a failed capture left the override in the enclosing transaction"
    end

    test "a nested failed capture leaves an ENCLOSING scope's GUC to its owner" do
      Loopctl.LocalGuc.scoped(Repo, [@probe], fn ->
        Repo.query!("SET LOCAL #{@probe} = 'outer'")

        Loopctl.LocalGuc.scoped(CaptureFailingRepo, [@probe], fn -> :ok end)

        assert current_probe() == "outer",
               "the inner reset clobbered the enclosing scope's deliberate SET LOCAL"
      end)
    end

    test "an invalid GUC name is rejected before it can reach the interpolated SQL" do
      for bad <- ["statement_timeout'; SELECT 1; --", "Foo", "a.b.c", :statement_timeout] do
        assert_raise ArgumentError, ~r/invalid GUC name/, fn ->
          Loopctl.LocalGuc.capture(Repo, [bad])
        end

        assert_raise ArgumentError, ~r/invalid GUC name/, fn ->
          Loopctl.LocalGuc.scoped(Repo, [bad], fn -> :ok end)
        end
      end
    end
  end

  defp show_statement_timeout(repo) do
    %{rows: [[value]]} = repo.query!("SHOW statement_timeout")
    value
  end

  # NOTE (US-38.4): the per-query `hnsw.ef_search` tests that PRIME the VM-global
  # `SystemConfig "hnsw_ef_search"` persistent_term key live in the sibling `async: false`
  # `Loopctl.HeavyReadHnswEfSearchTest` (test/loopctl/heavy_read_hnsw_ef_search_test.exs).
  # They were split out because that key is also read by real ANN reads in other `async: true`
  # files (dual_index_recall_test, vector_search_test), so priming it from an async module
  # would let a concurrent cross-file reader observe the primed value. This file stays
  # `async: true` — it mutates no global state.
end
