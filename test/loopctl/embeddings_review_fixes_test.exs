defmodule Loopctl.EmbeddingsReviewFixesTest do
  @moduledoc """
  US-41.1 REVIEW fixes — the classes the original story shipped without cover.

  Every test here corresponds to a confirmed review finding, and each one FAILED
  before its fix:

    * embedding IDEMPOTENCY at a non-1536 dimension (the dedupe guards read only the
      legacy columns, which are never written for those tenants — an unbounded paid
      re-billing loop);
    * `suggest_links` reading the SOURCE vector from the legacy column (the candidate
      half was migrated, the source half was not);
    * a model-derived but instance-unsupported dimension (3072) accepted on the write
      path and RAISING on the read path;
    * the AC-41.1.10 model pin that makes "a re-embed does not black out recall" true;
    * `live_denorm` marker drift (the write-skew safety net);
    * the side-table upsert aborting a whole dual-write Multi on a concurrent write;
    * memory/system write paths not PINNING the tenant's dimension;
    * system-corpus materialization being existence-only and status-blind;
    * the read-path materialization enqueue looping forever past a terminal job;
    * the re-embed pin moving BEFORE the completeness-gated sweep;
    * the enforced (not merely denormalized) `memory_embeddings.subject_id`.

  `async: true` for the same reason as `Loopctl.EmbeddingsSideTableReadsTest`: the
  cutover read-path decision is injected (`Loopctl.Embeddings.ReadPathBehaviour`)
  and stubbed per-process, never flipped VM-globally, so nothing here writes shared
  state.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Memory
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ArticleEmbeddingWorker
  alias Loopctl.Workers.BatchArticleEmbeddingWorker
  alias Loopctl.Workers.MemoryEmbeddingWorker
  alias Loopctl.Workers.ReembedWorker
  alias Loopctl.Workers.SystemCorpusEmbeddingWorker

  setup :verify_on_exit!

  defp enable_side_table_reads do
    stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> true end)
    assert Embeddings.side_table_reads_enabled?()
  end

  # Per-test-unique via `Loopctl.DataCase.test_vec/2` (dissolves the shared-HNSW-index
  # clique; see its @doc). `vec` == `:primary` (cosine 1.0), `far_vec` == `:orthogonal`
  # (cosine 0). NOTE: a 3072-dim vector has no supported HNSW index; test_vec still returns a
  # valid sparse vector for the dimension-rejection tests that never index it.
  defp vec(dim), do: test_vec(dim, :primary)
  defp far_vec(dim), do: test_vec(dim, :orthogonal)

  defp content_hash(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp tenant_at(dimension) do
    tenant = fixture(:tenant)
    {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, dimension)
    tenant
  end

  defp article_text(article), do: "#{article.title}\n\n#{article.body}"

  # ---------------------------------------------------------------------------
  # Idempotency at a NON-1536 dimension
  # ---------------------------------------------------------------------------

  describe "embedding idempotency at a non-1536 dimension" do
    test "the per-article worker does NOT re-call the provider for identical content" do
      tenant = tenant_at(768)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})
      hash = content_hash(article_text(article))

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(768), hash, 768)
      enable_side_table_reads()

      # A provider call here would be the re-billing loop: the legacy columns stay
      # NULL for a 768 tenant, so the old guard could never see the stored hash.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text ->
        flunk("the provider was called for content that is already embedded at dim 768")
      end)

      assert :ok =
               perform_job(ArticleEmbeddingWorker, %{
                 "article_id" => article.id,
                 "tenant_id" => tenant.id
               })
    end

    test "the BATCH worker skips an already-embedded article at dim 768" do
      tenant = tenant_at(768)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})
      hash = content_hash(article_text(article))

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(768), hash, 768)
      enable_side_table_reads()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, _texts ->
        flunk("the provider was called for a batch whose every article is already embedded")
      end)

      assert :ok =
               perform_job(BatchArticleEmbeddingWorker, %{
                 "article_ids" => [article.id],
                 "tenant_id" => tenant.id
               })
    end

    test "the MEMORY worker does NOT re-call the provider for identical content" do
      tenant = tenant_at(768)
      memory = fixture(:memory, %{tenant_id: tenant.id, tier: :long_term})
      hash = Memory.Memory.embedding_content_hash(memory.text)

      {:ok, _} = Embeddings.upsert_memory_embedding(tenant.id, memory, vec(768), hash, 768)
      enable_side_table_reads()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text ->
        flunk("the provider was called for a memory already embedded at dim 768")
      end)

      assert :ok =
               perform_job(MemoryEmbeddingWorker, %{
                 "memory_id" => memory.id,
                 "tenant_id" => tenant.id
               })
    end

    test "a CHANGED content hash still re-embeds (the guard is a hash check, not a presence check)" do
      tenant = tenant_at(768)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, _} =
        Embeddings.upsert_article_embedding(tenant.id, article, vec(768), "stale-hash", 768)

      enable_side_table_reads()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text ->
        {:ok, far_vec(768)}
      end)

      assert :ok =
               perform_job(ArticleEmbeddingWorker, %{
                 "article_id" => article.id,
                 "tenant_id" => tenant.id
               })

      assert Embeddings.article_embedded_hash(tenant.id, article.id, 768) ==
               content_hash(article_text(article))
    end
  end

  # ---------------------------------------------------------------------------
  # suggest_links: the SOURCE vector must come from the side table too
  # ---------------------------------------------------------------------------

  describe "suggest_links source vector" do
    test "a 768-dimension tenant gets neighbours, not a silent empty result" do
      tenant = tenant_at(768)
      source = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Source"})

      neighbour =
        fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Neighbour"})

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, source, vec(768), nil, 768)
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, neighbour, vec(768), nil, 768)

      enable_side_table_reads()

      assert {:ok, suggestions, meta} = Knowledge.suggest_links_with_meta(tenant.id, source.id)
      assert Enum.map(suggestions, & &1.id) == [neighbour.id]
      refute meta.pool_exhausted
    end

    test "an article with NO vector at the active dimension still reports the empty meta" do
      tenant = tenant_at(768)
      source = fixture(:article, %{tenant_id: tenant.id, status: :published})

      enable_side_table_reads()

      assert {:ok, [], meta} = Knowledge.suggest_links_with_meta(tenant.id, source.id)
      refute meta.pool_exhausted
    end

    test "a MISSING article is still {:error, :not_found}, never an empty suggestion set" do
      tenant = tenant_at(768)
      enable_side_table_reads()

      assert {:error, :not_found} =
               Knowledge.suggest_links_with_meta(tenant.id, Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------------
  # An instance-UNSUPPORTED derived dimension (3072)
  # ---------------------------------------------------------------------------

  describe "a model-derived but unsupported dimension" do
    setup do
      tenant = fixture(:tenant)

      fixture(:tenant_llm_settings, %{
        tenant_id: tenant.id,
        embedding_model: "text-embedding-3-large"
      })

      {:ok, tenant: tenant}
    end

    test "active_dimension/1 never returns it — the read path has no cast for it", %{
      tenant: tenant
    } do
      assert Embeddings.declared_dimension(tenant.id) == 3072
      refute Embeddings.supported_dimension?(3072)
      assert Embeddings.active_dimension(tenant.id) == Embeddings.default_dimension()
    end

    test "recall_availability/1 DISCLOSES it instead of claiming semantic recall", %{
      tenant: tenant
    } do
      availability = Embeddings.recall_availability(tenant.id)

      refute availability.semantic_available
      assert availability.reason =~ "3072"
      assert availability.reason =~ "does not support"
    end

    test "the hottest read does NOT raise for such a tenant", %{tenant: tenant} do
      enable_side_table_reads()

      # 3072 has no per-dimension cast, so the pre-fix resolver produced an
      # ArgumentError from deep inside the ANN builder — an unhandled 500 on search.
      assert {:ok, %{results: [], meta: meta}} =
               Knowledge.search_semantic(tenant.id, vec(1536))

      assert meta.embedding_dimension == 1536
    end

    test "a 3072-length vector is REJECTED at write time, naming both numbers", %{
      tenant: tenant
    } do
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert {:error, changeset} =
               Knowledge.update_embedding(tenant.id, article.id, vec(3072), nil)

      assert %{embedding: [message]} = errors_on(changeset)
      assert message =~ "1536"
      assert message =~ "3072"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-41.1.10 — the query model pin
  # ---------------------------------------------------------------------------

  describe "the active-corpus model pin (AC-41.1.10)" do
    test "the first write PINS both the dimension and the model" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-m3"})

      article = fixture(:article, %{tenant_id: tenant.id, status: :published})
      dimension = Embeddings.resolve_write_dimension(tenant.id)

      assert dimension == 1024
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1024), nil, 1024)

      assert AdminRepo.get(Tenant, tenant.id).tenant_embedding_dimension == 1024
      assert Embeddings.active_model(tenant.id) == "bge-m3"
    end

    test "a query embedding uses the PINNED model once the tenant re-points at the pending one" do
      tenant = fixture(:tenant)
      settings = fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-m3"})
      assert Embeddings.resolve_write_dimension(tenant.id) == 1024

      # The re-embed's precondition: the tenant re-points at the NEW model. Before the
      # pin existed, every query vector followed it and disagreed with the whole live
      # corpus for the entire window.
      {:ok, _} = Loopctl.Llm.upsert_settings(tenant.id, %{embedding_model: "nomic-embed-text"})
      assert settings.embedding_model == "bge-m3"

      assert Embeddings.query_model_override(tenant.id) == "bge-m3"

      Mox.expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _scope, _text, opts ->
        assert Keyword.get(opts, :model) == "bge-m3"
        {:ok, vec(1024)}
      end)

      assert {:ok, _} = Knowledge.generate_embedding(tenant.id, "a query")
    end

    test "the RE-EMBED worker is the one caller that uses the CONFIGURED (pending) model" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-m3"})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert Embeddings.resolve_write_dimension(tenant.id) == 1024
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1024), nil, 1024)

      {:ok, _} = Loopctl.Llm.upsert_settings(tenant.id, %{embedding_model: "nomic-embed-text"})

      # No `:model` override at all => the client resolves the tenant's CURRENT
      # setting, which is the PENDING model — the only way to obtain 768-length
      # vectors. Any override would be the pinned (active-corpus) model and the
      # re-embed could never complete.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts ->
        {:ok, Enum.map(texts, fn _ -> vec(768) end)}
      end)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, _texts, opts ->
        flunk("the re-embed must not pin the model, got: #{inspect(opts)}")
      end)

      assert :ok =
               perform_job(ReembedWorker, %{"tenant_id" => tenant.id, "target_dim" => 768})

      assert Embeddings.article_dimension_counts(tenant.id)[768] == 1
    end

    test "completion re-pins the dimension AND the model together" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-m3"})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert Embeddings.resolve_write_dimension(tenant.id) == 1024
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1024), nil, 1024)
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(768), nil, 768)
      {:ok, _} = Loopctl.Llm.upsert_settings(tenant.id, %{embedding_model: "nomic-embed-text"})

      assert {:ok, _dropped} = Embeddings.complete_reembed(tenant.id, 768)

      assert Embeddings.active_dimension(tenant.id) == 768
      assert Embeddings.active_model(tenant.id) == "nomic-embed-text"
      # ... and with the pin caught up, ordinary embeddings stop overriding again.
      assert Embeddings.query_model_override(tenant.id) == nil
    end

    # Finding 8: a model that does NOT produce the target dimension must NOT be pinned —
    # pinning it would be a silent recall blackout `model_pin_conflict/1` (which only
    # fires on a nil pin) never surfaces. Completion NULLs the model so the conflict is
    # disclosed.
    test "completion pins the model NULL when the configured model disagrees with the target dim" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-m3"})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      assert Embeddings.resolve_write_dimension(tenant.id) == 1024
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1024), nil, 1024)
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(768), nil, 768)

      # Complete onto 768 while the configured model (bge-m3) still returns 1024 vectors.
      assert {:ok, _} = Embeddings.complete_reembed(tenant.id, 768)

      assert Embeddings.active_dimension(tenant.id) == 768
      assert Embeddings.active_model(tenant.id) == nil
      assert Embeddings.model_pin_conflict(tenant.id) != nil
    end

    # Finding 12 (TOCTOU): the pin records the model the worker THREADED (the one that
    # produced the target corpus), not whatever the tenant reconfigured to mid-run. A
    # threaded 768 model that DIFFERS from the live-config 768 model still wins.
    test "completion pins the THREADED model, not the tenant's currently-configured one" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-base-en"})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(768), nil, 768)
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1024), nil, 1024)

      # Thread a DIFFERENT 768 model than the live config (bge-base-en); both are 768 so
      # both agree with the target — the point is WHICH one is pinned.
      assert {:ok, _} = Embeddings.complete_reembed(tenant.id, 768, "nomic-embed-text")

      assert Embeddings.active_dimension(tenant.id) == 768
      assert Embeddings.active_model(tenant.id) == "nomic-embed-text"
    end
  end

  # ---------------------------------------------------------------------------
  # Re-embed EGRESS scope
  # ---------------------------------------------------------------------------

  describe "re-embed egress scope" do
    test "each provider call carries the ARTICLE's project, never a tenant-wide scope" do
      tenant = tenant_at(1536)
      project = fixture(:project, %{tenant_id: tenant.id})

      scoped =
        fixture(:article, %{
          tenant_id: tenant.id,
          project_id: project.id,
          status: :published
        })

      tenant_wide = fixture(:article, %{tenant_id: tenant.id, status: :published})

      for article <- [scoped, tenant_wide] do
        {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), nil, 1536)
      end

      test_pid = self()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn scope, texts ->
        send(test_pid, {:scope, scope.project_id, length(texts)})
        {:ok, Enum.map(texts, fn _ -> vec(768) end)}
      end)

      assert :ok = perform_job(ReembedWorker, %{"tenant_id" => tenant.id, "target_dim" => 768})

      # One call per project — a mixed call would force ONE egress scope on articles
      # with different local_only markings, and the tenant-wide scope silently drops a
      # project-only marking (`Egress.Policy.local_only?/1` is most-restrictive-wins).
      scopes =
        for _ <- 1..2 do
          assert_receive {:scope, project_id, 1}
          project_id
        end

      assert Enum.sort_by(scopes, &to_string/1) == Enum.sort_by([project.id, nil], &to_string/1)
    end
  end

  # ---------------------------------------------------------------------------
  # live_denorm drift
  # ---------------------------------------------------------------------------

  describe "live_denorm drift" do
    test "a desynchronized ARTICLE marker is detected and repaired by reconciliation" do
      tenant = tenant_at(1536)
      article = fixture(:article, %{tenant_id: tenant.id, status: :superseded})

      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), nil, 1536)
      refute row.live_denorm

      # Force the exact state the INSERT write skew produced: a superseded parent with
      # a row still marked live, IN the partial HNSW index.
      force_live_denorm("article_embeddings", "article_embeddings_live_denorm_trg", row.id, true)

      assert row.id in Embeddings.article_live_denorm_drift()
      assert {:ok, %{live_denorm_repaired: n}} = Embeddings.reconcile_articles()
      assert n >= 1
      assert Embeddings.article_live_denorm_drift() == []
      refute AdminRepo.get(ArticleEmbedding, row.id).live_denorm
    end

    test "a desynchronized MEMORY marker is detected and repaired" do
      tenant = tenant_at(1536)
      memory = fixture(:memory, %{tenant_id: tenant.id, tier: :long_term})
      {:ok, row} = Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536), nil, 1536)

      force_live_denorm("memory_embeddings", "memory_embeddings_live_denorm_trg", row.id, false)

      assert row.id in Embeddings.memory_live_denorm_drift()
      assert {:ok, %{live_denorm_repaired: n}} = Embeddings.reconcile_memories()
      assert n >= 1
      assert Embeddings.memory_live_denorm_drift() == []
      assert AdminRepo.get(MemoryEmbedding, row.id).live_denorm
    end

    test "the BEFORE-INSERT trigger locks the parent (the insert-time write skew)" do
      tenant = tenant_at(1536)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      # The parent read is `FOR SHARE` on INSERT, which conflicts with the
      # `FOR NO KEY UPDATE` a status change takes — so the two serialize instead of
      # both "winning". Asserting the lock clause is present in the deployed function
      # is the cheapest faithful check; the interleaving itself needs two connections.
      %{rows: [[source]]} =
        AdminRepo.query!(
          "SELECT prosrc FROM pg_proc WHERE proname = 'article_embeddings_set_live_denorm'"
        )

      assert source =~ "FOR SHARE"
      assert source =~ "TG_OP = 'INSERT'"

      {:ok, row} = Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), nil, 1536)
      assert row.live_denorm
    end
  end

  # ---------------------------------------------------------------------------
  # The side-table upsert is atomic
  # ---------------------------------------------------------------------------

  describe "side-table upsert" do
    test "a row written by a RACING writer is UPDATED, not a unique-violation" do
      tenant = tenant_at(1536)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      # Stand in for the lost race: the row already exists when this writer's INSERT
      # lands (previously both writers saw `existing == nil` and the loser's changeset
      # error rolled back the LEGACY write and the audit entry with it).
      {:ok, first} =
        Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), "hash-a", 1536)

      {:ok, second} =
        Embeddings.upsert_article_embedding(tenant.id, article, far_vec(1536), "hash-b", 1536)

      assert second.id == first.id
      assert Embeddings.article_embedded_hash(tenant.id, article.id, 1536) == "hash-b"

      assert AdminRepo.aggregate(
               from(ae in ArticleEmbedding,
                 where: ae.tenant_id == ^tenant.id and ae.article_id == ^article.id
               ),
               :count
             ) == 1
    end

    test "the dual-write Multi still commits the legacy column and the audit entry" do
      tenant = tenant_at(1536)
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, _} =
        Embeddings.upsert_article_embedding(tenant.id, article, vec(1536), "hash-a", 1536)

      assert {:ok, _updated} =
               Knowledge.update_embedding(tenant.id, article.id, far_vec(1536), "hash-c")

      assert Embeddings.article_embedded_hash(tenant.id, article.id, 1536) == "hash-c"
    end
  end

  # ---------------------------------------------------------------------------
  # The memory / system write paths PIN
  # ---------------------------------------------------------------------------

  describe "write paths pin the tenant dimension" do
    test "a MEMORY-only tenant is pinned by its first memory embedding" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-m3"})
      memory = fixture(:memory, %{tenant_id: tenant.id, tier: :long_term})

      assert is_nil(AdminRepo.get(Tenant, tenant.id).tenant_embedding_dimension)

      assert {:ok, _} =
               Memory.update_memory_embedding(tenant.id, memory.id, vec(1024), "hash-m")

      assert AdminRepo.get(Tenant, tenant.id).tenant_embedding_dimension == 1024

      # The pin is what stops a later model change from re-pointing recall at an
      # EMPTY dimension.
      {:ok, _} = Loopctl.Llm.upsert_settings(tenant.id, %{embedding_model: "nomic-embed-text"})
      assert Embeddings.active_dimension(tenant.id) == 1024
    end

    test "the SYSTEM-corpus worker pins too" do
      tenant = fixture(:tenant)
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_model: "bge-m3"})
      system_article()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts ->
        {:ok, Enum.map(texts, fn _ -> vec(1024) end)}
      end)

      assert :ok = perform_job(SystemCorpusEmbeddingWorker, %{"tenant_id" => tenant.id})
      assert AdminRepo.get(Tenant, tenant.id).tenant_embedding_dimension == 1024
    end
  end

  # ---------------------------------------------------------------------------
  # System corpus: status filter + content-change re-materialization
  # ---------------------------------------------------------------------------

  describe "system corpus materialization" do
    test "a NON-PUBLISHED system article is never enumerated or egressed" do
      tenant = tenant_at(1536)
      draft = system_article(status: :draft)

      # The instance ships a PUBLISHED bootstrap system corpus, so the assertion is
      # that the DRAFT is absent — not that the lists are empty.
      refute draft.id in system_article_ids(
               Embeddings.unmaterialized_system_articles(tenant.id, 1536, limit: 500)
             )

      refute draft.id in system_article_ids(
               Embeddings.stale_system_articles(tenant.id, 1536, limit: 500)
             )
    end

    test "an unpublishable system article can no longer pin the meta at keyword_only" do
      tenant = tenant_at(1536)
      materialize_published_system_corpus(tenant.id, 1536)

      assert Embeddings.system_corpus_meta(tenant.id, 1536).system_corpus_recall == "semantic"

      # A new DRAFT system article must not flip every tenant's search meta back.
      _draft = system_article(status: :draft)
      assert Embeddings.system_corpus_meta(tenant.id, 1536).system_corpus_recall == "semantic"

      # ... while a new PUBLISHED one legitimately does.
      _published = system_article()
      assert Embeddings.system_corpus_meta(tenant.id, 1536).system_corpus_recall == "keyword_only"
    end

    test "an EDITED system article is re-embedded, not left permanently stale" do
      tenant = tenant_at(1536)
      article = system_article()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts ->
        {:ok, Enum.map(texts, fn _ -> vec(1536) end)}
      end)

      assert :ok = perform_job(SystemCorpusEmbeddingWorker, %{"tenant_id" => tenant.id})
      original_hash = Embeddings.article_embedded_hash(tenant.id, article.id, 1536)
      assert is_binary(original_hash)
      assert Embeddings.stale_system_articles(tenant.id, 1536) == []

      stamp_article_newer(article.id, body: "a materially different body")

      assert Enum.map(Embeddings.stale_system_articles(tenant.id, 1536), & &1.id) == [article.id]

      assert :ok = perform_job(SystemCorpusEmbeddingWorker, %{"tenant_id" => tenant.id})
      assert Embeddings.article_embedded_hash(tenant.id, article.id, 1536) != original_hash
    end

    test "a TOUCHED-but-unchanged system article costs a timestamp, not a provider call" do
      tenant = tenant_at(1536)
      article = system_article()

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts ->
        {:ok, Enum.map(texts, fn _ -> vec(1536) end)}
      end)

      assert :ok = perform_job(SystemCorpusEmbeddingWorker, %{"tenant_id" => tenant.id})

      stamp_article_newer(article.id)

      assert Enum.map(Embeddings.stale_system_articles(tenant.id, 1536), & &1.id) == [article.id]

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, _texts ->
        flunk("re-embedded an article whose content hash did not change")
      end)

      assert :ok = perform_job(SystemCorpusEmbeddingWorker, %{"tenant_id" => tenant.id})
      assert Embeddings.stale_system_articles(tenant.id, 1536) == []
    end

    test "a TERMINAL job stops the read path re-enqueuing forever" do
      tenant = tenant_at(1536)

      # The suite runs Oban in `testing: :inline`, which executes jobs WITHOUT
      # persisting them — so the terminal row is written directly, exactly as a real
      # `{:discard, {:no_embedding_key, _}}` would leave it. Through OBAN's repo:
      # `AdminRepo` is a separate sandbox connection.
      Loopctl.Repo.query!(
        """
        INSERT INTO oban_jobs (state, queue, worker, args, inserted_at, scheduled_at)
        VALUES ('discarded', 'embeddings', $1, $2, NOW(), NOW())
        """,
        [
          "Loopctl.Workers.SystemCorpusEmbeddingWorker",
          %{"tenant_id" => tenant.id, "dim" => 1536}
        ]
      )

      assert Embeddings.system_corpus_terminal?(tenant.id, 1536)

      assert {:error, :materialization_terminal} =
               Embeddings.enqueue_system_corpus_materialization(tenant.id)

      # ... but an EXPLICIT operator/agent request still gets through.
      assert {:ok, _} =
               Embeddings.enqueue_system_corpus_materialization(tenant.id, force: true)
    end
  end

  # ---------------------------------------------------------------------------
  # Re-embed completion ordering
  # ---------------------------------------------------------------------------

  describe "re-embed completion" do
    test "an INCOMPLETE corpus leaves the pin AND the rows untouched" do
      tenant = tenant_at(1536)
      done = fixture(:article, %{tenant_id: tenant.id, status: :published})
      raced = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, done, vec(1536), nil, 1536)
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, done, vec(768), nil, 768)
      # The race the fail-closed guard exists for: a new 1536 row after the last batch.
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, raced, vec(1536), nil, 1536)

      assert {:error, :reembed_incomplete} = Embeddings.complete_reembed(tenant.id, 768)

      # Pre-fix the pin had ALREADY moved here, so recall served an empty/partial
      # target corpus while the raced rows were silently excluded.
      assert Embeddings.active_dimension(tenant.id) == 1536
      assert Embeddings.article_dimension_counts(tenant.id) == %{768 => 1, 1536 => 2}
    end

    test "an incomplete corpus is a RETRYABLE worker error, not a silent success" do
      tenant = tenant_at(1536)
      done = fixture(:article, %{tenant_id: tenant.id, status: :published})
      raced = fixture(:article, %{tenant_id: tenant.id, status: :published})

      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, done, vec(1536), nil, 1536)
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, done, vec(768), nil, 768)
      {:ok, _} = Embeddings.upsert_article_embedding(tenant.id, raced, vec(1536), nil, 1536)

      # The batch path migrates `raced`, then the completion attempt runs. (The
      # interleaving where a row is raced in AFTER the last batch is exercised
      # directly against `complete_reembed/2` above — it needs two connections to
      # produce here.)
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts ->
        {:ok, Enum.map(texts, fn _ -> vec(768) end)}
      end)

      assert :ok = perform_job(ReembedWorker, %{"tenant_id" => tenant.id, "target_dim" => 768})

      # The suite runs Oban `testing: :inline`, so the self-continuation runs the
      # whole chain: the batch migrates the pending row and the completion then finds
      # the corpus genuinely complete. The pin moves ONLY on that path — an
      # incomplete corpus leaves it (and the rows) untouched, which is asserted
      # directly against `complete_reembed/2` above.
      assert Embeddings.reembed_complete?(tenant.id, 768)
      assert Embeddings.active_dimension(tenant.id) == 768
      assert Embeddings.article_dimension_counts(tenant.id) == %{768 => 2}
    end
  end

  # ---------------------------------------------------------------------------
  # memory_embeddings.subject_id is ENFORCED, not merely denormalized
  # ---------------------------------------------------------------------------

  describe "memory_embeddings.subject_id" do
    test "a raw UPDATE to a foreign subject is REJECTED by the database" do
      tenant = tenant_at(1536)
      memory = fixture(:memory, %{tenant_id: tenant.id, tier: :long_term})
      {:ok, row} = Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536), nil, 1536)

      # `HeavyRead.guard_memory!/3` validates THIS column, so a desynchronized copy
      # would turn a cross-subject leak into a guard-PASSING query.
      assert_raise Postgrex.Error, fn ->
        AdminRepo.query!("UPDATE memory_embeddings SET subject_id = $1 WHERE id = $2", [
          "some-other-subject",
          Ecto.UUID.dump!(row.id)
        ])
      end
    end

    test "a subject move on the PARENT cascades to the denormalized copy" do
      tenant = tenant_at(1536)
      memory = fixture(:memory, %{tenant_id: tenant.id, tier: :long_term})
      {:ok, row} = Embeddings.upsert_memory_embedding(tenant.id, memory, vec(1536), nil, 1536)

      AdminRepo.query!("UPDATE memories SET subject_id = $1 WHERE id = $2", [
        "moved-subject",
        Ecto.UUID.dump!(memory.id)
      ])

      assert AdminRepo.get(MemoryEmbedding, row.id).subject_id == "moved-subject"
    end
  end

  # The side table's BEFORE UPDATE trigger RECOMPUTES `live_denorm` from the parent on
  # every update — which is itself part of the invariant — so a desynchronized marker
  # cannot be produced by an ordinary UPDATE. Disabling the trigger for one statement
  # reproduces the state the INSERT-time write skew used to leave behind (and that a
  # COPY/restore could still leave), which is what the sweep exists to repair.
  defp force_live_denorm(table, trigger, id, value) do
    AdminRepo.query!("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")

    AdminRepo.query!("UPDATE #{table} SET live_denorm = $1 WHERE id = $2", [
      value,
      Ecto.UUID.dump!(id)
    ])

    AdminRepo.query!("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
  end

  defp system_article_ids(articles), do: Enum.map(articles, & &1.id)

  # Materializes every PUBLISHED system article for `tenant_id` so the corpus meta is
  # "semantic" — the instance ships a bootstrap system corpus, so a test that needs a
  # materialized state has to embed it.
  defp materialize_published_system_corpus(tenant_id, dim) do
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts ->
      {:ok, Enum.map(texts, fn _ -> vec(dim) end)}
    end)

    Enum.reduce_while(1..20, :ok, fn _i, :ok ->
      case Embeddings.stale_system_articles(tenant_id, dim, limit: 100) do
        [] -> {:halt, :ok}
        articles -> materialize_batch(tenant_id, dim, articles)
      end
    end)
  end

  defp materialize_batch(tenant_id, dim, articles) do
    Enum.each(articles, fn article ->
      text = "#{article.title}\n\n#{article.body}"

      {:ok, _} =
        Embeddings.materialize_system_article_embedding(
          tenant_id,
          article,
          vec(dim),
          content_hash(text),
          dim
        )
    end)

    {:cont, :ok}
  end

  # A SYSTEM-scoped article: `tenant_id IS NULL`, `scope: :system`.
  # Stamp an article's `updated_at` STRICTLY after its embedding, using an app-side
  # UTC timestamp — the SAME basis the embedding worker writes with
  # (`DateTime.utc_now()`). Do NOT use Postgres `NOW()` here: `articles.updated_at`
  # is `timestamp WITHOUT time zone`, and a `timestamptz` `NOW()` coerced into it is
  # converted to the SESSION timezone and stored naive. On a non-UTC server (e.g. a
  # dev box in America/Denver, UTC-6) that value lands HOURS behind the UTC timestamp
  # the worker wrote, so `ae.updated_at < a.updated_at` is false and the article
  # never looks stale — a deterministic local failure that passes on CI only because
  # CI runs Postgres in UTC. Binding an explicit naive-UTC value removes the
  # ambient-timezone dependency entirely.
  defp stamp_article_newer(article_id, opts \\ []) do
    newer = NaiveDateTime.add(NaiveDateTime.utc_now(), 1, :second)

    case Keyword.fetch(opts, :body) do
      {:ok, body} ->
        AdminRepo.query!(
          "UPDATE articles SET body = $1, updated_at = $2 WHERE id = $3",
          [body, newer, Ecto.UUID.dump!(article_id)]
        )

      :error ->
        AdminRepo.query!(
          "UPDATE articles SET updated_at = $1 WHERE id = $2",
          [newer, Ecto.UUID.dump!(article_id)]
        )
    end
  end

  defp system_article(opts \\ []) do
    status = Keyword.get(opts, :status, :published)
    now = DateTime.utc_now()

    id = Ecto.UUID.generate()

    AdminRepo.insert_all(Article, [
      %{
        id: id,
        tenant_id: nil,
        title: "System article #{System.unique_integer([:positive])}",
        body: "shared operator content",
        category: :reference,
        status: status,
        scope: :system,
        tags: [],
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    AdminRepo.get!(Article, id)
  end
end
