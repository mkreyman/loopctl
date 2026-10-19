defmodule Loopctl.IntakeGenerationConcurrencyTest do
  @moduledoc """
  US-47.10: two concurrent reopens of a finished issue start ONE new generation between
  them (see "Generations" in `Loopctl.Intake`).

  `async: false` and COMMITTED rows on two real connections, because the subject is the
  interaction of the `FOR UPDATE` lock on the newest record with the unique index on
  `(tenant_id, source_id, issue_number, generation)` across two transactions. The sandbox
  gives every process one connection, so there the two reopens are serial by construction
  and the losing branch is unreachable. The rows are this module's own, under a committed
  tenant it sweeps.

  The HOLDER stands in for the reopen that wins: it locks generation 1, inserts generation 2
  and waits to commit. The contender is a real reopen through the webhook path. It reads
  generation 1 as newest, waits on the lock, and once the holder commits it still holds
  generation 1 as newest, because the winner did not change that row. Its insert of
  generation 2 must then conflict, and its delivery must land on the winner's generation
  rather than starting a third.
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
    test_pid = self()

    holder =
      spawn_link(fn ->
        Sandbox.unboxed_run(Loopctl.Repo, fn ->
          AdminRepo.transaction(fn ->
            AdminRepo.one!(from r in Record, where: r.id == ^gen1.id, lock: "FOR UPDATE")

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

            send(test_pid, :locked)
            receive do: (:commit -> :ok)
          end)
        end)
      end)

    assert_receive :locked, 5_000

    contender =
      Task.async(fn ->
        Sandbox.unboxed_run(Loopctl.Repo, fn ->
          deliver(source, 42, "reopened", "Back again", "2026-09-12T12:00:00Z")
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
            where: r.tenant_id == ^tenant.id and r.issue_number == 42,
            order_by: r.generation
        )
      end)

    assert [1, 2] == Enum.map(records, & &1.generation)
    [after1, gen2] = records

    # The contender's delivery landed on the winner's generation, and generation 1 is as the
    # holder left it.
    assert gen2.untrusted_title == "Back again"
    assert gen2.last_action == "reopened"
    assert after1.untrusted_title == gen1.untrusted_title
    assert after1.last_action == "opened"
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
