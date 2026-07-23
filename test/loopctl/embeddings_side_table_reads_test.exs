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

  ## Why this is `async: true`

  It used to be `async: false`, because selecting the side-table path meant
  flipping the VM-GLOBAL `SystemConfig`/`:persistent_term` cutover flag for the
  whole node. `async: false` was not enough: the mutation still leaked past this
  module's boundary, and a test that had just asserted the flag was on could run
  its query after the value had been reset, silently take the LEGACY path, find no
  legacy embedding, and fail with `left: []`. Those failures looked like a vector
  recall bug and moved between tests and runs.

  The read-path decision is now an injected collaborator
  (`Loopctl.Embeddings.ReadPathBehaviour`), so `enable_side_table_reads/0` is a
  PROCESS-SCOPED `Mox.stub/3`. Nothing global is written, so these tests are
  isolated and run async.

  The flag's real globality is not incidental — it is the point of
  AC-41.1.8(ii)/(iii): per-NODE, flipped once every node runs dual-write code,
  reverted with a single operator UPDATE and no redeploy. That production
  behaviour is covered directly in
  `test/loopctl/embeddings/system_config_read_path_test.exs`.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Memory
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Memory.Scope

  setup :verify_on_exit!

  defp enable_side_table_reads do
    stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> true end)
    assert Embeddings.side_table_reads_enabled?()
  end

  # Per-test-unique vectors via `Loopctl.DataCase.test_vec/2` (see its @doc). `:close`
  # and `:query` are identical (cosine 1.0); `:far` is a strictly-worse but genuinely
  # NEAR neighbour (`:near`, cosine ~0.71). Keying every test's vectors into a disjoint
  # window is what dissolves the shared-HNSW-index clique that made this ranking test
  # flake on CI — a fixed `half_ones` vector shared across ~50 uses in this file (plus
  # siblings) formed an all-ties clique the approximate ANN walk could not navigate, so
  # `:far` was intermittently evicted before the tenant filter ran. Do NOT reintroduce a
  # fixed/global vector here.
  defp vec(dim, :close), do: test_vec(dim, :primary)
  defp vec(dim, :query), do: test_vec(dim, :primary)
  defp vec(dim, :far), do: test_vec(dim, :near)

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

    # PAGE SIZE IS LOAD-BEARING, do not "simplify" it back to the default.
    #
    # These two articles are not the only candidates: the on-demand system-corpus
    # materialization described on `vec/2` puts the seeded system rows in the pool
    # too. At the default `limit: 10` this asserts on pool capacity rather than on
    # ranking; a page wider than the whole candidate set keeps the assertion about
    # ORDER, which is what AC-41.1.5 actually promises. 50 is comfortably under
    # `max_relevance_page_size/0` (100).
    test "ranks by similarity over the side table at the tenant's dimension" do
      tenant = fixture(:tenant)
      close = embedded_article(tenant.id, %{title: "Close"}, :close, 1536)
      far = embedded_article(tenant.id, %{title: "Far"}, :far, 1536)

      enable_side_table_reads()

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query), limit: 50)

      ids = Enum.map(results, & &1.id)
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

      assert Enum.map(results, & &1.id) == [b_article.id]
      assert meta.embedding_dimension == 768
    end

    test "the pool query passes guard!/2 and an unscoped variant does NOT" do
      tenant = fixture(:tenant)
      article = embedded_article(tenant.id, %{title: "Guarded"}, :close, 1536)

      query = Knowledge.semantic_side_table_pool_query(tenant.id, vec(1536, :query), 1536, 10)

      assert [%{article_id: id}] = HeavyRead.all(tenant.id, query)
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

      assert Enum.map(results, & &1.id) == [sys.id]
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
      assert Enum.map(results, & &1.id) == [live.id]
    end

    test "selective filters still apply — they just live OUTSIDE the index-ordered ANN" do
      tenant = fixture(:tenant)
      pattern = embedded_article(tenant.id, %{category: :pattern}, :close, 1536)
      _decision = embedded_article(tenant.id, %{category: :decision}, :close, 1536)

      enable_side_table_reads()

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant.id, vec(1536, :query), category: :pattern)

      assert Enum.map(results, & &1.id) == [pattern.id]
    end

    test "tenant isolation holds on the side-table read path" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      _a = embedded_article(tenant_a.id, %{title: "A"}, :close, 1536)
      b = embedded_article(tenant_b.id, %{title: "B"}, :close, 1536)

      enable_side_table_reads()

      assert {:ok, %{results: results}} =
               Knowledge.search_semantic(tenant_b.id, vec(1536, :query))

      assert Enum.map(results, & &1.id) == [b.id]
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

      assert {:ok, %{results: results}} = Knowledge.search_semantic(tenant.id, vec(1536, :query))
      assert article.id in Enum.map(results, & &1.id)
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

      assert Enum.map(results, & &1.id) == [article.id]
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
