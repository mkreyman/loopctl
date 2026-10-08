defmodule Loopctl.Runners.CapacityConcurrencyTest do
  @moduledoc """
  Issue #803: runner capacity under GENUINE concurrency — racing reservations, admissions and
  releases, a lock wait that must run out, the delivery decision's overlap, and the one lock
  order that keeps a reply and a release from deadlocking.

  `async: false`, and COMMITTED, because what is under test is how Postgres arbitrates
  concurrent transactions: a conditional UPDATE racing on one row, an advisory lock
  serializing a tenant's admissions, a lock wait that must run out. Inside the SQL sandbox every
  process shares ONE connection and one open transaction, so no two of them can ever race and
  no lock is ever released. So every process here runs on connections of its own
  (`Loopctl.Test.ProductionTopology`; `on_own_connection/1` gives a Task its own, since a
  Task would otherwise share its parent's through `$callers`), every write commits, and the
  tenant is `fixture(:committed_tenant)`, swept at the module boundaries. The capacity rules
  one transaction at a time are `Loopctl.Runners.CapacityTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.WorkBreakdown.Story

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # `fixture(:committed_tenant)` runs its own unboxed checkout, so it goes first; from the
    # checkout on, every write of this process commits.
    tenant = fixture(:committed_tenant, %{})
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])
    %{tenant: tenant}
  end

  # Runs `fun` on the calling process's OWN Repo connection, checked out on first use and
  # held for the process's life. The test process has one from `setup`; a Task gets its own
  # here, where it would otherwise share the test process's through `$callers`. Every path
  # these tests race is `Loopctl.Repo`'s, so a Task checks out nothing else.
  defp on_own_connection(fun) do
    :ok = ProductionTopology.checkout_unboxed!([Repo])
    fun.()
  end

  # A runner in this test's committed tenant unless `attrs` names one.
  defp runner(ctx, attrs) do
    {_raw, runner} = fixture(:runner, Map.put_new(attrs, :tenant_id, ctx.tenant.id))
    runner
  end

  describe "reserve_slot/2" do
    test "from more concurrent callers than slots, exactly max_sessions win", ctx do
      runner = runner(ctx, %{max_sessions: 3})

      results = concurrently(10, fn _ -> Runners.reserve_slot(runner.tenant_id, runner.id) end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :runner_at_capacity})) == 7
      assert in_flight(runner) == 3
    end
  end

  describe "record_sent/3 reserves" do
    test "from more concurrent dispatches than slots, exactly max_sessions are recorded", ctx do
      runner = runner(ctx, %{max_sessions: 3})
      dispatches = for _ <- 1..8, do: dispatch(runner.tenant_id)

      results =
        concurrently(8, fn i ->
          DispatchLedger.record_sent(runner.tenant_id, runner.id, Enum.at(dispatches, i - 1))
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :runner_at_capacity})) == 5
      # A refused dispatch leaves no row behind: the row and its slot commit together.
      assert ledger_rows(runner) == 3
      assert unreleased(runner) == 3
      assert in_flight(runner) == 3
    end

    test "a lock wait that runs out is capacity_busy, and nothing is recorded", ctx do
      runner = runner(ctx, %{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      parent = self()

      holder =
        Task.async(fn ->
          on_own_connection(fn ->
            Repo.transaction(fn ->
              hold_admission_lock!(runner.tenant_id)

              send(parent, :locked)

              receive do
                :release -> :ok
              end
            end)
          end)
        end)

      assert_receive :locked, 5_000
      started = System.monotonic_time(:millisecond)

      assert send_dispatch(runner, d) == {:error, :capacity_busy}
      assert System.monotonic_time(:millisecond) - started >= Capacity.lock_timeout_ms() - 100

      send(holder.pid, :release)
      Task.await(holder)

      assert ledger_rows(runner) == 0
      assert in_flight(runner) == 0
    end
  end

  describe "admission control" do
    test "caps a tenant's total across its runners, under concurrency", ctx do
      # Two runners with 8 slots between them; the tenant may use only limit/0 = 6.
      a = runner(ctx, %{max_sessions: 4})
      b = runner(ctx, %{max_sessions: 4, tenant_id: a.tenant_id})
      assert Capacity.limit() == 6

      jobs =
        for i <- 1..10 do
          {if(rem(i, 2) == 0, do: a, else: b), dispatch(a.tenant_id)}
        end

      results =
        concurrently(10, fn i ->
          {r, d} = Enum.at(jobs, i - 1)
          DispatchLedger.record_sent(r.tenant_id, r.id, d)
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 6
      refused = Enum.reject(results, &match?({:ok, _}, &1))

      assert Enum.all?(
               refused,
               &(&1 in [{:error, :admission_limit_reached}, {:error, :runner_at_capacity}])
             )

      assert {:error, :admission_limit_reached} in refused
      assert in_flight(a) + in_flight(b) == 6
      assert ledger_rows(a) + ledger_rows(b) == 6
    end
  end

  describe "release, exactly once" do
    test "concurrent releases of one dispatch decrement once", ctx do
      runner = runner(ctx, %{max_sessions: 3})
      d1 = dispatch(runner.tenant_id)
      d2 = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d1)
      {:ok, _} = send_dispatch(runner, d2)
      slot = generation(runner, d1.dispatch_id)

      results =
        concurrently(6, fn _ ->
          Runners.release_slot(runner.tenant_id, d1.dispatch_id, slot)
        end)

      assert Enum.count(results, &(&1 == {:ok, :released})) == 1
      assert in_flight(runner) == 1
    end
  end

  describe "a lock wait on a runner message" do
    # The reply and trace paths run inside the channel process that holds the runner's
    # socket. Unbounded they hold a pool connection for as long as the blocker runs; raised
    # they crash the channel, and the runner re-sends the same message on rejoin forever.
    test "a reply blocked behind a claim release is capacity_busy, not a wait and not a raise",
         ctx do
      runner = runner(ctx, %{max_sessions: 3})
      story = story(runner.tenant_id)
      d = dispatch(runner.tenant_id, %{"story_id" => story.id})
      {:ok, _} = send_dispatch(runner, d)

      test = self()

      blocker =
        Task.async(fn ->
          on_own_connection(fn ->
            Repo.with_tenant(runner.tenant_id, fn ->
              Repo.one!(
                from s in Story,
                  where: s.id == ^story.id,
                  lock: "FOR UPDATE",
                  select: s.claim_epoch
              )

              send(test, :blocking)
              assert_receive_in_task(:finish)
              :done
            end)
          end)
        end)

      assert_receive :blocking, 5_000
      started = System.monotonic_time(:millisecond)

      assert reply(runner, d, %{}) == {:error, :capacity_busy}
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= Capacity.lock_timeout_ms() - 100
      assert elapsed < Capacity.lock_timeout_ms() * 3

      send(blocker.pid, :finish)
      assert {:ok, :done} = Task.await(blocker, 30_000)

      # Nothing was recorded, so the runner's re-send is applied normally.
      assert {:ok, %DispatchRecord{status: "accepted"}} = reply(runner, d, %{})
    end

    test "a reservation blocked behind the runner row is capacity_busy, not an unbounded wait",
         ctx do
      runner = runner(ctx, %{max_sessions: 3})
      test = self()

      blocker =
        Task.async(fn ->
          on_own_connection(fn ->
            Repo.with_tenant(runner.tenant_id, fn ->
              Repo.one!(
                from r in Runner,
                  where: r.id == ^runner.id,
                  lock: "FOR UPDATE",
                  select: r.in_flight
              )

              send(test, :blocking)
              assert_receive_in_task(:finish)
              :done
            end)
          end)
        end)

      assert_receive :blocking, 5_000

      assert on_own_connection(fn -> Runners.reserve_slot(runner.tenant_id, runner.id) end) ==
               {:error, :capacity_busy}

      send(blocker.pid, :finish)
      assert {:ok, :done} = Task.await(blocker, 30_000)
      assert in_flight(runner) == 0
    end

    test "a release blocked behind a row lock is capacity_busy", ctx do
      runner = runner(ctx, %{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      slot = generation(runner, d.dispatch_id)

      test = self()

      blocker =
        Task.async(fn ->
          on_own_connection(fn ->
            Repo.with_tenant(runner.tenant_id, fn ->
              Repo.one!(
                from x in DispatchRecord,
                  where: x.tenant_id == ^runner.tenant_id and x.dispatch_id == ^d.dispatch_id,
                  lock: "FOR UPDATE",
                  select: x.id
              )

              send(test, :blocking)
              assert_receive_in_task(:finish)
              :done
            end)
          end)
        end)

      assert_receive :blocking, 5_000

      assert release(runner, d.dispatch_id, slot) == {:error, :capacity_busy}

      send(blocker.pid, :finish)
      assert {:ok, :done} = Task.await(blocker, 30_000)
      assert in_flight(runner) == 1
    end
  end

  describe "the delivery decision" do
    test "a push and a drop of one broadcast: whichever commits first decides, both ways", ctx do
      for first <- [:drop, :push] do
        runner = runner(ctx, %{max_sessions: 3})
        d = dispatch(runner.tenant_id)
        {:ok, _} = send_dispatch(runner, d)

        # The loser is started while the winner holds the row, so the two transactions really
        # do overlap and Postgres orders them.
        {winner, loser} = interleave(runner, d, first)

        case first do
          :drop ->
            assert winner == {:ok, :released}
            assert loser == {:ok, {:already, "dropped"}}
            assert record(runner, d.dispatch_id).delivery == "dropped"
            assert in_flight(runner) == 0

          :push ->
            assert winner == {:ok, :pushed}
            assert loser == {:ok, {:already, "pushed"}}
            assert record(runner, d.dispatch_id).delivery == "pushed"
            # The session the push started still holds its slot.
            assert in_flight(runner) == 1
            refute record(runner, d.dispatch_id).released_at
        end
      end
    end
  end

  describe "lock order" do
    # The cycle the one order removes, staged as two real transactions:
    #
    #   releaser  a claim release or stage transition: holds the story FOR UPDATE, then takes
    #             the dispatch row (what `DispatchLedger.release_slot_in/4` does)
    #   reply     the code under test
    #
    # Taking the dispatch row BEFORE fencing the story — the old order — makes `reply` hold
    # the row while it waits for the story, so the releaser's wait for the row closes the
    # cycle and Postgres breaks it with a deadlock error in about a second, well inside
    # `lock_timeout`. Fencing the story FIRST leaves `reply` holding nothing while it waits,
    # and both finish.
    # The capacity lock is the FIRST lock of the fleet order, so any transaction that holds
    # it may go on to lock a story. A dispatch that took the story FIRST and asked for the
    # lock afterwards — the old order — cycles with exactly that caller.
    test "a dispatch racing a caller that holds the admission lock and then a story never deadlocks",
         ctx do
      runner = runner(ctx, %{max_sessions: 3})
      story = story(runner.tenant_id)
      d = dispatch(runner.tenant_id, %{"story_id" => story.id})

      test = self()
      waiting = waiting_locks()

      admitter =
        Task.async(fn ->
          on_own_connection(fn ->
            Repo.with_tenant(runner.tenant_id, fn ->
              hold_admission_lock!(runner.tenant_id)
              send(test, :holding_lock)
              assert_receive_in_task(:take_story)

              Repo.one!(
                from s in Story,
                  where: s.id == ^story.id,
                  lock: "FOR UPDATE",
                  select: s.claim_epoch
              )

              :took_story
            end)
          end)
        end)

      assert_receive :holding_lock, 5_000

      sender = Task.async(fn -> send_dispatch(runner, d) end)

      # Blocked on the admission lock under the fixed order, holding no story; blocked on it
      # while HOLDING the story's share lock under the old one. (A FOR SHARE request DOES
      # queue behind a FOR UPDATE holder, and a FOR SHARE holder blocks a later FOR UPDATE
      # requester — the cycle is broken by the single global order, not by any compatibility
      # between the two modes.)
      await_waiting_locks(waiting + 1)
      send(admitter.pid, :take_story)

      assert {:ok, :took_story} = Task.await(admitter, 30_000)
      assert {:ok, %DispatchRecord{status: "sent"}} = Task.await(sender, 30_000)
      assert in_flight(runner) == 1
    end

    test "a reply racing a claim release never deadlocks", ctx do
      runner = runner(ctx, %{max_sessions: 3})
      story = story(runner.tenant_id)
      d = dispatch(runner.tenant_id, %{"story_id" => story.id})
      {:ok, _} = send_dispatch(runner, d)

      test = self()
      waiting = waiting_locks()

      releaser =
        Task.async(fn ->
          on_own_connection(fn ->
            Repo.with_tenant(runner.tenant_id, fn ->
              Repo.one!(
                from s in Story,
                  where: s.id == ^story.id,
                  lock: "FOR UPDATE",
                  select: s.claim_epoch
              )

              send(test, :holding_story)
              assert_receive_in_task(:take_row)

              Repo.one!(
                from x in DispatchRecord,
                  where: x.tenant_id == ^runner.tenant_id and x.dispatch_id == ^d.dispatch_id,
                  lock: "FOR UPDATE",
                  select: x.id
              )

              :took_row
            end)
          end)
        end)

      assert_receive :holding_story, 5_000

      replier = Task.async(fn -> reply(runner, d, %{}) end)

      # The reply is now blocked on something. Under the fixed order that is the story, and
      # it holds nothing; under the old order it is the story too, but it holds the dispatch
      # row the releaser is about to ask for.
      await_waiting_locks(waiting + 1)
      send(releaser.pid, :take_row)

      assert {:ok, :took_row} = Task.await(releaser, 30_000)
      assert {:ok, %DispatchRecord{status: "accepted"}} = Task.await(replier, 30_000)
      assert in_flight(runner) == 1
    end
  end

  defp in_flight(runner) do
    on_own_connection(fn ->
      AdminRepo.one!(from r in Runner, where: r.id == ^runner.id, select: r.in_flight)
    end)
  end

  defp unreleased(runner) do
    on_own_connection(fn ->
      {:ok, count} =
        Repo.with_tenant(runner.tenant_id, fn ->
          Repo.aggregate(
            from(d in DispatchRecord, where: d.runner_id == ^runner.id and is_nil(d.released_at)),
            :count
          )
        end)

      count
    end)
  end

  defp ledger_rows(runner) do
    on_own_connection(fn ->
      {:ok, count} =
        Repo.with_tenant(runner.tenant_id, fn ->
          Repo.aggregate(from(d in DispatchRecord, where: d.runner_id == ^runner.id), :count)
        end)

      count
    end)
  end

  defp story(tenant_id, epoch \\ 0) do
    on_own_connection(fn ->
      fixture(:ledger_story, %{tenant_id: tenant_id, claim_epoch: epoch})
    end)
  end

  defp dispatch(tenant_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    story_id = Map.get_lazy(attrs, "story_id", fn -> story(tenant_id).id end)

    {:ok, dispatch} =
      RunnerContract.cast_dispatch(build(:runner_dispatch, Map.put(attrs, "story_id", story_id)))

    dispatch
  end

  defp send_dispatch(runner, dispatch),
    do:
      on_own_connection(fn ->
        DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      end)

  defp reply(runner, dispatch, attrs) do
    payload =
      Map.merge(
        %{
          "dispatch_id" => dispatch.dispatch_id,
          "claim_epoch" => dispatch.claim_epoch,
          "decision" => "accepted"
        },
        attrs
      )

    {:ok, reply} = RunnerContract.cast_dispatch_reply(payload)
    on_own_connection(fn -> DispatchLedger.record_reply(runner.tenant_id, runner.id, reply) end)
  end

  # Runs `fun` from `count` processes at once, each on its own connection, released
  # together so their transactions genuinely overlap.
  defp concurrently(count, fun) do
    tasks = Enum.map(1..count, &start_waiting(fun, &1))

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp start_waiting(fun, i), do: Task.async(fn -> await_go(fun, i) end)

  defp await_go(fun, i) do
    receive do
      :go -> on_own_connection(fn -> fun.(i) end)
    end
  end

  # Runs the two halves of a delivery decision so they OVERLAP: the winner holds the row
  # inside an open transaction, the loser is started against it and blocks on the row lock,
  # then the winner commits. Returns {winner_result, loser_result}.
  defp interleave(runner, dispatch, first) do
    test = self()

    winner =
      Task.async(fn ->
        on_own_connection(fn -> hold_then_decide(runner, dispatch, first, test) end)
      end)

    assert_receive :holding, 5_000
    waiting = waiting_locks()
    loser = Task.async(fn -> decide_delivery(runner, dispatch, other_half(first)) end)
    await_waiting_locks(waiting + 1)
    send(winner.pid, :go)

    {:ok, winner_result} = Task.await(winner, 30_000)
    {winner_result, Task.await(loser, 30_000)}
  end

  defp hold_then_decide(runner, dispatch, half, test) do
    Repo.with_tenant(runner.tenant_id, fn ->
      Repo.one!(
        from x in DispatchRecord,
          where: x.tenant_id == ^runner.tenant_id and x.dispatch_id == ^dispatch.dispatch_id,
          lock: "FOR UPDATE",
          select: x.id
      )

      send(test, :holding)
      assert_receive_in_task(:go)
      decide_delivery(runner, dispatch, half)
    end)
  end

  defp other_half(:push), do: :drop

  defp other_half(:drop), do: :push

  # Inside a transaction the caller already owns (the winner) the decision is a plain call;
  # the loser opens its own.
  defp decide_delivery(runner, dispatch, :push) do
    if Repo.in_transaction?(),
      do: {:ok, DispatchLedger.decide_delivery_in(Repo, runner.tenant_id, dispatch, "pushed")},
      else: on_own_connection(fn -> DispatchLedger.record_push(runner.tenant_id, dispatch) end)
  end

  defp decide_delivery(runner, dispatch, :drop) do
    if Repo.in_transaction?(),
      do: {:ok, DispatchLedger.decide_delivery_in(Repo, runner.tenant_id, dispatch, "dropped")},
      else:
        on_own_connection(fn ->
          DispatchLedger.record_drop(runner.tenant_id, dispatch.dispatch_id)
        end)
  end

  defp record(runner, dispatch_id),
    do: on_own_connection(fn -> DispatchLedger.get_record(runner.tenant_id, dispatch_id) end)

  defp generation(runner, dispatch_id), do: record(runner, dispatch_id).slot_generation

  # The release a caller with no transaction of its own makes, naming the slot it holds.
  defp release(runner, dispatch_id, generation),
    do:
      on_own_connection(fn -> Runners.release_slot(runner.tenant_id, dispatch_id, generation) end)

  defp hold_admission_lock!(tenant_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      Capacity.admission_lock_namespace(),
      Capacity.admission_lock_key(tenant_id)
    ])
  end

  defp assert_receive_in_task(message) do
    receive do
      ^message -> :ok
    after
      30_000 -> raise "the test never sent #{inspect(message)}"
    end
  end

  defp waiting_locks do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM pg_locks WHERE NOT granted", [])
    count
  end

  # A transaction blocked on a row lock shows up in pg_locks as an ungranted request, so this
  # waits for a REAL state rather than for a duration.
  defp await_waiting_locks(expected, attempts \\ 400) do
    cond do
      waiting_locks() >= expected ->
        :ok

      attempts == 0 ->
        flunk("expected #{expected} waiting locks; saw #{waiting_locks()}")

      true ->
        Process.sleep(25)
        await_waiting_locks(expected, attempts - 1)
    end
  end
end
