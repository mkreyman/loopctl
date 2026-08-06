defmodule Loopctl.Workers.KnowledgeLintWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.HeavyRead.TenantGate
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.MockArticleSimilaritySearch
  alias Loopctl.Workers.KnowledgeLintWorker

  # The lint worker acts on orphans by enqueuing (inline, in-process) ArticleLinkingWorker,
  # whose similarity lookup is injected (Loopctl.Knowledge.SimilaritySearchBehaviour). The
  # DataCase default stub returns [] (so most lint tests link nothing — they assert counts,
  # not links); the one test that asserts an orphan pair actually gets re-linked feeds a
  # deterministic candidate, keeping the whole path off the flaky 250 ms heavy read.

  # A published article with a known embedding vector, written directly via
  # AdminRepo to bypass the inline Oban cascade (embedding -> linking) that
  # `fixture(:article)` would otherwise trigger on publish.
  defp published_article_with_embedding(tenant_id, embedding, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Test article body.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published, embedding: embedding})
    |> AdminRepo.update!()
  end

  # Two near-identical directional vectors -> cosine similarity ~1.0, above the 0.6 linking
  # threshold. Per-test-unique via `Loopctl.DataCase.test_vec/2` (dissolves the shared-HNSW-index
  # clique; see its @doc): `near_similar` adds a tiny orthogonal-window perturbation (~0.9999).
  defp similar_embedding, do: test_vec(1536, :primary)

  defp near_similar_embedding do
    primary = test_vec(1536, :primary)
    orthogonal = test_vec(1536, :orthogonal)
    Enum.zip_with(primary, orthogonal, fn p, o -> p + 0.01 * o end)
  end

  # A published orphan with NO embedding — the case a plain re-link no-ops on.
  defp published_without_embedding(tenant_id) do
    fixture(:article, %{
      tenant_id: tenant_id,
      title: "Article #{System.unique_integer([:positive])}",
      body: "Test article body.",
      category: :pattern,
      tags: []
    })
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp lint_audit_entries(tenant_id) do
    from(a in AuditLog,
      where: a.tenant_id == ^tenant_id,
      where: a.action == "knowledge.lint_completed"
    )
    |> AdminRepo.all()
  end

  describe "perform/1 per-tenant" do
    test "logs a knowledge.lint_completed audit event carrying the lint summary" do
      tenant = fixture(:tenant)
      _article = published_article_with_embedding(tenant.id, similar_embedding())

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.actor_type == "system"
      assert entry.actor_label == "worker:knowledge_lint"
      # new_state is jsonb -> string keys on read
      assert entry.new_state["summary"]["total_articles"] == 1
      assert is_integer(entry.new_state["summary"]["total_issues"])
      assert is_integer(entry.new_state["orphans_relinked"])
      assert is_integer(entry.new_state["orphans_embedding_enqueued"])
    end

    test "re-links orphan articles against the current corpus" do
      tenant = fixture(:tenant)
      # Two similar, published, unlinked articles -> both orphans.
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())

      # Each orphan's re-link job asks for its nearest neighbor (excluding itself); return the
      # OTHER article of the pair so the two get linked. Called once per embedded orphan.
      a_id = a.id
      b_id = b.id
      a_cand = %{id: a.id, title: a.title, category: a.category, similarity_score: 0.99}
      b_cand = %{id: b.id, title: b.title, category: b.category, similarity_score: 0.99}

      stub(MockArticleSimilaritySearch, :nearest, fn _t, _emb, _k, opts ->
        case Keyword.fetch!(opts, :exclude_id) do
          ^a_id -> [b_cand]
          ^b_id -> [a_cand]
          _ -> []
        end
      end)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # Orphan re-link (inline Oban) ran ArticleLinkingWorker -> a relates_to
      # link now connects the previously-orphaned pair.
      links =
        from(l in ArticleLink,
          where: l.tenant_id == ^tenant.id,
          where: l.relationship_type == :relates_to,
          where:
            (l.source_article_id == ^a.id and l.target_article_id == ^b.id) or
              (l.source_article_id == ^b.id and l.target_article_id == ^a.id)
        )
        |> AdminRepo.all()

      assert length(links) == 1

      assert [entry] = lint_audit_entries(tenant.id)
      # Both were embedded orphans, so both were re-linked (not embedding-enqueued).
      assert entry.new_state["summary"]["total_per_category"]["orphan_articles"] == 2
      assert entry.new_state["orphans_relinked"] == 2
      assert entry.new_state["orphans_embedding_enqueued"] == 0
    end

    test "embeds orphans that have no embedding (a plain re-link would no-op them)" do
      tenant = fixture(:tenant)
      orphan = published_without_embedding(tenant.id)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # The embedding worker ran inline (default Mox stub yields a 1536-dim vector)
      # and stored an embedding, so the orphan is no longer un-embeddable.
      reloaded = Loopctl.Knowledge.get_article_with_embedding(tenant.id, orphan.id)
      assert {:ok, %{embedding: embedding}} = reloaded
      refute is_nil(embedding)

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["orphans_relinked"] == 0
      assert entry.new_state["orphans_embedding_enqueued"] == 1
    end

    test "US-37.4: BATCHES the orphan-embedding backfill — N orphans => one array call, not N" do
      tenant = fixture(:tenant)
      test_pid = self()

      orphans = for _ <- 1..3, do: published_without_embedding(tenant.id)

      # Count provider round-trips via a message per BATCH call.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _t, texts ->
        send(test_pid, {:batch_call, length(texts)})
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 1536) end)}
      end)

      # The per-article path must NOT be used for the bulk backfill.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        flunk("orphan backfill must batch, not use per-article generate_embedding/2")
      end)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # ONE array call covered all 3 orphans (batch_max default ~100), not 3 calls.
      assert drain_batch_calls([]) == [3]

      for o <- orphans do
        assert {:ok, %{embedding: emb}} =
                 Loopctl.Knowledge.get_article_with_embedding(tenant.id, o.id)

        refute is_nil(emb)
      end

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["orphans_embedding_enqueued"] == 3
    end

    test "#584: runs the consolidation pass inside the SAME nightly run" do
      tenant = fixture(:tenant)
      published_article_with_embedding(tenant.id, similar_embedding(), %{title: "Retry Policy"})
      published_article_with_embedding(tenant.id, similar_embedding(), %{title: "retry-policy!"})

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # One consolidation report for the tenant, produced by the lint run — no second
      # scheduler, no second corpus scan.
      assert [report] =
               AdminRepo.all(
                 from(r in Loopctl.Knowledge.ConsolidationReport,
                   where: r.tenant_id == ^tenant.id
                 )
               )

      assert report.day == Date.utc_today()
      assert report.proposals_by_class["duplicate_capture"] == 1

      assert [proposal] =
               AdminRepo.all(
                 from(p in Loopctl.Knowledge.ConsolidationProposal,
                   where: p.tenant_id == ^tenant.id
                 )
               )

      assert proposal.proposal_class == :duplicate_capture
      assert proposal.review_status == :pending
      assert length(proposal.evidence) == 2

      # The single audit event carries the consolidation counts alongside the lint summary.
      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["consolidation"]["status"] == "ok"
      assert entry.new_state["consolidation"]["proposal_count"] == 1
      assert entry.new_state["consolidation"]["persisted_count"] == 1
      assert entry.new_state["consolidation"]["day"] == Date.to_iso8601(Date.utc_today())

      # ...and the APPLY's own tally, which the proposal counts cannot express: nothing was
      # applied here because only one report exists, so nothing has been confirmed twice.
      # Without these keys a systematically failing apply looks exactly like a quiet night.
      assert entry.new_state["consolidation"]["duplicates_unpublished"] == 0
      assert entry.new_state["consolidation"]["duplicate_groups_skipped"] == 0
    end

    # The consolidation stage runs AFTER the effectful steps (orphan re-link, conflict
    # promotion, applied resolutions) and BEFORE the audit event. If it could abort the run,
    # a tenant whose corpus deterministically fails those scans would lose the pre-existing
    # lint pass's observability entirely while Oban redid the effectful steps each retry.
    # Forced here through a REAL failure mode: the tenant's whole HeavyRead in-flight budget
    # is already reserved, so the pass's `with_slot/3` sheds and raises.
    test "#584: a consolidation failure does NOT abort the lint run or suppress its audit event" do
      tenant = fixture(:tenant)
      published_article_with_embedding(tenant.id, similar_embedding(), %{title: "Retry Policy"})
      published_article_with_embedding(tenant.id, similar_embedding(), %{title: "retry-policy!"})

      cap = TenantGate.cap()
      assert TenantGate.acquire(tenant.id, cap, cap) == :ok

      try do
        assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
      after
        TenantGate.release(tenant.id, cap)
      end

      # No consolidation report was written...
      assert AdminRepo.all(
               from(r in Loopctl.Knowledge.ConsolidationReport, where: r.tenant_id == ^tenant.id)
             ) == []

      # ...but the lint pass's own audit event still is, and it NAMES the failure.
      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["summary"]["total_articles"] == 2
      assert entry.new_state["consolidation"]["status"] == "failed"
      assert is_binary(entry.new_state["consolidation"]["error"])

      # The gate key is the one an auditor parses to learn WHY nothing applied, so it is
      # recorded on the failing nights too — absent-on-failure is the one answer it must not
      # give. This also guards the `:apply_failed` tally: both come from the same zero-tally
      # constructor, and it was a constructor missing `:gate` that raised a KeyError one line
      # after the rescue swallowed the original error, making Oban re-run the whole night.
      assert entry.new_state["consolidation"]["duplicate_apply_gate"] == "scan_failed"
    end

    # The apply reads the two most recent reports. If a failed scan could fall through to it,
    # those two rows are last night and the night before — the two-run agreement gate would
    # silently become "two STALE reports agree" and unpublish on evidence nobody re-derived,
    # every night the scan keeps failing.
    test "#608: a failed consolidation scan does NOT apply against two stale reports" do
      tenant = fixture(:tenant)

      a =
        published_article_with_embedding(tenant.id, similar_embedding(), %{
          title: "Retry Policy",
          body: String.duplicate("long winner body ", 20)
        })

      b =
        published_article_with_embedding(tenant.id, similar_embedding(), %{
          title: "retry-policy!",
          body: "short"
        })

      # Two prior nights already agree on the duplicate group, so an ungated apply would fire.
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -2))
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))

      cap = TenantGate.cap()
      assert TenantGate.acquire(tenant.id, cap, cap) == :ok

      try do
        assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
      after
        TenantGate.release(tenant.id, cap)
      end

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["consolidation"]["status"] == "failed"

      assert AdminRepo.get!(Loopctl.Knowledge.Article, a.id).status == :published
      assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :published
    end

    test "handles a tenant with no published articles" do
      tenant = fixture(:tenant)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["summary"]["total_articles"] == 0
      assert entry.new_state["orphans_relinked"] == 0
      assert entry.new_state["orphans_embedding_enqueued"] == 0
    end
  end

  describe "perform/1 all_tenants mode" do
    test "fans out and lints every active tenant, skipping inactive ones" do
      active_a = fixture(:tenant)
      active_b = fixture(:tenant)
      suspended = fixture(:tenant, %{status: :suspended})

      for t <- [active_a, active_b, suspended] do
        published_article_with_embedding(t.id, similar_embedding())
      end

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})

      assert [_] = lint_audit_entries(active_a.id)
      assert [_] = lint_audit_entries(active_b.id)
      assert [] == lint_audit_entries(suspended.id)
    end
  end

  describe "tenant isolation" do
    test "lint summary counts only the caller tenant's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      published_article_with_embedding(tenant_a.id, similar_embedding())
      published_article_with_embedding(tenant_a.id, near_similar_embedding())

      published_article_with_embedding(tenant_b.id, similar_embedding())
      published_article_with_embedding(tenant_b.id, near_similar_embedding())
      published_article_with_embedding(tenant_b.id, similar_embedding())

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant_a.id}})

      assert [entry] = lint_audit_entries(tenant_a.id)
      assert entry.new_state["summary"]["total_articles"] == 2
      # Tenant B was never linted.
      assert [] == lint_audit_entries(tenant_b.id)
    end
  end

  describe "conflict promotion (#4 existing-corpus backstop)" do
    defp relates_link(tenant_id, src_id, tgt_id, score) do
      %ArticleLink{tenant_id: tenant_id}
      |> ArticleLink.changeset(%{
        source_article_id: src_id,
        target_article_id: tgt_id,
        relationship_type: :relates_to,
        metadata: %{"auto_generated" => true, "similarity_score" => score}
      })
      |> AdminRepo.insert!()
    end

    defp conflict_links(tenant_id, a_id, b_id) do
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where:
          (l.source_article_id == ^a_id and l.target_article_id == ^b_id) or
            (l.source_article_id == ^b_id and l.target_article_id == ^a_id)
      )
      |> AdminRepo.all()
    end

    defp resolutions(tenant_id, a_id, b_id) do
      from(r in Loopctl.Knowledge.ConflictResolution,
        where: r.tenant_id == ^tenant_id,
        where:
          (r.source_article_id == ^a_id and r.target_article_id == ^b_id) or
            (r.source_article_id == ^b_id and r.target_article_id == ^a_id)
      )
      |> AdminRepo.all()
    end

    test "a promoted conflict is JUDGED the same night, as redundant rather than contradictory" do
      # Before this, nothing ever closed a potential_conflict: the count was monotone by
      # construction and every open one withheld BOTH articles from curated answers. With no
      # human in the loop that is permanent.
      #
      # The verdict is `:redundant`, not a contradiction finding, because that is what the
      # signal measures. Cosine similarity says "these say the same thing"; contradiction
      # says "these disagree". Measured across all 16,117 flagged pairs on the hosted corpus:
      # 0 identical bodies, 261 identical normalised titles, and a 20-pair sample spanning
      # 0.93-0.99 with ZERO contradictions — the top matches differ by a colon, a hyphen, a
      # percent sign and a plural.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      relates_link(tenant.id, a.id, b.id, 0.96)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [conflict] = conflict_links(tenant.id, a.id, b.id)
      assert conflict.metadata["promoted_from"] == "relates_to"

      assert [verdict] = resolutions(tenant.id, a.id, b.id)
      assert verdict.classification == :redundant
      assert verdict.disposition == :dismiss
      assert verdict.annotated_by == "worker:knowledge_lint"
      # 0.96 >= the high-confidence cutoff.
      assert verdict.confidence == :high
      # Dismiss has nothing to execute; marking it done keeps it out of the executor's
      # pending set, which is the limbo this drain exists to end.
      refute is_nil(verdict.executed_at)
      assert verdict.execution_result["action"] == "noop"

      # The pair is stored canonically (source <= target) regardless of link orientation.
      assert verdict.source_article_id <= verdict.target_article_id

      # And the audit event carries BOTH counters, because their difference is the
      # convergence signal.
      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["conflicts_promoted"] == 1
      assert entry.new_state["conflicts_judged_redundant"] == 1
    end

    test "judging is idempotent — a second night does not re-judge an already-judged pair" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      relates_link(tenant.id, a.id, b.id, 0.94)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
      assert [_one] = resolutions(tenant.id, a.id, b.id)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # Still exactly one row, and the second run reports nothing new to judge — otherwise
      # the "judged" counter would climb every night on a static corpus and the convergence
      # signal in the audit event would be meaningless.
      assert [_still_one] = resolutions(tenant.id, a.id, b.id)
      assert [_first, second] = lint_audit_entries(tenant.id)
      assert second.new_state["conflicts_judged_redundant"] == 0
    end

    test "promotes a high-similarity relates_to link to a :potential_conflict flag" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      relates_link(tenant.id, a.id, b.id, 0.95)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [conflict] = conflict_links(tenant.id, a.id, b.id)
      assert conflict.metadata["promoted_from"] == "relates_to"
      assert conflict.metadata["similarity_score"] == 0.95

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["conflicts_promoted"] == 1
    end

    test "leaves a below-threshold relates_to link alone" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      relates_link(tenant.id, a.id, b.id, 0.80)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [] == conflict_links(tenant.id, a.id, b.id)
    end

    # kb-02: a relates_to link WITHOUT the system auto_generated marker (the agent-forged
    # case, even at a very high similarity_score) is NOT promoted — this closes the
    # laundering path where an agent plants a relates_to+score to mint a system-stamped
    # potential_conflict.
    test "does NOT promote a relates_to link that is not system-authored" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())

      # No "auto_generated" marker — as if planted by an agent via the public API.
      %ArticleLink{tenant_id: tenant.id}
      |> ArticleLink.changeset(%{
        source_article_id: a.id,
        target_article_id: b.id,
        relationship_type: :relates_to,
        metadata: %{"similarity_score" => 0.99}
      })
      |> AdminRepo.insert!()

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [] == conflict_links(tenant.id, a.id, b.id)
      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["conflicts_promoted"] == 0
    end

    # kb-02 end-to-end: an agent-created relates_to link (metadata stripped by
    # create_link) cannot be laundered into a resolvable potential_conflict, even at
    # similarity 0.99 — the pair never becomes system-flagged, so a verdict is refused.
    test "an agent-created relates_to link cannot be laundered into a resolvable conflict" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())

      # Model the agent's API POST (which routes through create_link): forged provenance
      # + score. create_link strips the reserved keys.
      {:ok, link} =
        Loopctl.Knowledge.create_link(tenant.id, %{
          source_article_id: a.id,
          target_article_id: b.id,
          relationship_type: :relates_to,
          metadata: %{"auto_generated" => true, "similarity_score" => 0.99}
        })

      refute Map.has_key?(link.metadata, "auto_generated")

      # Nightly promotion must NOT mint a potential_conflict from the forged link.
      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
      assert [] == conflict_links(tenant.id, a.id, b.id)

      # And a resolution verdict for the pair is refused (no system flag).
      assert {:error, :no_potential_conflict} =
               Loopctl.Knowledge.annotate_conflict(tenant.id, %{
                 "source_article_id" => a.id,
                 "target_article_id" => b.id,
                 "disposition" => "supersede",
                 "authoritative_article_id" => a.id,
                 "confidence" => "high"
               })
    end

    test "is idempotent — a second run promotes nothing new" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      relates_link(tenant.id, a.id, b.id, 0.96)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # The pair is promoted exactly ONCE no matter how many times the worker runs
      # (guarded by promote_conflicts/1's `not exists` check AND the article_links
      # unique index — a same-direction re-insert can never mint a second row).
      assert [_only_one] = conflict_links(tenant.id, a.id, b.id)

      # Idempotency is ORDER-INDEPENDENT: across the two runs exactly one promotion
      # happened (the first); the other run promoted nothing new. Assert the MULTISET of
      # per-run promotion counts, not positional order. `lint_audit_entries/1` is
      # unordered and audit `inserted_at` is NOT a total order across two same-tenant
      # runs — the audit_log column carries a DB-side `now()` (transaction-timestamp)
      # default, so two entries written in this test's single sandbox transaction can
      # share an `inserted_at` to the microsecond. Sorting on that key alone then leaves
      # the "second" slot at the mercy of arbitrary heap return order and can surface the
      # first run's entry (conflicts_promoted == 1) — the intermittent failure. (The
      # production audit-history reader guards the same collision with a mandatory
      # (inserted_at, id) tiebreak.)
      promotions =
        lint_audit_entries(tenant.id)
        |> Enum.map(& &1.new_state["conflicts_promoted"])
        |> Enum.sort()

      assert promotions == [0, 1]
    end
  end

  # Collect all {:batch_call, n} messages currently in the mailbox (batch workers ran
  # inline before perform/1 returned, so they're all already delivered).
  defp drain_batch_calls(acc) do
    receive do
      {:batch_call, n} -> drain_batch_calls([n | acc])
    after
      0 -> acc
    end
  end

  describe "consolidation apply caps reach the context (#611)" do
    # No embedding: this describe exercises the LEXICAL duplicate class only, and an embedded
    # publish would fire the inline linking cascade these tests do not want.
    defp published_no_embedding(tenant_id, attrs) do
      base = %{category: :pattern, status: :draft, tags: []}

      fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
      |> Ecto.Changeset.change(%{status: :published})
      |> AdminRepo.update!()
    end

    test "honours BOTH configured apply caps instead of the module defaults" do
      # config/test.exs pins the caps ASYMMETRICALLY (max_applies: 2, max_unpublishes: 1)
      # against three confirmed one-loser groups, so each opt owns its own assertion:
      #   * both wired      -> 2 proposals fetched, 1 applies, 1 skipped
      #   * max_applies gone (25)     -> 3 fetched  -> skipped == 2, not 1
      #   * max_unpublishes gone (100) -> both fetched apply -> applied == 2, not 1
      # With both caps at 1 the answer was one applied loser either way, which is how the
      # unreachable-opts bug could have half-regressed unnoticed.
      tenant = fixture(:tenant)

      groups =
        for n <- 1..3 do
          winner =
            published_no_embedding(tenant.id, %{
              title: "Cap Group #{n} Document",
              body: String.duplicate("long winner body ", 20)
            })

          loser =
            published_no_embedding(tenant.id, %{title: "cap-group-#{n}-document!", body: "s"})

          {winner, loser}
        end

      # Two adjacent reports so the agreement gate is open on all three groups.
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{
                 id: 0,
                 args: %{"tenant_id" => tenant.id}
               })

      still_published =
        Enum.count(groups, fn {_w, loser} ->
          AdminRepo.get!(Loopctl.Knowledge.Article, loser.id).status == :published
        end)

      assert still_published == 2,
             "an article cap of 1 must leave 2 of 3 losers published"

      assert [entry] = lint_audit_entries(tenant.id)
      applied = entry.new_state["consolidation"]

      assert applied["duplicates_unpublished"] == 1,
             ":max_unpublishes was not honoured — a second group applied"

      assert applied["duplicate_groups_skipped"] == 1,
             ":max_applies was not honoured — a third proposal was fetched and skipped"
    end
  end
end
