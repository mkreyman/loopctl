defmodule Loopctl.IntakeGenerationConcurrencyTest do
  @moduledoc """
  US-47.10: a delivery that races a generation bump lands on the NEW generation (see
  "Generations" in `Loopctl.Intake`).

  `async: false` and COMMITTED rows on two real connections. The subject is
  `SELECT ... ORDER BY generation DESC LIMIT 1 FOR UPDATE` picking its row from its snapshot
  before it waits on the lock, which only exists between two transactions. The sandbox gives
  every process one connection, so there every delivery is serial and the race cannot
  happen. The rows are this module's own, under a committed tenant it sweeps.

  The HOLDER stands in for the reopen that bumps. It locks generation 1, inserts generation
  2 and waits to commit. The contender is a real delivery through the webhook path. It reads
  generation 1 as newest and waits on the lock. Once the holder commits it gets generation 1
  back, because the bump did not change that row. Without the re-check in
  `newest_locked/2` it would apply there:
  - a second reopen would see a finished loop and try to insert generation 2 again;
  - an edit would rewrite generation 1, which is never to be written again.
  With the re-check, both land on generation 2.
  """
  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Signature
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.TriageTriggerWorker

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    sweep_committed_runner_tenants()
    %{tenant: fixture(:committed_tenant, %{trust_tier: :agent_rooted})}
  end

  test "two concurrent reopens of a finished issue start one generation", %{tenant: tenant} do
    {source, gen1} = finished_issue(tenant, 42)

    [after1, gen2] = race(tenant, source, gen1, "reopened", "Back again")

    assert gen2.untrusted_title == "Back again"
    assert gen2.last_action == "reopened"
    assert after1 == gen1
  end

  test "an edit racing the bump lands on generation 2, and generation 1 is unchanged", %{
    tenant: tenant
  } do
    {source, gen1} = finished_issue(tenant, 42)

    [after1, gen2] = race(tenant, source, gen1, "edited", "Edited during the bump")

    assert gen2.untrusted_title == "Edited during the bump"
    assert gen2.last_action == "edited"
    assert after1 == gen1
  end

  # The holder bumps to generation 2 under generation 1's lock while a real `action`
  # delivery waits on that lock. Returns the issue's records once both have committed, after
  # asserting there are exactly two generations.
  defp race(tenant, source, gen1, action, title) do
    test_pid = self()

    holder = spawn_link(fn -> hold_while_bumping(gen1, test_pid) end)

    assert_receive :locked, 5_000

    contender =
      Task.async(fn ->
        Sandbox.unboxed_run(Loopctl.Repo, fn ->
          deliver(source, gen1.issue_number, action, title, "2026-09-12T12:00:00Z")
        end)
      end)

    # A liveness precondition: the contender is waiting on generation 1's lock.
    assert Task.yield(contender, 300) == nil

    send(holder, :commit)

    assert {:ok, {:ok, :recorded}} = Task.yield(contender, 10_000)

    records =
      Sandbox.unboxed_run(Loopctl.Repo, fn ->
        AdminRepo.all(
          from r in Record,
            where: r.tenant_id == ^tenant.id and r.issue_number == ^gen1.issue_number,
            order_by: r.generation
        )
      end)

    assert [1, 2] == Enum.map(records, & &1.generation)
    records
  end

  # The bump: generation 1 locked, generation 2 inserted, then wait to be told to commit.
  defp hold_while_bumping(gen1, test_pid) do
    Sandbox.unboxed_run(Loopctl.Repo, fn ->
      AdminRepo.transaction(fn ->
        AdminRepo.one!(from r in Record, where: r.id == ^gen1.id, lock: "FOR UPDATE")
        insert_generation_2(gen1)
        send(test_pid, :locked)
        receive do: (:commit -> :ok)
      end)
    end)
  end

  defp insert_generation_2(gen1) do
    now = DateTime.utc_now()

    {1, _} =
      AdminRepo.insert_all(Record, [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: gen1.tenant_id,
          source_id: gen1.source_id,
          project_id: gen1.project_id,
          issue_number: gen1.issue_number,
          generation: 2,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  # A committed issue opened through the webhook, promoted, and its story put at `done`.
  defp finished_issue(tenant, number) do
    Sandbox.unboxed_run(Loopctl.Repo, fn ->
      {source, _seed} = fixture(:intake_pair, %{tenant_id: tenant.id, issue_number: 1})
      {:ok, :recorded} = deliver(source, number, "opened", "First report", "2026-09-12T10:00:00Z")
      :ok = TriageTriggerWorker.drain(tenant_id: tenant.id)

      record =
        AdminRepo.one!(
          from r in Record, where: r.tenant_id == ^tenant.id and r.issue_number == ^number
        )

      story = AdminRepo.get_by!(Story, intake_record_id: record.id)

      {1, _} =
        AdminRepo.update_all(from(st in StoryStage, where: st.story_id == ^story.id),
          set: [stage: :done]
        )

      {source, record}
    end)
  end

  defp deliver(source, number, action, title, updated_at) do
    raw =
      Jason.encode!(
        build(:github_issues_payload, %{
          repo: source.repo_full_name,
          number: number,
          action: action,
          title: title,
          updated_at: updated_at
        })
      )

    Intake.receive_github_delivery(source.id, %{
      raw_body: raw,
      signature: Signature.header(source.webhook_secret, raw),
      event: "issues",
      delivery_id: Ecto.UUID.generate(),
      content_type: "application/json"
    })
  end
end
