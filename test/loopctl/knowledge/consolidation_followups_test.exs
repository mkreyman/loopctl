defmodule Loopctl.Knowledge.ConsolidationFollowupsTest do
  @moduledoc """
  The #615/#616 review follow-ups on the consolidation pass (issue #617).

  Each describe block pins ONE of them, written against the failure it prevents
  rather than against the shape of the code.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

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
end
