defmodule Loopctl.Workers.ArticleLinkingWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import ExUnit.CaptureLog

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
  #
  # SCOPED to `source_id` (US-36.4 review): telemetry handlers fire in the EMITTING process
  # across the whole VM, so under `async: true` a CONCURRENT test that publishes an embedded
  # article runs `ArticleLinkingWorker.perform` inline and — at the test `sample_rate` — emits
  # its OWN corpus_size event. Without a filter this global handler would forward that stray
  # emission to THIS test's pid, false-failing `refute_received` and letting `assert_received`
  # match another tenant's numbers (the exact flake class fixed in commit c86c36d). Filtering
  # on `metadata.article_id == source_id` keeps each test scoped to its own source.
  defp attach_corpus_telemetry(source_id) do
    ref = make_ref()
    test_pid = self()
    handler_id = "corpus-size-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:loopctl, :knowledge, :article_linking, :corpus_size],
      fn _event, measurements, %{article_id: article_id} = metadata, _cfg ->
        if article_id == source_id do
          send(test_pid, {ref, :corpus_size, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # Counts the worker's `article_links` `insert_all` invocations for a SPECIFIC source, via
  # the AdminRepo Ecto query telemetry. Scoped to `source_id` (its dumped UUID appears in the
  # `insert_all` params of every chunk, since all of this source's rows share it) so a
  # concurrent async test's inserts can never inflate the count. Lets the chunking test
  # ASSERT the batch boundary (N chunks) rather than only the final row count — which a
  # single un-chunked insert would satisfy identically, failing to guard the AC-36.4.4
  # bind-parameter chunking safeguard.
  defp attach_insert_all_counter(source_id) do
    ref = make_ref()
    test_pid = self()
    handler_id = "insert-all-#{inspect(ref)}"
    {:ok, dumped_source_id} = Ecto.UUID.dump(source_id)

    :telemetry.attach(
      handler_id,
      [:loopctl, :admin_repo, :query],
      fn _event, _measurements, metadata, _cfg ->
        if metadata[:source] == "article_links" and is_binary(metadata[:query]) and
             String.starts_with?(metadata[:query], "INSERT") and
             is_list(metadata[:params]) and dumped_source_id in metadata[:params] do
          send(test_pid, {ref, :insert_all})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp received_count(ref, tag) do
    receive do
      {^ref, ^tag} -> 1 + received_count(ref, tag)
    after
      0 -> 0
    end
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

  # Finding #2 (US-37.5 review): when the per-tenant HeavyRead gate sheds the kNN read
  # (returned as `{:error, :heavy_read_overloaded}` via `on_overload: :tag`), the worker
  # must yield LOSS-FREE with `{:snooze, n}` — not error/retry-churn toward max_attempts
  # (which could permanently lose an article's auto-links under a sustained burst).
  describe "perform/1 heavy-read overload (US-37.5)" do
    test "passes on_overload: :tag and SNOOZES (no attempt consumed) when the read is shed" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, opts ->
        # The worker asks for the graceful-degrade disposition, not a raise.
        assert Keyword.fetch!(opts, :on_overload) == :tag
        {:error, :heavy_read_overloaded}
      end)

      assert {:snooze, seconds} =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      assert is_integer(seconds) and seconds > 0

      # No links were created — the job made no partial progress before snoozing.
      assert AdminRepo.all(from(l in ArticleLink, where: l.tenant_id == ^tenant.id)) == []
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

  describe "relates_to degree cap (#611 stage 0)" do
    # A threshold is not a bound. Before this cap `relates_to` took EVERY candidate over
    # 0.6 — up to `max_comparisons` (50) per article, bidirectionally — and the hosted
    # corpus reached 1,402,699 edges over 79,276 articles, 56% of them carrying 21+. At
    # that density the graph relates nearly everything to everything and distinguishes
    # nothing. The cap is what makes the producer bounded.
    test "keeps only the top-K nearest, and keeps the NEAREST ones" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      # 14 candidates, all comfortably over the relates threshold and all under the
      # conflict threshold, with strictly descending similarity so "which K" is decidable.
      scored =
        for i <- 0..13 do
          {create_published_article(tenant.id), 0.92 - i * 0.01}
        end

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        # Returned in a deliberately WRONG order: the cut must sort, not trust arrival
        # order, or it degrades to "whichever K the vector index happened to yield first".
        scored |> Enum.reverse() |> Enum.map(fn {a, s} -> candidate(a, s) end)
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      linked =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where: l.source_article_id == ^source.id,
          select: l.target_article_id
        )
        |> AdminRepo.all()
        |> MapSet.new()

      cap = Application.get_env(:loopctl, :article_max_relates_to_links, 10)
      assert MapSet.size(linked) == cap

      {kept, dropped} = Enum.split(scored, cap)

      for {article, sim} <- kept do
        assert MapSet.member?(linked, article.id),
               "candidate at similarity #{sim} is in the top #{cap} but was not linked"
      end

      for {article, sim} <- dropped do
        refute MapSet.member?(linked, article.id),
               "candidate at similarity #{sim} is outside the top #{cap} but was linked"
      end
    end

    test "tops an already-linked article UP to K rather than adding K more" do
      # The cut used to run on the candidate list BEFORE the already-linked rejection, so
      # stored edges cost nothing against K: every re-link (nightly orphan pass, a re-embed)
      # could add K MORE and outbound degree grew without bound between prunes.
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      first = for _i <- 1..14, do: create_published_article(tenant.id)
      second = for _i <- 1..14, do: create_published_article(tenant.id)

      run = fn ->
        ArticleLinkingWorker.perform(%Oban.Job{
          args: %{"article_id" => source.id, "tenant_id" => tenant.id}
        })
      end

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        Enum.map(first, &candidate(&1, 0.90))
      end)

      assert :ok = run.()

      # A later run whose candidate set has shifted: all NEW pairs, all nearer than the
      # stored ones. The article is already at K, so it may write none of them.
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        Enum.map(second, &candidate(&1, 0.92))
      end)

      assert :ok = run.()

      degree =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where: l.source_article_id == ^source.id or l.target_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      assert degree == Application.get_env(:loopctl, :article_max_relates_to_links, 10)
    end

    test "an edge the prune can never free does not consume the headroom" do
      # Headroom used to count EVERY incident relates_to edge, including hand-made ones that
      # `LinkPruning` may never delete. K of those switched this article's auto-linking off for
      # good: no pass could free a slot again, so the writer's bound and the pruner's target
      # were two different definitions of degree and the article lost by the difference.
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      cap = Application.get_env(:loopctl, :article_max_relates_to_links, 10)

      for _i <- 1..cap do
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: source.id,
          target_article_id: create_published_article(tenant.id).id,
          relationship_type: :relates_to,
          metadata: %{"note" => "curated by hand"}
        })
      end

      candidates = for _i <- 1..3, do: create_published_article(tenant.id)

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        Enum.map(candidates, &candidate(&1, 0.90))
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      for c <- candidates do
        assert links_of_type(tenant.id, source.id, c.id, :relates_to) != [],
               "a hand-made link the prune cannot reclaim consumed a write slot forever"
      end
    end

    test "does NOT cap potential_conflict — that queue has its own draining consumer" do
      # `judge_redundant_conflicts/1` drains this pile capped ABOVE the promotion rate, so
      # it converges by arithmetic. Capping the producer here as well would silently
      # withhold pairs from a queue designed to empty itself.
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      targets = for _i <- 1..14, do: create_published_article(tenant.id)

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        Enum.map(targets, &candidate(&1, 0.97))
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      conflict_count =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :potential_conflict,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      assert conflict_count == 14

      # ...while relates_to for the same 14 candidates IS capped.
      relates_count =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where: l.source_article_id == ^source.id
        )
        |> AdminRepo.aggregate(:count)

      assert relates_count == Application.get_env(:loopctl, :article_max_relates_to_links, 10)
    end
  end

  describe "candidate fan-out" do
    test "creates a relates_to link for each returned candidate under the degree cap" do
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

      ref = attach_corpus_telemetry(source.id)

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

      ref = attach_corpus_telemetry(source.id)

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

  describe "corpus-size count degradation (AC-36.4.3)" do
    test "an EXIT from the observational count degrades softly and still links" do
      # The count's rescue clause was `rescue`-only, so it caught the raise shape
      # (`Postgrex.Error` 57014) and missed the other one. A pool checkout against a wedged,
      # saturated or unstarted `AdminRepo` EXITS rather than raising — `{:noproc, {DBConnection,
      # ...}}` — which walked straight past it and aborted `perform/1`. Because sampling is
      # deterministic by `article_id`, all three Oban attempts re-sampled and re-exited, so the
      # article was left permanently unlinked: the exact regression the rescue exists to
      # prevent, reached by the other of the two ways this call can fail.
      #
      # `corpus_count_query/2` consults the injected read path and is the ONLY caller of it in
      # this module, so stubbing that to exit puts a production-shaped exit precisely inside
      # the observational block and nowhere else.
      %{tenant: tenant} = setup_tenant()
      source = create_article_in_bucket(tenant.id, true)
      target = create_published_article(tenant.id)

      ref = attach_corpus_telemetry(source.id)

      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn ->
        exit({:noproc, {DBConnection, :execute, []}})
      end)

      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(target, 0.88)]
      end)

      log =
        capture_log(fn ->
          assert :ok =
                   ArticleLinkingWorker.perform(%Oban.Job{
                     args: %{"article_id" => source.id, "tenant_id" => tenant.id}
                   })
        end)

      # The observational signal is the ONLY casualty...
      refute_received {^ref, :corpus_size, _measurements, _metadata}
      assert log =~ "corpus-size count exited"

      # ...tagged, not swallowed anonymously: a bounded class, never the raw exit reason
      # (which carries the whole DBConnection call tuple).
      assert log =~ "(noproc)"
      refute log =~ "DBConnection"

      # ...and the linking it merely observes still happened. That is the whole point.
      assert [_] = links_of_type(tenant.id, source.id, target.id, :relates_to)
    end

    test "a propagated CRASH exit is tagged by exception module, not degraded to \"unknown\"" do
      # A pool process that dies of an exception (rather than being absent) propagates
      # `{{exception, stacktrace}, call}`. An atom-only tagger degrades that — at least as
      # common as `:noproc` — to the catch-all, costing the operator the usable class.
      %{tenant: tenant} = setup_tenant()
      source = create_article_in_bucket(tenant.id, true)
      target = create_published_article(tenant.id)

      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn ->
        exit({{%RuntimeError{message: "pool died"}, []}, {GenServer, :call, [self(), :req]}})
      end)

      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(target, 0.88)]
      end)

      log =
        capture_log(fn ->
          assert :ok =
                   ArticleLinkingWorker.perform(%Oban.Job{
                     args: %{"article_id" => source.id, "tenant_id" => tenant.id}
                   })
        end)

      assert log =~ "corpus-size count exited (RuntimeError)"
      refute log =~ "pool died"
      assert [_] = links_of_type(tenant.id, source.id, target.id, :relates_to)
    end

    test "a THROW from the observational count degrades softly and still links" do
      # The third non-local exit kind. `rescue` + `catch :exit` alone still let it abort
      # `perform/1` over a signal the job does not depend on.
      %{tenant: tenant} = setup_tenant()
      source = create_article_in_bucket(tenant.id, true)
      target = create_published_article(tenant.id)

      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> throw(:boom) end)

      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(target, 0.88)]
      end)

      log =
        capture_log(fn ->
          assert :ok =
                   ArticleLinkingWorker.perform(%Oban.Job{
                     args: %{"article_id" => source.id, "tenant_id" => tenant.id}
                   })
        end)

      assert log =~ "corpus-size count threw (boom)"
      assert [_] = links_of_type(tenant.id, source.id, target.id, :relates_to)
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

    test "inserts every link across multiple insert_all chunks (and actually chunks)" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      targets = for _i <- 1..5, do: create_published_article(tenant.id)

      # Test config sets a chunk size of 2, so five relates_to links span multiple chunks.
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        Enum.map(targets, &candidate(&1, 0.80))
      end)

      insert_ref = attach_insert_all_counter(source.id)

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

      # GUARD the chunking itself (not just the row total): 5 rows at chunk size 2 must span
      # ceil(5/2) = 3 separate insert_all calls. A regression that dropped `Enum.chunk_every`
      # would issue ONE insert of 5 and fail this — the row count above would still pass.
      assert received_count(insert_ref, :insert_all) == 3
    end
  end

  describe "vanished-target resilience (AC-36.4.3 — behavior parity)" do
    test "skips a candidate whose target no longer exists and still links the rest, no crash" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      valid = create_published_article(tenant.id)
      # A candidate id with no backing article: the old row-by-row path skipped this as an FK
      # `{:error, changeset}`; the batched insert_all would raise + abort the whole batch. The
      # pre-filter drops it before the insert, reproducing "skip the vanished target, link the
      # rest, succeed" without an aborted transaction.
      vanished_id = Ecto.UUID.generate()

      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [
          %{id: vanished_id, title: "gone", category: :pattern, similarity_score: 0.80},
          candidate(valid, 0.80)
        ]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # The surviving candidate linked...
      assert [_] = links_of_type(tenant.id, source.id, valid.id, :relates_to)

      # ...and the vanished target produced no link.
      vanished_links =
        from(l in ArticleLink,
          where: l.source_article_id == ^source.id,
          where: l.target_article_id == ^vanished_id
        )
        |> AdminRepo.all()

      assert vanished_links == []
    end

    test "drops the whole batch (no crash) when the SOURCE article vanishes before the insert" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)
      valid = create_published_article(tenant.id)

      # The similarity lookup fires AFTER the source was fetched (get_article_with_embedding)
      # but BEFORE create_links inserts. Hard-delete the source HERE to simulate a concurrent
      # hard-delete in exactly that window — possible precisely because the source has no links
      # yet, so its `on_delete: :restrict` FK does not block deletion. Every candidate row
      # shares this source, so an unguarded insert_all would FK-violate on source_article_id
      # and abort the whole transaction, crashing the job. The source guard in
      # `reject_vanished_endpoints/2` drops the entire batch instead — matching the old
      # row-by-row path's "skip every row, return :ok with 0 links".
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        AdminRepo.delete!(source)
        [candidate(valid, 0.80)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      # No links created (source gone) and — the point of the guard — no crash / no aborted
      # transaction. A `on_delete: :restrict` FK violation would have raised instead.
      assert [] ==
               from(l in ArticleLink, where: l.source_article_id == ^source.id)
               |> AdminRepo.all()
    end
  end

  describe "self-link guard (US-36.4 review — defense-in-depth)" do
    test "never inserts a self-link even if the lookup returns the source as a candidate" do
      %{tenant: tenant} = setup_tenant()
      source = create_published_article(tenant.id)

      # A misbehaving lookup returns the SOURCE itself as a candidate. `build_links/5` must
      # reject source == target — the batched insert_all path bypasses
      # `ArticleLink.changeset/2`'s `validate_no_self_link`, so the guard lives in the worker.
      expect(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, _opts ->
        [candidate(source, 0.99)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant.id}
               })

      links =
        from(l in ArticleLink, where: l.source_article_id == ^source.id)
        |> AdminRepo.all()

      assert links == []
    end
  end

  # --- AC-36.4.3 / TC-36.4.4: two-tenant isolation of the count + inserts ---

  describe "tenant isolation of corpus count and inserts (AC-36.4.3 / TC-36.4.4)" do
    test "only tenant A's corpus is counted and only A's links are inserted; B untouched" do
      %{tenant: tenant_a} = setup_tenant()
      %{tenant: tenant_b} = setup_tenant()

      # Source in A, forced into the sample bucket so the corpus count actually runs.
      source = create_article_in_bucket(tenant_a.id, true)

      # A's corpus: exactly two other published+embedded articles the count should see.
      a1 = create_published_article(tenant_a.id)
      a2 = create_published_article(tenant_a.id)

      # B's corpus: three published+embedded articles that must be excluded from BOTH the
      # count and the inserts (different tenant → filtered by `a.tenant_id == ^tenant_id`).
      for _i <- 1..3, do: create_published_article(tenant_b.id)

      ref = attach_corpus_telemetry(source.id)

      # The lookup returns only A's in-tenant candidates; the worker asserts it passes A's
      # tenant, then links them. (VectorSearch enforces the real cross-tenant read exclusion;
      # here we assert the COUNT and INSERT scoping the worker owns around it.)
      expect(MockArticleSimilaritySearch, :nearest, fn tenant_id, _emb, _k, _opts ->
        assert tenant_id == tenant_a.id
        [candidate(a1, 0.80), candidate(a2, 0.80)]
      end)

      assert :ok =
               ArticleLinkingWorker.perform(%Oban.Job{
                 args: %{"article_id" => source.id, "tenant_id" => tenant_a.id}
               })

      # The corpus count saw ONLY A's two other articles — B's three are excluded by scoping.
      assert_received {^ref, :corpus_size, measurements, metadata}
      assert measurements.total == 2
      assert metadata.tenant_id == tenant_a.id

      # Inserts landed under tenant A only.
      a_links =
        from(l in ArticleLink, where: l.source_article_id == ^source.id)
        |> AdminRepo.all()

      assert length(a_links) == 2
      assert Enum.all?(a_links, &(&1.tenant_id == tenant_a.id))

      # Tenant B has NO links at all — nothing leaked across the tenant boundary.
      b_link_count =
        from(l in ArticleLink, where: l.tenant_id == ^tenant_b.id)
        |> AdminRepo.aggregate(:count)

      assert b_link_count == 0
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

    # Per-test-unique via `Loopctl.DataCase.test_vec/2` (dissolves the shared-HNSW-index
    # clique; see its @doc). `similar` == the source direction (cosine 1.0); `near_similar`
    # adds a tiny orthogonal-window perturbation (cosine ~0.9999, well above the 0.6 link
    # threshold); `dissimilar` is orthogonal (cosine 0).
    defp similar_embedding, do: test_vec(1536, :primary)

    defp near_similar_embedding do
      primary = test_vec(1536, :primary)
      orthogonal = test_vec(1536, :orthogonal)
      Enum.zip_with(primary, orthogonal, fn p, o -> p + 0.01 * o end)
    end

    defp dissimilar_embedding, do: test_vec(1536, :orthogonal)

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
