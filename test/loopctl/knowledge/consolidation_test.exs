defmodule Loopctl.Knowledge.ConsolidationTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
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

  # Ages an article past any staleness threshold. Written straight through AdminRepo because
  # `updated_at` is what a changeset would refresh.
  defp backdate(article, days: days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(a in Article, where: a.id == ^article.id, update: [set: [updated_at: ^at]])
    |> AdminRepo.update_all([])

    article
  end

  describe "analyze/2 — duplicate_capture" do
    test "proposes a group whose titles collide once case and punctuation normalize away" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Retry Policy", body: "Retry with jitter, always."})
      b = published(tenant.id, %{title: "retry-policy!", body: "Retry with jitter, always."})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

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

      # SEPARATOR drift with case held constant — that is the #583 shape: one writer used
      # colons, another underscores, for the same key.
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
          idempotency_key: "session_2026_08_04_harvest"
        })

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert [proposal] = proposals_of(analysis, :duplicate_capture)
      assert Enum.sort(proposal.article_ids) == Enum.sort([a.id, b.id])
      assert Enum.all?(proposal.evidence, &(&1["excerpt"] != ""))
    end

    test "does NOT group idempotency keys that differ only by CASE" do
      # An `idempotency_key` is an opaque token chosen by the writer, so case can be the only
      # thing distinguishing two of them — unlike a title, which is prose. Folding case here
      # would be a collision rather than a normalization, and this class AUTO-APPLIES: a
      # deterministic false grouping is confirmed by the two-run gate on night two and the
      # loser is unpublished. Titles keep their case folding; keys do not.
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Harvest A", idempotency_key: "session:AB12:harvest"})
      published(tenant.id, %{title: "Harvest B", idempotency_key: "session:ab12:harvest"})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :duplicate_capture) == []
      assert analysis.summary.by_class["duplicate_capture"] == 0
    end

    test "does not propose distinct articles that share neither a title nor a key shape" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Retry Policy", idempotency_key: "a-1"})
      published(tenant.id, %{title: "Backoff Policy", idempotency_key: "b-2"})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :duplicate_capture) == []
      assert analysis.summary.by_class["duplicate_capture"] == 0
    end

    # The normalization strips everything outside [a-z0-9], so titles in a non-Latin script
    # or made only of symbols ALL collapse to the empty string and would be emitted as one
    # "same capture under title drift" group — a deterministic false positive in the one class
    # that applies itself, so the two-run agreement gate would confirm it and unpublish them.
    test "does not group titles that share only an EMPTY normalized form" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "日本語ガイド", body: "Japanese guide."})
      published(tenant.id, %{title: "中文指南", body: "Chinese guide."})
      published(tenant.id, %{title: "!!!", body: "Symbols only."})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :duplicate_capture) == []
      assert analysis.summary.by_class["duplicate_capture"] == 0
      # Nor does the empty bucket fall through to the placeholder-title class.
      assert proposals_of(analysis, :generic_title) == []
    end

    test "does not group idempotency keys that share only an EMPTY normalized form" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Harvest A", idempotency_key: "***"})
      published(tenant.id, %{title: "Harvest B", idempotency_key: "///"})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :duplicate_capture) == []
    end

    # The other half of the same failure: an ASCII-only separator class does not only
    # empty a non-Latin title, it collapses it onto whatever incidental ASCII it carries,
    # so unrelated articles group on a shared version token or a shared Latin word.
    test "does not group non-Latin titles that share only an incidental ASCII token" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "日本語ガイド v2", body: "Japanese guide."})
      published(tenant.id, %{title: "中文指南 v2", body: "Chinese guide."})
      published(tenant.id, %{title: "Паттерн Retry", body: "Retry pattern."})
      published(tenant.id, %{title: "Обзор Retry", body: "Retry overview."})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :duplicate_capture) == []
      assert analysis.summary.by_class["duplicate_capture"] == 0
    end

    test "still groups two non-Latin titles that DO normalize to the same key" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Паттерн Retry", body: "Retry pattern."})
      b = published(tenant.id, %{title: "  паттерн — retry!", body: "Retry pattern again."})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert [proposal] = proposals_of(analysis, :duplicate_capture)
      assert Enum.sort(proposal.article_ids) == Enum.sort([a.id, b.id])
    end

    test "does not group non-Latin idempotency keys sharing only an incidental ASCII token" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Harvest A", idempotency_key: "сессия:harvest"})
      published(tenant.id, %{title: "Harvest B", idempotency_key: "セッション_HARVEST"})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :duplicate_capture) == []
    end

    # "idempotency-tag" sorts before "title", so sorting on the reason string starved the
    # title signal entirely under the cap instead of sharing it between the two signals.
    test "gives BOTH drift signals representation under the per-class cap" do
      tenant = fixture(:tenant)

      for n <- 1..3 do
        published(tenant.id, %{title: "Key Drift #{n} A", idempotency_key: "harvest:#{n}"})
        published(tenant.id, %{title: "Key Drift #{n} B", idempotency_key: "harvest_#{n}"})
      end

      published(tenant.id, %{title: "Retry Policy", body: "Retry with jitter."})
      published(tenant.id, %{title: "retry-policy!", body: "Retry with jitter."})

      {:ok, analysis} = Consolidation.analyze(tenant.id, max_per_class: 2)

      assert analysis.summary.by_class["duplicate_capture"] == 4
      assert analysis.summary.truncated["duplicate_capture"] == true

      reasons =
        analysis
        |> proposals_of(:duplicate_capture)
        |> Enum.map(fn p -> if p.rationale =~ "title drift", do: :title, else: :idempotency end)

      assert length(reasons) == 2
      assert :title in reasons
      assert :idempotency in reasons
    end
  end

  describe "analyze/2 — contradiction_candidate is RETIRED (#605)" do
    test "a conflict-flagged pair with no verdict is NOT proposed — the lint judge owns it" do
      # This class used to be produced here. It is not any more: the nightly lint now
      # resolves these pairs automatically (`judge_redundant_conflicts/1`, capped above the
      # promotion rate so the queue converges), and proposing them here as well put two
      # subsystems on one pile — one resolving it, the other re-reporting it nightly.
      #
      # Measured on the hosted corpus in the run that settled it: 15,588 of 16,340 proposals
      # were this class, crowding the report's other 752 out of the per-class caps.
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Use Ecto.Multi", body: "Always wrap writes in Multi."})
      b = published(tenant.id, %{title: "Avoid Ecto.Multi", body: "Multi is usually overkill."})
      system_conflict_link(tenant.id, a, b)

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :contradiction_candidate) == [],
             "the lint judge owns this pile; a second proposer re-reports what it resolves"

      refute Map.has_key?(analysis.summary.by_class, "contradiction_candidate"),
             "a retired class must not keep occupying a slot in by_class"
    end

    test "the class VALUE survives in the schema enum, so historical rows still load" do
      # Retiring a class and deleting it are different things. Reports persisted before #605
      # carry proposals with this class, and dropping the value from the Ecto.Enum would make
      # those rows fail to LOAD — turning a docs change into a read outage on history.
      assert :contradiction_candidate in ConsolidationProposal.classes()
    end
  end

  describe "analyze/2 — generic_title" do
    test "proposes a placeholder title with the article opening as evidence" do
      tenant = fixture(:tenant)

      article =
        published(tenant.id, %{
          title: "Untitled Document",
          body: "The hub that could not be created because the title collided."
        })

      published(tenant.id, %{title: "A Perfectly Good Title", body: "Fine."})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert [proposal] = proposals_of(analysis, :generic_title)
      assert proposal.article_ids == [article.id]
      assert [evidence] = proposal.evidence
      assert evidence["excerpt"] =~ "hub that could not be created"
      assert proposal.rationale =~ "409"
    end

    # Under an ASCII-only separator class these normalized to "draft" / "document 2" and
    # were flagged as placeholders, telling the reviewer a perfectly specific title is one.
    test "does not flag a specific non-Latin title whose ASCII residue is a placeholder word" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "設計ドキュメント Draft", body: "Design doc."})
      published(tenant.id, %{title: "Черновик Document 2", body: "Draft doc."})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :generic_title) == []
      assert analysis.summary.by_class["generic_title"] == 0
    end
  end

  describe "analyze/2 — stale_entry is RETIRED (#605)" do
    test "an article far past any staleness threshold is NOT proposed" do
      # Age is not a correctness signal: "nobody edited this in N days" says nothing about
      # whether the article is wrong, so the class could never earn an apply path — and
      # auto-archiving on age would silently delete the corpus, irreversibly. It was a queue
      # whose only consumer was a human nobody staffs.
      #
      # Removing it also cost nothing: `Knowledge.lint/2` computes stale articles itself and
      # publishes them on its own endpoint with a caller-chosen `stale_days`, so this class
      # was a second rendering of one signal occupying a per-class cap slot.
      tenant = fixture(:tenant)
      ancient = published(tenant.id, %{title: "Ancient", body: "Written a long time ago."})
      backdate(ancient, days: 400)

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert proposals_of(analysis, :stale_entry) == [],
             "age is not a defect signal; GET /knowledge/lint owns staleness"

      refute Map.has_key?(analysis.summary.by_class, "stale_entry"),
             "a retired class must not keep occupying a slot in by_class"

      refute Map.has_key?(analysis.summary.truncated, "stale_entry")
    end

    test "the class VALUE survives in the schema enum, so historical rows still load" do
      assert :stale_entry in ConsolidationProposal.classes()
    end

    test "the pass takes no lint report, so staleness cannot leak back in through one" do
      # `analyze/2` used to accept the nightly lint report purely to source this class.
      # Dropping the parameter is what makes the retirement structural rather than a
      # promise: there is no longer an input that could carry stale articles in.
      assert function_exported?(Consolidation, :analyze, 1)
      assert function_exported?(Consolidation, :analyze, 2)
      refute function_exported?(Consolidation, :analyze, 3)
    end
  end

  describe "analyze/2 — the live class set" do
    test "produces ONLY the two live classes, with both retired signals present" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Retry Policy", body: "Retry with jitter."})
      b = published(tenant.id, %{title: "retry-policy", body: "Retry with jitter."})
      published(tenant.id, %{title: "Untitled Document", body: "No title here."})
      # Both retired classes have a live SIGNAL in this corpus — a system-flagged conflict
      # pair and an ancient article — so a re-added producer would have something to emit
      # and this assertion would fail rather than pass vacuously.
      system_conflict_link(tenant.id, a, b)
      backdate(a, days: 400)

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert Enum.sort(Map.keys(analysis.summary.by_class)) ==
               ["duplicate_capture", "generic_title"]

      # The live classes still fired, so the assertion above is not passing because the pass
      # returned nothing at all.
      assert length(proposals_of(analysis, :duplicate_capture)) == 1
      assert length(proposals_of(analysis, :generic_title)) == 1
    end
  end

  describe "analyze/2 — numbering and bounding" do
    test "numbers proposals contiguously from 1 across classes" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Retry Policy"})
      published(tenant.id, %{title: "retry policy"})
      published(tenant.id, %{title: "Untitled Document"})

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      numbers = Enum.map(analysis.proposals, & &1.number)
      assert numbers == Enum.to_list(1..length(analysis.proposals))
      assert analysis.summary.emitted == length(analysis.proposals)
    end

    test "caps the emitted array per class while reporting the TRUE pre-cap total" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document"})
      published(tenant.id, %{title: "untitled document!"})
      published(tenant.id, %{title: "New Article"})

      {:ok, analysis} = Consolidation.analyze(tenant.id, max_per_class: 1)

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

      {:ok, analysis} = Consolidation.analyze(tenant.id)

      assert analysis.summary.corpus_size == 1
    end
  end

  describe "run/2 — report only" do
    test "writes NOTHING to articles, article_links or conflict_resolutions" do
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Retry Policy", body: "Retry with jitter."})
      b = published(tenant.id, %{title: "retry-policy", body: "Retry with jitter."})
      published(tenant.id, %{title: "Untitled Document", body: "No title here."})

      system_conflict_link(tenant.id, a, b)

      before = corpus_snapshot(tenant.id)

      assert {:ok, report} = Consolidation.run(tenant.id)

      assert corpus_snapshot(tenant.id) == before
      assert report.persisted_count > 0
    end

    test "persists the report with its numbered, evidence-carrying proposals" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document", body: "Needs a real title."})

      assert {:ok, report} = Consolidation.run(tenant.id)

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

      {:ok, first} = Consolidation.run(tenant.id)
      {:ok, second} = Consolidation.run(tenant.id)

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

      {:ok, _} = Consolidation.run(tenant.id)

      [proposal] =
        AdminRepo.all(from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id))

      proposal
      |> Ecto.Changeset.change(%{
        review_status: :approved,
        reviewed_by: "mark",
        reviewed_at: DateTime.utc_now()
      })
      |> AdminRepo.update!()

      {:ok, _} = Consolidation.run(tenant.id)

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

      {:ok, _} = Consolidation.run(tenant.id)

      assert [_] =
               AdminRepo.all(from(p in ConsolidationProposal, where: p.tenant_id == ^tenant.id))

      article |> Ecto.Changeset.change(%{title: "A Real Title Now"}) |> AdminRepo.update!()

      {:ok, report} = Consolidation.run(tenant.id)

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

      {:ok, analysis} = Consolidation.analyze(tenant_a.id)

      assert analysis.summary.corpus_size == 1
      assert [proposal] = analysis.proposals
      assert proposal.proposal_class == :generic_title
      assert [evidence] = proposal.evidence
      assert evidence["excerpt"] == "A's placeholder."

      {:ok, report_a} = Consolidation.run(tenant_a.id)

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

      {:ok, _} = Consolidation.run(tenant.id)

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
      {:ok, _} = Consolidation.run(tenant.id, day: yesterday)
      {:ok, _} = Consolidation.run(tenant.id)

      {:ok, older} = Consolidation.latest(tenant.id, day: yesterday)
      assert older.report.day == yesterday
      assert older.total_count == 1

      {:ok, newest} = Consolidation.latest(tenant.id)
      assert newest.report.day == Date.utc_today()
    end

    # An unclamped offset reaches Postgrex as an arbitrary-precision integer and raises
    # DBConnection.EncodeError — a 500 on a parameter the endpoint documents as clamped.
    test "clamps an out-of-bigint-range offset instead of raising" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document"})

      {:ok, _} = Consolidation.run(tenant.id)

      assert {:ok, result} = Consolidation.latest(tenant.id, offset: 99_999_999_999_999_999_999)
      assert result.proposals == []
      assert result.total_count == 1
    end
  end

  describe "latest/2 — evidence never outlives the article it quotes" do
    test "redacts the excerpt of an article that was HARD-deleted after the pass ran" do
      tenant = fixture(:tenant)

      article =
        published(tenant.id, %{title: "Untitled Document", body: "SECRET harvested material."})

      {:ok, _} = Consolidation.run(tenant.id)

      {:ok, before} = Consolidation.latest(tenant.id)
      assert [%{evidence: [entry]}] = before.proposals
      assert entry["excerpt"] =~ "SECRET harvested"

      AdminRepo.delete!(article)

      {:ok, after_delete} = Consolidation.latest(tenant.id)
      assert [%{evidence: [redacted]}] = after_delete.proposals
      assert redacted["article_id"] == article.id
      assert redacted["excerpt"] == ""
      assert redacted["title"] == nil
      assert redacted["redacted"] == true
      # Uniform key set across every evidence branch — a redacted entry carries the key with
      # a nil value rather than omitting it, so a caller never has to ask which branch it got.
      assert Map.has_key?(redacted, "idempotency_key")
      assert redacted["idempotency_key"] == nil
    end

    test "redacts the excerpt of an article archived after the pass ran" do
      tenant = fixture(:tenant)

      article =
        published(tenant.id, %{title: "Untitled Document", body: "SECRET harvested material."})

      {:ok, _} = Consolidation.run(tenant.id)

      article |> Ecto.Changeset.change(%{status: :archived}) |> AdminRepo.update!()

      {:ok, result} = Consolidation.latest(tenant.id)
      assert [%{evidence: [redacted]}] = result.proposals
      assert redacted["redacted"] == true
      assert redacted["excerpt"] == ""
    end

    # Prior-day reports are addressable forever via `day`, which is exactly where the
    # stale copy used to survive: nothing prunes them and the pass never revisits them.
    test "redacts in a PRIOR-DAY report read back by day" do
      tenant = fixture(:tenant)

      article =
        published(tenant.id, %{title: "Untitled Document", body: "SECRET harvested material."})

      yesterday = Date.add(Date.utc_today(), -1)
      {:ok, _} = Consolidation.run(tenant.id, day: yesterday)

      AdminRepo.delete!(article)

      {:ok, older} = Consolidation.latest(tenant.id, day: yesterday)
      assert [%{evidence: [redacted]}] = older.proposals
      assert redacted["redacted"] == true
      assert redacted["excerpt"] == ""
    end

    test "leaves the evidence of a still-published article untouched" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document", body: "Still published."})

      {:ok, _} = Consolidation.run(tenant.id)

      {:ok, result} = Consolidation.latest(tenant.id)
      assert [%{evidence: [entry]}] = result.proposals
      assert entry["excerpt"] =~ "Still published"
      refute Map.has_key?(entry, "redacted")
    end

    # The pass's own unpublish must not blank the evidence for the action it just took:
    # the excerpt is the only surface carrying WHY the loser was retracted, and a draft is
    # fully recoverable. Redaction is for the one-way doors (hard delete, archive).
    test "keeps the evidence of an article this pass UNPUBLISHED" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Untitled Document", body: "Unpublished, not archived."})
      {:ok, _} = Consolidation.run(tenant.id)

      {:ok, result} = Consolidation.latest(tenant.id)
      assert [%{evidence: [entry]}] = result.proposals
      {:ok, _} = Knowledge.unpublish_article(tenant.id, entry["article_id"])

      {:ok, after_unpublish} = Consolidation.latest(tenant.id)
      assert [%{evidence: [kept]}] = after_unpublish.proposals
      assert kept["excerpt"] =~ "Unpublished, not archived"
      refute Map.has_key?(kept, "redacted")
    end
  end

  describe "apply_confirmed_duplicates/2 (#605 — the one class that applies itself)" do
    # Two published articles whose titles collide once punctuation/case are normalized away.
    defp duplicate_pair(tenant_id) do
      a =
        published(tenant_id, %{
          title: "AWS CodeDeploy: Traffic Control",
          body: String.duplicate("long winner body ", 20)
        })

      b = published(tenant_id, %{title: "AWS CodeDeploy Traffic Control", body: "short"})
      {a, b}
    end

    defp status(id), do: AdminRepo.get!(Article, id).status

    # Runs the pass on two adjacent days so the agreement gate is satisfied.
    defp confirm_over_two_nights(tenant_id) do
      {:ok, _} = Consolidation.run(tenant_id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant_id)
    end

    test "bounds LOSER ARTICLES per run, not just duplicate groups" do
      # A group cap is not an article cap: one group can carry many members, so 25 groups is
      # an unbounded number of unpublishes. A group that would cross the article budget is
      # skipped WHOLE — a half-applied group has no winner, which is the one state neither
      # the next run nor a reader can interpret.
      tenant = fixture(:tenant)

      for n <- 1..4 do
        published(tenant.id, %{title: "Group #{n} Doc", body: String.duplicate("long ", 30)})
        published(tenant.id, %{title: "group-#{n}-doc!", body: "short"})
      end

      confirm_over_two_nights(tenant.id)

      # Budget of 3 loser articles against 4 groups of 1 loser each: three groups apply,
      # the fourth is skipped rather than partially applied.
      assert %{applied: 3, skipped: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id, max_unpublishes: 3)
    end

    test "reports WHY nothing applied — a closed gate is not a quiet night" do
      # `applied: 0, skipped: 0` used to be byte-identical for a fresh install, a tenant
      # mid-outage, and a genuinely clean corpus. The audit event is the surface an auditor
      # reads; without a reason it cannot tell a blocked pass from a healthy one.
      tenant = fixture(:tenant)
      {_a, _b} = duplicate_pair(tenant.id)

      # One report only.
      {:ok, _} = Consolidation.run(tenant.id)
      assert %{gate: :insufficient_history} = Consolidation.apply_confirmed_duplicates(tenant.id)

      # Two reports, but further apart than the confirmation window allows.
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -30))
      assert %{gate: :report_gap} = Consolidation.apply_confirmed_duplicates(tenant.id)

      # Adjacent reports: the gate is open, and it says so even when it applies.
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      assert %{gate: :open} = Consolidation.apply_confirmed_duplicates(tenant.id)
    end

    test "never unpublishes an agent's PRIVATE article, however its title collides" do
      # The pass runs as the SYSTEM and holds no agent identity, so it can never be the owner
      # a private article would be visible to. Two harms, and the quieter one is worse: the
      # loud one is unpublishing another agent's memory, the quiet one is quoting a private
      # body into a report any orchestrator key can read.
      tenant = fixture(:tenant)

      published(tenant.id, %{
        title: "Deploy Runbook",
        body: String.duplicate("shared body ", 20)
      })

      private =
        published(tenant.id, %{
          title: "deploy-runbook!",
          body: "PRIVATE agent memory",
          metadata: %{"visibility" => "private", "agent_id" => Ecto.UUID.generate()}
        })

      confirm_over_two_nights(tenant.id)

      assert %{applied: 0} = Consolidation.apply_confirmed_duplicates(tenant.id)
      assert status(private.id) == :published

      # And the private body never reached the report at all.
      {:ok, report} = Consolidation.latest(tenant.id)
      excerpts = report.proposals |> Enum.flat_map(& &1.evidence) |> Enum.map(& &1["excerpt"])
      refute Enum.any?(excerpts, &(&1 =~ "PRIVATE agent memory"))
    end

    test "applies NOTHING after a single run — one observation is not confirmation" do
      # This is what replaces human approve/reject. A duplicate that appears once and is gone
      # by the next run (a half-finished import, a title edited mid-scan) is never acted on,
      # and it costs one night of latency to get that.
      tenant = fixture(:tenant)
      {a, b} = duplicate_pair(tenant.id)

      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, skipped: 0} = Consolidation.apply_confirmed_duplicates(tenant.id)
      assert status(a.id) == :published
      assert status(b.id) == :published
    end

    test "a duplicate that appeared only in the NEWEST run is not applied" do
      # The real confirmation test. Two reports exist, so the fewer-than-two short-circuit
      # does not fire — the proposal is excluded because its fingerprint is absent from the
      # PREVIOUS report. Without this, the sibling test above passes for the wrong reason.
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Something Else Entirely", body: "unrelated"})

      # Night one: no duplicates exist yet.
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))

      # The duplicate is created AFTER that run.
      {a, b} = duplicate_pair(tenant.id)

      # Night two: the proposal appears for the first time.
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, skipped: 0} = Consolidation.apply_confirmed_duplicates(tenant.id)
      assert status(a.id) == :published
      assert status(b.id) == :published
    end

    test "applies once TWO consecutive runs agree, unpublishing the losers and keeping the richest" do
      tenant = fixture(:tenant)
      {a, b} = duplicate_pair(tenant.id)

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 1, skipped: 0, failed: 0} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      # The richest (longest body) survives; the duplicate is UNPUBLISHED, never archived —
      # :archived is terminal for an article, so it is the one retraction that cannot be
      # undone in code.
      assert status(a.id) == :published
      assert status(b.id) == :draft
    end

    test "SKIPS a group that no longer holds at apply time" do
      # The corpus moves between the scan and the write. If the group resolved itself in
      # between, applying would unpublish the last remaining copy.
      tenant = fixture(:tenant)
      {a, b} = duplicate_pair(tenant.id)

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)

      # Someone (or something) already unpublished one of them.
      {:ok, _} = Knowledge.unpublish_article(tenant.id, b.id)

      assert %{applied: 0, skipped: 1} = Consolidation.apply_confirmed_duplicates(tenant.id)
      assert status(a.id) == :published, "the survivor must never be unpublished"
    end

    test "placeholder titles never become a duplicate group, so they are never applied" do
      # "Untitled Document" and "untitled document!" both survive the case-sensitive
      # active-title index and normalize to ONE key. Grouping them would make the one
      # auto-applying class unpublish unrelated articles whose only shared property is a
      # MISSING title — and the two-run gate would agree with itself, because the grouping is
      # deterministic. They belong to `:generic_title`, which applies nothing.
      tenant = fixture(:tenant)

      a =
        published(tenant.id, %{
          title: "Untitled Document",
          body: String.duplicate("long body ", 20)
        })

      b = published(tenant.id, %{title: "untitled document!", body: "unrelated, and short"})

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, analysis} = Consolidation.analyze(tenant.id)
      assert proposals_of(analysis, :duplicate_capture) == []
      assert length(proposals_of(analysis, :generic_title)) == 2
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, skipped: 0} = Consolidation.apply_confirmed_duplicates(tenant.id)
      assert status(a.id) == :published
      assert status(b.id) == :published
    end

    test "two reports that are not ADJACENT do not confirm each other" do
      # The gate advertises "tonight agreed with last night". On a tenant whose scans failed
      # for a fortnight the two most recent reports straddle the outage, and agreement across
      # that gap is not the transience filter this claims to be.
      tenant = fixture(:tenant)
      {a, b} = duplicate_pair(tenant.id)

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -14))
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, skipped: 0, failed: 0} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(a.id) == :published
      assert status(b.id) == :published
    end

    test "the unpublish is REVERSIBLE, which is the whole reason this class may auto-apply" do
      tenant = fixture(:tenant)
      {_a, b} = duplicate_pair(tenant.id)

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)
      assert %{applied: 1} = Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(b.id) == :draft
      assert {:ok, _} = Knowledge.publish_article(tenant.id, b.id)
      assert status(b.id) == :published
    end
  end
end
