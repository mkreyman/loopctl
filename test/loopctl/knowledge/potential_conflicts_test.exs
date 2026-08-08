defmodule Loopctl.Knowledge.PotentialConflictsTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleLink
  alias LoopctlWeb.ArticleJSON

  defp published(tenant_id, title) do
    fixture(:article, %{tenant_id: tenant_id, title: title, status: :published})
  end

  # Confidence is GRANTED from the recording role, never accepted from the caller: only an
  # orchestrator+ recorder can produce the `:high` the nightly executor acts on, and a
  # `:high` supersede must carry its evidence. Every verdict below that is MEANT to execute
  # therefore records as an orchestrator would. The agent-role cap has its own tests.
  @orchestrator [actor_role: :orchestrator]

  defp conflict_link(tenant_id, src, tgt, score) do
    %ArticleLink{tenant_id: tenant_id}
    |> ArticleLink.changeset(%{
      source_article_id: src.id,
      target_article_id: tgt.id,
      relationship_type: :potential_conflict,
      metadata: %{"auto_generated" => true, "similarity_score" => score}
    })
    |> AdminRepo.insert!()
  end

  describe "list_potential_conflicts/2" do
    test "returns flagged pairs, highest overlap first, with both articles" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "A")
      b = published(tenant.id, "B")
      c = published(tenant.id, "C")
      conflict_link(tenant.id, a, b, 0.94)
      conflict_link(tenant.id, a, c, 0.985)

      %{data: data, meta: meta} = Knowledge.list_potential_conflicts(tenant.id)

      assert meta.total_count == 2
      # Highest similarity first.
      assert [%{similarity: 0.985}, %{similarity: 0.94}] = data
      first = hd(data)
      titles = Enum.map(first.articles, & &1.title) |> Enum.sort()
      assert titles == ["A", "C"]
    end

    test "paginates with limit/offset" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "A")

      for n <- 1..3 do
        peer = published(tenant.id, "peer #{n}")
        conflict_link(tenant.id, a, peer, 0.9 + n / 100)
      end

      page = Knowledge.list_potential_conflicts(tenant.id, limit: 2, offset: 0)
      assert length(page.data) == 2
      assert page.meta.total_count == 3

      page2 = Knowledge.list_potential_conflicts(tenant.id, limit: 2, offset: 2)
      assert length(page2.data) == 1
    end

    test "is tenant-scoped" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      a1 = published(tenant_a.id, "A1")
      a2 = published(tenant_a.id, "A2")
      conflict_link(tenant_a.id, a1, a2, 0.95)

      assert %{meta: %{total_count: 0}, data: []} =
               Knowledge.list_potential_conflicts(tenant_b.id)
    end
  end

  describe "get_article surfaces potential_conflicts" do
    test "the JSON view flattens conflict links to the peer + similarity" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "Main")
      peer = published(tenant.id, "Peer")
      conflict_link(tenant.id, a, peer, 0.96)

      {:ok, loaded} = Knowledge.get_article(tenant.id, a.id)
      json = ArticleJSON.article_data_with_links(loaded)

      assert [%{article_id: pid, title: "Peer", similarity: 0.96}] = json.potential_conflicts
      assert pid == peer.id
    end

    test "is an empty list when the article has no conflicts" do
      tenant = fixture(:tenant)
      a = published(tenant.id, "Solo")

      {:ok, loaded} = Knowledge.get_article(tenant.id, a.id)
      json = ArticleJSON.article_data_with_links(loaded)

      assert json.potential_conflicts == []
    end
  end

  describe "annotate_conflict/3 + executor" do
    setup do
      tenant = fixture(:tenant)
      a = published(tenant.id, "Winner")
      b = published(tenant.id, "Loser")
      conflict_link(tenant.id, a, b, 0.95)
      %{tenant: tenant, a: a, b: b}
    end

    test "dismiss takes effect immediately and drops the pair from the queue", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert %{meta: %{total_count: 1}} = Knowledge.list_potential_conflicts(t.id)

      assert {:ok, res} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "dismiss",
                   "classification" => "complementary"
                 },
                 actor_label: "agent:x"
               )

      assert res.disposition == :dismiss
      # Immediate.
      refute is_nil(res.executed_at)
      # Queue now excludes it.
      assert %{meta: %{total_count: 0}, data: []} = Knowledge.list_potential_conflicts(t.id)
    end

    test "a supersede BELOW high confidence is closed, not left invisible forever", ctx do
      %{tenant: t, a: a, b: b} = ctx

      # The silent black hole: the executor requires :high confidence, so a medium-confidence
      # supersede never executes — yet because the ROW EXISTS it also drops out of the queue
      # and out of Consolidation's judged pairs. It vanished from every surface while
      # changing nothing: not pending, not applied, not visible. Survivable only if a human
      # might one day re-annotate it, which is exactly what will not happen here.
      assert {:ok, res} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "supersede",
                   "classification" => "redundant",
                   "confidence" => "medium",
                   "authoritative_article_id" => a.id
                 },
                 actor_label: "agent:x"
               )

      assert res.confidence == :medium
      assert is_nil(res.executed_at), "precondition: it starts unexecuted"

      assert 0 = Knowledge.execute_conflict_resolutions(t.id)

      reloaded = AdminRepo.get!(Loopctl.Knowledge.ConflictResolution, res.id)

      # Closed rather than executed: it no longer sits unexecuted forever.
      refute is_nil(reloaded.executed_at)
      assert reloaded.execution_result["action"] == "skipped"
      assert reloaded.execution_result["reason"] == "insufficient_confidence"

      # And BOTH articles survive. Lowering the executor's bar to :medium instead would let a
      # judgement the annotator did not trust retire an article; the reversible outcome is
      # the only defensible default with nobody to adjudicate.
      assert AdminRepo.get!(Loopctl.Knowledge.Article, a.id).status == :published
      assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :published
    end

    test "supersede at high confidence is applied by the executor (loser retired)", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:ok, res} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => b.id,
                   "target_article_id" => a.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high",
                   "evidence" => "same capture; bodies agree"
                 },
                 @orchestrator
               )

      # Deferred — not executed on record.
      assert is_nil(res.executed_at)
      # Loser still published until the executor runs.
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published

      assert 1 == Knowledge.execute_conflict_resolutions(t.id)

      # Loser retired; a supersedes link points winner -> loser.
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :superseded

      assert Loopctl.AdminRepo.get_by(ArticleLink,
               tenant_id: t.id,
               source_article_id: a.id,
               target_article_id: b.id,
               relationship_type: :supersedes
             )
    end

    test "supersede below high confidence is NOT auto-applied", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "supersede",
          "authoritative_article_id" => a.id,
          "confidence" => "medium"
        })

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published
    end

    test "last-write-wins: re-annotating the same pair (any order) upserts", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "dismiss"
        })

      # Re-annotate with the pair in the OTHER order and a different verdict.
      {:ok, res2} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => b.id,
            "target_article_id" => a.id,
            "disposition" => "supersede",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert res2.disposition == :supersede
      # Exactly one row for the pair.
      assert 1 ==
               Loopctl.AdminRepo.aggregate(
                 Loopctl.Knowledge.ConflictResolution,
                 :count,
                 :id
               )
    end

    test "get_article drops a resolved conflict from its surfaced conflicts", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, before} = Knowledge.get_article(t.id, a.id)
      assert [_] = ArticleJSON.article_data_with_links(before).potential_conflicts

      {:ok, _} =
        Knowledge.annotate_conflict(t.id, %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "dismiss"
        })

      {:ok, loaded} = Knowledge.get_article(t.id, a.id)
      assert ArticleJSON.article_data_with_links(loaded).potential_conflicts == []
    end

    test "requires the authoritative article for supersede", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:error, changeset} =
               Knowledge.annotate_conflict(t.id, %{
                 "source_article_id" => a.id,
                 "target_article_id" => b.id,
                 "disposition" => "supersede"
               })

      assert %{authoritative_article_id: _} = errors_on(changeset)
    end

    # kb-02 (GHSA-9gqg-9r6p-658v) primary fix: a verdict may only be recorded against a
    # REAL, system-flagged potential-conflict pair. Two arbitrary articles with no
    # potential_conflict link cannot be resolved — this closes the fabrication path
    # where an agent picks any two articles and has the executor retire one.
    test "rejects a verdict on a pair with no potential_conflict link (no row created)", ctx do
      %{tenant: t} = ctx
      x = published(t.id, "X")
      y = published(t.id, "Y")

      assert {:error, :no_potential_conflict} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => x.id,
                   "target_article_id" => y.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => x.id,
                   "confidence" => "high",
                   "evidence" => "same capture; bodies agree"
                 },
                 @orchestrator
               )

      # Nothing persisted for the fabricated pair, so the executor retires nothing.
      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
      assert AdminRepo.get(Loopctl.Knowledge.Article, x.id).status == :published
      assert AdminRepo.get(Loopctl.Knowledge.Article, y.id).status == :published
    end

    # kb-02 FIX B (TOCTOU): retracting the flag after the verdict is recorded stops the
    # executor — it noops instead of retiring the loser.
    test "executor noops when the potential_conflict flag was retracted after the verdict", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "supersede",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      # A :user retracts the mistaken flag (DELETE link) before the nightly run.
      link =
        AdminRepo.get_by(ArticleLink, tenant_id: t.id, relationship_type: :potential_conflict)

      {:ok, _} = Knowledge.delete_link(t.id, link.id)

      # Executor must NOT retire the loser; it records a noop.
      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
      assert AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published

      row = AdminRepo.get_by(Loopctl.Knowledge.ConflictResolution, tenant_id: t.id)
      refute is_nil(row.executed_at)
      assert row.execution_result["reason"] == "potential_conflict flag retracted"
    end

    # kb-02 FIX A provenance: a :potential_conflict link WITHOUT the system
    # `auto_generated` marker is not accepted as evidence (a forged/non-system flag).
    test "rejects a verdict when the potential_conflict link is not system-generated", ctx do
      %{tenant: t} = ctx
      x = published(t.id, "X")
      y = published(t.id, "Y")

      # A flag lacking the auto_generated provenance marker (as if planted by a non-system path).
      %ArticleLink{tenant_id: t.id}
      |> ArticleLink.changeset(%{
        source_article_id: x.id,
        target_article_id: y.id,
        relationship_type: :potential_conflict,
        metadata: %{"similarity_score" => 0.99}
      })
      |> AdminRepo.insert!()

      assert {:error, :no_potential_conflict} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => x.id,
                   "target_article_id" => y.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => x.id,
                   "confidence" => "high",
                   "evidence" => "same capture; bodies agree"
                 },
                 @orchestrator
               )
    end

    # A dismiss verdict is likewise only accepted for a real flagged pair.
    test "rejects a dismiss on a pair with no potential_conflict link", ctx do
      %{tenant: t} = ctx
      x = published(t.id, "X")
      y = published(t.id, "Y")

      assert {:error, :no_potential_conflict} =
               Knowledge.annotate_conflict(t.id, %{
                 "source_article_id" => x.id,
                 "target_article_id" => y.id,
                 "disposition" => "dismiss"
               })
    end

    # Tenant isolation: tenant B's flag does not authorize resolving tenant A's pair.
    test "a potential_conflict link in another tenant does not authorize this tenant", ctx do
      %{a: a, b: b} = ctx
      other = fixture(:tenant)

      # The real flag lives in the setup tenant. Resolving the SAME article ids under a
      # different tenant must not find it.
      assert {:error, :no_potential_conflict} =
               Knowledge.annotate_conflict(
                 other.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high",
                   "evidence" => "same capture; bodies agree"
                 },
                 @orchestrator
               )
    end
  end

  # The conflict PAIR is manufacturable: the queue is fed by a mechanical similarity
  # threshold, so the party recording a verdict can arrange for the pair to be flagged. The
  # invariant these tests hold is that nothing an agent can record ON ITS OWN drives the
  # unattended retirement — while every disposition stays recordable at agent role (#331).
  describe "confidence is granted from the recording role, not accepted from the caller" do
    setup do
      tenant = fixture(:tenant)
      a = published(tenant.id, "Winner")
      b = published(tenant.id, "Loser")
      conflict_link(tenant.id, a, b, 0.95)
      %{tenant: tenant, a: a, b: b}
    end

    test "an agent asking for :high is recorded at :medium, and the ask is kept", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:ok, res} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high",
                   "evidence" => "looks the same to me"
                 },
                 actor_role: :agent
               )

      assert res.confidence == :medium
      assert res.requested_confidence == :high
      assert res.annotated_by_role == "agent"

      # Asserted on the PERSISTED row, not the returned struct: an upsert returns what the
      # changeset said, so a column missing from the `on_conflict` replace list would look
      # correct here and be wrong in the database the executor reads.
      stored = AdminRepo.get!(Loopctl.Knowledge.ConflictResolution, res.id)
      assert stored.confidence == :medium
      assert stored.requested_confidence == :high
      assert stored.annotated_by_role == "agent"
    end

    test "the capped verdict never retires the loser; both articles survive the executor",
         ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "supersede",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "looks the same to me"
          },
          actor_role: :agent
        )

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
      assert AdminRepo.get!(Loopctl.Knowledge.Article, a.id).status == :published
      assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :published

      refute AdminRepo.get_by(ArticleLink, tenant_id: t.id, relationship_type: :supersedes)
    end

    # The cap is only defensible if the verdict remains actionable. A capped row is neither
    # applied nor auto-dismissed, and its pair stays on BOTH surfaces an orchestrator could
    # rediscover it from — otherwise the remedy the response note names does not exist.
    test "a capped verdict is left pending and its pair stays in the conflict queue", ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, res} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "supersede",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "looks the same to me"
          },
          actor_role: :agent
        )

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
      assert is_nil(AdminRepo.get!(Loopctl.Knowledge.ConflictResolution, res.id).executed_at)

      assert %{data: [_ | _]} = Knowledge.list_potential_conflicts(t.id)

      {:ok, fetched} = Knowledge.get_article(t.id, a.id)
      assert Enum.any?(fetched.outgoing_links, &(&1.relationship_type == :potential_conflict))

      # And an orchestrator re-recording it at :high then applies normally.
      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "supersede",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert 1 == Knowledge.execute_conflict_resolutions(t.id)
      assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :superseded
    end

    # `:merge` retires NOTHING — it synthesizes a new draft and leaves both sources
    # published — so the retirement gate does not apply to it. Capping it turned the
    # disposition off for the agent role the KB-content carve-out (#331) exists to serve.
    test "a merge is NOT capped: an agent's :high is granted verbatim", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:ok, res} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "merge",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high"
                 },
                 actor_role: :agent
               )

      assert res.confidence == :high
      assert is_nil(res.requested_confidence)
      assert res.annotated_by_role == "agent"

      stored = AdminRepo.get!(Loopctl.Knowledge.ConflictResolution, res.id)
      assert stored.confidence == :high
    end

    test "an OMITTED actor_role is capped like an agent, not trusted", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:ok, res} =
               Knowledge.annotate_conflict(t.id, %{
                 "source_article_id" => a.id,
                 "target_article_id" => b.id,
                 "disposition" => "supersede",
                 "authoritative_article_id" => a.id,
                 "confidence" => "high",
                 "evidence" => "unattributed"
               })

      assert res.confidence == :medium
      assert res.annotated_by_role == "agent"
      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
    end

    test "an orchestrator's :high is granted verbatim and applies", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:ok, res} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high",
                   "evidence" => "same capture; bodies agree"
                 },
                 @orchestrator
               )

      assert res.confidence == :high
      assert is_nil(res.requested_confidence)
      assert res.annotated_by_role == "orchestrator"

      assert 1 == Knowledge.execute_conflict_resolutions(t.id)
      assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :superseded
    end

    test "an agent re-annotating an orchestrator's applied-pending verdict does not inherit it",
         ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "supersede",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      # Last-write-wins upserts the SAME row. Both provenance columns must be replaced with
      # the verdict — otherwise the agent's write keeps the orchestrator's authorization.
      {:ok, res} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => b.id,
            "target_article_id" => a.id,
            "disposition" => "supersede",
            "authoritative_article_id" => b.id,
            "confidence" => "high",
            "evidence" => "actually the other one wins"
          },
          actor_role: :agent
        )

      assert res.confidence == :medium

      # The PERSISTED provenance is what the executor reads, and an upsert returns the
      # changeset rather than the row — so both columns must be in the replace list or the
      # agent's write silently inherits the orchestrator's authorization. Fetched by tenant
      # (there is exactly one row for the pair): on the conflict path the returned struct
      # carries a freshly generated id, not the surviving row's.
      stored = AdminRepo.get_by!(Loopctl.Knowledge.ConflictResolution, tenant_id: t.id)
      assert stored.annotated_by_role == "agent"
      assert stored.requested_confidence == :high

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)
      assert AdminRepo.get!(Loopctl.Knowledge.Article, a.id).status == :published
      assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :published
    end

    test "a :high supersede with no evidence is rejected — the unattended write must say why",
         ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:error, changeset} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high"
                 },
                 @orchestrator
               )

      assert %{evidence: _} = errors_on(changeset)

      # Whitespace is not evidence.
      assert {:error, blank} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high",
                   "evidence" => "   "
                 },
                 @orchestrator
               )

      assert %{evidence: _} = errors_on(blank)
    end

    # The cap must not COERCE an unrecognized value — that would answer a malformed request
    # with a silent default. It is passed through for the changeset's enum cast to reject,
    # and a non-scalar must not raise on the way there (the 422-not-500 rule the disposition
    # field already follows).
    test "an unrecognized or non-scalar confidence is a changeset error, not a coercion", ctx do
      %{tenant: t, a: a, b: b} = ctx

      for bad <- ["HIGH", %{"nested" => "object"}] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 Knowledge.annotate_conflict(
                   t.id,
                   %{
                     "source_article_id" => a.id,
                     "target_article_id" => b.id,
                     "disposition" => "supersede",
                     "authoritative_article_id" => a.id,
                     "confidence" => bad
                   },
                   @orchestrator
                 )

        assert %{confidence: _} = errors_on(cs)
      end
    end

    test "evidence is NOT required below :high, nor for merge", ctx do
      %{tenant: t, a: a, b: b} = ctx

      assert {:ok, _} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => a.id,
                   "confidence" => "medium"
                 },
                 @orchestrator
               )

      assert {:ok, _} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "merge",
                   "authoritative_article_id" => a.id,
                   "confidence" => "high"
                 },
                 @orchestrator
               )
    end

    # The executor re-checks the persisted authorization rather than trusting the grant that
    # produced it. An unattributed or unrecognized recorder is not an authorization — and the
    # pair must NOT disappear behind a verdict nothing will act on, or the documented remedy
    # ("re-record it at :high") is reachable only by someone who memorised both ids.
    for {label, role} <- [{"no recorder", nil}, {"an unrecognized role", "not-a-role"}] do
      test "a :high supersede with #{label} is not applied, and its pair stays discoverable",
           ctx do
        %{tenant: t, a: a, b: b} = ctx

        {:ok, res} =
          Knowledge.annotate_conflict(
            t.id,
            %{
              "source_article_id" => a.id,
              "target_article_id" => b.id,
              "disposition" => "supersede",
              "authoritative_article_id" => a.id,
              "confidence" => "high",
              "evidence" => "same capture; bodies agree"
            },
            @orchestrator
          )

        {1, _} =
          AdminRepo.update_all(
            from(r in Loopctl.Knowledge.ConflictResolution, where: r.id == ^res.id),
            set: [annotated_by_role: unquote(role)]
          )

        assert 0 == Knowledge.execute_conflict_resolutions(t.id)
        assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :published

        # Left PENDING, not stamped as dismissed: an authorized re-record still applies it.
        assert is_nil(AdminRepo.get!(Loopctl.Knowledge.ConflictResolution, res.id).executed_at)

        assert %{data: [_ | _]} = Knowledge.list_potential_conflicts(t.id)
      end
    end

    # Tenant isolation: one tenant's executor never reaches another tenant's verdict, even
    # a fully authorized one.
    test "the executor does not apply another tenant's authorized verdict", ctx do
      %{tenant: t, a: a, b: b} = ctx
      other = fixture(:tenant)

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "supersede",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert 0 == Knowledge.execute_conflict_resolutions(other.id)
      assert AdminRepo.get!(Loopctl.Knowledge.Article, b.id).status == :published
    end
  end

  describe "merge executor (#4 step 2)" do
    import Mox

    setup do
      tenant = fixture(:tenant)
      # Mandatory BYO (Epic 28, #179): the merge executor now gates on has_api_key?
      # before synthesizing. Configure a key so these merge-path tests reach the
      # synthesizer (the keyless-skip path has its own dedicated test below).
      fixture(:tenant_llm_settings, %{tenant_id: tenant.id})
      a = published(tenant.id, "XML in Elixir with xmerl")
      b = published(tenant.id, "How to parse XML documents in Elixir")
      conflict_link(tenant.id, a, b, 0.98)
      %{tenant: tenant, a: a, b: b}
    end

    test "high-confidence merge synthesizes a DRAFT, links both sources, leaves them intact",
         ctx do
      %{tenant: t, a: a, b: b} = ctx

      stub(Loopctl.MockMergeSynthesizer, :synthesize, fn _tenant_id, _a, _b ->
        {:ok, %{title: "Parsing XML in Elixir (xmerl)", body: "Merged body covering both."}}
      end)

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "merge",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert 1 == Knowledge.execute_conflict_resolutions(t.id)

      # A new DRAFT exists, tagged merged, pointing at both sources.
      draft =
        AdminRepo.get_by(Loopctl.Knowledge.Article,
          tenant_id: t.id,
          title: "Parsing XML in Elixir (xmerl)"
        )

      assert draft.status == :draft
      assert draft.category == a.category
      assert draft.metadata["merged_from"] == [min(a.id, b.id), max(a.id, b.id)]

      links =
        AdminRepo.all(
          from(l in ArticleLink,
            where: l.source_article_id == ^draft.id and l.relationship_type == :relates_to,
            select: l.target_article_id
          )
        )

      assert Enum.sort(links) == Enum.sort([a.id, b.id])

      # Sources are untouched (never destroyed by a merge).
      assert AdminRepo.get(Loopctl.Knowledge.Article, a.id).status == :published
      assert AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published
    end

    test "merge is NOT executed when the synthesizer has no backend (stays for retry)", ctx do
      %{tenant: t, a: a, b: b} = ctx
      # Default stub returns {:error, :not_configured}.

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "merge",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)

      row = AdminRepo.get_by(Loopctl.Knowledge.ConflictResolution, tenant_id: t.id)
      assert is_nil(row.executed_at)
    end

    test "respects the wall-clock budget: budget_ms 0 applies nothing, leaves rows for next run (review #4)",
         ctx do
      %{tenant: t, a: a, b: b} = ctx

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "merge",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      # With a zero budget, the executor halts BEFORE applying the first row, so
      # nothing is executed and the (high-confidence) resolution stays for the next
      # run — the bound that prevents a 200-row loop pinning a shared slot for hours.
      assert 0 == Knowledge.execute_conflict_resolutions(t.id, budget_ms: 0)

      row = AdminRepo.get_by(Loopctl.Knowledge.ConflictResolution, tenant_id: t.id)
      assert is_nil(row.executed_at)
    end

    test "applies resolutions OLDEST-first and drains the tail across runs (order_by, review round 4)" do
      tenant = fixture(:tenant)

      # Three high-confidence SUPERSEDE resolutions (no LLM synthesizer needed, so this
      # is deterministic + fast) created oldest→newest with distinct inserted_at.
      [ra, rb, rc] =
        for label <- ["A", "B", "C"] do
          a = published(tenant.id, "#{label}1")
          b = published(tenant.id, "#{label}2")
          conflict_link(tenant.id, a, b, 0.95)

          {:ok, r} =
            Knowledge.annotate_conflict(
              tenant.id,
              %{
                "source_article_id" => a.id,
                "target_article_id" => b.id,
                "disposition" => "supersede",
                "authoritative_article_id" => a.id,
                "confidence" => "high",
                "evidence" => "same capture; bodies agree"
              },
              @orchestrator
            )

          # Distinct inserted_at (the `asc: r.id` tiebreaker also makes the order total).
          Process.sleep(5)
          r
        end

      executed? = fn r ->
        not is_nil(AdminRepo.get!(Loopctl.Knowledge.ConflictResolution, r.id).executed_at)
      end

      # Each bounded run makes forward progress OLDEST-first — never re-picking the
      # same head while the tail starves.
      assert 1 == Knowledge.execute_conflict_resolutions(tenant.id, limit: 1)
      assert executed?.(ra)
      refute executed?.(rb)
      refute executed?.(rc)

      assert 1 == Knowledge.execute_conflict_resolutions(tenant.id, limit: 1)
      assert executed?.(rb)
      refute executed?.(rc)

      # The TAIL (newest) eventually executes — no permanent starvation.
      assert 1 == Knowledge.execute_conflict_resolutions(tenant.id, limit: 1)
      assert executed?.(rc)
    end

    test "mandatory BYO: a keyless tenant's merge is marked skipped, not retried forever (review #10)" do
      # A DISTINCT tenant with NO llm settings row (no key configured).
      tenant = fixture(:tenant)
      a = published(tenant.id, "Alpha article about widgets")
      b = published(tenant.id, "Beta article about widgets")
      conflict_link(tenant.id, a, b, 0.98)

      # The synthesizer must NEVER be called without a tenant key.
      stub(Loopctl.MockMergeSynthesizer, :synthesize, fn _t, _a, _b ->
        flunk("merge synthesizer must not run without a tenant key")
      end)

      {:ok, _} =
        Knowledge.annotate_conflict(
          tenant.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "merge",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert 0 == Knowledge.execute_conflict_resolutions(tenant.id)

      # Marked executed with a DISTINCT, queryable "skipped/no_api_key" result —
      # NOT left unexecuted (which would retry every run forever).
      row = AdminRepo.get_by(Loopctl.Knowledge.ConflictResolution, tenant_id: tenant.id)
      refute is_nil(row.executed_at)
      assert row.execution_result["action"] == "skipped"
      assert row.execution_result["reason"] == "no_api_key"
    end

    # REGRESSION (review, US-41.4 AC-41.4.3): `permanent_merge_error?/1`'s catch-all
    # bucketed `{:egress_blocked, details}` as TRANSIENT, so the row was left
    # unexecuted and the nightly executor re-attempted the identical, PERMANENTLY
    # refused synthesis forever — logging "transiently failed" each time. AC-41.4.3
    # names merge explicitly as a path that must treat `:egress_blocked` as
    # permanent (the reclassify worker was already fixed for exactly this).
    test "an :egress_blocked synthesis is PERMANENT — marked failed, never retried", ctx do
      %{tenant: t, a: a, b: b} = ctx

      stub(Loopctl.MockMergeSynthesizer, :synthesize, fn _scope, _a, _b ->
        {:error, {:egress_blocked, %{host: "api.anthropic.com", scope: "tenant:#{t.id}"}}}
      end)

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "merge",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)

      row = AdminRepo.get_by(Loopctl.Knowledge.ConflictResolution, tenant_id: t.id)
      refute is_nil(row.executed_at)
      assert row.execution_result["action"] == "failed"
      assert row.execution_result["reason"] =~ "egress_blocked"
    end

    # ... while a TRANSIENT egress refusal still self-heals and must stay retryable.
    test "a :pin_stale synthesis stays TRANSIENT and is left for the next run", ctx do
      %{tenant: t, a: a, b: b} = ctx

      stub(Loopctl.MockMergeSynthesizer, :synthesize, fn _scope, _a, _b ->
        {:error, {:pin_stale, %{host: "ollama.example.com"}}}
      end)

      {:ok, _} =
        Knowledge.annotate_conflict(
          t.id,
          %{
            "source_article_id" => a.id,
            "target_article_id" => b.id,
            "disposition" => "merge",
            "authoritative_article_id" => a.id,
            "confidence" => "high",
            "evidence" => "same capture; bodies agree"
          },
          @orchestrator
        )

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)

      assert is_nil(
               AdminRepo.get_by(Loopctl.Knowledge.ConflictResolution, tenant_id: t.id).executed_at
             )
    end
  end
end
