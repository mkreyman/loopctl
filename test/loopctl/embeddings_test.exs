defmodule Loopctl.EmbeddingsTest do
  @moduledoc """
  US-41.1 — per-tenant embedding dimension via the `article_embeddings` /
  `memory_embeddings` side tables.

  Covers TC-41.1.1 (two dimensions coexist), TC-41.1.3 (resumable backfill +
  reconciliation), TC-41.1.4 (legible wrong-length rejection), TC-41.1.5 (RLS +
  HeavyRead guard), TC-41.1.6 (trigger-enforced live marker, including the
  `update_all` bypass), TC-41.1.7 (system corpus disclosure), TC-41.1.8 (published
  set == migrated indexes; no index DDL on the request path) and TC-41.1.9 (no
  per-item dimension lookup in a batch).
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Memory.Memory
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Repo.HnswIndex

  setup :verify_on_exit!

  # Traced by `count_calls/2` for the AC-41.1.11 N+1 guards (see the helpers at the bottom).
  @resolve_dimension_mfa {Loopctl.Embeddings, :resolve_write_dimension, 1}
  @sub_batch_mfa {Loopctl.Workers.BatchArticleEmbeddingWorker, :embed_and_store_sub_batch, 3}

  # Both helpers ride this test's OWN sparse dimensions (`test_vec/2`, seeded per test by
  # `Process.put(:test_vec_axis, ...)` in DataCase.setup) rather than a shape every test
  # shares. They used to be `sin(i / dim)` and `sin((i + seed) / dim)` — DENSE and IDENTICAL
  # across every test at a given dim, which is a distance-0 clique in the shared pgvector
  # HNSW index: under concurrent load the graph walk cannot navigate a clique of exact ties
  # and non-deterministically misses exact matches (KB `4e5ccb17`, `0bdadd52`). It is the
  # same reason DataCase's default MockEmbeddingClient stub keys its vector on `tenant_id`
  # instead of returning a constant.
  #
  # NOT "dead tuples crowd out the live row" — KB `c6fd1e5d` lists that as a dead theory,
  # disproved by probe (pgvector skips invisible tuples and keeps scanning past 2000
  # rolled-back ties). Read that article before touching this; the family has been
  # misdiagnosed twice.
  defp vec(dim), do: test_vec(dim, :primary)

  # N DISTINCT vectors that all stay inside THIS test's region: the primary window carries
  # the identity, and a seed-scaled component on the test's own orthogonal window separates
  # the members from each other. No call site depends on a particular similarity BETWEEN
  # them — they just have to be distinct and findable.
  defp vec(dim, seed) do
    base = test_vec(dim, :primary)
    orthogonal = test_vec(dim, :orthogonal)
    Enum.zip_with(base, orthogonal, fn b, o -> b + o * (seed / 10.0) end)
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.4 / TC-41.1.4 — the tenant's dimension and legible rejection
  # ---------------------------------------------------------------------------

  describe "active_dimension/1 (AC-41.1.4)" do
    test "defaults to :embedding_dimensions for a tenant with no model and no record" do
      tenant = fixture(:tenant)
      assert Embeddings.active_dimension(tenant.id) == 1536
      assert Embeddings.default_dimension() == 1536
    end

    test "derives from the static model table when the tenant names a model" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, tenant_id: tenant.id, embedding_model: "nomic-embed-text")

      assert Embeddings.active_dimension(tenant.id) == 768
    end

    test "the explicitly recorded column WINS over the model table" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, tenant_id: tenant.id, embedding_model: "nomic-embed-text")

      assert {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 1024)
      assert Embeddings.active_dimension(tenant.id) == 1024
    end

    test "rejects a dimension outside the published supported set" do
      tenant = fixture(:tenant)
      assert {:error, :unsupported_dimension} = Embeddings.set_tenant_dimension(tenant.id, 3072)
    end

    test "the model table normalizes provider prefixes, tags and casing" do
      assert Dimensions.for_model("ollama/nomic-embed-text:latest") == 768
      assert Dimensions.for_model("BAAI/bge-m3") == 1024
      assert Dimensions.for_model("text-embedding-3-small") == 1536
      assert Dimensions.for_model("a-model-nobody-has-heard-of") == nil
      assert Dimensions.for_model(nil) == nil
    end
  end

  describe "wrong-length vectors (TC-41.1.4)" do
    test "are rejected with an error naming BOTH the expected and actual length" do
      tenant = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 768)
      article = fixture(:article, tenant_id: tenant.id)

      assert {:error, changeset} =
               Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), nil)

      assert %{embedding: [message]} = errors_on(changeset)
      assert message =~ "expected 768"
      assert message =~ "got 1536"

      # ... and NOTHING was written, in either location.
      assert AdminRepo.aggregate(ArticleEmbedding, :count) == 0
      assert is_nil(AdminRepo.reload!(article).embedding_content_hash)
    end

    test "the validator is PURE — the expected value is the argument, not config" do
      article = %Article{}

      changeset = Article.embedding_changeset(article, vec(768), nil, 768)
      assert changeset.valid?

      changeset = Article.embedding_changeset(article, vec(768), nil, 1536)
      refute changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.1 / TC-41.1.1 — two dimensions coexist, never cross-rank
  # ---------------------------------------------------------------------------

  describe "coexisting dimensions (TC-41.1.1)" do
    test "two tenants at different dimensions coexist and are dimension-excluded" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant_b.id, 768)

      article_a = fixture(:article, tenant_id: tenant_a.id)
      article_b = fixture(:article, tenant_id: tenant_b.id)

      assert {:ok, row_a} = Embeddings.upsert_article_embedding(tenant_a.id, article_a, vec(1536))
      assert {:ok, row_b} = Embeddings.upsert_article_embedding(tenant_b.id, article_b, vec(768))

      assert row_a.dim == 1536
      assert row_b.dim == 768

      # The ANN pool for tenant B at 768 can NEVER see tenant A's 1536 vectors —
      # not merely "is unlikely to": the inner query is dimension-scoped, so a
      # cross-dimension comparison (which pgvector errors on) is unreachable.
      query =
        VectorSearch.index_safe_dimension_knn_base(
          ArticleEmbedding,
          tenant_b.id,
          vec(768),
          768,
          10
        )

      ids = tenant_b.id |> HeavyRead.all(query) |> Enum.map(& &1.id)

      assert ids == [row_b.id]
    end

    test "the SAME row may carry two dimensions at once (the re-embed window)" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id)

      assert {:ok, _} =
               Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), nil, 1536)

      assert {:ok, _} =
               Embeddings.upsert_article_embedding(tenant.id, article, vec(768), nil, 768)

      assert Embeddings.dimension_counts(tenant.id) == %{768 => 1, 1536 => 1}
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.1 / TC-41.1.6 — the live marker is enforced by the DB TRIGGER
  # ---------------------------------------------------------------------------

  describe "live_denorm (TC-41.1.6)" do
    test "an article superseded THROUGH THE CONTEXT leaves the ANN pool" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id, status: :published)
      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536))

      assert row.live_denorm

      article
      |> Ecto.Changeset.change(status: :superseded)
      |> AdminRepo.update!()

      refute AdminRepo.reload!(row).live_denorm
      assert ann_ids(tenant.id, ArticleEmbedding, 1536) == []
    end

    test "an article superseded via Repo.update_all STILL flips the marker" do
      # The load-bearing case: `update_all` bypasses every changeset, so if the
      # marker only moved in application code this row would keep occupying a pool
      # slot forever (the US-28.2 regression).
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id, status: :published)
      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536))

      AdminRepo.update_all(
        from(a in Article, where: a.id == ^article.id),
        set: [status: :superseded]
      )

      refute AdminRepo.reload!(row).live_denorm
      assert ann_ids(tenant.id, ArticleEmbedding, 1536) == []
    end

    test "a memory superseded via Repo.update_all STILL flips the marker" do
      tenant = fixture(:tenant)
      memory = fixture(:memory, tenant_id: tenant.id)
      other = fixture(:memory, tenant_id: tenant.id, subject_id: memory.subject_id)

      {:ok, row} =
        Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536), nil, 1536)

      assert row.live_denorm

      AdminRepo.update_all(
        from(m in Memory, where: m.id == ^memory.id),
        set: [superseded_by: other.id]
      )

      refute AdminRepo.reload!(row).live_denorm
    end

    test "live rows still fill the pool — no silent under-fill" do
      tenant = fixture(:tenant)

      rows =
        for i <- 1..5 do
          article = fixture(:article, tenant_id: tenant.id, status: :published)
          {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536, i))
          {article, row}
        end

      [{superseded_article, _} | live] = rows

      AdminRepo.update_all(
        from(a in Article, where: a.id == ^superseded_article.id),
        set: [status: :superseded]
      )

      recalled = ann_ids(tenant.id, ArticleEmbedding, 1536)

      assert length(recalled) == 4
      assert Enum.sort(recalled) == live |> Enum.map(fn {_, row} -> row.id end) |> Enum.sort()
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.6 / TC-41.1.5 — isolation on BOTH paths
  # ---------------------------------------------------------------------------

  describe "tenant isolation (TC-41.1.5)" do
    test "HeavyRead.guard!/2 ACCEPTS the real dimension-scoped search query" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id)
      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536))

      query =
        VectorSearch.index_safe_dimension_knn_base(
          ArticleEmbedding,
          tenant.id,
          vec(1536),
          1536,
          10
        )

      assert [%{id: id}] = HeavyRead.all(tenant.id, query)
      assert id == row.id
    end

    test "an intentionally UNSCOPED variant DOES raise — the guard is load-bearing" do
      tenant = fixture(:tenant)

      unscoped =
        from(ae in ArticleEmbedding,
          where: ae.dim == 1536,
          where: ae.live_denorm,
          limit: 10
        )

      assert_raise ArgumentError, ~r/not fully scoped to the given tenant/, fn ->
        HeavyRead.all(tenant.id, unscoped)
      end
    end

    test "memory_embeddings carries subject_id so guard_memory!/3 is satisfiable" do
      tenant = fixture(:tenant)
      memory = fixture(:memory, tenant_id: tenant.id)
      {:ok, row} = Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536), nil, 1536)

      assert row.subject_id == memory.subject_id

      inner =
        VectorSearch.index_safe_dimension_knn_base(
          MemoryEmbedding,
          tenant.id,
          vec(1536),
          1536,
          10
        )

      outer =
        from(
          c in subquery(
            select(inner, [x], %{id: x.id, tenant_id: x.tenant_id, subject_id: x.subject_id})
          ),
          where: c.tenant_id == ^tenant.id,
          where: c.subject_id == ^memory.subject_id,
          select: c.id
        )

      assert HeavyRead.all_memory(tenant.id, memory.subject_id, outer) == [row.id]
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.8 / AC-41.1.9 / TC-41.1.3 — dual-write, backfill, reconciliation
  # ---------------------------------------------------------------------------

  describe "dual-write and backfill (TC-41.1.3)" do
    test "a dim-1536 write lands in BOTH locations, in ONE transaction" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id)

      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), "hash-1")

      reloaded =
        AdminRepo.one(from(a in Article, where: a.id == ^article.id, select: a.embedding))

      assert Dimensions.vector_length(reloaded) == 1536
      assert row.embedding_content_hash == "hash-1"
      assert Dimensions.vector_length(row.embedding) == 1536
    end

    test "a NON-1536 write is side-table-only — the legacy column is untouched" do
      tenant = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 768)
      article = fixture(:article, tenant_id: tenant.id)

      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(768))

      assert row.dim == 768

      legacy = AdminRepo.one(from(a in Article, where: a.id == ^article.id, select: a.embedding))
      assert is_nil(legacy)
    end

    test "recall_availability/1 SAYS a non-default dimension is not yet readable" do
      tenant = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 768)

      availability = Embeddings.recall_availability(tenant.id)

      assert availability.dimension == 768
      refute availability.semantic_available
      assert availability.reason =~ "keyword-only"
    end

    test "the backfill is batched, resumable and produces no duplicates on re-run" do
      tenant = fixture(:tenant)

      articles =
        for i <- 1..5 do
          article = fixture(:article, tenant_id: tenant.id)

          article
          |> Article.embedding_changeset(vec(1536, i), "h#{i}", 1536)
          |> AdminRepo.update!()
        end

      # Interrupt it: one batch of two rows only.
      assert {:ok, %{copied: 2, batches: 1}} =
               Embeddings.backfill_articles(batch_size: 2, max_batches: 1)

      assert AdminRepo.aggregate(ArticleEmbedding, :count) == 2

      # Mid-flight search over the partially-migrated corpus still sees the
      # LEGACY column, so results are unchanged (the read flag has not flipped).
      refute Embeddings.side_table_reads_enabled?()

      # Resume to completion.
      assert {:ok, %{copied: 3}} = Embeddings.backfill_articles(batch_size: 2)
      assert AdminRepo.aggregate(ArticleEmbedding, :count) == 5

      # Re-running a completed backfill is a no-op — no duplicates.
      assert {:ok, %{copied: 0, batches: 0}} = Embeddings.backfill_articles(batch_size: 2)
      assert AdminRepo.aggregate(ArticleEmbedding, :count) == 5

      for article <- articles do
        assert AdminRepo.aggregate(
                 from(ae in ArticleEmbedding, where: ae.article_id == ^article.id),
                 :count
               ) == 1
      end
    end

    test "a simulated crash between the two writes is caught by the RECONCILIATION pass" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id)

      # Simulate the crash window: the legacy column was written, the side-table
      # row never was. A cursor-based resumable backfill that had already reported
      # completion would never revisit this row — only the standing anti-join does.
      article
      |> Article.embedding_changeset(vec(1536), "h", 1536)
      |> AdminRepo.update!()

      assert Embeddings.article_reconciliation_gaps() == [article.id]

      assert {:ok, %{repaired: 1}} = Embeddings.reconcile_articles()
      assert Embeddings.article_reconciliation_gaps() == []
    end

    test "the memories backfill and reconciliation behave identically" do
      tenant = fixture(:tenant)
      memory = fixture(:memory, tenant_id: tenant.id)

      memory
      |> Memory.embedding_changeset(vec(1536), "h", 1536)
      |> AdminRepo.update!()

      assert Embeddings.memory_reconciliation_gaps() == [memory.id]
      assert {:ok, %{repaired: 1}} = Embeddings.reconcile_memories()
      assert Embeddings.memory_reconciliation_gaps() == []

      row = AdminRepo.one(MemoryEmbedding)
      assert row.subject_id == memory.subject_id
      assert row.dim == 1536
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.7 / TC-41.1.7 — the system-scoped corpus
  # ---------------------------------------------------------------------------

  describe "system-scoped corpus (TC-41.1.7)" do
    test "before materialization the meta reports keyword-only, never a silent absence" do
      tenant = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 768)
      system_article()

      meta = Embeddings.system_corpus_meta(tenant.id)

      assert meta.system_corpus_recall == "keyword_only"
      assert meta.system_corpus_dimension == 768
      assert meta.system_corpus_reason =~ "keyword"
    end

    test "after per-tenant materialization it is semantically recallable and guard-clean" do
      tenant = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 768)
      article = system_article()

      # The instance ships a bootstrap system corpus (US-26.0.5), so assert on
      # MEMBERSHIP rather than an exact list.
      pending_ids =
        tenant.id
        |> Embeddings.unmaterialized_system_articles(768, limit: 500)
        |> Enum.map(& &1.id)

      assert article.id in pending_ids

      # Materialized with the REQUESTING tenant's own credential, stored as an
      # ordinary row carrying THAT tenant_id — so the conjunctive tenant predicate
      # holds and `guard!/2` is not relaxed.
      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(768), nil, 768)
      assert row.tenant_id == tenant.id

      remaining =
        tenant.id
        |> Embeddings.unmaterialized_system_articles(768, limit: 500)
        |> Enum.map(& &1.id)

      refute article.id in remaining

      query =
        VectorSearch.index_safe_dimension_knn_base(ArticleEmbedding, tenant.id, vec(768), 768, 10)

      assert [%{id: id}] = HeavyRead.all(tenant.id, query)
      assert id == row.id
    end

    test "two tenants may each materialize the SAME system article at the same dim" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      article = system_article()

      assert {:ok, a} =
               Embeddings.upsert_article_embedding(tenant_a.id, article, vec(768), nil, 768)

      assert {:ok, b} =
               Embeddings.upsert_article_embedding(tenant_b.id, article, vec(768), nil, 768)

      refute a.id == b.id
      assert a.article_id == b.article_id
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.3 / TC-41.1.8 — the published set == the migrated index set
  # ---------------------------------------------------------------------------

  describe "supported dimensions and index DDL (TC-41.1.8)" do
    test "every published dimension has a per-dimension index on BOTH side tables" do
      published = Embeddings.supported_dimensions()

      assert published ==
               LoopctlWeb.WellKnownController.discovery_body().capabilities[
                 :supported_embedding_dimensions
               ]

      for table <- ["article_embeddings", "memory_embeddings"] do
        existing = hnsw_index_names(table)

        for dim <- published do
          expected = HnswIndex.dimension_index_name(table, dim)
          assert expected in existing, "missing #{expected}"
        end

        # And nothing EXTRA: an index for an unpublished dimension would be an
        # undeclared capability.
        assert length(existing) == length(published)
      end
    end

    test "the query builder refuses a dimension outside the compile-time set" do
      tenant = fixture(:tenant)

      assert_raise ArgumentError, ~r/not supported by this instance/, fn ->
        VectorSearch.index_safe_dimension_knn_base(
          ArticleEmbedding,
          tenant.id,
          vec(3072),
          3072,
          10
        )
      end
    end

    test "no lib/ module outside a migration issues CREATE INDEX" do
      # `repo/hnsw_index.ex` BUILDS the SQL but is only ever CALLED from a migration
      # (asserted below); `index_health.ex` only ever RENDERS remediation advice; the
      # `loopctl.embeddings` mix task is the OPERATOR plane and likewise only renders —
      # its GH #578 revert refusal prints the rebuild for a human to run (asserted
      # below: it never hands the DDL to a repo).
      allowed = [
        "lib/loopctl/repo/hnsw_index.ex",
        "lib/loopctl/index_health.ex",
        "lib/mix/tasks/loopctl.embeddings.ex"
      ]

      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&(&1 in allowed))
        |> Enum.filter(fn path ->
          path |> File.read!() |> String.match?(~r/CREATE\s+INDEX/i)
        end)

      assert offenders == [],
             "index DDL is migration/operator plane only, found in: #{inspect(offenders)}"

      # "Operator plane" must not become a blanket exemption for a file that could
      # quietly grow a LIVE `CREATE INDEX`. The task renders the rebuild into a string
      # for a human to run; every repo call it makes is a catalog SELECT.
      task_source = File.read!("lib/mix/tasks/loopctl.embeddings.ex")

      verbs =
        ~r/(?:query!?|execute)\(\s*"{0,3}\s*\n?\s*([A-Za-z]+)/
        |> Regex.scan(task_source)
        |> Enum.map(fn [_full, verb] -> String.upcase(verb) end)

      refute verbs == [], "expected the operator task to make at least one repo call"

      assert Enum.all?(verbs, &(&1 == "SELECT")),
             "the operator task must RENDER index DDL, never execute it; found: #{inspect(verbs)}"

      # And no REQUEST-PATH module reaches the DDL builder at all.
      callers =
        Path.wildcard("lib/loopctl_web/**/*.ex")
        |> Enum.filter(fn path ->
          path |> File.read!() |> String.contains?("HnswIndex")
        end)

      assert callers == []
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.11 / TC-41.1.9 — no per-item dimension lookup
  # ---------------------------------------------------------------------------

  describe "batch embedding (TC-41.1.9)" do
    test "a batch of 100 articles resolves the dimension ONCE" do
      tenant = fixture(:tenant)

      entries =
        for i <- 1..100 do
          {fixture(:article, tenant_id: tenant.id), vec(1536, i), "h#{i}"}
        end

      {counts, result} =
        count_calls([resolution: @resolve_dimension_mfa], fn ->
          Embeddings.upsert_article_embeddings(tenant.id, entries)
        end)

      assert {:ok, rows} = result
      assert length(rows) == 100

      assert counts.resolution == 1,
             "the dimension was resolved #{counts.resolution} times for a 100-item batch; " <>
               "AC-41.1.11 requires exactly one resolution, threaded into every write"
    end
  end

  describe "batch embedding — the REAL US-37.4 path (TC-41.1.9)" do
    # The TC-41.1.9 test above exercises `upsert_article_embeddings/3`. The path the
    # PRODUCT actually runs is `BatchArticleEmbeddingWorker.store_all/2`, which loops
    # `Knowledge.update_embedding/5` once per article — so asserting only the former
    # let the gate pass while the production path did ~100 tenant lookups per batch
    # (review #5). This asserts on the SHAPE that matters: the dimension is resolved once
    # per provider sub-batch, so the count tracks the SUB-BATCH count and never the
    # article count.
    test "the tenant dimension is resolved once per sub-batch, never per article" do
      for n <- [3, 30] do
        counts = batch_worker_dimension_resolutions(n)

        # This one is what keeps the next assertion DISCRIMINATING, so it is asserted
        # rather than assumed: a ratio of resolutions to sub-batches cannot tell a
        # per-ARTICLE N+1 from a per-SUB-BATCH resolution once the two counts coincide,
        # which is exactly what a one-article-per-sub-batch byte budget produces.
        assert counts.sub_batch == 1,
               "expected #{n} tiny articles to ride ONE provider sub-batch at the default " <>
                 "byte budget, got #{counts.sub_batch} — with one article per sub-batch " <>
                 "the resolution count below cannot detect the N+1 at all"

        assert counts.resolution == 1,
               "for #{n} articles the dimension was resolved #{counts.resolution} time(s) " <>
                 "across #{counts.sub_batch} provider sub-batch(es); AC-41.1.11 requires " <>
                 "exactly one resolution per sub-batch. A count that tracks the ARTICLE " <>
                 "count IS the N+1."
      end
    end
  end

  describe "one transaction, both locations (AC-41.1.8(i))" do
    # The existing coverage asserted atomicity by reading BOTH locations after a
    # SUCCESSFUL write, which cannot distinguish one transaction from two (review
    # #11). This forces a FAILURE after the dual-write steps and proves the legacy
    # column write is rolled back with the side-table row.
    test "a failure AFTER the dual-write rolls BOTH locations back" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id)

      result =
        Ecto.Multi.new()
        |> Embeddings.article_embedding_multi(tenant.id, article, vec(1536), "h", 1536)
        |> Ecto.Multi.run(:boom, fn _repo, _changes -> {:error, :boom} end)
        |> AdminRepo.transaction()

      assert {:error, :boom, :boom, _done} = result

      assert is_nil(
               AdminRepo.one(from(a in Article, where: a.id == ^article.id, select: a.embedding))
             )

      assert AdminRepo.aggregate(
               from(ae in ArticleEmbedding, where: ae.article_id == ^article.id),
               :count
             ) == 0
    end

    test "a wrong-length vector fails the whole transaction, writing NEITHER location" do
      tenant = fixture(:tenant)
      article = fixture(:article, tenant_id: tenant.id)

      assert {:error, %Ecto.Changeset{}} =
               Embeddings.upsert_article_embedding(tenant.id, article, vec(768), "h", 1536)

      assert is_nil(
               AdminRepo.one(from(a in Article, where: a.id == ^article.id, select: a.embedding))
             )

      assert AdminRepo.aggregate(ArticleEmbedding, :count) == 0
    end
  end

  describe "search results MID-backfill (AC-41.1.8 / TC-41.1.3)" do
    # The backfill test asserted only `refute side_table_reads_enabled?()` — a config
    # flag, not search output (review #11). AC-41.1.8 requires asserting that a
    # semantic search over a PARTIALLY migrated corpus returns results IDENTICAL to
    # pre-backfill.
    test "a semantic search over a partially migrated corpus is byte-identical" do
      tenant = fixture(:tenant)

      for i <- 1..5 do
        :article
        |> fixture(tenant_id: tenant.id, status: :published)
        |> Article.embedding_changeset(vec(1536, i), "h#{i}", 1536)
        |> AdminRepo.update!()
      end

      assert {:ok, before} = Knowledge.search_semantic(tenant.id, vec(1536), limit: 10)

      # Interrupt the backfill halfway: two of five rows mirrored.
      assert {:ok, %{copied: 2}} = Embeddings.backfill_articles(batch_size: 2, max_batches: 1)
      assert AdminRepo.aggregate(ArticleEmbedding, :count) == 2

      assert {:ok, midway} = Knowledge.search_semantic(tenant.id, vec(1536), limit: 10)

      assert Enum.map(midway.results, & &1.id) == Enum.map(before.results, & &1.id)
      assert midway.meta.total_count == before.meta.total_count
      assert midway.meta.search_mode == before.meta.search_mode
    end

    test "the backfill only reports `complete` once the gap probe agrees" do
      tenant = fixture(:tenant)

      for i <- 1..3 do
        :article
        |> fixture(tenant_id: tenant.id)
        |> Article.embedding_changeset(vec(1536, i), "h#{i}", 1536)
        |> AdminRepo.update!()
      end

      # Budget-limited run: work remains, so `complete` must be FALSE. AC-41.1.8
      # makes the read-flag flip conditional on that report, so a premature
      # completion is load-bearing (review #14).
      assert {:ok, %{copied: 1, complete: false}} =
               Embeddings.backfill_articles(batch_size: 1, max_batches: 1)

      assert {:ok, %{complete: true}} = Embeddings.backfill_articles(batch_size: 10)
    end
  end

  # --- helpers ---

  # AC-41.1.11 says the tenant dimension is resolved ONCE per provider sub-batch and threaded
  # into every write. Both guards above used to count `FROM "tenants"` QUERIES, which cannot see
  # that for two independent reasons — and did it anyway from 2026-08 until 2026-08-25:
  #
  #   1. `:telemetry.attach/4` is VM-GLOBAL. The handler matched any query containing
  #      `FROM "tenants"`, and the whole async suite queries tenants constantly, so every
  #      OTHER test running concurrently posted into this test's mailbox. The count measured
  #      how busy the box was. On the `<= 1` assertion foreign traffic could only push the
  #      number UP, which is a spurious FAILURE — the flake.
  #   2. Worse, the number being reached for is ZERO either way: `resolve_write_dimension/1`
  #      reads a CACHE, so a correct implementation and an N+1 one both emit no tenants
  #      query here. Measured 2026-08-25 with correct scoping: both counts were 0, so
  #      `large <= small` was `0 <= 0` and `<= 1` was `0 <= 1` — vacuously true, forever,
  #      for any implementation. Neither guard could fail. Neither protected AC-41.1.11.
  #
  # So count the RESOLUTIONS themselves. `:erlang.trace/3` is scoped to a single PID and every
  # call site here runs inline in the test process, so no other test can be observed — which
  # fixes (1) structurally rather than by filtering — and it measures the invariant directly
  # rather than a proxy that caching had already zeroed out, which fixes (2). A count of zero
  # is asserted against too: it means the code under test never ran.
  defp count_calls(labelled_mfas, fun) do
    collector = spawn_link(fn -> collect_traces(%{}) end)

    # Load-bearing: `trace_pattern` on an UNLOADED module matches nothing and silently
    # traces nothing. Without this, the first call in a fresh VM reported 0 resolutions and
    # the second reported 1 — an invented asymmetry that looks exactly like a real finding.
    Enum.each(labelled_mfas, fn {_label, {module, _f, _a}} ->
      {:module, _} = Code.ensure_loaded(module)
    end)

    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    # The match count is asserted so a future rename cannot make this guard quietly count
    # nothing and pass.
    Enum.each(labelled_mfas, fn {label, mfa} ->
      assert :erlang.trace_pattern(mfa, true, [:local]) == 1,
             "trace_pattern matched no #{label} function — nothing would have been counted"
    end)

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])
      end

    send(collector, {:report, self()})

    traced =
      receive do
        {:traces, counts} -> counts
      after
        2_000 -> flunk("the trace collector never reported")
      end

    {Map.new(labelled_mfas, fn {label, mfa} -> {label, Map.get(traced, mfa, 0)} end), result}
  end

  defp collect_traces(counts) do
    receive do
      {:trace, _pid, :call, {m, f, args}} ->
        collect_traces(Map.update(counts, {m, f, length(args)}, 1, &(&1 + 1)))

      {:report, pid} ->
        send(pid, {:traces, counts})
    end
  end

  # Runs the REAL batch worker over `n` articles and returns how many times it resolved the
  # dimension, alongside how many provider sub-batches it ran. Both numbers are returned
  # because the caller needs BOTH: `generate_and_store_project_group/3` splits by
  # `Knowledge.embedding_batch_max_chars/0`, and at a budget that puts one article per
  # sub-batch a per-ARTICLE resolution and a per-SUB-BATCH one are the same number, so a
  # bare ratio between them would be inert. The budget here is the 1_000_000-char default:
  # its `:persistent_term` cache is VM-global, but every test that shrinks it lives in
  # `batch_article_embedding_worker_test.exs`, which is `async: false` PRECISELY so the
  # write cannot leak (ExUnit runs sync modules only after every async module has finished).
  # Do NOT add such a write to an async module — that is the cross-module leakage
  # `config_embedding_read_path_test.exs` guards against.
  defp batch_worker_dimension_resolutions(n) do
    tenant = fixture(:tenant)
    articles = for _ <- 1..n, do: fixture(:article, tenant_id: tenant.id)

    {counts, result} =
      count_calls([resolution: @resolve_dimension_mfa, sub_batch: @sub_batch_mfa], fn ->
        perform_job(Loopctl.Workers.BatchArticleEmbeddingWorker, %{
          "tenant_id" => tenant.id,
          "article_ids" => Enum.map(articles, & &1.id)
        })
      end)

    # A snooze or a provider error would leave the counts below meaningless; say so instead
    # of raising a MatchError that reads like the N+1 guard itself failed.
    assert result == :ok,
           "the batch worker did not complete (#{inspect(result)}), so the resolution " <>
             "counts prove nothing about AC-41.1.11"

    counts
  end

  defp ann_ids(tenant_id, schema, dim) do
    schema
    |> VectorSearch.index_safe_dimension_knn_base(tenant_id, vec(dim), dim, 100)
    |> then(&HeavyRead.all(tenant_id, &1))
    |> Enum.map(& &1.id)
  end

  defp hnsw_index_names(table) do
    %{rows: rows} =
      AdminRepo.query!(
        """
        SELECT i.relname
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am am ON am.oid = i.relam
        WHERE t.relname = $1 AND n.nspname = 'public' AND am.amname = 'hnsw'
        """,
        [table]
      )

    List.flatten(rows)
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
