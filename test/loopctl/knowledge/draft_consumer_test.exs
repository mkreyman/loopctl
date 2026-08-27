defmodule Loopctl.Knowledge.DraftConsumerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.DraftConsumer
  alias Loopctl.Knowledge.ProposalGate
  alias Loopctl.MockProposalAssessor

  # The assessor is injected PER CALL through the `:proposal_assessor` opt, never through
  # `Application.put_env` — this suite is `async: true` and that would mutate VM-global state
  # every other test would see. `config/test.exs` already resolves the config layer to this
  # same mock, so passing it explicitly exercises the opt seam rather than bypassing it.
  @assessor [proposal_assessor: MockProposalAssessor]

  # Backdated past the 48h hold floor — a FRESH draft is held on purpose (own test below).
  defp draft(tenant_id, attrs \\ %{}) do
    fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :draft}, attrs)) |> aged(-7)
  end

  defp published(tenant_id, attrs \\ %{}) do
    tenant_id
    |> draft(attrs)
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp reload(article), do: AdminRepo.get!(Article, article.id)

  defp links_from(article_id) do
    from(l in ArticleLink, where: l.source_article_id == ^article_id) |> AdminRepo.all()
  end

  defp verdict(verdict, neighbors \\ []) do
    %{verdict: verdict, score: List.first(neighbors)[:similarity_score], neighbors: neighbors}
  end

  defp neighbor(article, score),
    do: %{id: article.id, title: article.title, similarity_score: score}

  defp stub_verdict(assessment) do
    Mox.stub(MockProposalAssessor, :assess, fn _tenant_id, _attrs, _opts -> assessment end)
  end

  describe "consume/2 — the default is publish" do
    test "a novel draft is PUBLISHED" do
      tenant = fixture(:tenant)
      held = draft(tenant.id)
      stub_verdict(verdict(:novel))

      tally = DraftConsumer.consume(tenant.id, @assessor)

      assert reload(held).status == :published
      assert tally.published == 1
      assert tally.offered == 1
      assert tally.linked == 0
      assert tally.gate == :open
      assert links_from(held.id) == []
    end

    test "a near-duplicate draft is PUBLISHED AND LINKED, and is never archived" do
      tenant = fixture(:tenant)
      canonical = published(tenant.id)
      held = draft(tenant.id)
      stub_verdict(verdict(:low_novelty, [neighbor(canonical, 0.94)]))

      tally = DraftConsumer.consume(tenant.id, @assessor)

      reloaded = reload(held)
      assert reloaded.status == :published
      # The #765 spec's "archive the twin" is the one disposition this step may not take:
      # `:archived` is TERMINAL (`Article`'s @valid_transitions has no `{:archived, _}`).
      refute reloaded.status == :archived

      assert [link] = links_from(held.id)
      assert link.target_article_id == canonical.id
      assert link.relationship_type == :relates_to
      assert tally.published == 1
      assert tally.linked == 1
      assert tally.link_failed == 0
    end

    test "the annotation carries the shape promote_conflicts/1 reads" do
      tenant = fixture(:tenant)
      canonical = published(tenant.id)
      held = draft(tenant.id)
      stub_verdict(verdict(:duplicate, [neighbor(canonical, 0.985)]))

      DraftConsumer.consume(tenant.id, @assessor)

      assert [link] = links_from(held.id)
      # Both keys are what the promoter's candidate query filters on. Without them the edge
      # is invisible to the `:potential_conflict` promoter and to the judge behind it, so the
      # redundancy this step deliberately delegates would never be handled at all.
      assert link.metadata["auto_generated"] == true
      assert link.metadata["similarity_score"] == 0.985
      assert link.metadata["novelty_verdict"] == "duplicate"
      assert link.metadata["linked_by"] == DraftConsumer.actor_label()
    end

    test "a near-duplicate whose assessment carries no neighbour is still published, unannotated" do
      tenant = fixture(:tenant)
      held = draft(tenant.id)
      stub_verdict(verdict(:low_novelty, []))

      log =
        capture_log(fn -> assert DraftConsumer.consume(tenant.id, @assessor).published == 1 end)

      assert reload(held).status == :published
      assert links_from(held.id) == []
      assert log =~ "no usable neighbour"
    end

    test "nothing this step touches reaches a TERMINAL state" do
      tenant = fixture(:tenant)
      canonical = published(tenant.id)
      _novel = draft(tenant.id)
      near = draft(tenant.id)

      Mox.stub(MockProposalAssessor, :assess, fn _t, attrs, _o ->
        if attrs["title"] == near.title,
          do: verdict(:low_novelty, [neighbor(canonical, 0.94)]),
          else: verdict(:novel)
      end)

      DraftConsumer.consume(tenant.id, @assessor)

      statuses =
        from(a in Article, where: a.tenant_id == ^tenant.id, select: a.status)
        |> AdminRepo.all()

      refute :archived in statuses
      refute :superseded in statuses
    end
  end

  describe "consume/2 — a failed assessment" do
    test "leaves the draft alone and COUNTS it" do
      tenant = fixture(:tenant)
      held = draft(tenant.id)
      # `ProposalGate` falls open on any embedding/search failure, so `:unknown` means "not
      # assessed" and never "not a duplicate".
      stub_verdict(%{verdict: :unknown, score: nil, neighbors: []})

      tally = DraftConsumer.consume(tenant.id, @assessor)

      assert reload(held).status == :draft
      assert tally.unassessed == 1
      assert tally.published == 0
      assert tally.offered == 1
    end

    test "a verdict outside the behaviour's vocabulary is NOT treated as novel" do
      tenant = fixture(:tenant)
      held = draft(tenant.id)
      stub_verdict(%{verdict: :something_else, score: nil, neighbors: []})

      tally = DraftConsumer.consume(tenant.id, @assessor)

      assert reload(held).status == :draft
      assert tally.unassessed == 1
      assert tally.published == 0
    end

    test "a raising assessor is contained per item and the rest of the night still runs" do
      tenant = fixture(:tenant)
      boom = draft(tenant.id)
      fine = draft(tenant.id)

      Mox.stub(MockProposalAssessor, :assess, fn _t, attrs, _o ->
        if attrs["title"] == boom.title, do: raise("provider exploded"), else: verdict(:novel)
      end)

      tally =
        capture_log(fn -> send(self(), {:tally, DraftConsumer.consume(tenant.id, @assessor)}) end)

      assert_received {:tally, tally_result}
      assert tally =~ "could not be consumed"

      assert tally_result.failed == 1
      assert tally_result.published == 1
      assert reload(boom).status == :draft
      assert reload(fine).status == :published
    end
  end

  describe "consume/2 — the bounds" do
    test "the budget truncating is REPORTED, never silent" do
      tenant = fixture(:tenant)
      a = draft(tenant.id)
      b = draft(tenant.id)
      stub_verdict(verdict(:novel))

      log =
        capture_log(fn ->
          tally = DraftConsumer.consume(tenant.id, Keyword.put(@assessor, :budget_ms, 0))
          send(self(), {:tally, tally})
        end)

      assert_received {:tally, tally}
      # A budget of exactly 0 — the state a night whose prelude overran arrives in — must buy
      # NO provider call at all, because the deadline is checked at the HEAD of each item.
      assert tally.published == 0
      assert tally.offered == 2
      assert tally.budget_exhausted
      assert log =~ "budget after 0 of 2"
      assert reload(a).status == :draft
      assert reload(b).status == :draft
    end

    test "a night that drained everything it was offered is NOT reported truncated" do
      tenant = fixture(:tenant)
      _held = draft(tenant.id)
      stub_verdict(verdict(:novel))

      tally = DraftConsumer.consume(tenant.id, @assessor)

      # A bound reported unconditionally says nothing at all.
      refute tally.budget_exhausted
      assert tally.published == 1
    end

    test "a cap of 0 PAUSES the drain without a deploy" do
      tenant = fixture(:tenant)
      held = draft(tenant.id)
      stub_verdict(verdict(:novel))

      tally = DraftConsumer.consume(tenant.id, Keyword.put(@assessor, :max_publishes, 0))

      assert tally.gate == :drain_disabled
      assert tally.offered == 0
      assert reload(held).status == :draft
    end

    test "a NEGATIVE cap is a pause too, and a non-integer one falls back to the default" do
      tenant = fixture(:tenant)
      held = draft(tenant.id)
      stub_verdict(verdict(:novel))

      # A negative cap must not wrap round to "unbounded" — and it must not reach the query
      # as a negative LIMIT either.
      assert DraftConsumer.consume(tenant.id, Keyword.put(@assessor, :max_publishes, -1)).gate ==
               :drain_disabled

      assert reload(held).status == :draft

      # A non-integer must fall back rather than raise inside the nightly's rescue, where it
      # would surface as an outage instead of the config typo it is.
      log =
        capture_log(fn ->
          assert DraftConsumer.consume(tenant.id, Keyword.put(@assessor, :max_publishes, "30")).published ==
                   1
        end)

      assert log =~ "ignoring non-integer cap"
      assert reload(held).status == :published
    end

    test "the OLDEST drafts are drained first, with a slice reserved for the NEWEST" do
      tenant = fixture(:tenant)
      # Inserted NEWEST-first on purpose: heap order then disagrees with `inserted_at`, so
      # only the ORDER BY can produce this result. Created oldest-first, the assertion passes
      # on scan order alone and says nothing.
      recent = aged(draft(tenant.id), -3)
      middle = aged(draft(tenant.id), -20)
      old = aged(draft(tenant.id), -30)
      stub_verdict(verdict(:novel))

      DraftConsumer.consume(tenant.id, Keyword.put(@assessor, :max_publishes, 2))

      # The backlog bias takes the oldest; the reserved slice takes the newest, which is what
      # keeps the drain positive when a permanently unconsumable head owns every backlog slot.
      assert reload(old).status == :published
      assert reload(recent).status == :published
      assert reload(middle).status == :draft
    end

    test "a draft younger than the hold floor is never offered" do
      tenant = fixture(:tenant)
      # `draft: true` (and ingestion without `publish: true`) is an advertised staging opt-in.
      fresh = aged(draft(tenant.id), 0)
      stub_verdict(verdict(:novel))

      assert DraftConsumer.consume(tenant.id, @assessor).offered == 0
      assert reload(fresh).status == :draft
    end
  end

  describe "consume/2 — drafts that were held on purpose" do
    test "a draft consolidation retracted is never republished (durable marker)" do
      tenant = fixture(:tenant)

      held =
        tenant.id
        |> draft()
        |> Ecto.Changeset.change(%{consolidation_retracted_at: DateTime.utc_now()})
        |> AdminRepo.update!()

      stub_verdict(verdict(:novel))

      tally = DraftConsumer.consume(tenant.id, @assessor)

      assert tally.offered == 0
      assert reload(held).status == :draft
    end

    test "a draft ANY actor retracted is never republished (audit_log record)" do
      tenant = fixture(:tenant)
      # The pre-marker shape: retracted before migration 20260818055453 stamped the column.
      # `unpublish_article/3` / `bulk_unpublish/3` leave the same row behind, so the guard is
      # NOT narrowed to one actor label — republishing a `role: :user` retraction would revert
      # a human-gated act unattended.
      by_worker = draft(tenant.id)
      by_human = draft(tenant.id)
      unpublished_by(tenant.id, by_worker.id, "worker:consolidation")
      unpublished_by(tenant.id, by_human.id, "human:operator")
      stub_verdict(verdict(:novel))

      assert DraftConsumer.consume(tenant.id, @assessor).offered == 0
      assert reload(by_worker).status == :draft
      assert reload(by_human).status == :draft
    end

    test "a conflict-MERGE draft is never auto-published" do
      tenant = fixture(:tenant)

      # The carve-out that lets an AGENT-role key record a merge verdict rests on the
      # synthesised draft never being auto-published.
      merged =
        draft(tenant.id, %{
          metadata: %{"merged_from" => [Ecto.UUID.generate(), Ecto.UUID.generate()]}
        })

      stub_verdict(verdict(:novel))

      assert DraftConsumer.consume(tenant.id, @assessor).offered == 0
      assert reload(merged).status == :draft
    end
  end

  describe "consume/2 — scope discipline" do
    test "a private/owner draft is never shipped to a provider" do
      tenant = fixture(:tenant)
      private = draft(tenant.id, %{metadata: %{"visibility" => "private"}})
      owner = draft(tenant.id, %{metadata: %{"visibility" => "owner"}})
      stub_verdict(verdict(:novel))

      tally = DraftConsumer.consume(tenant.id, @assessor)

      assert tally.offered == 0
      assert reload(private).status == :draft
      assert reload(owner).status == :draft
    end

    test "a keyless tenant is not offered its drafts at all" do
      tenant = fixture(:tenant)
      held = draft(tenant.id)

      # Every assessment on a keyless tenant falls open on `{:error, :no_api_key}` AND appends
      # an `llm.blocked_no_api_key` row to the hash-chained audit_log — for a known-zero run.
      tally = DraftConsumer.consume(tenant.id, proposal_assessor: ProposalGate)

      assert tally.gate == :no_embedding_key
      assert tally.offered == 0
      assert reload(held).status == :draft
    end

    # `ArticleLinkingWorker` scopes neighbours `project_or_global` and skips private/owner rows,
    # so the graph has never held either edge — and the promoter, which cannot tell one from an
    # auto-linker edge, would flag a pair that suppresses BOTH its articles from curated answers.
    test "a neighbour in ANOTHER project is published unannotated, never linked" do
      tenant = fixture(:tenant)

      elsewhere =
        published(tenant.id, %{project_id: fixture(:project, %{tenant_id: tenant.id}).id})

      held = draft(tenant.id, %{project_id: fixture(:project, %{tenant_id: tenant.id}).id})
      stub_verdict(verdict(:duplicate, [neighbor(elsewhere, 0.99)]))

      log = capture_log(fn -> DraftConsumer.consume(tenant.id, @assessor) end)

      assert reload(held).status == :published
      assert links_from(held.id) == []
      assert log =~ "no usable neighbour"
    end

    test "a PRIVATE neighbour is published unannotated, never linked" do
      tenant = fixture(:tenant)
      secret = published(tenant.id, %{metadata: %{"visibility" => "private"}})
      held = draft(tenant.id)
      stub_verdict(verdict(:duplicate, [neighbor(secret, 0.99)]))

      capture_log(fn -> assert DraftConsumer.consume(tenant.id, @assessor).published == 1 end)

      assert links_from(held.id) == []
    end

    test "a draft that stops being eligible after the offer is SKIPPED, never published" do
      tenant = fixture(:tenant)
      first = aged(draft(tenant.id), -30)
      second = aged(draft(tenant.id), -20)

      # The live re-fetch guard, forced deterministically: consuming the FIRST draft archives
      # the second, so by the time the reduce reaches it the row is no longer an eligible
      # draft. Without the re-read this step would spend a provider call and then attempt a
      # publish on a row that had moved.
      # EXACTLY ONE call. That is the assertion the re-read earns: without it the second
      # draft is still skipped (the publish transition refuses it), but only AFTER an
      # embedding call has been paid for on a row that had already moved. `verify_on_exit!`
      # fails the test on a second invocation.
      Mox.expect(MockProposalAssessor, :assess, 1, fn _t, attrs, _o ->
        if attrs["title"] == first.title do
          second |> Ecto.Changeset.change(%{status: :archived}) |> AdminRepo.update!()
        end

        verdict(:novel)
      end)

      tally = DraftConsumer.consume(tenant.id, @assessor)

      assert tally.offered == 2
      assert tally.published == 1
      assert tally.skipped == 1
      # It is SKIPPED, not published and not failed: nothing is wrong and nothing is owed.
      assert tally.failed == 0
      assert reload(second).status == :archived
    end
  end

  describe "consume/2 — tenant isolation" do
    test "tenant A's run never touches tenant B's drafts" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      mine = draft(tenant_a.id)
      theirs = draft(tenant_b.id)
      stub_verdict(verdict(:novel))

      tally = DraftConsumer.consume(tenant_a.id, @assessor)

      assert tally.offered == 1
      assert tally.published == 1
      assert reload(mine).status == :published
      assert reload(theirs).status == :draft
    end
  end

  # `inserted_at` is not castable, so age it directly — the ordering guard is about which
  # rows a capped run reaches, and every fixture row is otherwise inserted in the same second.
  defp unpublished_by(tenant_id, article_id, actor_label) do
    {:ok, _} =
      Audit.create_log_entry(tenant_id, %{
        entity_type: "article",
        entity_id: article_id,
        action: "article.unpublished",
        actor_type: "system",
        actor_id: nil,
        actor_label: actor_label,
        new_state: %{"status" => "draft"}
      })
  end

  defp aged(article, days) do
    article
    |> Ecto.Changeset.change(%{
      inserted_at: DateTime.add(DateTime.utc_now(), days * 86_400, :second)
    })
    |> AdminRepo.update!()
  end
end
