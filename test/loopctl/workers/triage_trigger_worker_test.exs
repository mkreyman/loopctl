defmodule Loopctl.Workers.TriageTriggerWorkerTest do
  @moduledoc """
  The drainer that gives `Loopctl.Delivery.TriageTrigger.promote/1` a production caller
  (#803 §2/§4).

  `promote/1` straddles BOTH repos — it creates the story through `AdminRepo` and opens the
  stage on the RLS `Loopctl.Repo` — and AdminRepo shares Repo's sandbox connection in test,
  so every row here is sandboxed and the module runs async. The cron run's candidate read is
  FLEET-WIDE, and inside a sandbox transaction that fleet is this test's rows plus whatever
  is committed, so a run here drains its OWN tenant (`drain/1`'s `:tenant_id`): a committed
  `pending_triage` row is neither promoted by this test nor able to take its batch slots.

  The one test whose subject needs a SECOND session, a story row another connection holds
  `FOR UPDATE` while the run opens its stage, is `Loopctl.Workers.TriageTriggerWorkerLockTest`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.TriageTriggerWorker

  setup :verify_on_exit!

  setup do
    %{tenant: fixture(:tenant, %{trust_tier: :agent_rooted})}
  end

  describe "drain/1" do
    test "a pending record becomes a story the delivery loop can see", %{tenant: tenant} do
      {source, record} = fixture(:intake_pair, %{tenant_id: tenant.id, issue_number: 412})

      assert :ok = run(tenant)

      # All three bindings, because each is a different half of "the loop can see it": the link
      # is how triage finds its record back, the epic is where a human looks for it, and the
      # stage row is the only thing `Loopctl.Delivery.Placement` selects on.
      story = story_for(record.id)
      assert story.epic_id == source.target_epic_id
      assert Stages.get(tenant.id, story.id).stage == :detected

      # Promotion is not triage. The record stays in the queue triage consumes, and a
      # successful promote is not an escalation.
      assert %Record{status: :pending_triage, escalation_reasons: []} = reload(record)
    end

    test "a source naming no target epic RETRIES, and recovers when the source is repointed",
         %{tenant: tenant} do
      {source, record} =
        fixture(:intake_pair, %{tenant_id: tenant.id, target_epic_id: nil})

      assert :ok = run(tenant)

      # NOT escalated, and this is the correction of the worst defect in this worker.
      # Escalation is terminal — nothing un-escalates, and `candidates/0` requires
      # `:pending_triage` — while `target_epic_id` is nullable precisely so that sources
      # enrolled before the column existed keep working. Escalating here would have burned
      # every record of every pre-migration source, fleet-wide, within one minute of deploy.
      record = reload(record)
      assert record.status == :pending_triage
      assert record.escalation_reasons == []
      assert record.escalated_at == nil
      assert story_for(record.id) == nil

      # And the recovery is a real one, through the API rather than through SQL: naming the
      # epic promotes the waiting record on the very next run, with nothing lost.
      #
      # The NUMBER is bounded, for the reason `fixture(:intake_pair, ...)` states at length:
      # `build(:epic)` numbers from a raw `System.unique_integer/1`, which is small when this
      # file runs alone and six or seven digits in a full suite — and a story number is
      # `EPIC.SEQUENCE` with both parts under 10_000, so an epic above that makes every story
      # in it unnumberable. This test passed alone and failed in the suite on exactly that:
      # the recovery run escalated `:epic_number_unnumberable` instead of promoting.
      epic =
        fixture(:epic, %{
          tenant_id: tenant.id,
          project_id: source.project_id,
          number: rem(System.unique_integer([:positive]), 9_000) + 1
        })

      {:ok, _} = Intake.repoint_source(tenant.id, source.id, epic.id)

      assert :ok = run(tenant)

      assert story = story_for(record.id)
      assert story.epic_id == epic.id
    end

    test "an epic numbered past the story-number ceiling escalates too", %{tenant: tenant} do
      {_source, record} =
        fixture(:intake_pair, %{tenant_id: tenant.id, epic_number: 10_000})

      # The second shape of "a human must change data": the operator's remedy is to renumber
      # the epic. Asserted alongside `:no_target_epic` because the two reach the escalation
      # through different clauses of `promote/1` and only one of them is in the happy path of
      # the fixture.
      assert :ok = run(tenant)

      record = reload(record)
      assert record.status == :escalated
      assert "triage_trigger:epic_number_unnumberable" in record.escalation_reasons
    end

    test "a record that already has a story the loop can see is not picked up again", %{
      tenant: tenant
    } do
      {source, record} = fixture(:intake_pair, %{tenant_id: tenant.id, issue_number: 412})

      assert :ok = run(tenant)
      story = story_for(record.id)

      # The target epic is then REMOVED, which makes a second promote of this record
      # escalate it. Idempotency alone cannot tell "excluded from the read" from "promoted a
      # second time harmlessly" — both leave one story and one stage row — so the record is
      # armed to leave a trace if it is read again.
      clear_target_epic(source.id)

      assert :ok = run(tenant)

      assert %Record{status: :pending_triage, escalation_reasons: []} = reload(record)
      assert story_for(record.id).id == story.id
      refute record.id in candidate_ids(tenant)
    end

    test "a story with NO stage row keeps its record a candidate, and the next run opens it",
         %{tenant: tenant} do
      {source, record} = fixture(:intake_pair, %{tenant_id: tenant.id, epic_number: 43})

      # The state a promote whose create succeeded and whose open failed leaves behind — the
      # `{:stage_not_opened, :busy}` that `Loopctl.Delivery.Stages` documents as ordinary and
      # retryable. Against `stories.intake_record_id` ALONE this record is excluded from every
      # later run and the story is stranded for ever: `Loopctl.Delivery.Placement` selects on
      # the stage row and nothing else, so nothing would ever reach it again.
      story = create_story(tenant.id, source.target_epic_id, record.id, "43.1")
      assert Stages.get(tenant.id, story.id) == nil
      assert record.id in candidate_ids(tenant)

      assert :ok = run(tenant)

      # The recovery is the SAME promote: the create's collision is surfaced as the existing
      # story and the open is the half that had not happened.
      assert story_for(record.id).id == story.id
      assert Stages.get(tenant.id, story.id).stage == :detected
    end

    test "a revoked source's record is neither promoted nor escalated", %{tenant: tenant} do
      {_source, record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          revoked_at: DateTime.utc_now()
        })

      # Excluded from the READ, not fetched and skipped, and the difference is not cosmetic:
      # revocation is one-way, so this record can never leave `pending_triage`, and the read is
      # oldest-first and bounded — fetched, it would hold a slot in every batch for ever and
      # enough of them would starve the drain.
      refute record.id in candidate_ids(tenant)

      assert :ok = run(tenant)

      # Not escalated either. Escalation is a queue of questions for a person and this one
      # carries none: the repository is no longer bound, so there is no action to take.
      assert %Record{status: :pending_triage, escalation_reasons: []} = reload(record)
      assert story_for(record.id) == nil
    end

    test "one bad record does not stop the others in the same run", %{tenant: tenant} do
      # An UNNUMBERABLE epic, not a missing one: a missing target epic is a retry now, and a
      # retry leaves the record exactly as a record the run never reached. This record has to
      # be one whose handling is VISIBLE in the row, or the assertion below cannot tell "the
      # run continued past it" from "the run stopped before it".
      {_bad_source, bad} =
        fixture(:intake_pair, %{tenant_id: tenant.id, epic_number: 10_000})

      {_good_source, good} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          repo_full_name: "mkreyman/cron_books"
        })

      # The failing record is made the OLDEST so the read reaches it FIRST. Otherwise the run
      # could stop at the first failure and still leave this test green, which would assert
      # nothing at all.
      backdate(bad.id, DateTime.add(DateTime.utc_now(), -60, :second))

      assert :ok = run(tenant)

      assert reload(bad).status == :escalated
      assert story_for(good.id)
      assert Stages.get(tenant.id, story_for(good.id).id).stage == :detected
    end
  end

  describe "run_result/1" do
    test "a batch where EVERY candidate errored fails the job" do
      # The one outcome no fixture can produce — nothing reachable makes `promote/1` raise —
      # and the one that must not report as a clean run. On a connection-pool outage every
      # candidate raises, the per-record rescue swallows each, and an `:ok` here means Oban
      # records success: no retry, nothing discarded, nothing alerting.
      assert TriageTriggerWorker.run_result([:errored, :errored]) ==
               {:error, {:all_candidates_errored, 2}}
    end

    test "a batch with some progress is a successful job" do
      # The one-bad-record case the per-record rescue exists for. The record's own escalation
      # or its next run bounds it; failing the job here would retry the whole batch instead.
      assert TriageTriggerWorker.run_result([:errored, :promoted]) == :ok
    end

    test "an empty batch is a successful job" do
      # Nothing to drain is the steady state, not a failure — and `count == count` would make
      # zero-of-zero "every candidate errored" without the positive guard.
      assert TriageTriggerWorker.run_result([]) == :ok
    end
  end

  defp run(tenant), do: TriageTriggerWorker.drain(tenant_id: tenant.id)

  defp candidate_ids(tenant),
    do: Enum.map(TriageTriggerWorker.candidates(tenant_id: tenant.id), & &1.id)

  defp reload(%Record{} = record), do: AdminRepo.get!(Record, record.id)

  defp story_for(record_id) do
    AdminRepo.one(from s in Story, where: s.intake_record_id == ^record_id)
  end

  defp create_story(tenant_id, epic_id, record_id, number) do
    {:ok, story} =
      Stories.create_story(
        tenant_id,
        %{epic_id: epic_id, number: number, title: "Triage pending: already created"},
        intake_record_id: record_id
      )

    story
  end

  # The only way to reach the field: `Source.create_changeset/2` does not cast it and there is
  # no update path (see `Loopctl.WorkBreakdown.Epics`' delete-constraint message).
  defp clear_target_epic(source_id) do
    {1, _} =
      AdminRepo.update_all(from(s in Source, where: s.id == ^source_id),
        set: [target_epic_id: nil]
      )
  end

  defp backdate(record_id, at) do
    {1, _} =
      AdminRepo.update_all(from(r in Record, where: r.id == ^record_id), set: [inserted_at: at])
  end
end
