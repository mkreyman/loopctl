defmodule Loopctl.Progress.CustodyInvariantsTest do
  @moduledoc """
  Chain-of-custody invariants (docs/chain-of-custody-v2.md §2.1/§2.2, L2):

  * INVARIANT 1 — `reported_done` ⇒ `assigned_agent_id NOT NULL` (or backfilled).
    Enforced structurally by the DB CHECK `stories_reported_done_requires_agent`
    and backstopped by the fail-closed `validate_not_self_verify/2` guard
    (surfaced via `ensure_verify_allowed/2`).

  * INVARIANT 2 — a review record is bound to the report generation it reviewed
    via `reviewed_report_at`. A review of a superseded report no longer qualifies
    at verify time, in BOTH `verify_story/4` and `BulkOperations.bulk_verify/4`.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.BulkOperations
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  # A story that has been genuinely reported_done: assigned agent + reported_done_at.
  defp reported_story(reported_done_at \\ nil) do
    tenant = fixture(:tenant)
    epic = fixture(:epic, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})
    rdt = reported_done_at || now_usec()

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        assigned_agent_id: agent.id,
        assigned_at: now_usec(),
        reported_done_at: rdt
      })
      |> AdminRepo.update!()

    %{tenant: tenant, agent: agent, reviewer: reviewer, story: story}
  end

  defp now_usec, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp seconds_ago(n), do: now_usec() |> DateTime.add(-n, :second)

  defp review_params(summary),
    do: %{"review_type" => "enhanced", "summary" => summary}

  # ------------------------------------------------------------------
  # INVARIANT 1 — reported_done requires an assigned agent
  # ------------------------------------------------------------------

  describe "INVARIANT 1: reported_done requires provenance (DB CHECK)" do
    test "rejects erasing the assigned agent from a DISPATCHED reported_done story" do
      tenant = fixture(:tenant)
      epic = fixture(:epic, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {:ok, %{dispatch: dispatch}} =
        Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

      # A dispatched, reported story: carries an implementer dispatch lineage AND
      # its assigned agent (as claim_story would set them together).
      story =
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          implementer_dispatch_id: dispatch.id,
          reported_done_at: now_usec()
        })
        |> AdminRepo.update!()

      # Erasing the implementer identity while the dispatch lineage remains is the
      # forbidden state (it would let the implementer self-verify vacuously).
      assert_raise Ecto.ConstraintError, ~r/stories_reported_done_requires_agent/, fn ->
        story
        |> Ecto.Changeset.change(%{assigned_agent_id: nil})
        |> AdminRepo.update!()
      end
    end

    test "allows a never-dispatched reported_done story with a NULL assigned_agent_id" do
      # backfill / bulk mark-complete / import all legitimately produce a
      # reported_done story with no assigned agent and NO dispatch lineage. The
      # CHECK permits it (the operation-level guard, tested below, prevents it from
      # being vacuously verified). backfill_story is the representative path.
      tenant = fixture(:tenant)
      epic = fixture(:epic, %{tenant_id: tenant.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      assert {:ok, updated} =
               Progress.backfill_story(tenant.id, story.id, %{
                 "reason" => "completed before loopctl onboarding"
               })

      assert updated.agent_status == :reported_done
      assert is_nil(updated.assigned_agent_id)
      assert is_nil(updated.implementer_dispatch_id)
    end
  end

  describe "INVARIANT 1: self-verify guard fails closed (backstop)" do
    test "ensure_verify_allowed/2 rejects a custody-orphaned story with :missing_assigned_agent" do
      orphan = %Story{
        tenant_id: Ecto.UUID.generate(),
        agent_status: :reported_done,
        verified_status: :unverified,
        assigned_agent_id: nil,
        implementer_dispatch_id: nil,
        verifier_dispatch_id: nil
      }

      # A non-nil verifier would otherwise "!= nil implementer" and pass VACUOUSLY.
      assert {:error, :missing_assigned_agent} =
               Progress.ensure_verify_allowed(orphan, Ecto.UUID.generate())
    end

    test "ensure_verify_allowed/2 still separates verifier from a real assigned agent" do
      implementer = Ecto.UUID.generate()

      story = %Story{
        tenant_id: Ecto.UUID.generate(),
        agent_status: :reported_done,
        verified_status: :unverified,
        assigned_agent_id: implementer,
        implementer_dispatch_id: nil,
        verifier_dispatch_id: nil
      }

      assert :ok = Progress.ensure_verify_allowed(story, Ecto.UUID.generate())
      assert {:error, :self_verify_blocked} = Progress.ensure_verify_allowed(story, implementer)
    end

    test "verify_story/4 fails closed on a persisted custody-orphaned story" do
      # An import-shaped orphan (reported_done + unverified + NULL-agent +
      # NULL-dispatch) is permitted by the scoped CHECK but must not be verifiable:
      # the self-verify check would otherwise pass vacuously.
      tenant = fixture(:tenant)
      epic = fixture(:epic, %{tenant_id: tenant.id})

      story =
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          verified_status: :unverified,
          reported_done_at: now_usec()
        })
        |> AdminRepo.update!()

      orchestrator = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      assert {:error, :missing_assigned_agent} =
               Progress.verify_story(tenant.id, story.id, %{"summary" => "x"},
                 orchestrator_agent_id: orchestrator.id
               )
    end

    test "record_review fails closed on a custody-orphaned story" do
      # A reported_done + unverified + NULL-agent + NULL-dispatch story (import-
      # shaped): permitted by the scoped CHECK, but must NOT be reviewable — there
      # is no known implementer to separate the reviewer from.
      tenant = fixture(:tenant)
      epic = fixture(:epic, %{tenant_id: tenant.id})

      story =
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          verified_status: :unverified,
          reported_done_at: now_usec()
        })
        |> AdminRepo.update!()

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      assert {:error, :missing_assigned_agent} =
               Progress.record_review(tenant.id, story.id, review_params("x"),
                 reviewer_agent_id: reviewer.id
               )
    end
  end

  describe "INVARIANT 1: legitimate flow still verifies" do
    test "a reported_done story with an assigned agent + independent review verifies" do
      %{tenant: tenant, story: story, reviewer: reviewer} = reported_story()

      assert {:ok, _} =
               Progress.record_review(tenant.id, story.id, review_params("ok"),
                 reviewer_agent_id: reviewer.id
               )

      assert {:ok, updated} =
               Progress.verify_story(tenant.id, story.id, %{"summary" => "good"},
                 orchestrator_agent_id: reviewer.id
               )

      assert updated.verified_status == :verified
    end
  end

  # ------------------------------------------------------------------
  # INVARIANT 2 — review bound to the report generation it reviewed
  # ------------------------------------------------------------------

  describe "INVARIANT 2: reviewed_report_at snapshot" do
    test "record_review snapshots the story's current reported_done_at" do
      t1 = seconds_ago(100)
      %{tenant: tenant, story: story, reviewer: reviewer} = reported_story(t1)

      assert {:ok, rr} =
               Progress.record_review(tenant.id, story.id, review_params("gen1"),
                 reviewer_agent_id: reviewer.id
               )

      assert DateTime.compare(rr.reviewed_report_at, t1) == :eq
    end
  end

  describe "INVARIANT 2: verify_story requires the review to match the current report" do
    test "verifies when the review matches the current generation" do
      t1 = seconds_ago(100)
      %{tenant: tenant, story: story, reviewer: reviewer} = reported_story(t1)

      {:ok, _} =
        Progress.record_review(tenant.id, story.id, review_params("gen1"),
          reviewer_agent_id: reviewer.id
        )

      assert {:ok, updated} =
               Progress.verify_story(tenant.id, story.id, %{"summary" => "ok"},
                 orchestrator_agent_id: reviewer.id
               )

      assert updated.verified_status == :verified
    end

    test "blocks verify when the story was re-reported after the review (stale generation)" do
      t1 = seconds_ago(100)
      %{tenant: tenant, story: story, reviewer: reviewer} = reported_story(t1)

      # Review of generation T1. completed_at defaults to ~now, which is LATER
      # than the T2 we re-report to below — so the secondary completed_at >
      # reported_done_at guard still PASSES and only the reviewed_report_at
      # binding can block. This isolates INVARIANT 2.
      {:ok, _} =
        Progress.record_review(tenant.id, story.id, review_params("gen1"),
          reviewer_agent_id: reviewer.id
        )

      # Re-report: reported_done_at advances to T2 (T1 < T2 < review.completed_at).
      t2 = seconds_ago(50)

      story
      |> Ecto.Changeset.change(%{reported_done_at: t2})
      |> AdminRepo.update!()

      assert {:error, :review_not_conducted} =
               Progress.verify_story(tenant.id, story.id, %{"summary" => "try"},
                 orchestrator_agent_id: reviewer.id
               )

      # A fresh review of generation T2 re-qualifies.
      {:ok, _} =
        Progress.record_review(tenant.id, story.id, review_params("gen2"),
          reviewer_agent_id: reviewer.id
        )

      assert {:ok, updated} =
               Progress.verify_story(tenant.id, story.id, %{"summary" => "ok"},
                 orchestrator_agent_id: reviewer.id
               )

      assert updated.verified_status == :verified
    end
  end

  describe "INVARIANT 2: bulk_verify enforces the same binding" do
    test "bulk_verify blocks a stale-generation review and passes after re-review" do
      t1 = seconds_ago(100)
      %{tenant: tenant, story: story, reviewer: reviewer} = reported_story(t1)

      {:ok, _} =
        Progress.record_review(tenant.id, story.id, review_params("gen1"),
          reviewer_agent_id: reviewer.id
        )

      t2 = seconds_ago(50)

      story
      |> Ecto.Changeset.change(%{reported_done_at: t2})
      |> AdminRepo.update!()

      entry = %{"story_id" => story.id, "summary" => "bulk", "review_type" => "enhanced"}

      assert {:ok, [stale]} = BulkOperations.bulk_verify(tenant.id, [entry], reviewer.id)
      assert stale.status == "error"
      assert stale.reason =~ "review"

      {:ok, _} =
        Progress.record_review(tenant.id, story.id, review_params("gen2"),
          reviewer_agent_id: reviewer.id
        )

      assert {:ok, [ok_result]} = BulkOperations.bulk_verify(tenant.id, [entry], reviewer.id)
      assert ok_result.status == "success"
    end
  end

  describe "INVARIANT 2: tenant isolation of the review-record check" do
    test "a review record in another tenant does not satisfy verify" do
      t1 = seconds_ago(100)
      %{tenant: tenant_b, story: story_b} = reported_story(t1)

      other_tenant = fixture(:tenant)

      # A review row in ANOTHER tenant that, if tenant scoping were broken, would
      # match story_b's current generation exactly.
      %ReviewRecord{
        tenant_id: other_tenant.id,
        story_id: story_b.id,
        review_type: "enhanced",
        summary: "cross-tenant",
        completed_at: now_usec(),
        reviewed_report_at: story_b.reported_done_at
      }
      |> AdminRepo.insert!()

      orch_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      assert {:error, :review_not_conducted} =
               Progress.verify_story(tenant_b.id, story_b.id, %{"summary" => "x"},
                 orchestrator_agent_id: orch_b.id
               )
    end
  end
end
