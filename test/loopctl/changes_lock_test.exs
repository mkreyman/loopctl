defmodule Loopctl.ChangesLockTest do
  @moduledoc """
  US-47.1 AC-47.1.2: `Loopctl.Changes.bind/4` under GENUINE concurrency — separate database
  sessions, so the story row lock and the `(tenant_id, repo, change_id)` unique index are what
  decide the outcome.

  `async: false` because the subject is committed transactions racing each other: inside the
  SQL sandbox every allowed process shares one connection, which serialises the binds on its
  own and would pass with no lock at all (`progress/claim_lock_test.exs` sets out why). So the
  rows here are COMMITTED under `fixture(:committed_tenant)`, every process runs on
  production's connections (`Loopctl.Test.ProductionTopology`), and the module sweeps exactly
  the tenants it committed when it ends (`track_committed_tenants/0`), audit-chain rows
  included.
  """

  use ExUnit.Case, async: false

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Changes
  alias Loopctl.Changes.Binding
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.WorkBreakdown.Story

  @ownership_timeout :timer.seconds(60)
  # Longer than the test's own wait for the racers to block, so a racer never gives up first.
  @lock_timeout_ms 20_000

  setup_all do
    %{ledger: track_committed_tenants()}
  end

  setup %{ledger: ledger} do
    # `fixture(:committed_tenant)` runs its own unboxed checkout, so it goes first.
    tenant = fixture(:committed_tenant, %{})
    track_committed_tenant(ledger, tenant.id)
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    %{tenant: tenant}
  end

  defp attrs(story_id, change_id),
    do: %{story_id: story_id, repo: "mkreyman/loopctl", change_id: change_id}

  defp bind_in_task(tenant_id, attrs) do
    Task.async(fn ->
      :ok = ProductionTopology.checkout_unboxed!([Repo], ownership_timeout: @ownership_timeout)
      Changes.bind(tenant_id, attrs, %{agent_id: nil}, lock_timeout_ms: @lock_timeout_ms)
    end)
  end

  # Opens a transaction in its own session, runs `hold` in it, reports the session's backend
  # pid, and keeps the transaction open until told to commit.
  defp holder(tenant_id, hold) do
    parent = self()

    task =
      Task.async(fn ->
        :ok =
          ProductionTopology.checkout_unboxed!([Repo], ownership_timeout: @ownership_timeout)

        Repo.with_tenant(tenant_id, fn ->
          hold.()
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
          send(parent, {:holding, pid})

          receive do
            :commit -> :ok
          end
        end)
      end)

    backend =
      receive do
        {:holding, pid} -> pid
      after
        10_000 -> flunk("the holder never opened its transaction")
      end

    {task, backend}
  end

  defp release({task, _backend}) do
    send(task.pid, :commit)
    {:ok, :ok} = Task.await(task)
  end

  # Are `n` backends waiting behind OUR HOLDER? `pg_blocking_pids/1` names what a backend
  # actually waits on, so another branch's traffic cannot satisfy it. The queue is followed one
  # hop: a second waiter on one row lock queues behind the FIRST waiter's tuple lock, so it
  # names that waiter, not the holder.
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

  test "two concurrent binds to one story serialize on the story lock: one current, one superseded",
       %{tenant: tenant} do
    story = fixture(:story, %{tenant_id: tenant.id})

    # Hold the story row the way a bind does, so both racers are inside `bind/4` and past
    # input validation when they meet.
    holding =
      holder(tenant.id, fn ->
        import Ecto.Query, only: [from: 2]

        Repo.one!(
          from s in Story, where: s.id == ^story.id, lock: "FOR NO KEY UPDATE", select: s.id
        )
      end)

    racers = [
      bind_in_task(tenant.id, attrs(story.id, "C1")),
      bind_in_task(tenant.id, attrs(story.id, "C2"))
    ]

    assert blocked_by?(elem(holding, 1), 2)
    release(holding)

    # Without the lock both read "no current binding", both insert, and the partial unique
    # index refuses the second: one of these would be a changeset error.
    assert [{:ok, %Binding{}}, {:ok, %Binding{}}] = Enum.map(racers, &Task.await(&1, 30_000))

    assert [%Binding{superseded_at: %DateTime{}}, %Binding{superseded_at: nil}] =
             Changes.list_bindings(tenant.id, story.id)
  end

  test "a bind that loses the change to another story rolls its supersede back", %{
    tenant: tenant
  } do
    story = fixture(:story, %{tenant_id: tenant.id})
    other = fixture(:story, %{tenant_id: tenant.id})
    {:ok, kept} = Changes.bind(tenant.id, attrs(story.id, "C0"), %{agent_id: nil})

    # Another session binds C1 to the OTHER story and has not committed: the racer cannot see
    # it, so it supersedes C0 and then waits on the unique index for that session's verdict.
    holding =
      holder(tenant.id, fn ->
        %Binding{tenant_id: tenant.id}
        |> Binding.create_changeset(attrs(other.id, "C1"))
        |> Repo.insert!()
      end)

    racer = bind_in_task(tenant.id, attrs(story.id, "C1"))
    assert blocked_by?(elem(holding, 1), 1)
    release(holding)

    assert {:error, :change_bound_to_other_story} = Task.await(racer, 30_000)

    # C0 is still the story's current binding: the supersede went with the lost insert.
    assert Changes.current_binding(tenant.id, story.id).id == kept.id
    assert Changes.current_binding(tenant.id, other.id).change_id == "C1"
  end
end
