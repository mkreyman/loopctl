defmodule Loopctl.Changes.EventsLockTest do
  @moduledoc """
  US-47.3 AC-47.3.3: change events under GENUINE concurrency — separate database sessions, so
  the per-change cursor lock and its bounded wait are what decide the outcome.

  `async: false` because the subject is committed transactions racing each other: inside the
  SQL sandbox every allowed process shares one connection, which serialises the ingests on its
  own and would pass with no lock at all (`Loopctl.ChangesLockTest` sets out the same). So the
  rows are COMMITTED under `fixture(:committed_tenant)`, every process runs on production's
  connections (`Loopctl.Test.ProductionTopology`), and the module sweeps exactly the tenants it
  committed when it ends (`track_committed_tenants/0`).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology

  @ownership_timeout :timer.seconds(60)
  @lock_timeout_ms 20_000
  @repo "mkreyman/infra"

  setup_all do
    %{ledger: track_committed_tenants()}
  end

  setup %{ledger: ledger} do
    tenant = fixture(:committed_tenant, %{})
    track_committed_tenant(ledger, tenant.id)
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    %{secret: secret, source: source} = fixture(:chg_source, %{tenant_id: tenant.id})
    %{tenant: tenant, secret: secret, source: source}
  end

  defp push(ctx, seq, opts) do
    raw = Jason.encode!(build(:chg_event, %{change_id: "C1", event_seq: seq}))
    ts = Integer.to_string(System.os_time(:second))

    Events.receive_push(
      ctx.source.id,
      %{
        raw_body: raw,
        timestamp: ts,
        signature: Signature.header(ctx.secret, Signature.delivery_string(ts, raw))
      },
      opts
    )
  end

  defp push_in_task(ctx, seq) do
    Task.async(fn ->
      :ok =
        ProductionTopology.checkout_unboxed!([Repo, AdminRepo],
          ownership_timeout: @ownership_timeout
        )

      push(ctx, seq, lock_timeout_ms: @lock_timeout_ms)
    end)
  end

  # Holds the change's cursor row FOR UPDATE in its own session until told to commit.
  defp hold_cursor(ctx) do
    parent = self()

    task =
      Task.async(fn ->
        :ok =
          ProductionTopology.checkout_unboxed!([Repo], ownership_timeout: @ownership_timeout)

        Repo.with_tenant(ctx.tenant.id, fn ->
          Repo.one!(
            from c in Cursor,
              where: c.tenant_id == ^ctx.tenant.id and c.change_id == "C1",
              lock: "FOR UPDATE"
          )

          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
          send(parent, {:holding, pid})

          receive do
            :commit -> :ok
          end
        end)
      end)

    receive do
      {:holding, pid} -> {task, pid}
    after
      10_000 -> flunk("the holder never took the cursor lock")
    end
  end

  defp release({task, _pid}) do
    send(task.pid, :commit)
    {:ok, :ok} = Task.await(task)
  end

  defp blocked_by?(backend, n) do
    eventually(fn ->
      %{rows: [[blocked]]} =
        AdminRepo.query!(
          """
          WITH direct AS (
            SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))
          )
          SELECT count(*) FROM pg_stat_activity a
          WHERE $1 = ANY(pg_blocking_pids(a.pid))
             OR pg_blocking_pids(a.pid) && ARRAY(SELECT pid FROM direct)
          """,
          [backend]
        )

      blocked >= n
    end)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end

  test "a held cursor lock answers :busy within the bounded wait and writes nothing", ctx do
    assert {:ok, %{outcome: :applied}} = push(ctx, 1, [])
    holding = hold_cursor(ctx)

    assert {:error, :busy} = push(ctx, 2, lock_timeout_ms: 100)

    release(holding)

    assert [%Event{event_seq: 1}] = Events.list_events(ctx.tenant.id, @repo, "C1")
    # The redelivery after the lock frees is what chg does on a 503.
    assert {:ok, %{outcome: :applied, applied_seq: 2}} = push(ctx, 2, [])
  end

  test "two events of one change racing apply in order, each exactly once", ctx do
    assert {:ok, %{outcome: :applied}} = push(ctx, 1, [])
    holding = hold_cursor(ctx)

    racers = [push_in_task(ctx, 3), push_in_task(ctx, 2)]
    assert blocked_by?(elem(holding, 1), 2)
    release(holding)

    results = Enum.map(racers, &Task.await(&1, 30_000))
    assert Enum.all?(results, &match?({:ok, _}, &1))

    assert [
             %Event{event_seq: 1, applied_at: %DateTime{}},
             %Event{event_seq: 2, applied_at: %DateTime{}},
             %Event{event_seq: 3, applied_at: %DateTime{}}
           ] = Events.list_events(ctx.tenant.id, @repo, "C1")

    assert %Cursor{applied_seq: 3} = Events.get_cursor(ctx.tenant.id, @repo, "C1")

    positions =
      AdminRepo.all(
        from e in Loopctl.AuditChain.Entry,
          where: e.tenant_id == ^ctx.tenant.id and e.action == "change_event_applied",
          order_by: [asc: e.chain_position],
          select: fragment("(?->>'event_seq')::int", e.payload)
      )

    assert positions == [1, 2, 3]
  end
end
