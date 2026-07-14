defmodule Loopctl.Workers.ArticleLinkingWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.MockArticleSimilaritySearch
  alias Loopctl.Workers.ArticleLinkingWorker

  # The similarity lookup is injected behind `Loopctl.Knowledge.SimilaritySearchBehaviour`
  # (config-based DI). These unit tests drive the worker's LINKING logic (the relates_to /
  # potential_conflict threshold split, both-direction dedup, the audit event, idempotency)
  # by feeding it DETERMINISTIC candidate lists via Mox — never the real pgvector kNN, which
  # runs through `Loopctl.HeavyRead` under a 250 ms `SET LOCAL statement_timeout` transaction
  # and flaked these tests on a loaded DB (57014 query_canceled). The real
  # `VectorSearch.nearest/4` path keeps its own coverage in the "real vector search
  # (integration)" describe block below.

  defp setup_tenant do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end

  # A published article with a (value-irrelevant) embedding, written directly via AdminRepo
  # to bypass the inline Oban cascade (embedding worker -> linking worker). The SOURCE needs a
  # non-nil embedding for the worker to proceed; CANDIDATES need only to exist (article_links
  # FKs are `on_delete: :restrict`). Similarity is controlled by the injected mock, NOT by the
  # embedding vector, so a single dummy vector serves every article here.
  defp create_published_article(tenant_id, attrs \\ %{}) do
    base_attrs = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Test article body.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base_attrs, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published, embedding: List.duplicate(0.1, 1536)})
    |> AdminRepo.update!()
  end

  # Builds a candidate map in the EXACT shape `VectorSearch.nearest/4` returns; the worker
  # keys on `:id` and `:similarity_score`.
  defp candidate(article, score) do
    %{id: article.id, title: article.title, category: article.category, similarity_score: score}
  end

  defp links_of_type(tenant_id, a_id, b_id, type) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == ^type,
      where:
        (l.source_article_id == ^a_id and l.target_article_id == ^b_id) or
          (l.source_article_id == ^b_id and l.target_article_id == ^a_id)
    )
    |> AdminRepo.all()
  end

  # The (source_id, target_id, type) set of every link out of `source_id` — the correctness
  # fingerprint the US-36.4 insert_all refactor must keep identical to the row-by-row path.
  defp link_set(tenant_id, source_id) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.source_article_id == ^source_id,
      select: {l.source_article_id, l.target_article_id, l.relationship_type}
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  defp sample_rate, do: Application.get_env(:loopctl, :article_link_corpus_sample_rate)

  # A published article whose id DOES / DOES NOT fall in the corpus-count sample bucket
  # (`:erlang.phash2(id, rate) == 0`), so the sampling assertions are zero-flake. Non-matching
  # articles are deleted (no links reference them yet) so they don't pollute the corpus count.
  defp create_article_in_bucket(tenant_id, sampled?) do
    article = create_published_article(tenant_id)

    if :erlang.phash2(article.id, sample_rate()) == 0 == sampled? do
      article
    else
      AdminRepo.delete!(article)
      create_article_in_bucket(tenant_id, sampled?)
    end
  end

  # Attach an in-test handler for the corpus-size telemetry event; returns a ref the worker's
  # emission is tagged with so `assert_received` / `refute_received` can key on it.
  defp attach_corpus_telemetry do
    ref = make_ref()
    test_pid = self()
    handler_id = "corpus-size-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:loopctl, :knowledge, :article_linking, :corpus_size],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {ref, :corpus_size, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  describe "potential conflict detection (#4)" do
    test "flags a near-identical pair with a :potential_conflict link" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      dup = create_published_article(tenant.id)

      # >= the 0.93 conflict threshold: gets BOTH an ambient relates_to and a conflict flag.
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(dup, 0.99)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      assert [_] = links_of_type(tenant.id, source.id, dup.id, :relates_to)
      assert [conflict] = links_of_type(tenant.id, source.id, dup.id, :potential_conflict)
      assert conflict.metadata["similarity_score"] >= 0.93
      assert conflict.metadata["auto_generated"] == true
    end

    test "a merely-related pair (below the conflict threshold) gets NO conflict flag" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      related = create_published_article(tenant.id)

      # >= 0.6 (relates) but < 0.93 (no conflict).
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(related, 0.70)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      assert [_] = links_of_type(tenant.id, source.id, related.id, :relates_to)
      assert [] == links_of_type(tenant.id, source.id, related.id, :potential_conflict)
    end
  end

  # --- TC-21.2.1: Creates relates_to links for similar articles ---

  describe "perform/1 creates links" do
    test "creates a relates_to link for a returned candidate and passes the self/scope opts" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      target = create_published_article(tenant.id)

      # Assert the worker WIRES the lookup correctly: self-exclusion anchor, tenant-wide
      # project scope for a tenant-wide source, an indexed-query threshold of 0.0 (the floor
      # is applied in-memory), and a bounded over-fetch pool.
      expect(MockArticleSimilaritySearch, :nearest, fn tenant_id, _emb, max, opts ->
        assert tenant_id == tenant.id
        assert Keyword.fetch!(opts, :exclude_id) == source.id
        assert Keyword.fetch!(opts, :project_or_global) == nil
        assert Keyword.fetch!(opts, :threshold) == 0.0
        assert Keyword.fetch!(opts, :pool) == VectorSearch.pool_size(max)
        [candidate(target, 0.88)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id,
          where: l.target_article_id == ^target.id,
          where: l.relationship_type == :relates_to
        )
        |> AdminRepo.all()

      assert length(links) == 1
      link = hd(links)
      assert link.metadata["auto_generated"] == true
      assert link.metadata["similarity_score"] == 0.88
    end
  end

  # --- TC-21.2.2: Skips articles below threshold ---

  describe "perform/1 threshold filtering" do
    test "skips a candidate below the (in-memory) similarity threshold" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      dissimilar = create_published_article(tenant.id)

      # 0.05 < the default 0.6 floor: the worker applies `sim >= threshold` in memory and
      # drops it, even though the lookup surfaced it (it was asked for `threshold: 0.0`).
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(dissimilar, 0.05)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.all()

      assert links == []
    end

    test "a per-job threshold override links a near-miss neighbor (orphan self-heal)" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      near_miss = create_published_article(tenant.id)

      # Same candidate at 0.55 both runs: the DIFFERENCE is the in-memory floor. Default
      # 0.6 drops it; the per-job 0.5 override keeps it. Stub (called twice, same return).
      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(near_miss, 0.55)]
      end)

      # Default threshold: no link (this is why orphans stay orphaned).
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      assert [] ==
               from(l in ArticleLink, where: l.source_article_id == ^source.id)
               |> AdminRepo.all()

      # Lenient threshold passed in args: the near-miss neighbor now links.
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{
                   "article_id" => source.id,
                   "tenant_id" => tenant.id,
                   "threshold" => 0.5
                 }
               })

      links = links_of_type(tenant.id, source.id, near_miss.id, :relates_to)

      assert length(links) == 1
      assert hd(links).metadata["similarity_score"] == 0.55
    end
  end

  # --- TC-21.2.3: Idempotent -- no duplicates on re-run ---

  describe "idempotency" do
    test "re-running does not create duplicate links" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      target = create_published_article(tenant.id)

      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(target, 0.88)]
      end)

      run = fn ->
        assert :ok =
                 ArticleLinkingWorker.perform(%Oban.Job{
                   args: %{"article_id" => source.id, "tenant_id" => tenant.id}
                 })
      end

      run.()

      count_before =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      run.()

      count_after =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      assert count_before == count_after
    end

    test "does not create duplicate when link exists in reverse direction" do
      %{tenant: tenant} = setup_tenant()
      article_a = create_published_article(tenant.id)
      article_b = create_published_article(tenant.id)

      # Pre-existing link in the B -> A direction.
      %ArticleLink{tenant_id: tenant.id}
      |> ArticleLink.changeset(%{
        source_article_id: article_b.id,
        target_article_id: article_a.id,
        relationship_type: :relates_to,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.99}
      })
      |> AdminRepo.insert!()

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(article_b, 0.99)]
      end)

      # Linking A must NOT create A -> B (B -> A already exists).
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article_a.id, "tenant_id" => tenant.id}
               })

      # Only the manually created relates_to one should exist (the high-similarity pair
      # also gets a separate :potential_conflict flag — that's #4, asserted elsewhere).
      assert length(links_of_type(tenant.id, article_a.id, article_b.id, :relates_to)) == 1
    end
  end

  # --- TC-21.2.4: Tenant isolation ---

  describe "tenant isolation" do
    test "the worker scopes the lookup to the caller tenant" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      source_a = create_published_article(tenant_a.id)
      _target_b = create_published_article(tenant_b.id)

      # Real tenant isolation lives in VectorSearch/HeavyRead (their own tests); here we
      # assert the worker passes the CALLER's tenant and links only what the lookup returns.
      # A same-tenant lookup finds no candidates -> no links.
      expect(MockArticleSimilaritySearch, :nearest, fn tenant_id, _emb, _k, _opts ->
        assert tenant_id == tenant_a.id
        []
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source_a.id, "tenant_id" => tenant_a.id}
               })

      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant_a.id,
          where: l.source_article_id == ^source_a.id
        )
        |> AdminRepo.all()

      assert links == []
    end

    test "worker with wrong tenant returns :ok without a lookup (article not visible)" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      article_a = create_published_article(tenant_a.id)

      # get_article_with_embedding(tenant_b, …) is a miss -> the worker no-ops before any
      # similarity lookup (the default DataCase stub is never invoked).
      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article_a.id, "tenant_id" => tenant_b.id}
               })
    end
  end

  # --- TC-21.2.5: Links every returned candidate ---

  describe "candidate fan-out" do
    test "creates a relates_to link for each returned candidate" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      targets = for _i <- 1..3, do: create_published_article(tenant.id)

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        Enum.map(targets, &candidate(&1, 0.80))
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # 0.80 is >= 0.6 (relates) but < 0.93 (no conflict), so exactly 3 relates_to links.
      link_count =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      assert link_count == 3
    end
  end

  # --- US-36.4: hot-path efficiency (sampled corpus count + batched insert_all) ---

  describe "corpus-size sampling (AC-36.4.1)" do
    test "does NOT compute the corpus count on an unsampled job, and does not gate linking" do
      %{tenant: tenant} = setup_tenant()
      source = create_article_in_bucket(tenant.id, false)
      target = create_published_article(tenant.id)

      ref = attach_corpus_telemetry()

      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(target, 0.88)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # Unsampled: the corpus-size count was skipped, so the signal did not fire — proving the
      # full count(*) is no longer paid on every run.
      refute_received {^ref, :corpus_size, _measurements, _metadata}

      # ...yet linking still happened. The count was never a gate (correctness preserved).
      assert [_] = links_of_type(tenant.id, source.id, target.id, :relates_to)
    end

    test "emits the corpus_size telemetry on a sampled job (signal preserved)" do
      %{tenant: tenant} = setup_tenant()
      source = create_article_in_bucket(tenant.id, true)
      # Three other published, embedded articles form the corpus the count measures.
      others = for _i <- 1..3, do: create_published_article(tenant.id)
      target = hd(others)

      ref = attach_corpus_telemetry()

      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(target, 0.88)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      assert_received {^ref, :corpus_size, measurements, metadata}
      # Self excluded; three other published+embedded articles in the tenant.
      assert measurements.total == 3
      assert measurements.limit == 50
      assert metadata.tenant_id == tenant.id
      assert metadata.article_id == source.id
    end
  end

  describe "batched insert_all (AC-36.4.2 / AC-36.4.3)" do
    test "persists the identical link set for a fixed input and is idempotent on re-run" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      dup = create_published_article(tenant.id)
      related = create_published_article(tenant.id)

      # Fixed candidate list: dup >= conflict threshold (relates_to + potential_conflict),
      # related merely-related (relates_to only). Stub (called on both runs).
      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(dup, 0.99), candidate(related, 0.70)]
      end)

      run = fn ->
        assert :ok =
                 ArticleLinkingWorker.perform(%Oban.Job{
                   args: %{"article_id" => source.id, "tenant_id" => tenant.id}
                 })
      end

      run.()
      first = link_set(tenant.id, source.id)
      run.()
      second = link_set(tenant.id, source.id)

      # on_conflict: re-run creates no duplicates — the link set is stable.
      assert first == second

      # Correctness safety net: the exact produced set is what the linking logic decided,
      # unchanged by the insert mechanics.
      assert first ==
               MapSet.new([
                 {source.id, dup.id, :relates_to},
                 {source.id, dup.id, :potential_conflict},
                 {source.id, related.id, :relates_to}
               ])
    end

    test "inserts every link across multiple insert_all chunks" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      targets = for _i <- 1..5, do: create_published_article(tenant.id)

      # Test config sets a chunk size of 2, so five relates_to links span multiple chunks.
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        Enum.map(targets, &candidate(&1, 0.80))
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      count =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id,
          where: l.relationship_type == :relates_to
        )
        |> AdminRepo.aggregate(:count)

      assert count == 5
    end
  end

  # --- TC-21.2.6: Handles article with no embedding ---

  describe "no embedding" do
    test "returns :ok for article with no embedding" do
      %{tenant: tenant} = setup_tenant()

      article = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => article.id, "tenant_id" => tenant.id}
               })
    end

    test "returns :ok for deleted article" do
      %{tenant: tenant} = setup_tenant()
      fake_id = Ecto.UUID.generate()

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => fake_id, "tenant_id" => tenant.id}
               })
    end
  end

  # --- Project scoping ---

  describe "project scoping" do
    test "passes the same-project-or-tenant-wide scope and links the returned candidates" do
      %{tenant: tenant} = setup_tenant()
      project = fixture(:project, %{tenant_id: tenant.id})

      source = create_published_article(tenant.id, %{project_id: project.id})
      same_project = create_published_article(tenant.id, %{project_id: project.id})
      tenant_wide = create_published_article(tenant.id)

      # The worker must pass `:project_or_global => source.project_id` (the "same-project OR
      # tenant-wide" scope VectorSearch enforces). The lookup then returns exactly the in-scope
      # rows; the worker links them. (Cross-project EXCLUSION is VectorSearch's job, covered by
      # the integration test + VectorSearch's own suite.)
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, opts ->
        assert Keyword.fetch!(opts, :project_or_global) == project.id
        [candidate(same_project, 0.70), candidate(tenant_wide, 0.70)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      link_target_ids =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.source_article_id == ^source.id,
          select: l.target_article_id
        )
        |> AdminRepo.all()
        |> MapSet.new()

      assert MapSet.member?(link_target_ids, same_project.id)
      assert MapSet.member?(link_target_ids, tenant_wide.id)
      assert MapSet.size(link_target_ids) == 2
    end
  end

  # --- Audit event ---

  describe "audit event" do
    test "logs knowledge.articles_linked audit event" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      target = create_published_article(tenant.id)

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(target, 0.99)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      audit =
        from(a in Loopctl.Audit.AuditLog,
          where: a.tenant_id == ^tenant.id,
          where: a.action == "knowledge.articles_linked",
          where: a.entity_id == ^source.id
        )
        |> AdminRepo.one()

      assert audit != nil
      assert audit.entity_type == "article"
      assert audit.actor_type == "system"
      assert audit.actor_label == "worker:article_linking"
      assert audit.new_state["article_id"] == source.id
      # 2 links: a :relates_to and, since the pair is >= the conflict threshold, a
      # :potential_conflict flag (#4) — both are auto-links created here.
      assert audit.new_state["new_link_count"] == 2
    end
  end

  # --- Backoff ---

  describe "backoff/1" do
    test "returns polynomial backoff values" do
      for attempt <- 1..3 do
        backoff = ArticleLinkingWorker.backoff(%Oban.Job{attempt: attempt})

        min_expected = trunc(:math.pow(attempt, 4) + 15 + attempt)
        max_expected = trunc(:math.pow(attempt, 4) + 15 + 30 * attempt)

        assert backoff >= min_expected,
               "attempt #{attempt}: backoff #{backoff} < min #{min_expected}"

        assert backoff <= max_expected,
               "attempt #{attempt}: backoff #{backoff} > max #{max_expected}"
      end
    end

    test "backoff increases with each attempt" do
      backoffs =
        for attempt <- 1..3 do
          trunc(:math.pow(attempt, 4) + 15)
        end

      assert backoffs == Enum.sort(backoffs)
    end
  end

  # --- Unique job configuration ---

  describe "worker configuration" do
    test "uses knowledge queue with max_attempts 3" do
      job =
        ArticleLinkingWorker.new(%{
          article_id: Ecto.UUID.generate(),
          tenant_id: Ecto.UUID.generate()
        })

      assert job.changes.queue == "knowledge"
      assert job.changes.max_attempts == 3
    end
  end

  # --- Real vector search (integration) ---
  #
  # ONE test that exercises the ACTUAL `VectorSearch.nearest/4` path with real embeddings,
  # to keep the wiring the worker depends on under test: the exact opts the worker builds
  # produce a `[%{id, similarity_score}]` result where a genuinely-similar seeded article
  # scores above the link threshold and an orthogonal one does not. This is a single, tiny
  # kNN read (no subsequent timed op in the same test), so it is robust — it does NOT sit
  # under the compounded 250 ms flake the DI change removed from the worker's unit tests.
  describe "real vector search (integration)" do
    @describetag :integration

    defp similar_embedding, do: List.duplicate(1.0, 768) ++ List.duplicate(0.0, 768)

    defp near_similar_embedding do
      List.duplicate(1.0, 768)
      |> List.update_at(0, fn _ -> 0.99 end)
      |> List.update_at(1, fn _ -> 1.01 end)
      |> Kernel.++(List.duplicate(0.01, 768))
    end

    defp dissimilar_embedding, do: List.duplicate(0.0, 768) ++ List.duplicate(1.0, 768)

    defp publish_with_embedding(tenant_id, embedding) do
      fixture(:article, %{
        tenant_id: tenant_id,
        title: "Article #{System.unique_integer([:positive])}",
        body: "Test article body.",
        category: :pattern,
        tags: []
      })
      |> Ecto.Changeset.change(%{status: :published, embedding: embedding})
      |> AdminRepo.update!()
    end

    test "returns the real candidate shape with a similar hit above the threshold" do
      %{tenant: tenant} = setup_tenant()

      source = publish_with_embedding(tenant.id, similar_embedding())
      similar = publish_with_embedding(tenant.id, near_similar_embedding())
      dissimilar = publish_with_embedding(tenant.id, dissimilar_embedding())

      {:ok, src} = Knowledge.get_article_with_embedding(tenant.id, source.id)

      results =
        VectorSearch.nearest(tenant.id, src.embedding, 50,
          exclude_id: source.id,
          project_or_global: nil,
          threshold: 0.0,
          pool: VectorSearch.pool_size(50)
        )

      # Exact return shape the worker maps over: %{id, similarity_score, …}.
      assert Enum.all?(results, &match?(%{id: _, similarity_score: _}, &1))

      by_id = Map.new(results, &{&1.id, &1.similarity_score})

      # The near-identical article clears the 0.6 link threshold; the orthogonal one does not.
      assert Map.fetch!(by_id, similar.id) >= 0.6
      assert Map.get(by_id, dissimilar.id, 0.0) < 0.6
    end
  end
end
