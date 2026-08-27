defmodule Loopctl.Workers.KnowledgeLintWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.HeavyRead.TenantGate
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.Knowledge.DraftConsumer
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

    test "consumes the DRAFT queue and reports the whole reading in the audit event" do
      tenant = fixture(:tenant)
      held = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{id: 0, args: %{"tenant_id" => tenant.id}})

      assert AdminRepo.get!(Loopctl.Knowledge.Article, held.id).status == :published

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["drafts_published"] == 1
      # OFFERED and the bound flag are recorded even on a night that drained everything: a
      # truncated night and a night with nothing to consume must never be the same numbers.
      assert entry.new_state["drafts_offered"] == 1
      assert entry.new_state["drafts_budget_exhausted"] == false
      # Read with `.gate`, never a defaulted Map.get — a crashed step must not record itself
      # as a clean night.
      assert entry.new_state["drafts_gate"] == "open"
      assert entry.new_state["drafts_unassessed"] == 0
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
    # promotion) and BEFORE the audit event. If it could abort the run,
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

    defp contradicts_links(tenant_id, a_id, b_id) do
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :contradicts,
        where:
          (l.source_article_id == ^a_id and l.target_article_id == ^b_id) or
            (l.source_article_id == ^b_id and l.target_article_id == ^a_id)
      )
      |> AdminRepo.all()
    end

    defmodule ContradictingJudge do
      @moduledoc false
      @behaviour Loopctl.Knowledge.ConflictJudge
      @impl true
      def judge(_scope, _left, _right, _opts) do
        {:ok,
         %{
           classification: :contradictory,
           confidence: :high,
           rationale: "A requires the lock, B forbids it"
         }}
      end
    end

    test "the judge decides the classification, and a contradiction adds a contradicts edge" do
      # `find_contradiction_clusters/2` reads `:contradicts` links and, until the semantic
      # judge existed, could only ever return empty: the nightly judge decided on cosine
      # similarity, which cannot tell agreement from disagreement, so `contradicts` sat at 0
      # edges across the whole hosted corpus. This is the producer.
      #
      # The implementation is injected per CALL rather than through `Application.put_env`,
      # which would mutate VM-global state every other test in this async suite can see.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())

      pair = %{source_article_id: a.id, target_article_id: b.id, similarity: 0.96}

      assert {:ok, _} =
               KnowledgeLintWorker.judge_and_record(tenant.id, pair,
                 conflict_judge_impl: ContradictingJudge
               )

      assert [verdict] = resolutions(tenant.id, a.id, b.id)
      assert verdict.classification == :contradictory
      # STILL a dismiss. `supersede`/`merge` defer to the executor and a `:high` supersede
      # authorizes an unattended retirement — deciding which of two contradicting articles is
      # right is not a call this judge is entitled to make.
      assert verdict.disposition == :dismiss
      assert verdict.evidence =~ "A requires the lock, B forbids it"

      assert [edge] = contradicts_links(tenant.id, a.id, b.id)
      assert edge.metadata["judged_by"] == "worker:knowledge_lint"
    end

    test "a redundant verdict writes NO contradicts edge" do
      # The edge is the part a human reads as a real disagreement, so it must appear only on
      # the classification that means one. Swap the judge above for the default and it goes.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())

      pair = %{source_article_id: a.id, target_article_id: b.id, similarity: 0.96}

      assert {:ok, _} = KnowledgeLintWorker.judge_and_record(tenant.id, pair)

      assert [%{classification: :redundant}] = resolutions(tenant.id, a.id, b.id)
      assert contradicts_links(tenant.id, a.id, b.id) == []
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

    # #730 review: the queue settles a flag only with a verdict that POSTDATES it, but this
    # worker's own `judged_pair_subquery/0` is a SECOND copy of that question and had no
    # such predicate. So a pair judged once and later RE-flagged read as unjudged on the
    # queue and as judged by the drain — and the drain's answer is the one that strands it,
    # since nothing else drains the queue.
    test "a RE-flagged pair is judged again, not skipped forever on an older verdict" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      relates_link(tenant.id, a.id, b.id, 0.94)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
      assert [first] = resolutions(tenant.id, a.id, b.id)

      # Retract the flag and raise a NEW one — a fresh link, created after that verdict.
      # (An operator deleting a mistaken flag, or a re-promotion after a corpus edit.)
      assert [flag] = conflict_links(tenant.id, a.id, b.id)
      AdminRepo.delete!(flag)
      # The relates_to edge survives, so the promoter raises a fresh flag on the next run.

      # Backdate the verdict a day. `article_links.inserted_at` is SECOND precision while
      # `conflict_resolutions.annotated_at` is microsecond, so a verdict and a flag created
      # in the same second compare as verdict-after-flag whichever order they really
      # happened in. Re-flagging is a different-night event in the real flow, so the day
      # gap is the realistic case — shrinking it would be testing the timestamp precision,
      # not the predicate.
      AdminRepo.update_all(
        from(r in Loopctl.Knowledge.ConflictResolution, where: r.id == ^first.id),
        set: [annotated_at: DateTime.add(first.annotated_at, -1, :day)]
      )

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      # The observable is the DRAIN'S OWN COUNTER, not the verdict row: `record_verdict/4`
      # inserts `on_conflict: :nothing`, so a re-judged pair keeps its existing row and
      # nothing about that row moves. What the fix changes is whether the pair is SELECTED
      # as unjudged at all — the sibling idempotency test above asserts this counter is 0
      # when a pair genuinely has not been re-flagged, so the two pin both directions.
      assert [_first_run, second_run] = lint_audit_entries(tenant.id)

      assert second_run.new_state["conflicts_judged_redundant"] == 1,
             "the drain skipped a flag raised AFTER the verdict it was matched against"
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

  describe "the generic_title retitle step" do
    test "the nightly run applies it and records BOTH what it did and what it was offered" do
      # The class was report-only and therefore leaked — re-derived every night with nothing
      # on the other end. This is the consumer, in the nightly pass, end to end.
      tenant = fixture(:tenant)

      article =
        published_no_embedding(tenant.id, %{title: "Untitled", body: "A body about Ecto."})

      # Last night's report; `perform/1` writes tonight's, so the agreement gate is
      # tonight-against-last-night exactly as it is for the duplicate drain.
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))

      Mox.expect(Loopctl.MockContentExtractor, :extract_from_content, fn _scope,
                                                                         _content,
                                                                         _opts ->
        {:ok,
         [
           %{
             title: "Ecto changesets validate before they cast",
             body: "Ignored.",
             category: :pattern,
             tags: [],
             metadata: %{}
           }
         ]}
      end)

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{id: 0, args: %{"tenant_id" => tenant.id}})

      assert AdminRepo.get!(Loopctl.Knowledge.Article, article.id).title ==
               "Ecto changesets validate before they cast"

      assert [entry] = lint_audit_entries(tenant.id)
      state = entry.new_state["consolidation"]

      assert state["generic_titles_retitled"] == 1
      # OFFERED and the bound flag are recorded even on a night that drained everything: a
      # truncated night and a night with nothing to do must never be the same numbers.
      assert state["generic_titles_offered"] == 1
      assert state["generic_title_budget_exhausted"] == false
      assert state["generic_title_apply_gate"] == "open"
    end

    test "records the gate on a night the step could not run at all" do
      # A fresh tenant has one report, so nothing has been confirmed twice. `retitled: 0`
      # alone is what a clean corpus reports too — the gate is the key that separates them,
      # and an absent key on exactly the nights nothing happened is the one answer it must
      # not give.
      tenant = fixture(:tenant)
      _article = published_no_embedding(tenant.id, %{title: "Untitled", body: "A body."})

      assert :ok =
               KnowledgeLintWorker.perform(%Oban.Job{id: 0, args: %{"tenant_id" => tenant.id}})

      assert [entry] = lint_audit_entries(tenant.id)
      state = entry.new_state["consolidation"]

      assert state["generic_titles_retitled"] == 0
      assert state["generic_titles_offered"] == 0
      assert state["generic_title_apply_gate"] == "insufficient_history"
    end

    test "its budget is CARVED OUT of the job timeout, never added beside it" do
      # The second step whose per-item cost is an outbound provider call, so it gets #761's
      # lesson applied up front: the clock it spends comes out of the same reserve, the
      # judge's ceiling falls by exactly that much, and `timeout/1` does not move.
      rescue_after =
        Enum.find_value(Loopctl.ObanConfig.plugins(), fn
          {Oban.Plugins.Lifeline, opts} -> Keyword.fetch!(opts, :rescue_after)
          _other -> nil
        end)

      timeout = KnowledgeLintWorker.timeout(%Oban.Job{args: %{}})

      assert timeout < rescue_after,
             "paying for a new step by raising the job timeout is exactly what #761 forbids"

      # The assertion that actually catches a budget added BESIDE the reserve rather than
      # inside it: all three claims on the job's clock must fit in the job. Every weaker
      # reading of these numbers — the timeout, the reserve, what this step is handed at
      # t=0 — stays true when the retitle budget is paid for out of thin air, which is
      # precisely how #761 shipped.
      assert KnowledgeLintWorker.judge_budget_ms() + KnowledgeLintWorker.retitle_budget_ms() +
               KnowledgeLintWorker.draft_budget_ms() + KnowledgeLintWorker.prelude_reserve_ms() <=
               timeout,
             "every claim on the job's clock must fit inside the job"

      # And the context's own fallback — used when the step is called directly rather than
      # from here — can never exceed the reserve carved out for it. Nothing but this
      # assertion can notice those two drifting apart.
      assert KnowledgeLintWorker.retitle_budget_ms() >=
               Consolidation.default_retitle_budget_ms()
    end

    test "the draft consumer's clock comes out of the SAME reserve, and its fallback fits it" do
      # The THIRD step whose per-item cost is an outbound provider call. Added to the reserve
      # rather than taken out of the judge's budget at the call site, so the ONE clamp keeps
      # doing the arithmetic: the judge's ceiling falls by exactly this much and `timeout/1`
      # does not move. Raising `timeout/1` to pay for a new step is what #761 makes fatal.
      assert KnowledgeLintWorker.draft_budget_ms() >= DraftConsumer.default_budget_ms(),
             "the context's direct-call fallback must never exceed the reserve carved out for it"

      # The assertion that catches THIS step's budget being added beside the reserve rather
      # than inside it. Every weaker reading — the timeout, what this step is handed at t=0 —
      # stays true when it is paid for out of thin air, which is exactly how #761 shipped.
      assert KnowledgeLintWorker.judge_budget_ms() + KnowledgeLintWorker.retitle_budget_ms() +
               KnowledgeLintWorker.draft_budget_ms() + KnowledgeLintWorker.prelude_reserve_ms() <=
               KnowledgeLintWorker.timeout(%Oban.Job{args: %{}}),
             "the draft reserve must come OUT of the job's clock, never be added beside it"

      now = System.monotonic_time(:millisecond)
      full = KnowledgeLintWorker.draft_budget_ms()

      assert KnowledgeLintWorker.draft_budget_remaining(now) == full,
             "a night whose prelude cost nothing gets the whole budget, never more"

      spent = now - (KnowledgeLintWorker.timeout(%Oban.Job{args: %{}}) - :timer.minutes(1))

      assert KnowledgeLintWorker.draft_budget_remaining(spent) < full,
             "a prelude that overran must shrink this step, not start a fresh one"

      assert KnowledgeLintWorker.draft_budget_remaining(now - :timer.hours(1)) == 0
    end

    test "the step is handed the time the job has LEFT, never a fresh budget" do
      now = System.monotonic_time(:millisecond)
      full = KnowledgeLintWorker.retitle_budget_ms()

      assert KnowledgeLintWorker.retitle_budget_remaining(now) == full,
             "a night whose prelude cost nothing gets the whole budget, never more"

      spent = now - (KnowledgeLintWorker.timeout(%Oban.Job{args: %{}}) - :timer.minutes(1))

      assert KnowledgeLintWorker.retitle_budget_remaining(spent) < full,
             "a prelude that overran must shrink this step, not start a fresh one"

      assert KnowledgeLintWorker.retitle_budget_remaining(now - :timer.hours(1)) == 0
    end

    test "the overshoot allowance TRACKS the provider knobs it is sized for" do
      # `extraction_receive_timeout_ms` and `extraction_max_retries` are live-tunable
      # SystemConfig rows with no upper clamp, so a HARDCODED allowance stops covering the
      # in-flight call it was sized for the moment an operator raises either one — silently,
      # and what it lets through is an `Oban.TimeoutError` retry that re-runs
      # `apply_consolidation/2` and re-spends the nightly caps (#761's shape). Read through
      # the pure arity-2 form so nothing VM-global is mutated in this async suite.
      assert KnowledgeLintWorker.judge_overshoot_ms(25_000, 1) == :timer.seconds(60),
             "the seeded defaults sit under the floor, which is what keeps them at 60 s"

      assert KnowledgeLintWorker.judge_overshoot_ms(45_000, 1) == :timer.seconds(91),
             "a raised receive timeout raises the allowance with it"

      assert KnowledgeLintWorker.judge_overshoot_ms(25_000, 3) == :timer.seconds(101),
             "and so does a raised retry count"

      assert KnowledgeLintWorker.judge_overshoot_ms() >= :timer.seconds(60)
    end
  end

  describe "conflict judging is bounded by a wall clock, not only by a count (#761)" do
    defp flagged_pair(tenant_id, src_id, tgt_id, score) do
      %ArticleLink{tenant_id: tenant_id}
      |> ArticleLink.changeset(%{
        source_article_id: src_id,
        target_article_id: tgt_id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => score}
      })
      |> AdminRepo.insert!()
    end

    test "the job timeout is DERIVED from the judge budget, never picked beside it" do
      # This is the whole of #761 as one assertion. A flat `:timer.minutes(10)` stood next to
      # a judging step allowed 2000 outbound calls at ~0.85 s each — a ~28-minute ceiling
      # inside a 10-minute job. Nothing was wrong with either number on its own, which is why
      # it survived review and then killed every attempt on six consecutive nights once the
      # nightly inflow outgrew the promoter's 500/night cap.
      timeout = KnowledgeLintWorker.timeout(%Oban.Job{args: %{}})

      assert timeout > KnowledgeLintWorker.judge_budget_ms(),
             "the job must outlast the budget of the one step inside it that spends a clock"

      # And by enough to pay for the rest of the night: `execute_conflict_resolutions/2`
      # alone carries a ~2-minute internal budget, so a reserve smaller than that hands the
      # timeout back to the same race.
      assert timeout - KnowledgeLintWorker.judge_budget_ms() >= :timer.minutes(2)
    end

    test "the job timeout stays UNDER Oban's Lifeline rescue window" do
      # Lifeline does not check whether a job is alive: past `rescue_after` it moves anything
      # still `executing` back to `available`. A timeout above that window buys a SECOND
      # concurrent nightly pass on the same tenant — the same pairs billed twice and two
      # `apply_consolidation/2` runs against one report. Read from the real plugin list, so
      # lowering `rescue_after` fails here instead of in production.
      rescue_after =
        Enum.find_value(Loopctl.ObanConfig.plugins(), fn
          {Oban.Plugins.Lifeline, opts} -> Keyword.fetch!(opts, :rescue_after)
          _other -> nil
        end)

      assert is_integer(rescue_after)

      assert KnowledgeLintWorker.timeout(%Oban.Job{args: %{}}) < rescue_after,
             "a job allowed to outlast the rescue window runs concurrently with itself"

      # And at a budget that WOULD breach it: the default sits under the window with or
      # without the clamp, so asserting only on the default cannot tell whether the clamp is
      # there. The configured value is passed as an argument rather than through
      # `Application.put_env`, which every other test in this async suite would see.
      assert KnowledgeLintWorker.job_timeout_ms(:timer.minutes(40)) < rescue_after,
             "raising the configured budget past the ceiling must raise nothing"

      # The clamp holds the derivation's other half too — the reserve stays whole.
      assert KnowledgeLintWorker.job_timeout_ms(:timer.minutes(40)) -
               KnowledgeLintWorker.judge_budget_ms(:timer.minutes(40)) >= :timer.minutes(2)
    end

    test "the judge is handed the time the job has LEFT, never a fresh budget" do
      # `@job_reserve_ms` is a measured constant and nothing makes the steps before the judge
      # respect it, so a night whose prelude overran would otherwise start a full-length
      # judging step inside a job that can no longer contain it and die with
      # `Oban.TimeoutError` — #761 again, with tonight's unpublishes already committed.
      now = System.monotonic_time(:millisecond)
      full = KnowledgeLintWorker.judge_budget_ms()

      assert KnowledgeLintWorker.judge_budget_remaining(now) == full,
             "a night whose prelude cost nothing gets the whole budget, never more"

      spent = now - (KnowledgeLintWorker.timeout(%Oban.Job{args: %{}}) - :timer.minutes(1))

      assert KnowledgeLintWorker.judge_budget_remaining(spent) < full,
             "a prelude that overran must shrink the judging step, not start a fresh one"

      # Floors at 0: a negative budget is a deadline already in the past, which the reduce
      # reads as "halt after the first result" rather than as "no budget".
      assert KnowledgeLintWorker.judge_budget_remaining(now - :timer.hours(1)) == 0
    end

    defmodule ExitingJudge do
      @moduledoc false
      @behaviour Loopctl.Knowledge.ConflictJudge
      @impl true
      def judge(_scope, _left, _right, _opts), do: exit(:pool_checkout_timeout)
    end

    test "a pair that EXITS is contained inside its task, not taken out of the night" do
      # `Task.async_stream/3` LINKS its tasks, so an exit inside one — an AdminRepo checkout
      # timeout on the 3-connection pool is the production shape — arrives here as a SIGNAL
      # that no rescue around the stream can intercept. Uncontained it kills the whole job:
      # the night's audit event is lost and Oban retries a job whose unpublishes already
      # committed, spending `:knowledge_consolidation_max_unpublishes` again. `ConflictJudge`
      # rescues a RAISE for us; an exit is the half that has to be caught in the task.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      flagged_pair(tenant.id, a.id, b.id, 0.97)

      log =
        capture_log(fn ->
          result =
            KnowledgeLintWorker.judge_redundant_conflicts(tenant.id,
              conflict_judge_impl: ExitingJudge
            )

          assert result.candidates == 1
          assert result.judged == 0, "a pair that never returned a verdict was not judged"
          refute result.budget_exhausted, "the clock was not what stopped it"
        end)

      assert log =~ "pool_checkout_timeout"
    end

    test "an exhausted budget stops the stream, is reported, and is LOGGED" do
      # Budget injected per call rather than through `Application.put_env`, which would
      # mutate VM-global state every other test in this async suite can see.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      c = published_article_with_embedding(tenant.id, similar_embedding())
      d = published_article_with_embedding(tenant.id, near_similar_embedding())
      flagged_pair(tenant.id, a.id, b.id, 0.97)
      flagged_pair(tenant.id, c.id, d.id, 0.96)

      log =
        capture_log(fn ->
          result = KnowledgeLintWorker.judge_redundant_conflicts(tenant.id, budget_ms: 0)

          # The deadline is checked at the HEAD of each task, so a spent budget buys no
          # judgement at all — not the rounded-up one a post-result check was committed to.
          assert result.judged == 0
          assert result.candidates == 2
          assert result.budget_exhausted
        end)

      # NEVER silent. `judged: 0` alone reads identically to "there were no pairs", which is
      # the reading that hid six dead nights.
      assert log =~ "conflict judging hit its"
      assert log =~ "0 of 2 candidates"
    end

    test "an EXHAUSTED clock buys zero provider calls, not a rounded-up one" do
      # `async_stream` starts `judge_concurrency()` tasks before the reducer sees anything,
      # so a check that ran after each RESULT was committed to that many outbound calls and
      # their writes — and a `:dismiss` is terminal on record. The judge here EXITS on any
      # call, so its tag in the log is the proof a call was made; a spent clock must produce
      # none. The drained-night half of this pair is the untruncated test below.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      flagged_pair(tenant.id, a.id, b.id, 0.97)

      log =
        capture_log(fn ->
          result =
            KnowledgeLintWorker.judge_redundant_conflicts(tenant.id,
              budget_ms: 0,
              conflict_judge_impl: ExitingJudge
            )

          assert result.judged == 0
          assert result.candidates == 1
          assert result.budget_exhausted, "one candidate was left unjudged"
        end)

      refute log =~ "pool_checkout_timeout", "a spent clock reached the provider anyway"
    end

    test "the COUNT cap truncates visibly too, not only the clock" do
      # The count cap is the older bound and truncates while the clock never fires: with
      # `candidates` capped by the same limit, a night bigger than the cap reads exactly like
      # a night that had that many and drained them. That silence is the whole reason this
      # flag exists. It is NOT what happened during #761 — those runs were killed by the
      # 10-minute job timeout and wrote no audit event at all, so there was nothing to
      # misread; this guards the failure mode that would have replaced it.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      c = published_article_with_embedding(tenant.id, similar_embedding())
      d = published_article_with_embedding(tenant.id, near_similar_embedding())
      flagged_pair(tenant.id, a.id, b.id, 0.97)
      flagged_pair(tenant.id, c.id, d.id, 0.96)

      capped = KnowledgeLintWorker.judge_redundant_conflicts(tenant.id, cap: 1)

      assert capped.candidates == 1
      assert capped.judged == 1
      assert capped.count_capped, "a pair was left unoffered and nothing says so"
    end

    test "the untruncated run judges everything and says the budget was NOT the reason" do
      # The negative half of the pair above: without it, a bound that fires unconditionally
      # would pass every assertion in the truncation test.
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      c = published_article_with_embedding(tenant.id, similar_embedding())
      d = published_article_with_embedding(tenant.id, near_similar_embedding())
      flagged_pair(tenant.id, a.id, b.id, 0.97)
      flagged_pair(tenant.id, c.id, d.id, 0.96)

      result = KnowledgeLintWorker.judge_redundant_conflicts(tenant.id)

      assert result.judged == 2
      assert result.candidates == 2
      refute result.budget_exhausted
      refute result.count_capped
    end

    test "the audit event separates a truncated night from a night with nothing to judge" do
      tenant = fixture(:tenant)
      a = published_article_with_embedding(tenant.id, similar_embedding())
      b = published_article_with_embedding(tenant.id, near_similar_embedding())
      relates_link(tenant.id, a.id, b.id, 0.96)

      assert :ok = KnowledgeLintWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})

      assert [entry] = lint_audit_entries(tenant.id)
      assert entry.new_state["conflicts_judged_redundant"] == 1
      # The two keys that make `conflicts_judged_redundant` readable at all: how many were
      # OFFERED, and whether the clock cut the run short. A quiet night and a truncated one
      # are the same judged count without them.
      assert entry.new_state["conflicts_judge_candidates"] == 1
      assert entry.new_state["conflicts_judge_budget_exhausted"] == false
      assert entry.new_state["conflicts_judge_count_capped"] == false
    end
  end
end
