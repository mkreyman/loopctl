defmodule Loopctl.Knowledge.ConsolidationTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ConflictResolution
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.Knowledge.ConsolidationProposal
  alias Loopctl.Knowledge.ConsolidationReport

  # Published articles are written as draft-then-update via AdminRepo so the inline
  # Oban embedding -> linking cascade `fixture(:article, status: :published)` triggers
  # never runs: every signal this module detects is lexical, never vector.
  defp published(tenant_id, attrs) do
    attrs =
      Map.merge(
        %{
          body: "Body #{System.unique_integer([:positive])}.",
          category: :pattern,
          tags: []
        },
        attrs
      )

    fixture(:article, Map.put(attrs, :tenant_id, tenant_id))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  # A SYSTEM-flagged conflict link — the ONLY shape `contradiction_candidate` proposes on,
  # because it is the only shape `Knowledge.annotate_conflict/3` will accept a verdict for.
  defp system_conflict_link(tenant_id, source, target) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: source.id,
      target_article_id: target.id,
      relationship_type: :potential_conflict,
      metadata: %{"auto_generated" => true, "similarity_score" => 0.97}
    })
  end

  defp proposals_of(analysis, class) do
    Enum.filter(analysis.proposals, &(&1.proposal_class == class))
  end

  defp corpus_snapshot(tenant_id) do
    articles =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        order_by: a.id,
        select: {a.id, a.title, a.body, a.status, a.updated_at, a.metadata}
      )
      |> AdminRepo.all()

    links =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        order_by: l.id,
        select: {l.id, l.relationship_type, l.source_article_id, l.target_article_id, l.metadata}
      )
      |> AdminRepo.all()

    resolutions =
      from(r in ConflictResolution,
        where: r.tenant_id == ^tenant_id,
        order_by: r.id,
        select: {r.id, r.disposition, r.executed_at, r.evidence}
      )
      |> AdminRepo.all()

    {articles, links, resolutions}
  end

  describe "analyze/3 — duplicate_capture" do
    test "proposes a group whose titles collide once case and punctuation normalize away" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Retry Policy", body: "Retry with jitter, always."})
      b = published(tenant.id, %{title: "retry-policy!", body: "Retry with jitter, always."})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert [proposal] = proposals_of(analysis, :duplicate_capture)
      assert Enum.sort(proposal.article_ids) == Enum.sort([a.id, b.id])
      assert length(proposal.evidence) == 2

      for entry <- proposal.evidence do
        assert entry["excerpt"] =~ "Retry with jitter"
        assert entry["article_id"] in [a.id, b.id]
      end

      assert proposal.rationale =~ "same capture"
      assert analysis.summary.by_class["duplicate_capture"] == 1
    end

    test "proposes idempotency keys that collide under normalization but differ verbatim" do
      tenant = fixture(:tenant)

      a =
        published(tenant.id, %{
          title: "Harvest A",
          body: "Harvested from the 2026-08-04 session.",
          idempotency_key: "session:2026-08-04:harvest"
        })

      b =
        published(tenant.id, %{
          title: "Harvest B",
          body: "Harvested from the 2026-08-04 session.",
          idempotency_key: "SESSION_2026_08_04_HARVEST"
        })

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert [proposal] = proposals_of(analysis, :duplicate_capture)
      assert Enum.sort(proposal.article_ids) == Enum.sort([a.id, b.id])
      assert Enum.all?(proposal.evidence, &(&1["excerpt"] != ""))
    end

    test "does not propose distinct articles that share neither a title nor a key shape" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Retry Policy", idempotency_key: "a-1"})
      published(tenant.id, %{title: "Backoff Policy", idempotency_key: "b-2"})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert proposals_of(analysis, :duplicate_capture) == []
      assert analysis.summary.by_class["duplicate_capture"] == 0
    end

    # The normalization strips everything outside [a-z0-9], so titles in a non-Latin script
    # or made only of symbols ALL collapse to the empty string and would be emitted as one
    # "same capture under title drift" group. Deterministic false positive in the class #584
    # names as the likely first auto-apply candidate.
    test "does not group titles that share only an EMPTY normalized form" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "日本語ガイド", body: "Japanese guide."})
      published(tenant.id, %{title: "中文指南", body: "Chinese guide."})
      published(tenant.id, %{title: "!!!", body: "Symbols only."})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert proposals_of(analysis, :duplicate_capture) == []
      assert analysis.summary.by_class["duplicate_capture"] == 0
      # Nor does the empty bucket fall through to the placeholder-title class.
      assert proposals_of(analysis, :generic_title) == []
    end

    test "does not group idempotency keys that share only an EMPTY normalized form" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Harvest A", idempotency_key: "***"})
      published(tenant.id, %{title: "Harvest B", idempotency_key: "///"})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert proposals_of(analysis, :duplicate_capture) == []
    end
  end

  describe "analyze/3 — contradiction_candidate" do
    test "proposes a conflict-flagged pair that carries no recorded verdict" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Use Ecto.Multi", body: "Always wrap writes in Multi."})

      b =
        published(tenant.id, %{title: "Avoid Ecto.Multi", body: "Never wrap writes in Multi."})

      system_conflict_link(tenant.id, a, b)

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert [proposal] = proposals_of(analysis, :contradiction_candidate)
      assert Enum.sort(proposal.article_ids) == Enum.sort([a.id, b.id])
      excerpts = Enum.map(proposal.evidence, & &1["excerpt"])
      assert Enum.any?(excerpts, &(&1 =~ "Always wrap writes"))
      assert Enum.any?(excerpts, &(&1 =~ "Never wrap writes"))
      assert proposal.suggested_action =~ "conflict resolution"
    end

    test "does not propose a pair an agent already judged (either link direction)" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Use Ecto.Multi"})
      b = published(tenant.id, %{title: "Avoid Ecto.Multi"})

      system_conflict_link(tenant.id, a, b)

      [source_id, target_id] = Enum.sort([a.id, b.id])

      %ConflictResolution{tenant_id: tenant.id}
      |> ConflictResolution.changeset(%{
        source_article_id: source_id,
        target_article_id: target_id,
        classification: :contradictory,
        disposition: :dismiss,
        confidence: :high,
        evidence: "Judged already.",
        annotated_by: "agent-1",
        annotated_at: DateTime.utc_now()
      })
      |> AdminRepo.insert!()

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert proposals_of(analysis, :contradiction_candidate) == []
    end

    # An agent-created `contradicts` link is NOT a pair the conflict-resolution surface
    # accepts (`validate_potential_conflict_exists/3` 422s it), so a proposal naming it
    # would instruct the reviewer to make a call that always fails — and, since no verdict
    # can ever be recorded, would be re-derived every night forever.
    test "does not propose an agent-creatable contradicts link" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Use Ecto.Multi"})
      b = published(tenant.id, %{title: "Avoid Ecto.Multi"})

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: a.id,
        target_article_id: b.id,
        relationship_type: :contradicts
      })

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert proposals_of(analysis, :contradiction_candidate) == []
      assert analysis.summary.by_class["contradiction_candidate"] == 0
    end

    # Same dead end for a stray / legacy potential_conflict with no system stamp — which is
    # exactly what `Knowledge.list_potential_conflicts/2` refuses to surface (kb-02).
    test "does not propose a potential_conflict link that is not SYSTEM-flagged" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Use Ecto.Multi"})
      b = published(tenant.id, %{title: "Avoid Ecto.Multi"})

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: a.id,
        target_article_id: b.id,
        relationship_type: :potential_conflict,
        metadata: %{}
      })

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert proposals_of(analysis, :contradiction_candidate) == []
    end

    # Archiving retains article_links by design, so without a status join the pass kept
    # proposing over an archived article — and quoting its body — while `corpus_size`
    # excluded it from the denominator the same report states.
    test "does not propose a pair whose endpoint is archived, and never quotes its body" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Use Ecto.Multi", body: "Always wrap writes in Multi."})

      b =
        published(tenant.id, %{title: "Avoid Ecto.Multi", body: "SECRET archived reasoning."})

      system_conflict_link(tenant.id, a, b)

      b |> Ecto.Changeset.change(%{status: :archived}) |> AdminRepo.update!()

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert proposals_of(analysis, :contradiction_candidate) == []

      refute Enum.any?(analysis.proposals, fn p ->
               Enum.any?(p.evidence, &(&1["excerpt"] =~ "SECRET archived"))
             end)
    end
  end

  describe "analyze/3 — generic_title" do
    test "proposes a placeholder title with the article opening as evidence" do
      tenant = fixture(:tenant)

      article =
        published(tenant.id, %{
          title: "Untitled Document",
          body: "The hub that could not be created because the title collided."
        })

      published(tenant.id, %{title: "A Perfectly Good Title", body: "Fine."})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert [proposal] = proposals_of(analysis, :generic_title)
      assert proposal.article_ids == [article.id]
      assert [evidence] = proposal.evidence
      assert evidence["excerpt"] =~ "hub that could not be created"
      assert proposal.rationale =~ "409"
    end
  end

  describe "analyze/3 — stale_entry" do
    test "proposes stale articles from the lint report it is handed" do
      tenant = fixture(:tenant)
      article = published(tenant.id, %{title: "Ancient", body: "Written a long time ago."})

      lint_report = %{
        stale_articles: [
          %{
            article_id: article.id,
            title: article.title,
            days_since_update: 400,
            severity: "warning"
          }
        ],
        summary: %{total_per_category: %{stale_articles: 1}}
      }

      {:ok, analysis} = Consolidation.analyze(tenant.id, lint_report)

      assert [proposal] = proposals_of(analysis, :stale_entry)
      assert proposal.article_ids == [article.id]
      assert proposal.rationale =~ "400 days"
      assert [evidence] = proposal.evidence
      assert evidence["excerpt"] =~ "a long time ago"
    end
  end

  describe "analyze/3 — numbering and bounding" do
    test "numbers proposals contiguously from 1 across classes" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Retry Policy"})
      published(tenant.id, %{title: "retry policy"})
      published(tenant.id, %{title: "Untitled Document"})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      numbers = Enum.map(analysis.proposals, & &1.number)
      assert numbers == Enum.to_list(1..length(analysis.proposals))
      assert analysis.summary.emitted == length(analysis.proposals)
    end

    test "caps the emitted array per class while reporting the TRUE pre-cap total" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document"})
      published(tenant.id, %{title: "untitled document!"})
      published(tenant.id, %{title: "New Article"})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{}, max_per_class: 1)

      generic = proposals_of(analysis, :generic_title)
      assert length(generic) == 1
      assert analysis.summary.by_class["generic_title"] == 3
      assert analysis.summary.truncated["generic_title"] == true
      assert analysis.summary.max_per_class == 1
    end

    test "reports corpus_size as PUBLISHED articles only" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Published One"})
      fixture(:article, %{tenant_id: tenant.id, title: "Still A Draft", category: :pattern})

      {:ok, analysis} = Consolidation.analyze(tenant.id, %{})

      assert analysis.summary.corpus_size == 1
    end
  end

  describe "run/3 — report only" do
    test "writes NOTHING to articles, article_links or conflict_resolutions" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Retry Policy", body: "Retry with jitter."})
      b = published(tenant.id, %{title: "retry-policy", body: "Retry with jitter."})
      published(tenant.id, %{title: "Untitled Document", body: "No title here."})

      system_conflict_link(tenant.id, a, b)

      lint_report = %{
        stale_articles: [
          %{article_id: a.id, title: a.title, days_since_update: 200, severity: "warning"}
        ],
        summary: %{total_per_category: %{stale_articles: 1}}
      }

      before = corpus_snapshot(tenant.id)

      assert {:ok, report} = Consolidation.run(tenant.id, lint_report)

      assert corpus_snapshot(tenant.id) == before
      assert report.persisted_count > 0
    end

    test "persists the report with its numbered, evidence-carrying proposals" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document", body: "Needs a real title."})

      assert {:ok, report} = Consolidation.run(tenant.id, %{})

      assert report.day == Date.utc_today()
      assert report.corpus_size == 1
      assert report.proposal_count == 1
      assert report.persisted_count == 1
      assert report.proposals_by_class["generic_title"] == 1
      assert report.truncated["generic_title"] == false

      assert [proposal] =
               AdminRepo.all(from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id))

      assert proposal.number == 1
      assert proposal.proposal_class == :generic_title
      assert proposal.review_status == :pending
      assert [evidence] = proposal.evidence
      assert evidence["excerpt"] =~ "Needs a real title"
    end

    test "two runs on the same day upsert ONE report row, not two" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document"})

      {:ok, first} = Consolidation.run(tenant.id, %{})
      {:ok, second} = Consolidation.run(tenant.id, %{})

      assert first.id == second.id

      assert AdminRepo.aggregate(
               from(r in ConsolidationReport, where: r.tenant_id == ^tenant.id),
               :count,
               :id
             ) == 1

      assert AdminRepo.aggregate(
               from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id),
               :count,
               :id
             ) == 1
    end

    test "a re-run RESETS human review state — an approval never survives a re-derivation" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document"})

      {:ok, _} = Consolidation.run(tenant.id, %{})

      [proposal] =
        AdminRepo.all(from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id))

      proposal
      |> Ecto.Changeset.change(%{
        review_status: :approved,
        reviewed_by: "mark",
        reviewed_at: DateTime.utc_now()
      })
      |> AdminRepo.update!()

      {:ok, _} = Consolidation.run(tenant.id, %{})

      [refreshed] =
        AdminRepo.all(from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id))

      assert refreshed.id == proposal.id
      assert refreshed.review_status == :pending
      assert refreshed.reviewed_by == nil
      assert refreshed.reviewed_at == nil
    end

    test "withdraws a proposal the pass no longer derives" do
      tenant = fixture(:tenant)
      article = published(tenant.id, %{title: "Untitled Document"})

      {:ok, _} = Consolidation.run(tenant.id, %{})

      assert [_] =
               AdminRepo.all(from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id))

      article |> Ecto.Changeset.change(%{title: "A Real Title Now"}) |> AdminRepo.update!()

      {:ok, report} = Consolidation.run(tenant.id, %{})

      assert report.persisted_count == 0

      assert AdminRepo.all(from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id)) ==
               []
    end
  end

  describe "tenant isolation" do
    test "tenant A's pass never sees or proposes over tenant B's articles" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      published(tenant_a.id, %{title: "Untitled Document", body: "A's placeholder."})
      published(tenant_b.id, %{title: "Untitled Document", body: "B's placeholder."})
      published(tenant_b.id, %{title: "Retry Policy"})
      published(tenant_b.id, %{title: "retry policy"})

      {:ok, analysis} = Consolidation.analyze(tenant_a.id, %{})

      assert analysis.summary.corpus_size == 1
      assert [proposal] = analysis.proposals
      assert proposal.proposal_class == :generic_title
      assert [evidence] = proposal.evidence
      assert evidence["excerpt"] == "A's placeholder."

      {:ok, report_a} = Consolidation.run(tenant_a.id, %{})

      proposals_a =
        AdminRepo.all(from(p in ConsolidationProposal, where: p.report_id == ^report_a.id))

      b_article_ids =
        from(a in Article, where: a.tenant_id == ^tenant_b.id, select: a.id) |> AdminRepo.all()

      assert Enum.all?(proposals_a, fn p ->
               Enum.all?(p.article_ids, &(&1 not in b_article_ids))
             end)
    end
  end

  describe "latest/2" do
    test "returns an empty payload when the tenant has never been consolidated" do
      tenant = fixture(:tenant)

      assert {:ok, %{report: nil, proposals: [], total_count: 0}} =
               Consolidation.latest(tenant.id)
    end

    test "reads back the persisted report, filtered by class" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document"})
      published(tenant.id, %{title: "Retry Policy"})
      published(tenant.id, %{title: "retry policy"})

      {:ok, _} = Consolidation.run(tenant.id, %{})

      {:ok, all} = Consolidation.latest(tenant.id)
      assert all.total_count == 2
      assert Enum.map(all.proposals, & &1.number) == [1, 2]

      {:ok, filtered} = Consolidation.latest(tenant.id, class: :generic_title)
      assert filtered.total_count == 1
      assert [%{proposal_class: :generic_title}] = filtered.proposals
    end

    test "reads a specific day and does not leak another day's proposals" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document"})

      yesterday = Date.add(Date.utc_today(), -1)
      {:ok, _} = Consolidation.run(tenant.id, %{}, day: yesterday)
      {:ok, _} = Consolidation.run(tenant.id, %{})

      {:ok, older} = Consolidation.latest(tenant.id, day: yesterday)
      assert older.report.day == yesterday
      assert older.total_count == 1

      {:ok, newest} = Consolidation.latest(tenant.id)
      assert newest.report.day == Date.utc_today()
    end
  end
end
