defmodule Loopctl.Changes.ReviewCustodyLockTest do
  @moduledoc """
  US-47.5 AC-47.5.1 under GENUINE concurrency: one chg reviewer dispatch records at most one
  verdict, and the DATABASE decides it (`review_records_reviewer_dispatch_uidx`), not a read
  before the write.

  `async: false` because the subject is committed transactions racing each other: inside the
  SQL sandbox every allowed process shares one connection, which serialises the two
  `record_review/4` calls on its own and would pass with no index at all. So the rows are
  COMMITTED under `fixture(:committed_tenant)`, every process runs on production's
  connections (`Loopctl.Test.ProductionTopology`), and the module sweeps exactly the tenants it
  committed when it ends (`track_committed_tenants/0`).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology

  @ownership_timeout :timer.seconds(60)
  @sha String.duplicate("a", 40)

  setup_all do
    %{ledger: track_committed_tenants()}
  end

  setup %{ledger: ledger} do
    tenant = fixture(:committed_tenant, %{})
    track_committed_tenant(ledger, tenant.id)
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    # A recorded review enqueues the knowledge-extraction job, which the test Oban engine runs
    # INLINE in the recording process — off the subject here. The tenant's own setting turns
    # it off (an input, rather than global mocks for every racing process).
    tenant =
      tenant
      |> Ecto.Changeset.change(settings: %{"knowledge_auto_extract" => false})
      |> AdminRepo.update!()

    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{tenant_id: tenant.id})

    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: impl_agent.id})

    story =
      fixture(:story, %{tenant_id: tenant.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        reported_done_at: DateTime.add(DateTime.utc_now(), -60, :second),
        assigned_agent_id: impl_agent.id,
        implementer_dispatch_id: impl.id
      })
      |> AdminRepo.update!()

    raw =
      Jason.encode!(
        build(:chg_event, %{
          change_id: "C1",
          event_seq: 1,
          kind: "submitted",
          sha: @sha,
          data: %{"story_id" => story.id}
        })
      )

    ts = Integer.to_string(System.os_time(:second))

    {:ok, %{outcome: :applied}} =
      Events.receive_push(source.id, %{
        raw_body: raw,
        timestamp: ts,
        signature: Signature.header(secret, Signature.delivery_string(ts, raw))
      })

    reviewer = fixture(:chg_root_dispatch, %{tenant_id: tenant.id, parent: root})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    %{tenant: tenant, story: story, reviewer: reviewer, agent: agent}
  end

  defp review(ctx) do
    Progress.record_review(
      ctx.tenant.id,
      ctx.story.id,
      %{"review_type" => "chg", "commit_sha" => @sha},
      reviewer_agent_id: ctx.agent.id,
      reviewer_lineage: ctx.reviewer.lineage_path
    )
  end

  defp review_in_task(ctx) do
    Task.async(fn ->
      :ok =
        ProductionTopology.checkout_unboxed!([Repo, AdminRepo],
          ownership_timeout: @ownership_timeout
        )

      review(ctx)
    end)
  end

  # Holds an UNCOMMITTED verdict of the same reviewer dispatch in its own session.
  defp hold_verdict(ctx, outcome) do
    parent = self()

    Task.async(fn ->
      :ok =
        ProductionTopology.checkout_unboxed!([AdminRepo], ownership_timeout: @ownership_timeout)

      AdminRepo.transaction(fn ->
        AdminRepo.insert!(%ReviewRecord{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          review_type: "chg",
          completed_at: DateTime.utc_now(),
          reviewed_report_at: ctx.story.reported_done_at,
          commit_sha: @sha,
          reviewer_dispatch_id: ctx.reviewer.id
        })

        %{rows: [[pid]]} = AdminRepo.query!("SELECT pg_backend_pid()", [])
        send(parent, {:holding, pid})

        receive do
          :commit -> :ok
          :rollback -> AdminRepo.rollback(:held)
        end
      end)
    end)
    |> then(fn task ->
      receive do
        {:holding, pid} -> {task, pid, outcome}
      after
        10_000 -> flunk("the holder never inserted its verdict")
      end
    end)
  end

  defp release({task, _pid, outcome}) do
    send(task.pid, outcome)
    Task.await(task, 30_000)
  end

  defp blocked_on?(backend) do
    Enum.any?(1..200, fn _ ->
      %{rows: [[n]]} =
        AdminRepo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [backend]
        )

      n > 0 or (Process.sleep(25) && false)
    end)
  end

  defp verdicts(ctx) do
    AdminRepo.aggregate(
      from(r in ReviewRecord, where: r.reviewer_dispatch_id == ^ctx.reviewer.id),
      :count
    )
  end

  test "a verdict racing an uncommitted one waits on the index and is refused when it commits",
       ctx do
    holding = hold_verdict(ctx, :commit)
    racer = review_in_task(ctx)

    # The second verdict is BLOCKED on the first's unique-index entry: no read-then-write
    # could have seen the uncommitted row, so this wait is the database deciding.
    assert blocked_on?(elem(holding, 1))
    assert {:ok, _} = release(holding)

    assert {:error, :chg_review_already_recorded} = Task.await(racer, 30_000)
    assert verdicts(ctx) == 1
  end

  test "the same race with the first verdict rolled back records the second", ctx do
    holding = hold_verdict(ctx, :rollback)
    racer = review_in_task(ctx)

    assert blocked_on?(elem(holding, 1))
    assert {:error, :held} = release(holding)

    assert {:ok, %ReviewRecord{}} = Task.await(racer, 30_000)
    assert verdicts(ctx) == 1
  end

  test "two verdicts from one reviewer dispatch at once: exactly one is recorded", ctx do
    results = [review_in_task(ctx), review_in_task(ctx)] |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, %ReviewRecord{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :chg_review_already_recorded})) == 1
    assert verdicts(ctx) == 1
  end
end
