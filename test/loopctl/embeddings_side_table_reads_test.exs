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

  ## Why `async: false`

  The cutover flag is a `SystemConfig` integer cached in `:persistent_term`, which
  is VM-GLOBAL. Flipping it inside an async test would change the read path of
  every other test running concurrently. That globality is not incidental — it is
  the point of AC-41.1.8(ii)/(iii): the flag is per-NODE, flipped once every node
  runs dual-write code, and reverted with a single operator UPDATE and no redeploy.
  """

  use Loopctl.DataCase, async: false
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
  alias Loopctl.SystemConfig

  setup :verify_on_exit!

  setup do
    on_exit(fn -> SystemConfig.put(Embeddings.read_flag_key(), 0) end)
    :ok
  end

  defp enable_side_table_reads do
    {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 1)
    assert Embeddings.side_table_reads_enabled?()
  end

  # Deterministic, well-separated vectors: `:close` and `:query` are identical
  # (cosine distance 0); `:far` is a STRICTLY WORSE but still genuinely NEAR
  # neighbour (cosine similarity ~0.71 — it shares a quarter of the query's
  # non-zero dimensions).
  #
  # `:far` was ORTHOGONAL (similarity 0.0, the worst rank expressible) and that made
  # the ranking test flake ~8/10. Two independent mechanisms punish a worst-case
  # vector, and neither is a defect:
  #
  #   1. HNSW is an APPROXIMATE index. Its graph traversal is not obliged to reach
  #      the most distant point in the set, and the graph's shape depends on
  #      insertion order, so "does the single worst match come back" is a coin flip
  #      by construction — not something an ANN read path ever promises.
  #   2. AC-41.1.7 makes the semantic read path materialize the SYSTEM corpus on
  #      demand, and the Epic 26 bootstrap migrations seed a system-scoped article
  #      set into EVERY database, CI included (20260411231009_seed_epic_26_phase_0_
  #      articles and siblings). Under `testing: :inline` that runs SYNCHRONOUSLY
  #      inside the search, so those rows join the pool — and every one of them
  #      (positive similarity) outranks an orthogonal vector.
  #
  # Ranking is what AC-41.1.5 is about, so `:far` is now near enough that HNSW
  # reliably finds it and it reliably sorts BELOW `:close`. Keep it a real
  # neighbour; do not restore the orthogonal form.
  defp vec(dim, :close), do: half_ones(dim)
  defp vec(dim, :query), do: half_ones(dim)

  defp vec(dim, :far) do
    quarter = div(dim, 4)
    List.duplicate(1.0, quarter) ++ List.duplicate(0.0, dim - quarter)
  end

  defp half_ones(dim), do: List.duplicate(1.0, div(dim, 2)) ++ List.duplicate(0.0, div(dim, 2))

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
    test "the cutover flag switches the read path and is REVERSIBLE" do
      refute Embeddings.side_table_reads_enabled?()
      enable_side_table_reads()
      assert Embeddings.side_table_reads_enabled?()

      {:ok, _} = SystemConfig.put(Embeddings.read_flag_key(), 0)
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

    # Review #8: the LEGACY path deliberately carries NO dimension disclosure. It
    # cannot be a true statement there (results come from `articles.embedding`, there
    # is no per-dimension corpus to be unmaterialized and no re-embed can be
    # observed), and computing it cost three extra queries — a tenants SELECT +
    # settings read, a NOT EXISTS anti-join over every system-scoped article, and a
    # re-embed existence probe — on the hottest read in the product, against
    # AC-41.1.12's "the hosted default must not regress".
    test "the legacy read path pays NOTHING for the dimension disclosure" do
      tenant = fixture(:tenant)
      system_article()
      embedded_article(tenant.id, %{title: "Own"}, :close, 1536)

      refute Embeddings.side_table_reads_enabled?()

      assert {:ok, %{meta: meta}} = Knowledge.search_semantic(tenant.id, vec(1536, :query))
      refute Map.has_key?(meta, :system_corpus_recall)
      refute Map.has_key?(meta, :embedding_dimension)
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
