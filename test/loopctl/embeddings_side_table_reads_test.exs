defmodule Loopctl.EmbeddingsSideTableReadsTest do
  @moduledoc """
  US-41.1 — the SIDE-TABLE read path behind the cutover flag.

  Covers the half of the story that the data-model tests in
  `Loopctl.EmbeddingsTest` deliberately do not: the REAL request-path queries
  (`Knowledge.search_semantic/3`, `Memory.recall/2`) rewired onto the
  dimension-tagged side tables (AC-41.1.5), proven guard-clean through
  `Loopctl.HeavyRead` (AC-41.1.6), the system-corpus disclosure + materialization
  threaded into the search response `meta` (AC-41.1.7), and the re-embed
  coexistence + pending-dimension exclusion reporting (AC-41.1.10).

  ## The `left: []` flake — LEADING HYPOTHESIS, not proven, no fix landed. Read before touching.

  This file (and its siblings `system_config_read_path_test.exs`,
  `embeddings_review_fixes_test.exs`) intermittently fails with `left: []` — an
  assertion expecting article ids gets an empty list. It clears on re-run every time,
  it moves between files and between tests within a file, and four fixes have been aimed
  at it. It is still here.

  What is actually known:

    * **The plan for these reads is NOT STABLE, and that is measured, not theorised.**
      Running one of these assertions repeatedly against an unchanged database, three
      shapes appear: a Seq Scan + real Sort, an `article_embeddings_tenant_id_dim_index`
      (btree) Index Scan + real Sort — both EXACT, they cannot under-return — and an
      `article_embeddings_hnsw_dim_1536_idx` Index Scan, which is APPROXIMATE. One
      ten-run sample went 7 exact / 3 HNSW, with the Seq Scan's estimated cost climbing
      run over run as rolled-back test transactions leave dead tuples behind. So "this
      suite does not execute the ANN path" and "this suite does execute it" are BOTH
      true, at different moments. Any claim about this file's plan that does not say
      WHICH run it describes is not a fact about the suite.
    * **On the HNSW branch, the `tenant_id` predicate is a POST-INDEX residual Filter**
      (`Filter: (tenant_id = ...)`, `Rows Removed by Filter: N`), which is the shape
      that can under-return. Measured on the forced-failure runs of this file: with
      `hnsw.iterative_scan` OFF the HNSW branch returned `rows=0` and `rows=3` where 23
      rows were visible; with `relaxed_order` — which is what `HeavyRead` actually
      applies, and what prod runs — it returned the full `rows=20` every time.
    * **That hypothesis is now DEAD, and the diagnostic below is what killed it.** It
      predicted a recurrence would show an HNSW plan with iterative scan ABSENT. A real
      recurrence was captured (`tenant isolation holds on the side-table read path`) and
      showed the opposite: `iterative_scan="relaxed_order" (supported?=true)` — applied,
      not absent — and it under-returned anyway. Do not go looking for a failed
      capability probe.
    * **What that capture DOES show is an HNSW plan with a post-ANN tenant `Filter` that
      under-returned.** The plan was the shared `article_embeddings_hnsw_dim_1536_idx`, so
      the ANN picks its nearest N across EVERY tenant's rows and discards the non-matching
      ones afterwards; the inner pool produced 20 and the outer pool truncates to `pool=5`.
      CANDIDATE STARVATION — the tenant's one `scope: :tenant` row losing all 5 slots to its
      materialized system rows — fits those numbers and is the leading hypothesis, but is
      NOT proven by them: the ~24-row corpus the diagnostic printed was captured AFTER the
      read, and `search_semantic/3` materializes the system corpus as a side effect of
      building its disclosure `meta`, so that count can be strictly larger than the set the
      ANN actually scanned (the diagnostic says so itself). Let the next capture's
      `Rows Removed by Filter` decide it.
    * **So the page size is the lever that diagnosis points at — and config disables it.** `limit:` is
      clamped by `semantic_result_pool_cap` (5 in `config/test.exs`), so widening a page
      buys NOTHING while that cap stands. This is why four fixes and fourteen wide
      `limit:` annotations did not stop it: the diagnosis was right and the remedy was
      inert. Adding a fifteenth `limit:` is not the fix; the cap was — for the STARVATION
      mode only. See the second capture below: the recall-loss mode survives the raised cap.
    * The one CI failure captured in detail asserted on a raw `HeavyRead.all/2` and
      never called `search_semantic/3` at all.
    * Every failure mode seen UNDER-returns. Nothing has ever returned another tenant's
      rows: this is not an isolation defect.
    * A dedicated read-only investigation could not reproduce it in 33 local runs.

  So: do NOT ship a fifth speculative recall fix. `hnsw.ef_search`, exact-scan forcing,
  `hnsw.iterative_scan` and retry-on-empty have each been tried and each regressed
  something else — and none of them can be the lever while the pool cap clamps the page.
  Collect the diagnostic below FIRST and let it name the branch.

  The remaining work is to raise `semantic_result_pool_cap` for this suite WITHOUT
  breaking the three tests that depend on the current value —
  `knowledge_semantic_search_test.exs:1348`, `:1376` and `:1432` each seed exactly
  `cap + 2` rows to trip the truncation signal cheaply, so a naive raise fails all
  three. That is a real constraint, not a reason to leave the cap alone; this repo
  forbids `Application.put_env` in tests, so it needs either a reseed or a per-call
  override on those three.

  ### What to do on the next recurrence

  Every assertion in this file that has produced the signature is wrapped in
  `Loopctl.VectorRecallDiagnostics.diagnose_empty/2`, which fires ONLY on an empty
  result and dumps the two facts that a bare `left: []` cannot separate:

    * **(a) the row was not VISIBLE** to the read (tenant, `dim`, `live_denorm`, status),
      printed as unlimited `count()`s (decide on those, not on the capped row sample
      beside them); versus
    * **(b) the row was visible and the PLAN did not return it**, printed as
      `EXPLAIN (ANALYZE, BUFFERS)` of the exact query that just came back empty, run
      with the `hnsw.*` GUCs that read itself ran with — which for an assertion on a bare
      `HeavyRead.all/2` means none.

  Paste that output into the next investigation instead of another theory. The two
  numbers that decide it are the scan node's `actual ... rows=` and, on an HNSW plan,
  `Rows Removed by Filter`.

  ## Why this is `async: false`

  Not the flake. The read-path CUTOVER FLAG is an injected collaborator
  (`Loopctl.Embeddings.ReadPathBehaviour`), so `enable_side_table_reads/0` is a
  PROCESS-SCOPED `Mox.stub/3` and nothing VM-global is written for it. (The flag's real
  per-node globality is covered in `test/loopctl/embeddings/system_config_read_path_test.exs`.)

  `async: false` is kept as cheap insurance — these are the suite's heaviest vector
  reads and serializing them lowers DB contention. It is NOT a fix: #519 added it on the
  theory that concurrent async inserts perturbed a shared index, which is impossible
  (ExUnit runs every async module to completion BEFORE any sync one), and the same
  failure simply reappeared in `system_config_read_path_test.exs`.

  ## What #535 did fix (real, and still in place)

  `SET LOCAL` leaks out of a committed SAVEPOINT. Under Sandbox every heavy read nests in
  the test's transaction, so one successful read left its 250ms `statement_timeout` armed
  over the REST of the test — cancelling unrelated statements later (a plain
  `INSERT INTO audit_log` 57014'd) and blanking result sets far from the read that set it.
  Closed in `Loopctl.LocalGuc`, which `HeavyRead` routes every per-read `SET LOCAL`
  through. That took the failure from ~28% of runs to rare. It did not take it to zero.

  ONE recurrence has since been explained, and it was NOT any of the four dead theories.
  With the diagnostic below in the tree, a real CI failure captured: 24 tenant rows visible
  (unlimited COUNT, so the row WAS there), an HNSW plan with `Rows Removed by Filter: 1` —
  so the tenant filter discarded one row of a 25-row corpus and was not the cause — and a
  scan that returned `rows=20` of those 24, truncating at the inner pool before reaching
  the tenant's own article, which sorts below the materialized system corpus. That is
  candidate starvation, and it is why the wide `limit:` annotations exist.

  They were INERT until #634. `semantic_result_pool/1` is
  `min(max(offset + limit, floor), cap)`, and `config/test.exs` capped the pool at 5, so
  every wide page clamped back to 5 regardless of what the assertion asked for. The
  diagnosis in this file was right and its remedy had been disconnected from it for as long
  as the cap stood — which is the actual reason four fixes bounced off. #634 raised the test
  cap so the annotations bind, and added a deterministic reproduction of the starvation
  geometry that fails loudly at the knob.

  **#634 DID NOT SOLVE THE FLAKE, and a second capture proves it.** Taken on master WITH the
  raised cap already merged, on this same test:

      tenant rows: 24 (COUNT — authoritative)
      at dim=1536 AND live_denorm AND published: 24 (COUNT — authoritative)
      pool=10 inner_pool=40          <- the raised cap IS in effect
      Index Scan using article_embeddings_hnsw_dim_1536_idx  (actual rows=23)
            Filter: (tenant_id = '...'::uuid)
            [no `Rows Removed by Filter` line at all]

  Read that carefully, because it rules out the explanation above for THIS failure:

    * `inner_pool=40` against 24 candidates — there was room for every row, so truncation
      cannot be the cause;
    * the filter removed NOTHING (no `Rows Removed by Filter` line is emitted);
    * the scan returned **23 of 24** rows an authoritative COUNT can see, and the one it
      missed is exactly the `scope: :tenant` row the assertion wanted;
    * `iterative_scan="relaxed_order" (supported?=true)` — applied.

  So the HNSW walk did not reach a row that exists, is visible, and had a slot waiting.
  That is RECALL LOSS, and it is a DIFFERENT failure mode from the starvation above.
  There are at least two, and #634 closes only the first.

  **No cause is offered for the recall-loss mode, deliberately.** Every previous wrong turn
  on this file — including two in the same investigation that produced the capture above —
  came from promoting "fits the numbers" to "is the mechanism". The numbers above are what
  is established; anything about WHY the walk missed that row is not. Do not write one into
  this moduledoc until a capture supports it.

  The earlier savepoint-leak and residual-filter causes were different again and are
  separately fixed — KB c6fd1e5d carries the standing protocol (does your diff touch the
  read path, run the file 5x, then rerun) and the list of four recall-targeted
  theories that are DEAD (`hnsw.ef_search`, exact scan, `hnsw.iterative_scan`,
  retry-on-empty). Follow it there; do not open a fifth.

  What IS demonstrable, and is why every ranking assertion in this file passes a page
  wider than its candidate set: at the default `limit: 10` the index-ordered ANN can
  spend its slots on rows a post-ANN filter then discards. A missing `limit:` is the
  first thing to check on a NEW ranking assertion — it is not a diagnosis of the flake.

  The cross-tenant residual filter (the ANN applies `tenant_id` AFTER the index returns
  its top-`ef_search` batch) is a real, SEPARATE production concern, and `hnsw.iterative_scan`
  is its remedy. It remains a `SystemConfig`-only lever for the OPERATOR, but as of #535
  `config/test.exs` DOES pin the Application-level fallback (`:hnsw_iterative_scan_default`)
  ON — because prod runs iterative scan ON, so an unpinned test env was asserting exact
  recall against a configuration nobody runs. `test/loopctl/config_embedding_read_path_test.exs`
  enforces both halves: the pin exists in `config/test.exs` and in no other config file.

  That pin is NOT a fifth recall fix and does not repeal the warning above — it aligns the
  test env with prod. The test-side remedy for THIS file's flake is still orthogonal
  vectors and a page size wider than the candidate set (below).
  """

  use Loopctl.DataCase, async: false
  use Oban.Testing, repo: Loopctl.Repo

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Memory
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Memory.Scope
  alias Loopctl.VectorRecallDiagnostics

  setup :verify_on_exit!

  defp enable_side_table_reads do
    stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> true end)
    assert Embeddings.side_table_reads_enabled?()
  end

  # DIAGNOSTIC ONLY — see `Loopctl.VectorRecallDiagnostics` and the "what to do on the
  # next recurrence" section of the moduledoc. Returns `ids` unchanged and prints nothing
  # unless `ids` is EMPTY, so it costs nothing on green and changes no assertion.
  defp diagnose(ids, tenant_id, dim, label, opts \\ []) do
    VectorRecallDiagnostics.diagnose_empty(
      ids,
      opts ++ [tenant_id: tenant_id, dim: dim, query_vector: vec(dim, :query), label: label]
    )
  end

  # Per-test-unique vectors via `Loopctl.DataCase.test_vec/2` (see its @doc). `:close`
  # and `:query` are identical (cosine 1.0); `:far` is a strictly-worse but genuinely
  # NEAR neighbour (`:near`, cosine ~0.71).
  #
  # Keep them per-test-unique. The DURABLE reason is tie-breaking, and it does not depend
  # on which plan runs: a shared fixed vector made ~50 rows across this file and its
  # siblings mutually distance-0, and a tied ORDER BY has unspecified order in Postgres
  # whether it is served by an index scan or by a real Sort — which is what a ranking
  # assertion cannot tolerate. (An earlier comment credited "dissolving a shared-HNSW-index
  # clique" specifically. That is unconfirmed — the plan for these reads is not stable
  # between runs, see the moduledoc — so rely on the tie-break reason, which always holds.)
  defp vec(dim, :close), do: test_vec(dim, :primary)
  defp vec(dim, :query), do: test_vec(dim, :primary)
  defp vec(dim, :far), do: test_vec(dim, :near)

  # A DISTINCT near-neighbour per index, for the tests that seed a WHOLE crowd of near
  # rows at once. Handing every one of them `vec(dim, :close)` would rebuild the very
  # all-ties clique the note above forbids — dozens of byte-identical vectors in the shared
  # HNSW graph. One extra hot dimension taken from the cold tail keeps cosine at ~0.94
  # (still far above `:far`'s ~0.71) while making every vector unique.
  defp near_vec(dim, index) do
    base = vec(dim, :close)

    cold =
      base
      |> Enum.with_index()
      |> Enum.filter(fn {v, _i} -> v == 0.0 end)
      |> Enum.map(&elem(&1, 1))

    List.replace_at(base, Enum.at(cold, index), 1.0)
  end

  defp embedded_article(tenant_id, attrs, kind, dim) do
    article = fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))

    {:ok, _row} =
      Embeddings.upsert_article_embedding(tenant_id, article, vec(dim, kind), nil, dim)

    article
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.5 / AC-41.1.6 — the real search query, dimension-scoped and guard-clean
  # ---------------------------------------------------------------------------

  describe "search_semantic/3 on the side table (AC-41.1.5)" do
    # The FLAG mechanism itself (SystemConfig 0/1 -> legacy/side-table, and the
    # revert) is covered against the real production implementation in
    # `system_config_read_path_test.exs`. Asserting it here would only assert the
    # injected mock. What this module covers is the READ PATH each decision selects.
    # NB: this asserts the DI WIRING only — that `side_table_reads_enabled?/0` returns
    # whatever the injected decision says, in both directions. The QUERY paths each
    # decision selects are covered by the tests below (side table) and by "the legacy read
    # path discloses keyword-only..." (legacy).
    test "side_table_reads_enabled?/0 returns the injected decision, both ways (DI wiring)" do
      refute Embeddings.side_table_reads_enabled?()
      enable_side_table_reads()
      assert Embeddings.side_table_reads_enabled?()

      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> false end)
      refute Embeddings.side_table_reads_enabled?()
    end

    # `limit: 50` here is INERT in the test environment, and saying so is the point.
    # `Knowledge.semantic_result_pool/1` is `min(max(offset + limit, floor), cap)`, and
    # `config/test.exs` pins the cap at 5 — so `limit: 50` and the default `limit: 10`
    # both yield a pool of 5. It is kept because it is the PROD-correct shape (there the
    # cap is 1000, and a page wider than the candidate set keeps this assertion about
    # ORDER rather than about pool capacity), NOT because it does anything here.
    #
    # An earlier comment claimed "PAGE SIZE IS LOAD-BEARING, do not simplify it back to
    # the default". That was false in the very environment where the flake happens, and
    # it sent investigators after a page-size theory the plan does not support. What is
    # actually load-bearing is the pool CAP, which no `limit:` can raise.
    test "ranks by similarity over the side table at the tenant's dimension" do
      tenant = fixture(:tenant)
      close = embedded_article(tenant.id, %{title: "Close"}, :close, 1536)
      far = embedded_article(tenant.id, %{title: "Far"}, :far, 1536)

      enable_side_table_reads()

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query), limit: 50)

      ids =
        diagnose(Enum.map(results, & &1.id), tenant.id, 1536, "ranks by similarity", limit: 50)

      assert close.id in ids
      assert far.id in ids
      assert hd(ids) == close.id
      assert meta.search_mode == "semantic_only"
      assert meta.embedding_dimension == 1536
    end

    test "a 768-dimension tenant recalls ONLY its own 768 rows — never cross-dimension" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant_b.id, 768)

      _a_article = embedded_article(tenant_a.id, %{title: "A 1536"}, :close, 1536)
      b_article = embedded_article(tenant_b.id, %{title: "B 768"}, :close, 768)

      enable_side_table_reads()

      # No pgvector "different vector dimensions" error is possible here: the inner
      # pool is scoped to dim = 768 by construction, so tenant A's 1536 rows are
      # excluded TWICE over (RLS-equivalent tenant scope AND the dimension predicate).
      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant_b.id, vec(768, :query))

      ids = diagnose(Enum.map(results, & &1.id), tenant_b.id, 768, "768-dimension recall")

      assert ids == [b_article.id]
      assert meta.embedding_dimension == 768
    end

    test "the pool query passes guard!/2 and an unscoped variant does NOT" do
      tenant = fixture(:tenant)
      article = embedded_article(tenant.id, %{title: "Guarded"}, :close, 1536)

      query = Knowledge.semantic_side_table_pool_query(tenant.id, vec(1536, :query), 1536, 10)

      rows =
        diagnose(HeavyRead.all(tenant.id, query), tenant.id, 1536, "pool query", query: query)

      assert [%{article_id: id}] = rows
      assert id == article.id

      unscoped =
        from(ae in ArticleEmbedding, where: ae.dim == 1536 and ae.live_denorm, limit: 10)

      assert_raise ArgumentError, ~r/not fully scoped to the given tenant/, fn ->
        HeavyRead.all(tenant.id, unscoped)
      end
    end

    test "the count query is guard-clean and counts the live, filtered, embedded corpus" do
      tenant = fixture(:tenant)
      embedded_article(tenant.id, %{title: "One"}, :close, 1536)
      embedded_article(tenant.id, %{title: "Two"}, :far, 1536)

      query = Knowledge.semantic_side_table_count_query(tenant.id, 1536, :published, [])
      assert HeavyRead.one(tenant.id, query) == 2
    end

    # REVIEW #13: the count query used to join `articles` on `a.tenant_id ==
    # ^tenant_id`, excluding system-scoped rows, while the hydration selects
    # `tenant_id == ^tenant_id or scope == :system` and RETURNS them. Once a tenant
    # materialized the system corpus, `length(results)` could exceed `total_count`,
    # breaking the `total_count_scope: ranked_corpus` contract and making the
    # truncation signal wrong (degenerately: total_count 0 with non-empty results).
    test "total_count AGREES with the results about materialized system articles" do
      tenant = fixture(:tenant)
      sys = system_article()

      {:ok, _} =
        Embeddings.materialize_system_article_embedding(
          tenant.id,
          sys,
          vec(1536, :close),
          "sys",
          1536
        )

      enable_side_table_reads()

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query))

      ids = diagnose(Enum.map(results, & &1.id), tenant.id, 1536, "total_count agrees")

      assert ids == [sys.id]
      assert meta.total_count == 1
      refute meta.pool_capped
    end

    test "a superseded article leaves the side-table ANN pool (trigger-enforced)" do
      tenant = fixture(:tenant)
      live = embedded_article(tenant.id, %{title: "Live"}, :close, 1536)
      gone = embedded_article(tenant.id, %{title: "Gone"}, :close, 1536)

      AdminRepo.update_all(from(a in Article, where: a.id == ^gone.id),
        set: [status: :superseded]
      )

      enable_side_table_reads()

      assert {:ok, %{results: results}} = Knowledge.search_semantic(tenant.id, vec(1536, :query))

      ids = diagnose(Enum.map(results, & &1.id), tenant.id, 1536, "superseded leaves pool")

      assert ids == [live.id]
    end

    test "selective filters still apply — they just live OUTSIDE the index-ordered ANN" do
      tenant = fixture(:tenant)
      pattern = embedded_article(tenant.id, %{category: :pattern}, :close, 1536)
      _decision = embedded_article(tenant.id, %{category: :decision}, :close, 1536)

      enable_side_table_reads()

      # `limit: 50` is the PROD-correct shape for a post-pool filter — the `category`
      # filter is applied AFTER the pool is taken, so a page narrower than the candidate
      # set can starve it. In THIS environment it is inert for the reason given on "ranks
      # by similarity ..." above (the pool cap of 5 binds first), so do not read it as a
      # fix for the `left: []` flake.
      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query),
                 category: :pattern,
                 limit: 50
               )

      ids =
        diagnose(Enum.map(results, & &1.id), tenant.id, 1536, "selective filter", limit: 50)

      assert ids == [pattern.id]
    end

    test "tenant isolation holds on the side-table read path" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      _a = embedded_article(tenant_a.id, %{title: "A"}, :close, 1536)
      b = embedded_article(tenant_b.id, %{title: "B"}, :close, 1536)

      enable_side_table_reads()

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant_b.id, vec(1536, :query))

      ids = diagnose(Enum.map(results, & &1.id), tenant_b.id, 1536, "tenant isolation")

      assert ids == [b.id]
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.5 / AC-41.1.6 — memory recall
  # ---------------------------------------------------------------------------

  describe "Memory recall on the side table (AC-41.1.5 / AC-41.1.6)" do
    test "recalls at the tenant's dimension and satisfies guard_memory!/3" do
      tenant = fixture(:tenant)
      subject = "agent:#{System.unique_integer([:positive])}"

      memory = fixture(:memory, tenant_id: tenant.id, subject_id: subject)

      {:ok, _} =
        Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536, :close), nil, 1536)

      enable_side_table_reads()

      scope = %Scope{tenant_id: tenant.id, subject_id: subject, project_id: nil}

      %{results: results} = recall(scope, vec(1536, :query))

      assert Enum.map(results, fn {m, _score} -> m.id end) == [memory.id]
    end

    test "a superseded memory leaves the pool via the DB trigger" do
      tenant = fixture(:tenant)
      subject = "agent:#{System.unique_integer([:positive])}"

      live = fixture(:memory, tenant_id: tenant.id, subject_id: subject)
      gone = fixture(:memory, tenant_id: tenant.id, subject_id: subject)

      {:ok, _} = Embeddings.upsert_memory_embedding(tenant.id, live, vec(1536, :close), nil, 1536)
      {:ok, _} = Embeddings.upsert_memory_embedding(tenant.id, gone, vec(1536, :close), nil, 1536)

      AdminRepo.update_all(from(m in Loopctl.Memory.Memory, where: m.id == ^gone.id),
        set: [superseded_by: live.id]
      )

      enable_side_table_reads()

      scope = %Scope{tenant_id: tenant.id, subject_id: subject, project_id: nil}
      %{results: results} = recall(scope, vec(1536, :query))

      assert Enum.map(results, fn {m, _} -> m.id end) == [live.id]
    end

    test "another subject's rows are never recalled" do
      tenant = fixture(:tenant)
      mine = fixture(:memory, tenant_id: tenant.id, subject_id: "agent:mine")
      theirs = fixture(:memory, tenant_id: tenant.id, subject_id: "agent:theirs")

      {:ok, _} = Embeddings.upsert_memory_embedding(tenant.id, mine, vec(1536, :close), nil, 1536)

      {:ok, _} =
        Embeddings.upsert_memory_embedding(tenant.id, theirs, vec(1536, :close), nil, 1536)

      enable_side_table_reads()

      scope = %Scope{tenant_id: tenant.id, subject_id: "agent:mine", project_id: nil}
      %{results: results} = recall(scope, vec(1536, :query))

      assert Enum.map(results, fn {m, _} -> m.id end) == [mine.id]
    end

    test "the memory write path dual-writes both locations in one transaction" do
      tenant = fixture(:tenant)
      memory = fixture(:memory, tenant_id: tenant.id)

      assert {:ok, _} =
               Memory.update_memory_embedding(tenant.id, memory.id, vec(1536, :close), "mh")

      assert AdminRepo.one(
               from(me in MemoryEmbedding,
                 where: me.memory_id == ^memory.id,
                 select: me.dim
               )
             ) == 1536

      refute is_nil(
               AdminRepo.one(
                 from(m in Loopctl.Memory.Memory,
                   where: m.id == ^memory.id,
                   select: m.embedding
                 )
               )
             )
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.7 — the system corpus, disclosed then materialized
  # ---------------------------------------------------------------------------

  describe "system corpus in the search meta (AC-41.1.7)" do
    test "BEFORE materialization the response meta reports keyword-only, not silence" do
      tenant = fixture(:tenant)
      system_article()
      embedded_article(tenant.id, %{title: "Own"}, :close, 1536)

      enable_side_table_reads()

      assert {:ok, %{meta: meta}} = Knowledge.search_semantic(tenant.id, vec(1536, :query))

      assert meta.system_corpus_recall == "keyword_only"
      assert meta.system_corpus_reason =~ "keyword"
      assert meta.system_corpus_dimension == 1536
    end

    test "AFTER materialization the system article is semantically recallable" do
      tenant = fixture(:tenant)
      article = system_article()

      # Materialize with the REQUESTING tenant's own credential: an ordinary row
      # carrying THAT tenant_id, so the conjunctive tenant predicate holds and
      # `guard!/2` is not relaxed.
      {:ok, row} =
        Embeddings.materialize_system_article_embedding(
          tenant.id,
          article,
          vec(1536, :close),
          "sys",
          1536
        )

      assert row.tenant_id == tenant.id

      enable_side_table_reads()

      # `limit: 50` is the PROD-correct shape (AC-41.1.7 promises the system article is
      # RECALLABLE, not that it wins a narrow page against the rest of the system corpus),
      # but it is INERT here: the test pool cap of 5 binds before any `limit:` does.
      #
      # The candidate set really can be large — a migration seeds ~two dozen COMMITTED
      # system-scoped articles, and `search_semantic/3` materializes them for the calling
      # tenant as a side effect of building its disclosure meta. But that materialization
      # runs AFTER the pool query, so it is not a load-dependent race between tests: it is
      # deterministic within a test, and no `limit:` can widen a pool the cap holds at 5.
      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query), limit: 50)

      ids =
        diagnose(Enum.map(results, & &1.id), tenant.id, 1536, "system article recallable",
          limit: 50
        )

      assert article.id in ids
    end

    # THE REGRESSION GUARD FOR THE WIDE-PAGE REMEDY ITSELF.
    #
    # Every "PAGE SIZE IS LOAD-BEARING" note in this file asserts a page wider than the
    # candidate set — but a `limit:` is only a REQUEST. `Knowledge.semantic_result_pool/1`
    # is `min(max(offset + limit, floor), cap)`, so the cap has the last word: while
    # `config/test.exs` pinned it at 5, `limit: 50` and `limit: 10` produced the IDENTICAL
    # pool of 5 and every one of those annotations bought exactly nothing. That — an inert
    # annotation — is ALL this guard is about. It does NOT explain the `left: []` flake,
    # whose root cause is settled in KB c6fd1e5d (a `SET LOCAL` savepoint leak plus a
    # cross-tenant residual filter, #535, with rare unexplained recurrences that clear on
    # rerun); follow that article's protocol on the next sighting, not this comment.
    #
    # The geometry is the crowding one: the whole committed system corpus materialized
    # NEAREST the query vector so it outranks the tenant's own row (`:far`, ~0.71), which
    # lands LAST among the candidates. A page smaller than that set evicts it; a larger
    # one cannot.
    test "the tenant's own row survives a fully materialized system corpus (pool > candidates)" do
      tenant = fixture(:tenant)

      system_rows = Embeddings.unmaterialized_system_articles(tenant.id, 1536, limit: 1000)
      assert system_rows != [], "the committed system corpus is what crowds the ANN pool"

      for {article, i} <- Enum.with_index(system_rows) do
        {:ok, _} =
          Embeddings.materialize_system_article_embedding(
            tenant.id,
            article,
            near_vec(1536, i),
            "sys",
            1536
          )
      end

      own = embedded_article(tenant.id, %{title: "Own, ranked last"}, :far, 1536)

      # Assert the MARGIN, not a comment about it. The binding ceiling on THIS path is not
      # the raw cap: `search_semantic_side_table/7` hydrates from
      # `side_table_inner_pool(pool)` ANN rows, so that is what must clear the candidate
      # set (the raw cap binds on the LEGACY path). The requested page must clear it too,
      # since the page is what the ranking assertion reads. Shrink either (or grow the
      # system corpus past them) and this fails HERE, naming the knob — instead of
      # resurfacing as an intermittent `left: []` in a sibling suite.
      candidates = length(system_rows) + 1
      limit = 50

      reach =
        VectorSearch.side_table_ef_search(
          VectorSearch.side_table_inner_pool(min(limit, Knowledge.semantic_result_pool_cap()))
        )

      assert reach > candidates,
             "the side-table hydration pool (#{reach}) must exceed the #{candidates}-row " <>
               "candidate set, or wide `limit:` annotations are clamped back below it"

      assert limit > candidates,
             "the requested page (#{limit}) must exceed the #{candidates}-row candidate set"

      enable_side_table_reads()

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query), limit: limit)

      assert own.id in Enum.map(results, & &1.id)
      # The WHOLE candidate set is served, not just `own` — that is what "pool > candidates"
      # claims, and without it a pool regression that evicted most of the system rows would
      # still pass on the score check alone. One ANN recall miss is tolerated so the
      # approximate index cannot fail the run.
      assert length(results) >= candidates - 1

      # ...and `own` really is the WORST-ranked candidate, so its presence is pool capacity
      # doing its job, not a lucky tie. Compared by SCORE rather than by list position, so
      # a single ANN miss among the system rows cannot turn this into a false alarm.
      assert Enum.min_by(results, & &1.similarity_score).id == own.id
    end

    # The reach the flag is compared against is the ANN's REAL return bound. The inner
    # LIMIT is `pool * side_table_over_fetch()`, but an HNSW scan returns only
    # ~`hnsw.ef_search` nodes regardless of the LIMIT, so the smaller of the two binds.
    # Comparing against the unclamped over-fetch overstated the PROD reach 4x (4000 against
    # the 1000-node ceiling) and reported "complete" for every corpus in between.
    #
    # Driven with the PROD-shaped cap, not the shrunk test one: at cap 30 the over-fetch
    # (120) never reaches the ceiling, so a guard reading only the configured value would
    # pass with the clamp deleted.
    test "the side-table reach is clamped by the hnsw ef_search ceiling, not by the over-fetch" do
      ceiling = VectorSearch.max_side_table_ef_search()
      cap = ceiling

      assert VectorSearch.side_table_inner_pool(cap) > ceiling,
             "this guard is vacuous unless the over-fetch blows past the ef_search ceiling"

      assert Knowledge.semantic_side_table_reach(cap) == ceiling

      assert Knowledge.semantic_side_table_reach() ==
               Knowledge.semantic_side_table_reach(Knowledge.semantic_result_pool_cap())
    end

    # `total_count` counts rows that SURVIVE the post-ANN status/visibility trim; the reach
    # counts ANN candidate SLOTS, which the side-table inner index cannot filter. So when
    # the window saturates and part of it is discarded, the ranked rows behind it are
    # unreachable at any offset — and the starvation arm cannot say so, because it needs a
    # SHORT page and this case delivers a full one.
    test "a saturated ANN window that was trimmed reaches only what survived" do
      inner_pool = VectorSearch.side_table_inner_pool(Knowledge.semantic_result_pool_cap())
      ceiling = VectorSearch.side_table_ef_search(inner_pool)

      assert Knowledge.semantic_side_table_response_reach(inner_pool, ceiling, 7) == 7

      # Not saturated: the ANN already returned every candidate it could find, so nothing
      # is behind the window and the corpus-level reach stands.
      assert Knowledge.semantic_side_table_response_reach(inner_pool, ceiling - 1, 7) ==
               Knowledge.semantic_side_table_reach()

      # Saturated but nothing trimmed: the over-fetch bought exactly what it promised.
      assert Knowledge.semantic_side_table_response_reach(inner_pool, ceiling, ceiling) ==
               Knowledge.semantic_side_table_reach()
    end

    # `meta.pool_capped == false` is documented to mean "this query's results are complete".
    # It used to compare `total_count` against the RAW cap on BOTH paths — but this path
    # hydrates from an over-fetched ANN pool, so a corpus between the cap and
    # `semantic_side_table_reach/0` is fully served and was still flagged truncated, telling
    # the consumer to switch to list mode for nothing.
    #
    # The page is deliberately NARROWER than the corpus: at `limit: corpus` a single ANN
    # recall miss makes the page SHORT, which legitimately trips the starvation arm and
    # would fail this test for a reason it is not about (the sibling crowding test carries
    # the same margin).
    test "a corpus above the cap but within the side-table reach is not flagged truncated" do
      tenant = fixture(:tenant)
      cap = Knowledge.semantic_result_pool_cap()
      corpus = cap + 2
      page = 10
      assert Knowledge.semantic_side_table_reach() >= corpus
      assert page < corpus

      for i <- 1..corpus do
        article =
          fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Hub #{i}"})

        {:ok, _} =
          Embeddings.upsert_article_embedding(tenant.id, article, near_vec(1536, i), nil, 1536)
      end

      enable_side_table_reads()

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query), limit: page)

      assert meta.total_count == corpus
      assert length(results) == page
      refute meta.pool_capped
    end

    # Review, finding 3: AC-41.1.7 requires the system-corpus recall state be stated
    # EXPLICITLY on EVERY semantic response — "never a silent absence". On the LEGACY
    # path the shared system corpus is not semantically recallable at all (the legacy
    # inner ANN scopes `tenant_id == ^tenant_id`, excluding the NULL-tenant system
    # rows), so the response carries a STATIC `keyword_only` disclosure. Crucially it is
    # a compile-time CONSTANT — no per-dimension anti-join, no re-embed probe, no tenants
    # SELECT — so the hot-path query cost the review guarded against is still zero: the
    # per-DIMENSION side-table meta (`embedding_dimension` + the memoized
    # `search_disclosure_meta` probes) remains absent.
    test "the legacy read path discloses keyword-only system corpus WITHOUT paying any query cost" do
      tenant = fixture(:tenant)
      system_article()
      embedded_article(tenant.id, %{title: "Own"}, :close, 1536)

      refute Embeddings.side_table_reads_enabled?()

      assert {:ok, %{meta: meta}} = Knowledge.search_semantic(tenant.id, vec(1536, :query))
      # The disclosure is present (AC-41.1.7, never silent)...
      assert meta.system_corpus_recall == "keyword_only"
      # ...but it is a static constant, so the per-dimension side-table meta and its
      # queries are still absent on the legacy path.
      refute Map.has_key?(meta, :embedding_dimension)
      refute Map.has_key?(meta, :system_corpus_dimension)
    end

    test "the SIDE-TABLE read path carries the disclosure AND triggers materialization" do
      tenant = fixture(:tenant)
      system_article()
      embedded_article(tenant.id, %{title: "Own"}, :close, 1536)

      enable_side_table_reads()

      assert {:ok, %{meta: meta}} = Knowledge.search_semantic(tenant.id, vec(1536, :query))
      assert meta.system_corpus_recall == "keyword_only"

      # AC-41.1.7 "on demand": the read that OBSERVES the unmaterialized corpus is
      # what TRIGGERS its materialization. Without this the disclosure was a dead end
      # — a tenant stayed keyword-only for the shared corpus forever unless an
      # operator opened IEx. Oban runs `testing: :inline`, so the trigger has already
      # executed by the time the search returns: assert the EFFECT.
      assert Embeddings.unmaterialized_system_articles(tenant.id, 1536, limit: 1) == []
    end

    test "the materialization worker is enqueued idempotently per (tenant, dim)" do
      tenant = fixture(:tenant)

      assert {:ok, job} = Embeddings.enqueue_system_corpus_materialization(tenant.id)
      assert job.args["tenant_id"] == tenant.id
      assert job.args["dim"] == 1536
      assert job.worker == "Loopctl.Workers.SystemCorpusEmbeddingWorker"
    end

    # Review, finding 11: the worker's Oban uniqueness covers only
    # [:available, :scheduled, :retryable] (it must re-enqueue itself), so a COMPLETED
    # corpus is NOT deduped — every repeated POST would insert a fresh no-op job an
    # agent could loop to flood the embeddings queue. A fully-materialized corpus
    # short-circuits to `:already_materialized` with NO job created.
    test "a fully-materialized system corpus does NOT enqueue a redundant no-op job" do
      tenant = fixture(:tenant)

      for article <- Embeddings.unmaterialized_system_articles(tenant.id, 1536, limit: 1000) do
        {:ok, _} =
          Embeddings.materialize_system_article_embedding(
            tenant.id,
            article,
            vec(1536, :close),
            "sys",
            1536
          )
      end

      assert Embeddings.unmaterialized_system_articles(tenant.id, 1536, limit: 1) == []

      assert {:ok, :already_materialized} =
               Embeddings.enqueue_system_corpus_materialization(tenant.id)
    end

    test "the worker materializes the system corpus with the TENANT's own credential" do
      tenant = fixture(:tenant)
      article = system_article()

      assert :ok =
               perform_job(Loopctl.Workers.SystemCorpusEmbeddingWorker, %{
                 "tenant_id" => tenant.id,
                 "dim" => 1536
               })

      row =
        AdminRepo.one(
          from(ae in ArticleEmbedding,
            where: ae.article_id == ^article.id and ae.tenant_id == ^tenant.id
          )
        )

      # Written as an ORDINARY row carrying the requesting tenant's id — never a
      # NULL tenant_id, which could not satisfy the HeavyRead guard.
      refute is_nil(row)
      assert row.tenant_id == tenant.id
      assert row.dim == 1536

      # ... and the disclosure flips from keyword-only to semantic.
      assert Embeddings.system_corpus_meta(tenant.id, 1536).system_corpus_recall == "semantic"
    end

    test "the worker DISCARDS cleanly for a tenant with no embedding key (mandatory BYO)" do
      tenant = fixture(:tenant)
      system_article()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, _texts ->
        {:error, :no_api_key}
      end)

      assert {:discard, {:no_embedding_key, tenant_id}} =
               perform_job(Loopctl.Workers.SystemCorpusEmbeddingWorker, %{
                 "tenant_id" => tenant.id,
                 "dim" => 1536
               })

      assert tenant_id == tenant.id
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.10 — re-embed coexistence, progress and exclusion reporting
  # ---------------------------------------------------------------------------

  describe "re-embed backfill (AC-41.1.10)" do
    test "old and new dimensions coexist and recall stays at the ACTIVE dimension" do
      tenant = fixture(:tenant)
      article = embedded_article(tenant.id, %{title: "Both"}, :close, 1536)

      # The pending-dimension row is written WITHOUT changing the active dimension —
      # this is the whole point of `(id, dim)` uniqueness.
      {:ok, _} =
        Embeddings.upsert_article_embedding(tenant.id, article, vec(768, :close), nil, 768)

      assert Embeddings.dimension_counts(tenant.id) == %{768 => 1, 1536 => 1}
      assert Embeddings.active_dimension(tenant.id) == 1536

      enable_side_table_reads()

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query))

      ids = diagnose(Enum.map(results, & &1.id), tenant.id, 1536, "re-embed coexistence")

      assert ids == [article.id]
      assert meta.embedding_dimension == 1536
      assert meta.reembed_in_progress
      assert meta.reembed_pending_dimensions == [768]
    end

    test "the pending-dimension exclusion is REPORTED, never a silent shrink" do
      tenant = fixture(:tenant)
      done = embedded_article(tenant.id, %{title: "Done"}, :close, 1536)
      _todo = embedded_article(tenant.id, %{title: "Todo"}, :far, 1536)

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, done, vec(768, :close), nil, 768)

      progress = Embeddings.reembed_progress(tenant.id, 768)
      assert progress.total == 2
      assert progress.done == 1
      assert progress.pending == 1
      refute progress.complete

      meta = Embeddings.reembed_meta(tenant.id)
      assert meta.reembed_pending_rows == 1
      assert meta.reembed_excluded_reason =~ "not yet re-embedded"
    end

    test "reembed_meta/2 is EMPTY when nothing is in flight" do
      tenant = fixture(:tenant)
      embedded_article(tenant.id, %{title: "Only"}, :close, 1536)

      assert Embeddings.reembed_meta(tenant.id) == %{}
    end

    test "enqueue_reembed/2 refuses an unsupported target dimension" do
      tenant = fixture(:tenant)
      assert {:error, :unsupported_dimension} = Embeddings.enqueue_reembed(tenant.id, 3072)
      assert {:ok, job} = Embeddings.enqueue_reembed(tenant.id, 768)
      assert job.args["target_dim"] == 768
    end

    test "the worker flips the active dimension and drops stale rows ONLY at completion" do
      tenant = fixture(:tenant)
      article = embedded_article(tenant.id, %{title: "Migrating"}, :close, 1536)

      # Simulate the corpus fully re-embedded at 768 by an earlier batch: the worker's
      # anti-join is then empty and it takes the completion path.
      {:ok, _} =
        Embeddings.upsert_article_embedding(tenant.id, article, vec(768, :close), nil, 768)

      assert :ok =
               perform_job(Loopctl.Workers.ReembedWorker, %{
                 "tenant_id" => tenant.id,
                 "target_dim" => 768
               })

      assert Embeddings.active_dimension(tenant.id) == 768
      assert Embeddings.dimension_counts(tenant.id) == %{768 => 1}
    end

    # REVIEW #1 (critical): the completion sweep deletes off-dimension rows from BOTH
    # side tables, so anything the work queue does not enumerate but the sweep does
    # delete is a PERMANENT recall blackout. Memories and per-tenant materializations
    # of SYSTEM-scoped articles were both in that hole.
    test "the completion sweep NEVER deletes a row the re-embed did not migrate" do
      tenant = fixture(:tenant)
      article = embedded_article(tenant.id, %{title: "Own"}, :close, 1536)
      sys = system_article()
      memory = fixture(:memory, tenant_id: tenant.id)

      {:ok, _} =
        Embeddings.materialize_system_article_embedding(
          tenant.id,
          sys,
          vec(1536, :close),
          "sys",
          1536
        )

      {:ok, _} =
        Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536, :close), "mem", 1536)

      # Only the tenant's OWN article has a 768 twin — the memory and the system
      # materialization do not.
      {:ok, _} =
        Embeddings.upsert_article_embedding(tenant.id, article, vec(768, :close), nil, 768)

      refute Embeddings.reembed_complete?(tenant.id, 768)

      assert {:error, :reembed_incomplete} = Embeddings.drop_stale_dimensions(tenant.id, 768)

      # Nothing was deleted: all three 1536 rows survive.
      assert Embeddings.article_dimension_counts(tenant.id) == %{768 => 1, 1536 => 2}
      assert Embeddings.memory_dimension_counts(tenant.id) == %{1536 => 1}
    end

    test "the work queue enumerates SYSTEM-scoped materializations and MEMORIES" do
      tenant = fixture(:tenant)
      sys = system_article()
      memory = fixture(:memory, tenant_id: tenant.id)

      {:ok, _} =
        Embeddings.materialize_system_article_embedding(
          tenant.id,
          sys,
          vec(1536, :close),
          "sys",
          1536
        )

      {:ok, _} =
        Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536, :close), "mem", 1536)

      # `articles.tenant_id` is NULL for a system article — the previous queue keyed
      # off it and so never saw this row.
      assert Enum.map(Embeddings.pending_reembed_articles(tenant.id, 768, 10), & &1.id) == [
               sys.id
             ]

      assert Enum.map(Embeddings.pending_reembed_memories(tenant.id, 768, 10), & &1.id) == [
               memory.id
             ]
    end

    # REVIEW #10: the vectors come from the tenant's CURRENTLY configured model, which
    # (the ordinary case) still emits the OLD length. That must be one legible,
    # non-retryable failure, not five full-batch provider re-bills ending in an opaque
    # changeset term.
    test "the worker DISCARDS a batch whose model emits the wrong length, naming both" do
      tenant = fixture(:tenant)
      embedded_article(tenant.id, %{title: "Own"}, :close, 1536)

      # The default stub emits 1536-dim vectors; the target is 768.
      assert {:discard, {:dimension_mismatch, 768, 1536}} =
               perform_job(Loopctl.Workers.ReembedWorker, %{
                 "tenant_id" => tenant.id,
                 "target_dim" => 768
               })
    end

    # REVIEW #6: `active_dimension/1` is DERIVED, so a model change can move it to the
    # target while the whole corpus is still at the old one. The old
    # `active == target_dim -> :ok` short-circuit made the re-embed a permanent no-op
    # for exactly that tenant, leaving it with empty recall forever.
    test "a tenant whose ACTIVE dimension already equals the target still re-embeds" do
      tenant = fixture(:tenant)
      article = embedded_article(tenant.id, %{title: "Stale"}, :close, 1536)

      # The model table now says 768 while the corpus is entirely at 1536.
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 768)
      assert Embeddings.active_dimension(tenant.id) == 768

      assert Enum.map(Embeddings.pending_reembed_articles(tenant.id, 768, 10), & &1.id) == [
               article.id
             ]
    end

    # REVIEW #2: Oban's DEFAULT unique states include `:executing`, so a job
    # re-enqueuing ITSELF conflicts with the job doing the enqueueing and the
    # continuation is silently swallowed — a multi-batch corpus stalls after batch 1.
    test "both self-continuing workers exclude :executing from their unique states" do
      for worker <- [
            Loopctl.Workers.ReembedWorker,
            Loopctl.Workers.SystemCorpusEmbeddingWorker
          ] do
        states = worker.__opts__() |> Keyword.fetch!(:unique) |> Keyword.fetch!(:states)

        refute :executing in states,
               "#{inspect(worker)} would swallow its own self-continuation"

        refute :completed in states
        assert :available in states
        assert :scheduled in states
      end
    end

    test "the worker DISCARDS an unsupported target rather than seq-scanning forever" do
      tenant = fixture(:tenant)

      assert {:discard, {:unsupported_dimension, 3072}} =
               perform_job(Loopctl.Workers.ReembedWorker, %{
                 "tenant_id" => tenant.id,
                 "target_dim" => 3072
               })
    end
  end

  # --- helpers ---

  # `Memory.recall/2` accepts a PRECOMPUTED embedding, so these tests exercise the
  # real recall path (including the HeavyRead guard) without a provider round-trip.
  defp recall(scope, embedding) do
    Memory.recall(scope, embedding: {:ok, embedding}, limit: 10)
  end

  defp system_article do
    %Article{tenant_id: nil, scope: :system}
    |> Article.create_changeset(%{
      title: "System article #{System.unique_integer([:positive])}",
      body: "shared canonical content",
      category: :reference,
      status: :published,
      scope: :system
    })
    |> AdminRepo.insert!()
  end
end
