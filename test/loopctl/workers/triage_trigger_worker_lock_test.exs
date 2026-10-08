defmodule Loopctl.Workers.TriageTriggerWorkerLockTest do
  @moduledoc """
  `Loopctl.Workers.TriageTriggerWorker` when the stage open cannot get its lock: a transient
  failure the next run clears, so the record stays `pending_triage` and is never escalated.

  `async: false`, and COMMITTED, because the subject is a `stories` row held `FOR UPDATE` by
  a SECOND Postgres session while the run's `Stages.open/3` waits on it for a share lock. A
  lock cannot be held against your own connection, and another session cannot see a
  sandboxed row, so the story is committed under a `fixture(:committed_tenant)` and swept.
  Every path without the second session is in the async `Loopctl.Workers.TriageTriggerWorkerTest`.

  The candidate read is FLEET-WIDE, so the sweep runs before the test as well as at the
  module boundary: a committed record left `pending_triage` by an earlier run would be a
  candidate of this one too.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake.Record
  alias Loopctl.WorkBreakdown.Stories
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

  defp run, do: unboxed(fn -> TriageTriggerWorker.perform(%Oban.Job{args: %{}}) end)

  # UNBOXED: the story must be COMMITTED for the second session to see and lock it, and the
  # run commits what it writes, as it does in production.
  defp unboxed(fun) do
    Sandbox.unboxed_run(Loopctl.Repo, fun)
  end

  defp reload(%Record{} = record) do
    unboxed(fn -> AdminRepo.get!(Record, record.id) end)
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
