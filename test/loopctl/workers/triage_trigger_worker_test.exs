defmodule Loopctl.Workers.TriageTriggerWorkerTest do
  @moduledoc """
  The drainer that gives `Loopctl.Delivery.TriageTrigger.promote/1` a production caller
  (#803 §2/§4).

  `async: false`, and COMMITTED rather than sandboxed, for the reason
  `Loopctl.Delivery.TriageTriggerTest`'s own moduledoc states: `promote/1` straddles BOTH
  repos — it creates the story through `AdminRepo` and opens the stage on the RLS
  `Loopctl.Repo` — and two sandbox connections cannot see each other's uncommitted work.

  The candidate read is FLEET-WIDE, so the sweep runs before EVERY test rather than only at
  the module boundary: a record an earlier test deliberately left `pending_triage` is a
  candidate of every later run, and an assertion about "the run" would then be about
  somebody else's rows too.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.TriageTriggerWorker

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    sweep_committed_runner_tenants()
    %{tenant: fixture(:committed_tenant, %{})}
  end

  describe "perform/1" do
    test "a pending record becomes a story the delivery loop can see", %{tenant: tenant} do
      {source, record} = fixture(:committed_intake, %{tenant_id: tenant.id, issue_number: 412})

      assert :ok = run()

      # All three bindings, because each is a different half of "the loop can see it": the link
      # is how triage finds its record back, the epic is where a human looks for it, and the
      # stage row is the only thing `Loopctl.Delivery.Placement` selects on.
      story = story_for(record.id)
      assert story.epic_id == source.target_epic_id
      assert unboxed(fn -> Stages.get(tenant.id, story.id) end).stage == :detected

      # Promotion is not triage. The record stays in the queue triage consumes, and a
      # successful promote is not an escalation.
      assert %Record{status: :pending_triage, escalation_reasons: []} = reload(record)
    end

    test "a source naming no target epic RETRIES, and recovers when the source is repointed",
         %{tenant: tenant} do
      {source, record} =
        fixture(:committed_intake, %{tenant_id: tenant.id, target_epic_id: nil})

      assert :ok = run()

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
      # UNBOXED, like every other write in this file: the worker runs outside the sandbox, so
      # an epic created inside it does not exist as far as the repoint's in-project check is
      # concerned, and the recovery would fail for a reason that is purely about the test.
      #
      # And the NUMBER is bounded, for the reason `fixture(:committed_intake, ...)` states at
      # length: `build(:epic)` numbers from a raw `System.unique_integer/1`, which is small
      # when this file runs alone and six or seven digits in a full suite — and a story number
      # is `EPIC.SEQUENCE` with both parts under 10_000, so an epic above that makes every
      # story in it unnumberable. This test passed alone and failed in the suite on exactly
      # that: the recovery run escalated `:epic_number_unnumberable` instead of promoting.
      epic =
        unboxed(fn ->
          epic =
            fixture(:epic, %{
              tenant_id: tenant.id,
              project_id: source.project_id,
              number: rem(System.unique_integer([:positive]), 9_000) + 1
            })

          {:ok, _} = Intake.repoint_source(tenant.id, source.id, epic.id)
          epic
        end)

      assert :ok = run()

      assert story = story_for(record.id)
      assert story.epic_id == epic.id
    end

    test "an epic numbered past the story-number ceiling escalates too", %{tenant: tenant} do
      {_source, record} =
        fixture(:committed_intake, %{tenant_id: tenant.id, epic_number: 10_000})

      # The second shape of "a human must change data": the operator's remedy is to renumber
      # the epic. Asserted alongside `:no_target_epic` because the two reach the escalation
      # through different clauses of `promote/1` and only one of them is in the happy path of
      # the fixture.
      assert :ok = run()

      record = reload(record)
      assert record.status == :escalated
      assert "triage_trigger:epic_number_unnumberable" in record.escalation_reasons
    end

    test "a record that already has a story the loop can see is not picked up again", %{
      tenant: tenant
    } do
      {source, record} = fixture(:committed_intake, %{tenant_id: tenant.id, issue_number: 412})

      assert :ok = run()
      story = story_for(record.id)

      # The target epic is then REMOVED, which makes a second promote of this record
      # escalate it. Idempotency alone cannot tell "excluded from the read" from "promoted a
      # second time harmlessly" — both leave one story and one stage row — so the record is
      # armed to leave a trace if it is read again.
      unboxed(fn -> clear_target_epic(source.id) end)

      assert :ok = run()

      assert %Record{status: :pending_triage, escalation_reasons: []} = reload(record)
      assert story_for(record.id).id == story.id
      refute record.id in candidate_ids()
    end

    test "a story with NO stage row keeps its record a candidate, and the next run opens it",
         %{tenant: tenant} do
      {source, record} = fixture(:committed_intake, %{tenant_id: tenant.id, epic_number: 43})

      # The state a promote whose create succeeded and whose open failed leaves behind — the
      # `{:stage_not_opened, :busy}` that `Loopctl.Delivery.Stages` documents as ordinary and
      # retryable. Against `stories.intake_record_id` ALONE this record is excluded from every
      # later run and the story is stranded for ever: `Loopctl.Delivery.Placement` selects on
      # the stage row and nothing else, so nothing would ever reach it again.
      story = create_story(tenant.id, source.target_epic_id, record.id, "43.1")
      assert unboxed(fn -> Stages.get(tenant.id, story.id) end) == nil
      assert record.id in candidate_ids()

      assert :ok = run()

      # The recovery is the SAME promote: the create's collision is surfaced as the existing
      # story and the open is the half that had not happened.
      assert story_for(record.id).id == story.id
      assert unboxed(fn -> Stages.get(tenant.id, story.id) end).stage == :detected
    end

    test "a transient failure leaves the record pending_triage and unescalated", %{
      tenant: tenant
    } do
      {source, record} = fixture(:committed_intake, %{tenant_id: tenant.id, epic_number: 43})

      story = create_story(tenant.id, source.target_epic_id, record.id, "43.1")

      # `Stages.open/3` takes the story `FOR SHARE` before it touches the stage row, so a
      # session holding that row `FOR UPDATE` parks the open until the 2s `lock_timeout`
      # `Stages` sets locally fires. A LOCK, not a sleep: nothing here depends on timing.
      blocker = lock_story(story.id)

      try do
        assert :ok = run()
      after
        release(blocker)
      end

      # The record must NOT be escalated: the next run clears this by itself, and an
      # escalation is never cleared — so filing one here would put a question with no answer
      # in front of a person and take the record out of the read that would have fixed it.
      assert %Record{status: :pending_triage, escalation_reasons: []} = reload(record)
      assert unboxed(fn -> Stages.get(tenant.id, story.id) end) == nil
    end

    test "a revoked source's record is neither promoted nor escalated", %{tenant: tenant} do
      {_source, record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          revoked_at: DateTime.utc_now()
        })

      # Excluded from the READ, not fetched and skipped, and the difference is not cosmetic:
      # revocation is one-way, so this record can never leave `pending_triage`, and the read is
      # oldest-first and bounded — fetched, it would hold a slot in every batch for ever and
      # enough of them would starve the drain.
      refute record.id in candidate_ids()

      assert :ok = run()

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
        fixture(:committed_intake, %{tenant_id: tenant.id, epic_number: 10_000})

      {_good_source, good} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          repo_full_name: "mkreyman/cron_books"
        })

      # The failing record is made the OLDEST so the read reaches it FIRST. Otherwise the run
      # could stop at the first failure and still leave this test green, which would assert
      # nothing at all.
      unboxed(fn -> backdate(bad.id, DateTime.add(DateTime.utc_now(), -60, :second)) end)

      assert :ok = run()

      assert reload(bad).status == :escalated
      assert story_for(good.id)
      assert unboxed(fn -> Stages.get(tenant.id, story_for(good.id).id) end).stage == :detected
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

  defp run, do: unboxed(fn -> TriageTriggerWorker.perform(%Oban.Job{args: %{}}) end)

  # UNBOXED like every other read here: the fixtures are committed, so a sandbox connection
  # cannot see them and the read would come back empty whatever the predicate says.
  defp candidate_ids do
    unboxed(fn -> Enum.map(TriageTriggerWorker.candidates(), & &1.id) end)
  end

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

  defp reload(%Record{} = record) do
    unboxed(fn -> AdminRepo.get!(Record, record.id) end)
  end

  defp story_for(record_id) do
    unboxed(fn ->
      AdminRepo.one(from s in Story, where: s.intake_record_id == ^record_id)
    end)
  end

  defp create_story(tenant_id, epic_id, record_id, number) do
    {:ok, story} =
      unboxed(fn ->
        Stories.create_story(
          tenant_id,
          %{epic_id: epic_id, number: number, title: "Triage pending: already created"},
          intake_record_id: record_id
        )
      end)

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

  # A SEPARATE database session holding one story row `FOR UPDATE`, on its own raw connection
  # rather than a sandbox one: the sandbox owner's connection is the one this test process
  # already runs on, and a lock cannot be held against yourself. Copied in shape from
  # `Loopctl.Delivery.TriageTriggerTest`, retry included — it asks the server for one more
  # connection at the moment the suite holds the most, and a `too_many_clients` flake there
  # names a change that did not cause it.
  defp lock_story(story_id), do: lock_story(story_id, 5)

  defp lock_story(story_id, attempts_left) do
    config = Application.get_env(:loopctl, AdminRepo)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname] || "127.0.0.1",
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: config[:database],
        pool_size: 1
      )

    try do
      Postgrex.query!(conn, "BEGIN", [], timeout: 10_000)

      # `num_rows`, asserted: a lock on nothing blocks nothing, and the open would then succeed
      # for the ordinary reason and this test would prove nothing at all.
      %Postgrex.Result{num_rows: 1} =
        Postgrex.query!(conn, "SELECT id FROM stories WHERE id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(story_id)
        ])

      conn
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        GenServer.stop(conn)

        if attempts_left > 1 do
          Process.sleep(1_000)
          lock_story(story_id, attempts_left - 1)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp release(conn) do
    Postgrex.query!(conn, "ROLLBACK", [])
    GenServer.stop(conn)
  end
end
