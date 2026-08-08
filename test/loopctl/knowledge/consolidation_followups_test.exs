defmodule Loopctl.Knowledge.ConsolidationFollowupsTest do
  @moduledoc """
  The #615/#616 review follow-ups on the consolidation pass (issue #617).

  Each describe block pins ONE of them, written against the failure it prevents
  rather than against the shape of the code.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.Knowledge.ConsolidationProposal

  # Published articles are written draft-then-update so the inline embedding -> linking
  # cascade never fires: every signal exercised here is lexical, never vector.
  defp published(tenant_id, attrs) do
    base = %{category: :pattern, tags: [], body: "Body #{System.unique_integer([:positive])}."}

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp status(id), do: AdminRepo.get!(Article, id).status

  defp retitle!(article, title) do
    article |> Ecto.Changeset.change(%{title: title}) |> AdminRepo.update!()
  end

  # Genuine duplicates get identical vectors (cosine 1.0) so the #616 corroboration gate
  # is not what these tests end up measuring.
  defp corroborate_all!(tenant_id) do
    vector = List.duplicate(0.1, 1536)

    Article
    |> where([a], a.tenant_id == ^tenant_id)
    |> AdminRepo.all()
    |> Enum.each(fn a ->
      {:ok, _} = Loopctl.Knowledge.update_embedding(tenant_id, a.id, vector, nil)
    end)
  end

  defp confirm_over_two_nights(tenant_id) do
    corroborate_all!(tenant_id)
    {:ok, _} = Consolidation.run(tenant_id, day: Date.add(Date.utc_today(), -1))
    {:ok, _} = Consolidation.run(tenant_id)
  end

  defp proposal_count(tenant_id) do
    ConsolidationProposal
    |> where([p], p.tenant_id == ^tenant_id)
    |> AdminRepo.aggregate(:count)
  end

  describe "prune_proposals — the tenant predicate on a BYPASSRLS delete_all (#617 item 1)" do
    test "withdrawing one tenant's stale proposals never touches another tenant's rows" do
      # This is an AdminRepo `delete_all`, so RLS is bypassed and the WHERE clause is the
      # entire tenant boundary. `report_id` implies the tenant today; the predicate is
      # explicit so that implication is not the only thing standing between a re-run and
      # another tenant's data.
      a = fixture(:tenant)
      b = fixture(:tenant)

      published(a.id, %{title: "Shared Doc", body: "one"})
      published(a.id, %{title: "shared doc!", body: "two"})
      published(b.id, %{title: "Neighbour Doc", body: "one"})
      published(b.id, %{title: "neighbour doc!", body: "two"})

      {:ok, _} = Consolidation.run(a.id)
      {:ok, _} = Consolidation.run(b.id)

      assert proposal_count(a.id) > 0
      before_b = proposal_count(b.id)
      assert before_b > 0

      # Dissolve tenant A's only group, then re-run: A's proposal is withdrawn, B's stands.
      Article
      |> where([x], x.tenant_id == ^a.id)
      |> AdminRepo.all()
      |> Enum.with_index()
      |> Enum.each(fn {article, i} -> retitle!(article, "Distinct A Title #{i}") end)

      {:ok, _} = Consolidation.run(a.id)

      assert proposal_count(a.id) == 0
      assert proposal_count(b.id) == before_b
    end
  end

  describe ":max_per_class clamping (#617 item 4)" do
    test "a non-integer cap falls back to the DEFAULT, not to the hard ceiling" do
      # A number sorts BELOW every atom and binary in Erlang term order, so the old
      # `max(1) |> min(500)` resolved a config typo to 500 — the largest report available —
      # rather than to the intended 100.
      tenant = fixture(:tenant)
      for i <- 1..3, do: published(tenant.id, %{title: "Untitled #{i}", body: "b"})

      {:ok, typo} = Consolidation.analyze(tenant.id, max_per_class: "2")
      {:ok, default} = Consolidation.analyze(tenant.id)

      assert typo.summary.max_per_class == Consolidation.default_max_per_class()
      assert typo.summary.max_per_class == default.summary.max_per_class
      refute typo.summary.max_per_class == Consolidation.hard_max_per_class()
    end

    test "an integer cap is still honoured and still clamped to the ceiling" do
      tenant = fixture(:tenant)
      for i <- 1..3, do: published(tenant.id, %{title: "Untitled #{i}", body: "b"})

      assert {:ok, %{summary: %{max_per_class: 2}}} =
               Consolidation.analyze(tenant.id, max_per_class: 2)

      assert {:ok, %{summary: %{max_per_class: cap}}} =
               Consolidation.analyze(tenant.id, max_per_class: 10_000)

      assert cap == Consolidation.hard_max_per_class()
    end
  end

  describe "duplicate-group member cap (#617 item 5)" do
    test "a group larger than the member cap is truncated, and truncated IDENTICALLY twice" do
      # Determinism is what makes truncating safe: `fingerprint/2` hashes the sorted id set
      # and the two-run gate confirms only a repeated fingerprint, so a group that truncated
      # differently on two nights could never be confirmed — it would sit in the report
      # forever while appearing actionable.
      tenant = fixture(:tenant)

      # Verbatim-distinct (the exact active-title unique index forbids duplicates) but
      # normalizing to ONE key — which is exactly the collision class this pass exists for:
      # the punctuation is stripped and the result trimmed.
      for i <- 1..60 do
        published(tenant.id, %{
          title: "Bulk Collide Doc" <> String.duplicate("!", i),
          body: "member #{i}"
        })
      end

      {:ok, first} = Consolidation.analyze(tenant.id)
      {:ok, second} = Consolidation.analyze(tenant.id)

      [dup] = Enum.filter(first.proposals, &(&1.proposal_class == :duplicate_capture))
      [dup2] = Enum.filter(second.proposals, &(&1.proposal_class == :duplicate_capture))

      assert length(dup.article_ids) == 50
      assert dup.article_ids == dup2.article_ids
      assert dup.fingerprint == dup2.fingerprint
      assert length(dup.evidence) == length(dup.article_ids)
    end

    test "member truncation is REPORTED, not just logged" do
      # `truncated` is the operator-facing answer to "did this class see the whole
      # picture". Derived from group counts alone it read `false` while the proposal
      # silently omitted 10 members and its evidence array came up short.
      tenant = fixture(:tenant)

      for i <- 1..60 do
        published(tenant.id, %{title: "Cut Report Doc" <> String.duplicate("!", i), body: "b"})
      end

      assert {:ok, %{summary: %{truncated: %{"duplicate_capture" => true}}}} =
               Consolidation.analyze(tenant.id)

      # One group, well under the per-class cap: nothing GROUP-level was truncated, so the
      # flag can only be coming from the member cap.
      assert {:ok, %{summary: %{by_class: %{"duplicate_capture" => 1}}}} =
               Consolidation.analyze(tenant.id)
    end
  end

  describe "the apply-time re-check of the GROUPING signal (#617 / handoff gap)" do
    test "a title-drift group whose members were RETITLED is skipped, not applied" do
      # The liveness re-check proves the members are still published; it does NOT prove they
      # still collide. Retitling is the one remedy a human has for a false grouping — it is
      # what was done to 23 articles on 2026-08-06 to stop three unrelated `Changelog`
      # documents being auto-unpublished — and every one of those articles stayed live.
      tenant = fixture(:tenant)

      keep = published(tenant.id, %{title: "Changelog", body: String.duplicate("long ", 40)})
      other = published(tenant.id, %{title: "changelog!", body: "short"})

      confirm_over_two_nights(tenant.id)

      # The human fix lands AFTER the proposal was confirmed but BEFORE the apply.
      retitle!(other, "Changelog for the oauth2 library")

      assert %{applied: 0, skipped: 1, failed: 0} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(keep.id) == :published
      assert status(other.id) == :published
    end

    test "a group ARCHIVED down to two is skipped — a shrink is a remedy too, not just a retitle" do
      # Retitling SPLITS a group, so the subgroup check catches it. Archiving members (or
      # making them private) SHRINKS it without splitting, and the survivors still share
      # one title — so the pass would auto-unpublish on a two-id fingerprint no report ever
      # carried, on the night an operator hid the rest.
      tenant = fixture(:tenant)

      keep = published(tenant.id, %{title: "Shrunk Doc", body: String.duplicate("long ", 40)})
      stays = published(tenant.id, %{title: "shrunk doc.", body: "stays"})

      hidden =
        for i <- 1..3 do
          published(tenant.id, %{title: "Shrunk Doc" <> String.duplicate("!", i), body: "h"})
        end

      confirm_over_two_nights(tenant.id)

      Enum.each(hidden, fn a ->
        a |> Ecto.Changeset.change(%{status: :archived}) |> AdminRepo.update!()
      end)

      assert %{applied: 0, skipped: 1} = Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(keep.id) == :published
      assert status(stays.id) == :published
    end

    test "a group that SPLIT into two collisions is skipped whole rather than half-applied" do
      # The persisted proposal describes ONE collision; the corpus now holds two. Applying
      # the larger half would unpublish on grounds the proposal never asserted.
      tenant = fixture(:tenant)

      a1 = published(tenant.id, %{title: "Split Doc", body: String.duplicate("aaa ", 40)})
      a2 = published(tenant.id, %{title: "split doc!", body: "a2"})
      a3 = published(tenant.id, %{title: "SPLIT DOC.", body: "a3"})
      a4 = published(tenant.id, %{title: "Split  Doc", body: "a4"})

      confirm_over_two_nights(tenant.id)

      retitle!(a3, "Renamed Pair Doc")
      retitle!(a4, "renamed pair doc!")

      assert %{applied: 0, skipped: 1} = Consolidation.apply_confirmed_duplicates(tenant.id)

      for a <- [a1, a2, a3, a4], do: assert(status(a.id) == :published)
    end

    test "a group PARTLY retitled is skipped whole, not applied to the remnant" do
      # The two-run gate confirmed the FIVE-id fingerprint. Retitling three of them is a
      # human saying "these are not one capture"; auto-unpublishing the two left over
      # completes a partial remedy the same night it was made, on a set nothing confirmed.
      tenant = fixture(:tenant)

      keep = published(tenant.id, %{title: "Partial Doc", body: String.duplicate("long ", 40)})
      stays = published(tenant.id, %{title: "partial doc.", body: "stays"})

      moved =
        for i <- 1..3 do
          published(tenant.id, %{title: "Partial Doc" <> String.duplicate("!", i), body: "m"})
        end

      confirm_over_two_nights(tenant.id)

      Enum.each(Enum.with_index(moved), fn {a, i} -> retitle!(a, "Unrelated Title #{i}") end)

      assert %{applied: 0, skipped: 1} = Consolidation.apply_confirmed_duplicates(tenant.id)

      for a <- [keep, stays | moved], do: assert(status(a.id) == :published)
    end

    test "an intact title-drift group still applies — the re-check is not a blanket block" do
      # The guard has to be discriminating, or it silently turns the whole auto-apply class
      # off while the run keeps reporting `gate: :open`.
      tenant = fixture(:tenant)

      winner = published(tenant.id, %{title: "Intact Doc", body: String.duplicate("long ", 40)})
      loser = published(tenant.id, %{title: "intact doc!", body: "short"})

      confirm_over_two_nights(tenant.id)

      assert %{applied: 1, skipped: 0, failed: 0} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(winner.id) == :published
      assert status(loser.id) == :draft
    end

    test "an IDEMPOTENCY-drift group is judged on its key, never on its titles" do
      # These members collide on a writer-supplied key and have no reason to share a title.
      # Re-checking titles here would reject every group in the class — a guard that reads
      # as working while disabling the signal it guards.
      tenant = fixture(:tenant)
      key = "session:AB12-#{System.unique_integer([:positive])}"

      winner =
        published(tenant.id, %{
          title: "Idempotency Winner",
          body: String.duplicate("long ", 40),
          idempotency_key: key
        })

      loser =
        published(tenant.id, %{
          title: "A Completely Different Title",
          body: "short",
          idempotency_key: String.replace(key, ":", "-")
        })

      confirm_over_two_nights(tenant.id)

      assert %{applied: 1, skipped: 0, failed: 0} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(winner.id) == :published
      assert status(loser.id) == :draft
    end

    test "a group retitled onto PLACEHOLDER titles does not re-collide as a duplicate" do
      # `title_drift_groups/1` excludes placeholder titles on purpose — "Draft" collides with
      # "Draft" for reasons that have nothing to do with being the same capture, and
      # `:generic_title` is the class that owns them. The apply-time re-check must exclude
      # them too, or a retitle-to-placeholder would auto-unpublish on a signal the scan
      # deliberately refuses to raise.
      tenant = fixture(:tenant)

      a = published(tenant.id, %{title: "Placeholder Doc", body: String.duplicate("long ", 40)})
      b = published(tenant.id, %{title: "placeholder doc!", body: "short"})

      confirm_over_two_nights(tenant.id)

      retitle!(a, "Draft")
      retitle!(b, "draft")

      assert %{applied: 0, skipped: 1} = Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(a.id) == :published
      assert status(b.id) == :published
    end
  end

  describe "the corroboration gate refuses PREFIX vectors (#617 round 2)" do
    test "a member whose vector covers only a prefix is missing evidence, not evidence" do
      # The shrink ladder embeds an over-long body as its OPENING only. Two unrelated
      # captures that share a boilerplate opening (CHANGELOG/API-doc headers — the exact
      # population this gate was added for) then score near 1.0 against each other, and the
      # content check that exists to stop unrelated same-titled articles being
      # auto-unpublished would be satisfied by two truncations. A marked vector therefore
      # drops out of scoring and the whole group is withheld.
      tenant = fixture(:tenant)

      keep = published(tenant.id, %{title: "Prefix Doc", body: String.duplicate("long ", 40)})
      other = published(tenant.id, %{title: "prefix doc!", body: "short"})

      confirm_over_two_nights(tenant.id)

      mark_prefix_embedded!(tenant.id, other.id)

      assert %{applied: 0, uncorroborated: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert status(keep.id) == :published
      assert status(other.id) == :published
    end
  end

  # `corroborate_all!/1` stores whole-text hashes; this re-marks ONE of them the way the
  # ladder's storing callers do when they could only embed a prefix.
  defp mark_prefix_embedded!(tenant_id, id) do
    Article
    |> where([a], a.tenant_id == ^tenant_id and a.id == ^id)
    |> AdminRepo.update_all(set: [embedding_content_hash: ShrinkLadder.truncated_hash("abc")])
  end

  describe "generic_titles — count and page are separate queries (#617 item 6)" do
    test "the reported total counts the whole matching set while only the cap is fetched" do
      # The `truncated` flag is derived from `total > length(items)`, so replacing the
      # load-everything-then-take with count+limit must not quietly change what `total` means.
      tenant = fixture(:tenant)
      for i <- 1..5, do: published(tenant.id, %{title: "Untitled #{i}", body: "b"})

      {:ok, capped} = Consolidation.analyze(tenant.id, max_per_class: 2)

      assert capped.summary.by_class["generic_title"] == 5
      assert Enum.count(capped.proposals, &(&1.proposal_class == :generic_title)) == 2
      assert capped.summary.truncated["generic_title"] == true

      {:ok, whole} = Consolidation.analyze(tenant.id, max_per_class: 50)

      assert whole.summary.by_class["generic_title"] == 5
      assert Enum.count(whole.proposals, &(&1.proposal_class == :generic_title)) == 5
      assert whole.summary.truncated["generic_title"] == false
    end

    test "the capped page is the OLDEST matches, deterministically" do
      tenant = fixture(:tenant)
      for i <- 1..4, do: published(tenant.id, %{title: "Untitled #{i}", body: "b"})

      {:ok, first} = Consolidation.analyze(tenant.id, max_per_class: 2)
      {:ok, second} = Consolidation.analyze(tenant.id, max_per_class: 2)

      ids = fn r ->
        r.proposals
        |> Enum.filter(&(&1.proposal_class == :generic_title))
        |> Enum.map(& &1.article_ids)
      end

      assert ids.(first) == ids.(second)
    end
  end

  describe "validate_similarity/1 — the threshold cannot be set to a value that disables the gate" do
    test "0 falls back to the default instead of admitting every pair" do
      # The gate is `min_sim >= threshold`, so 0.0 is satisfied by EVERY pair — including a
      # cosine of 0. The only content check on the only self-applying class would be fully
      # OFF, silently, while every run still reported `gate: :open` and unpublished. 0 is
      # also the exact value an operator reaches for meaning "off", because on the sibling
      # drain caps 0 IS a pause. The DB percent path already refused it; this path did not.
      for off <- [0, 0.0] do
        assert Consolidation.validate_similarity(off) == 0.80
      end
    end

    test "1.0 and above DISABLE the class instead of quietly re-enabling it at 0.80" do
      # An impossible threshold has exactly one reading: an operator shutting the
      # auto-applying class down without a deploy. Falling back to the default did the
      # OPPOSITE of what was asked — it re-enabled auto-unpublish at 0.80 on the knob just
      # set to stop it. 1.0 itself lands here rather than being honoured verbatim, because
      # identical vectors score exactly 1.0 and would still be unpublished.
      for disable <- [1, 1.0, 2.0, 100] do
        assert Consolidation.validate_similarity(disable) > 1.0
      end
    end

    test "a legitimate in-range threshold is honoured, as a float" do
      # The guard has to discriminate, or it silently pins the threshold at the default and
      # an operator's tuning does nothing.
      assert Consolidation.validate_similarity(0.68) == 0.68
      assert Consolidation.validate_similarity(0.95) == 0.95
    end

    test "a non-number still falls back, and never sorts its way past the bound" do
      # A number sorts BELOW every atom and binary in Erlang term order, so a comparison
      # guard alone would let `nil` or `"0.8"` through as "greater than 0".
      for bad <- [nil, "0.8", :off, %{}] do
        assert Consolidation.validate_similarity(bad) == 0.80
      end
    end
  end

  describe "a withhold that can never clear does not churn nightly" do
    test "a tenant with NO embedding key enqueues no backfill at all" do
      # Mandatory BYO: every backfill job such a tenant enqueues is discarded
      # `{:no_embedding_key, _}` on pickup. The pass used to enqueue them every night
      # forever while logging "backfill enqueued", so a PERMANENT withhold read as a
      # transient gap and the drain converged to a floor.
      tenant = fixture(:tenant)
      a = published(tenant.id, %{title: "Keyless Doc", body: String.duplicate("long ", 40)})
      b = published(tenant.id, %{title: "keyless doc!", body: "short"})

      # `a` is embedded, `b` is not — so `b` is the unscored member that would be backfilled.
      embed!(tenant.id, a.id, List.duplicate(0.1, 1536))

      confirm_over_two_nights_no_corroborate(tenant.id)

      assert %{applied: 0, uncorroborated: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      # Inline Oban would have embedded `b` had a job been enqueued. Nothing was.
      refute embedded?(tenant.id, b.id)
      assert status(a.id) == :published
      assert status(b.id) == :published
    end

    test "a member whose vector is a PREFIX is not enqueued for backfill" do
      # A prefix-marked row is excluded from scoring on purpose (a prefix must never be
      # compared against a whole text), so it lands in `unscored`. But
      # `BatchArticleEmbeddingWorker` compares through `whole_hash/1` and reads a marked
      # row as ALREADY EMBEDDED — so the job did nothing, the gap never closed, and the
      # pass re-enqueued the same dead job every night. Re-embedding cannot help: the text
      # is over the provider's limit, which is WHY it is a prefix.
      tenant = fixture(:tenant)

      {:ok, _} =
        Loopctl.Llm.upsert_settings(tenant.id, %{"embedding_api_key" => "test-openai-embed-pfx"})

      a = published(tenant.id, %{title: "Prefix Doc", body: String.duplicate("long ", 40)})
      b = published(tenant.id, %{title: "prefix doc!", body: "short"})

      embed!(tenant.id, a.id, List.duplicate(0.1, 1536))
      # `b` carries a vector under a TRUNCATION-MARKED hash.
      {:ok, _} =
        Loopctl.Knowledge.update_embedding(
          tenant.id,
          b.id,
          List.duplicate(0.2, 1536),
          ShrinkLadder.truncated_hash("deadbeef")
        )

      confirm_over_two_nights_no_corroborate(tenant.id)

      assert %{applied: 0, uncorroborated: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      # The mark SURVIVES: nothing re-embedded it and erased the prefix marker.
      assert ShrinkLadder.truncated_hash?(stored_hash(tenant.id, b.id))
    end

    test "the keyless notice is logged once per RUN, not once per withheld proposal" do
      # A keyless tenant has no vectors AT ALL, so EVERY confirmed group withholds. Emitted
      # from the per-group backfill path, this one permanent-configuration sentence was
      # repeated per proposal, and a tenant with a standing backlog buried its own nightly
      # log under it.
      tenant = fixture(:tenant)

      for pair <- ["Alpha", "Beta"] do
        published(tenant.id, %{title: pair <> " Doc", body: String.duplicate("long ", 40)})
        published(tenant.id, %{title: String.downcase(pair) <> " doc!", body: "short"})
      end

      confirm_over_two_nights_no_corroborate(tenant.id)

      log =
        capture_log(fn ->
          assert %{applied: 0, uncorroborated: 2} =
                   Consolidation.apply_confirmed_duplicates(tenant.id)
        end)

      assert notices(log, "has no embedding key (mandatory BYO)") == 1
    end

    test "a repo fault while reading backfill evidence is a WITHHOLD, not a phantom failure" do
      # By the time the backfill runs, the group has ALREADY been decided uncorroborated —
      # a normal, correct outcome. An unguarded read there escaped into `tally_apply/5`'s
      # rescue, which reports the group as `failed`: a WRITE that could not be made,
      # counted in loser articles, on a night when no write was ever going to be attempted.
      tenant = fixture(:tenant)

      {:ok, _} =
        Loopctl.Llm.upsert_settings(tenant.id, %{"embedding_api_key" => "test-openai-embed-flt"})

      a = published(tenant.id, %{title: "Faulty Doc", body: String.duplicate("long ", 40)})
      b = published(tenant.id, %{title: "faulty doc!", body: "short"})

      # `a` is scored, `b` is the unscored member whose evidence the backfill goes to read.
      embed!(tenant.id, a.id, List.duplicate(0.1, 1536))
      confirm_over_two_nights_no_corroborate(tenant.id)

      # First read is the scoring pass; the second is the backfill's stored-hash lookup,
      # which faults. Ordered `expect`s, so a change in call order fails loudly here rather
      # than turning the assertions below vacuous — and the log assertions discriminate
      # which of the two reads actually broke.
      Mox.expect(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> false end)

      Mox.expect(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn ->
        raise "embedding read path unavailable"
      end)

      log =
        capture_log(fn ->
          assert %{applied: 0, failed: 0, uncorroborated: 1} =
                   Consolidation.apply_confirmed_duplicates(tenant.id)
        end)

      assert log =~ "could not enqueue the embedding backfill"
      refute log =~ "could not be applied"
      refute log =~ "similarity scoring failed"
      assert status(a.id) == :published
      assert status(b.id) == :published
    end
  end

  defp notices(log, phrase) do
    log |> String.split(phrase) |> length() |> Kernel.-(1)
  end

  # Confirms a group over two nights WITHOUT forcing corroboration, so the tests above
  # measure the gate rather than a helper that pre-satisfies it.
  defp confirm_over_two_nights_no_corroborate(tenant_id) do
    {:ok, _} = Consolidation.run(tenant_id, day: Date.add(Date.utc_today(), -1))
    {:ok, _} = Consolidation.run(tenant_id)
  end

  defp embed!(tenant_id, id, vector),
    do: {:ok, _} = Loopctl.Knowledge.update_embedding(tenant_id, id, vector, nil)

  defp stored_hash(tenant_id, id) do
    Loopctl.Embeddings.article_embedded_hashes(
      tenant_id,
      [id],
      Loopctl.Embeddings.active_dimension(tenant_id)
    )
    |> Map.get(id)
  end

  defp embedded?(tenant_id, id), do: is_binary(stored_hash(tenant_id, id))
end
