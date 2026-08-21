defmodule Loopctl.Knowledge.AssertConflictTest do
  @moduledoc """
  #730 — a session that deliberately writes a correction must be able to CONTEST the
  article it refutes. `annotate_conflict/3` could only judge pairs the auto-linker flagged
  by cosine similarity, which is exactly the wrong precondition for that case: the pair is
  minutes old, and a good correction argues about a conclusion rather than restating the
  vocabulary, so it may never cross the similarity threshold at all.

  The tests below hold BOTH halves. Reachability: an asserted pair reaches the queue and is
  resolvable. And the three properties that were NOT granted along with it — an assertion
  does not suppress its articles from curated answers, does not let its asserter judge it,
  and does not survive as system provenance.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ConflictResolution

  @asserter [actor_principal: "agent-writing-the-correction", actor_label: "agent:corrector"]
  @judge [actor_principal: "someone-else", actor_label: "orchestrator:judge"]

  defp published(tenant_id, title, metadata \\ %{}) do
    fixture(:article, %{
      tenant_id: tenant_id,
      title: title,
      status: :published,
      metadata: metadata
    })
  end

  defp assert_pair(tenant_id, a, b, opts \\ @asserter, attrs \\ %{}) do
    Knowledge.assert_conflict(
      tenant_id,
      Map.merge(
        %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "classification" => "contradictory",
          "evidence" => "measured on the live corpus; the conclusion does not follow"
        },
        attrs
      ),
      opts
    )
  end

  # TENANT-SCOPED, never a global aggregate: AdminRepo is BYPASSRLS, so counting every
  # article_link in the database makes these assertions fail on any test DB that carries a
  # committed row (the :scale suite commits its corpus into the shared one).
  defp link_count(tenant_id) do
    AdminRepo.aggregate(from(l in ArticleLink, where: l.tenant_id == ^tenant_id), :count, :id)
  end

  defp judge(tenant_id, a, b, opts \\ []) do
    Knowledge.annotate_conflict(
      tenant_id,
      %{"source_article_id" => a.id, "target_article_id" => b.id, "disposition" => "dismiss"},
      @judge ++ opts
    )
  end

  defp system_flag(tenant_id, a, b, score) do
    %ArticleLink{tenant_id: tenant_id}
    |> ArticleLink.changeset(%{
      source_article_id: a.id,
      target_article_id: b.id,
      relationship_type: :potential_conflict,
      metadata: %{"auto_generated" => true, "similarity_score" => score}
    })
    |> AdminRepo.insert!()
  end

  describe "assert_conflict/3 — reachability" do
    test "opens a pair the auto-linker never flagged, carrying the claim" do
      t = fixture(:tenant)
      correction = published(t.id, "The 27x ratio is corpus size, not quality")
      original = published(t.id, "Harvested articles are read 27x less — rank them down")

      assert {:ok, %ArticleLink{} = link, :created} =
               assert_pair(t.id, correction, original, @asserter, %{
                 "proposed_authoritative_article_id" => correction.id
               })

      assert link.relationship_type == :potential_conflict
      # NEVER `true` — this is the marker curated suppression and every system-provenance
      # site keys on, and an assertion must not be able to plant it.
      assert link.metadata["auto_generated"] == false
      assert link.metadata["asserted"] == true
      assert link.metadata["asserted_by_principal"] == "agent-writing-the-correction"
      assert link.metadata["classification"] == "contradictory"
      assert link.metadata["proposed_authoritative_article_id"] == correction.id
      assert link.metadata["evidence"] =~ "does not follow"
    end

    test "the asserted pair appears in the conflict queue, tagged and with its argument" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      assert {:ok, _link, :created} = assert_pair(t.id, a, b)

      assert %{data: [row], meta: %{total_count: 1}} = Knowledge.list_potential_conflicts(t.id)
      assert row.origin == "asserted"
      assert row.similarity == nil
      assert row.assertion.classification == "contradictory"
      assert row.assertion.evidence =~ "does not follow"
      # The server-derived PRINCIPAL, not the audit label: the label is
      # "<role>:<key_name>" and this queue is an agent-role read surface.
      assert row.assertion.asserted_by == "agent-writing-the-correction"
      assert Enum.map(row.articles, & &1.title) |> Enum.sort() == ["A", "B"]
    end

    test "a system-flagged pair keeps origin \"system\" and carries no assertion block" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      system_flag(t.id, a, b, 0.97)

      assert %{data: [row]} = Knowledge.list_potential_conflicts(t.id)
      assert row.origin == "system"
      assert row.similarity == 0.97
      refute Map.has_key?(row, :assertion)
    end

    test "asserted pairs lead the queue — they carry an argument, not a similarity score" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      c = published(t.id, "C")
      d = published(t.id, "D")
      system_flag(t.id, a, b, 0.99)
      assert {:ok, _link, :created} = assert_pair(t.id, c, d)

      assert %{data: [first, second]} = Knowledge.list_potential_conflicts(t.id)
      assert first.origin == "asserted"
      assert second.origin == "system"
    end

    test "another principal can judge the asserted pair, and the executor applies it" do
      t = fixture(:tenant)
      winner = published(t.id, "winner")
      loser = published(t.id, "loser")
      assert {:ok, link, :created} = assert_pair(t.id, winner, loser)

      assert {:ok, %ConflictResolution{}} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => winner.id,
                   "target_article_id" => loser.id,
                   "disposition" => "supersede",
                   "authoritative_article_id" => winner.id,
                   "confidence" => "high",
                   "evidence" => "the correction cites the measurement the original lacked"
                 },
                 @judge ++ [actor_role: :orchestrator]
               )

      # The recorder's principal is stamped on the flag, which is what the execution-time
      # re-check compares — an unstamped flag silently demotes it to the audit labels.
      assert AdminRepo.get(ArticleLink, link.id).metadata["verdict_by_principal"] ==
               "someone-else"

      assert 1 == Knowledge.execute_conflict_resolutions(t.id)
      assert AdminRepo.get(Loopctl.Knowledge.Article, loser.id).status == :superseded
    end
  end

  describe "assert_conflict/3 — what it deliberately does NOT grant" do
    # The load-bearing one. If an assertion suppressed its articles from curated answers,
    # any agent could retract any article from the governed answer path by asserting a
    # dispute over it — a caller-driven takedown wearing a curation hat.
    test "an assertion does not suppress either article from curated answers" do
      t = fixture(:tenant)
      {:ok, a} = Knowledge.mark_curated(t.id, published(t.id, "A").id, actor_label: "user:admin")
      b = published(t.id, "B")
      assert {:ok, _link, :created} = assert_pair(t.id, a, b)

      assert Knowledge.authoritative_curated?(a, t.id),
             "an asserted flag must not reach curated suppression — only a system flag does"

      assert a.id in Enum.map(Knowledge.list_curated_sources(t.id), & &1.id)

      # And a SYSTEM flag over the same article DOES suppress it, so the assertion above is
      # measuring the provenance marker rather than a suppression path that happens to be
      # switched off for everyone.
      c = published(t.id, "C")
      system_flag(t.id, a, c, 0.99)
      refute Knowledge.authoritative_curated?(a, t.id)
      refute a.id in Enum.map(Knowledge.list_curated_sources(t.id), & &1.id)
    end

    test "the asserting principal cannot record the pair's verdict" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      assert {:ok, _link, :created} = assert_pair(t.id, a, b)

      for disposition <- ["dismiss", "supersede", "merge"] do
        assert {:error, :self_asserted_conflict} =
                 Knowledge.annotate_conflict(
                   t.id,
                   %{
                     "source_article_id" => a.id,
                     "target_article_id" => b.id,
                     "disposition" => disposition,
                     "authoritative_article_id" => a.id,
                     "confidence" => "high",
                     "evidence" => "because I say so"
                   },
                   @asserter ++ [actor_role: :orchestrator]
                 ),
               "#{disposition} by the asserter must be refused"
      end
    end

    # The specific attack the refusal above closes for `:dismiss`: a dismiss is terminal
    # the moment it is recorded, so asserting a pair and dismissing it would let any caller
    # pre-settle an arbitrary pair and swallow a GENUINE system flag raised over it later.
    test "asserting then dismissing cannot pre-settle a pair against a later system flag" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      assert {:ok, _link, :created} = assert_pair(t.id, a, b)

      assert {:error, :self_asserted_conflict} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "dismiss"
                 },
                 @asserter
               )

      assert %{meta: %{total_count: 1}} = Knowledge.list_potential_conflicts(t.id)
    end

    # Fail closed: "no identity" must not be the way through the separation.
    test "a verdict with no recorder principal is refused on an asserted pair" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      assert {:ok, _link, :created} = assert_pair(t.id, a, b)

      assert {:error, :self_asserted_conflict} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "dismiss"
                 },
                 actor_label: "orchestrator:judge"
               )
    end

    test "an assertion with no principal is refused rather than recorded unattributed" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")

      assert {:error, :unattributed_assertion} =
               assert_pair(t.id, a, b, actor_label: "agent:anon")
    end

    test "evidence is required" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")

      assert {:error, :evidence_required} =
               assert_pair(t.id, a, b, @asserter, %{"evidence" => "   "})

      assert {:error, :evidence_required} =
               assert_pair(t.id, a, b, @asserter, %{"evidence" => nil})
    end

    test "an article cannot be asserted against itself" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      assert {:error, :same_article} = assert_pair(t.id, a, a)
    end

    # `:binary_id` normalizes case only at DUMP time, so an uppercase spelling used to pass
    # both this guard and the changeset's `validate_no_self_link` and land as a row whose
    # two FK columns hold identical bytes.
    test "an article cannot be asserted against itself under a different UUID casing" do
      t = fixture(:tenant)
      a = published(t.id, "A")

      assert {:error, :same_article} =
               assert_pair(t.id, a, %{a | id: String.upcase(a.id)})
    end

    test "a malformed article id is refused, never interpolated into the query" do
      t = fixture(:tenant)
      a = published(t.id, "A")

      assert {:error, :missing_article_id} =
               assert_pair(t.id, a, %{a | id: "not-a-uuid"})
    end

    test "classification must be one of the three declared values" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")

      assert {:error, :invalid_classification} =
               assert_pair(t.id, a, b, @asserter, %{"classification" => "authoritative"})
    end

    test "the proposed winner must be a member of the pair" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      elsewhere = published(t.id, "C")

      assert {:error, :invalid_proposed_article} =
               assert_pair(t.id, a, b, @asserter, %{
                 "proposed_authoritative_article_id" => elsewhere.id
               })

      assert {:error, :invalid_proposed_article} =
               assert_pair(t.id, a, b, @asserter, %{
                 "proposed_authoritative_article_id" => "not-a-uuid"
               })
    end

    test "evidence is bounded — it is echoed on every row of the queue" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")

      oversized = String.duplicate("x", Knowledge.max_assertion_evidence_bytes() + 1)

      assert {:error, :evidence_too_long} =
               assert_pair(t.id, a, b, @asserter, %{"evidence" => oversized})
    end

    # The queue admits two provenances and a reviewer must be able to ask for ONE —
    # asserted rows lead the ordering, so page 1 is otherwise caller-controlled.
    test "the queue can be filtered to one provenance" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      c = published(t.id, "C")
      d = published(t.id, "D")
      system_flag(t.id, a, b, 0.99)
      assert {:ok, _link, :created} = assert_pair(t.id, c, d)

      assert %{data: [only], meta: %{total_count: 1}} =
               Knowledge.list_potential_conflicts(t.id, origin: "system")

      assert only.origin == "system"

      assert %{data: [asserted], meta: %{total_count: 1}} =
               Knowledge.list_potential_conflicts(t.id, origin: "asserted")

      assert asserted.origin == "asserted"
    end

    # The inverse of "an assertion must not suppress": two principals must not be able to
    # pre-settle an arbitrary pair against a system flag raised over it LATER.
    test "a verdict cannot settle a system flag that did not exist when it was recorded" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      assert {:ok, link, :created} = assert_pair(t.id, a, b)

      assert {:ok, %ConflictResolution{}} =
               Knowledge.annotate_conflict(
                 t.id,
                 %{
                   "source_article_id" => a.id,
                   "target_article_id" => b.id,
                   "disposition" => "dismiss"
                 },
                 @judge
               )

      assert %{meta: %{total_count: 0}} = Knowledge.list_potential_conflicts(t.id)

      # The asserted flag is retracted and the sweep later raises a GENUINE system flag over
      # the same two articles. The verdict above judged a flag that no longer exists, so it
      # must not arrive pre-settled.
      AdminRepo.delete!(link)
      system_flag(t.id, a, b, 0.99)

      assert %{data: [row], meta: %{total_count: 1}} = Knowledge.list_potential_conflicts(t.id)
      assert row.origin == "system"
    end

    # The other half of the same predicate, and the reason it is NOT shared with curated
    # suppression: suppression asks "has anyone JUDGED this?", while the automatic drain
    # (`KnowledgeLintWorker.judge_redundant_conflicts/1`) skips any pair that already carries
    # a verdict row. A re-flagged judged pair that suppression counted as unjudged would
    # withhold BOTH articles for the whole window with nothing able to release them.
    test "a re-flagged pair that was already judged is not suppressed a second time" do
      t = fixture(:tenant)
      {:ok, a} = Knowledge.mark_curated(t.id, published(t.id, "A").id, actor_label: "user:admin")
      b = published(t.id, "B")
      flag = system_flag(t.id, a, b, 0.99)
      refute Knowledge.authoritative_curated?(a, t.id)

      assert {:ok, %ConflictResolution{}} = judge(t.id, a, b)
      assert Knowledge.authoritative_curated?(a, t.id)

      # Retracted, then re-raised by the nightly sweep AFTER the verdict was recorded.
      AdminRepo.delete!(flag)
      system_flag(t.id, a, b, 0.99)

      assert Knowledge.authoritative_curated?(a, t.id),
             "nothing would ever release it: the drain reads the pair as judged"

      # It is back in the QUEUE, which is where a reviewer picks it up.
      assert %{meta: %{total_count: 1}} = Knowledge.list_potential_conflicts(t.id)
    end

    test "an agent cannot assert a conflict over an article it cannot see" do
      t = fixture(:tenant)
      mine = published(t.id, "mine", %{"visibility" => "shared"})
      theirs = published(t.id, "theirs", %{"visibility" => "private", "agent_id" => "other"})

      assert {:error, :article_not_visible} =
               assert_pair(t.id, mine, theirs, @asserter ++ [visibility_agent_id: "me"])
    end

    test "an assertion never overwrites a system flag's provenance" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      system_flag(t.id, a, b, 0.97)

      assert {:ok, link, :existing} = assert_pair(t.id, a, b)
      assert link.metadata["auto_generated"] == true
      refute link.metadata["asserted"]
      assert link_count(t.id) == 1
    end

    test "asserting the same pair twice is idempotent, in either direction" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")

      assert {:ok, first, :created} = assert_pair(t.id, a, b)
      assert {:ok, again, :existing} = assert_pair(t.id, b, a)
      assert again.id == first.id
      assert link_count(t.id) == 1
    end
  end

  # Defense in depth. `annotate_conflict/3` refuses this at write time, so the row below is
  # constructed directly — the point is that the executor does not depend on the write path
  # having run, which is what "re-validate at execution time that the disposition's author
  # did not create both sides" means. Without this, one future caller reaching
  # ConflictResolution by another route would be enough to bypass the whole separation.
  describe "execution-time re-validation" do
    test "the executor refuses a verdict recorded by the pair's asserter" do
      t = fixture(:tenant)
      winner = published(t.id, "winner")
      loser = published(t.id, "loser")
      assert {:ok, _link, :created} = assert_pair(t.id, winner, loser)

      {src, tgt} = Enum.min_max_by([winner.id, loser.id], & &1)

      %ConflictResolution{tenant_id: t.id}
      |> ConflictResolution.changeset(%{
        source_article_id: src,
        target_article_id: tgt,
        authoritative_article_id: winner.id,
        disposition: :supersede,
        confidence: :high,
        classification: :contradictory,
        evidence: "recorded by the asserter, bypassing annotate_conflict/3",
        # The SAME audit label the assertion stamped — this is the identity the executor
        # compares, since the resolution row carries no principal column.
        annotated_by: "agent:corrector",
        annotated_by_role: "orchestrator",
        annotated_at: DateTime.utc_now()
      })
      |> AdminRepo.insert!()

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)

      row = AdminRepo.get_by(ConflictResolution, tenant_id: t.id)
      refute is_nil(row.executed_at), "the refused row must be closed, never left pending"
      assert row.execution_result["reason"] == "self_asserted_conflict"
      assert AdminRepo.get(Loopctl.Knowledge.Article, loser.id).status == :published
    end

    # `verdict_by_principal` carries only the LAST verdict recorded through
    # `annotate_conflict/3`, so an EARLIER legitimate verdict leaves a non-nil principal on
    # the flag. Deciding on the principals alone in that state makes the label comparison
    # unreachable exactly when the backstop is needed.
    test "an earlier legitimate verdict does not disable the audit-label backstop" do
      t = fixture(:tenant)
      winner = published(t.id, "winner")
      loser = published(t.id, "loser")
      assert {:ok, _link, :created} = assert_pair(t.id, winner, loser)
      assert {:ok, %ConflictResolution{}} = judge(t.id, winner, loser)

      # The ASSERTER now overwrites the verdict by some other route (the row is a
      # last-write-wins upsert on the pair) — the alternate-route write this exists for.
      AdminRepo.get_by(ConflictResolution, tenant_id: t.id)
      |> Ecto.Changeset.change(%{
        disposition: :supersede,
        confidence: :high,
        authoritative_article_id: winner.id,
        annotated_by: "agent:corrector",
        annotated_by_role: "orchestrator",
        annotated_at: DateTime.utc_now(),
        executed_at: nil,
        execution_result: %{}
      })
      |> AdminRepo.update!()

      assert 0 == Knowledge.execute_conflict_resolutions(t.id)

      row = AdminRepo.get_by(ConflictResolution, tenant_id: t.id)
      assert row.execution_result["reason"] == "self_asserted_conflict"
      assert AdminRepo.get(Loopctl.Knowledge.Article, loser.id).status == :published
    end
  end

  # The principal alone cannot hold two DISPATCH keys of one operator apart: v2 mints a key
  # per dispatch, so the ids differ. The lineage is what decides, and it decides the same way
  # the L4 custody gates do — a shared root-to-leaf CHAIN is one party, siblings are two.
  describe "assert_conflict/3 — dispatch lineage separation" do
    test "a descendant dispatch cannot judge the pair, a sibling can" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")
      root = Ecto.UUID.generate()
      asserting = Ecto.UUID.generate()

      assert {:ok, _link, :created} =
               assert_pair(t.id, a, b, @asserter ++ [actor_lineage: [root, asserting]])

      assert {:error, :self_asserted_conflict} =
               judge(t.id, a, b, actor_lineage: [root, asserting, Ecto.UUID.generate()])

      # A SIBLING is separation. Comparing the lineage ROOT instead would collapse every
      # dispatch-minted key in the documented single-root tenant into one party, and the
      # pair could never be judged by anything but the raw operator key.
      assert {:ok, %ConflictResolution{}} =
               judge(t.id, a, b, actor_lineage: [root, Ecto.UUID.generate()])
    end

    test "a caller with no lineage — the tenant operator key — may judge" do
      t = fixture(:tenant)
      a = published(t.id, "A")
      b = published(t.id, "B")

      assert {:ok, _link, :created} =
               assert_pair(t.id, a, b, @asserter ++ [actor_lineage: [Ecto.UUID.generate()]])

      assert {:ok, %ConflictResolution{}} = judge(t.id, a, b)
    end
  end

  # The budget bounds how many pairs one principal may OPEN. A call that opens nothing is
  # not what it is bounding, and refusing one breaks the idempotency this endpoint documents
  # for exactly the caller who needs it — a client retrying after a timeout.
  describe "assert_conflict/3 — open-assertion budget" do
    test "at the cap a re-assert is still idempotent while a NEW pair is refused" do
      t = fixture(:tenant)
      articles = for i <- 1..8, do: published(t.id, "cap-#{i}")

      pairs =
        for {x, i} <- Enum.with_index(articles),
            y <- Enum.drop(articles, i + 1),
            do: {x, y}

      [{held_a, held_b} | _] = Enum.take(pairs, 25)

      for {x, y} <- Enum.take(pairs, 25) do
        assert {:ok, _link, :created} = assert_pair(t.id, x, y)
      end

      assert {:ok, _existing, :existing} = assert_pair(t.id, held_a, held_b)

      {new_a, new_b} = Enum.at(pairs, 25)
      assert {:error, :too_many_open_assertions} = assert_pair(t.id, new_a, new_b)
    end
  end

  describe "tenant isolation" do
    test "a conflict asserted in tenant A is invisible to tenant B" do
      a_tenant = fixture(:tenant)
      b_tenant = fixture(:tenant)
      x = published(a_tenant.id, "X")
      y = published(a_tenant.id, "Y")
      assert {:ok, _link, :created} = assert_pair(a_tenant.id, x, y)

      assert %{data: [], meta: %{total_count: 0}} =
               Knowledge.list_potential_conflicts(b_tenant.id)

      # And tenant B cannot reach the pair to judge it either.
      assert {:error, :no_potential_conflict} =
               Knowledge.annotate_conflict(
                 b_tenant.id,
                 %{
                   "source_article_id" => x.id,
                   "target_article_id" => y.id,
                   "disposition" => "dismiss"
                 },
                 @judge
               )
    end

    test "articles from two different tenants cannot be asserted against each other" do
      a_tenant = fixture(:tenant)
      b_tenant = fixture(:tenant)
      mine = published(a_tenant.id, "mine")
      theirs = published(b_tenant.id, "theirs")

      assert {:error, %Ecto.Changeset{} = changeset} = assert_pair(a_tenant.id, mine, theirs)
      assert "does not exist in this tenant" in errors_on(changeset).target_article_id
    end
  end
end
