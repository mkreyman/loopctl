defmodule Loopctl.Runners.CapacityTest do
  @moduledoc """
  Issue #803: runner capacity reservation, exactly-once release, tenant admission control
  and the heal sweep.

  ## Why `async: false`, and why every write runs UNBOXED

  What is under test is how Postgres arbitrates concurrent transactions: a conditional
  UPDATE racing on one row, an advisory lock serializing a tenant's admissions, a lock wait
  that must run out. Inside the SQL sandbox every write of a test shares ONE connection and
  one open transaction, so no two of them can ever race and no lock is ever released. So
  the tenants, runners and stories here are committed (`fixture(:committed_runner)`, swept
  at module boundaries, which is why no other test may run meanwhile), and every capacity
  call runs through `unboxed/1` on a real connection of its own, committing as production
  does. A write left in the test's sandbox transaction would hold its runner row locked
  until the test ended and stall every unboxed writer behind it.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.HealRunnerCapacityWorker

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp runner(attrs) do
    {_raw, runner} = fixture(:committed_runner, attrs)
    runner
  end

  defp in_flight(runner) do
    unboxed(fn ->
      AdminRepo.one!(from r in Runner, where: r.id == ^runner.id, select: r.in_flight)
    end)
  end

  defp unreleased(runner) do
    unboxed(fn ->
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
    unboxed(fn ->
      {:ok, count} =
        Repo.with_tenant(runner.tenant_id, fn ->
          Repo.aggregate(from(d in DispatchRecord, where: d.runner_id == ^runner.id), :count)
        end)

      count
    end)
  end

  defp story(tenant_id, epoch \\ 0) do
    unboxed(fn -> fixture(:ledger_story, %{tenant_id: tenant_id, claim_epoch: epoch}) end)
  end

  defp dispatch(tenant_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    story_id = Map.get_lazy(attrs, "story_id", fn -> story(tenant_id).id end)

    {:ok, dispatch} =
      RunnerContract.cast_dispatch(build(:runner_dispatch, Map.put(attrs, "story_id", story_id)))

    dispatch
  end

  defp send_dispatch(runner, dispatch),
    do: unboxed(fn -> DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch) end)

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
    unboxed(fn -> DispatchLedger.record_reply(runner.tenant_id, runner.id, reply) end)
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
      :go -> unboxed(fn -> fun.(i) end)
    end
  end

  defp force_dispatch(runner, dispatch_id, fields) do
    unboxed(fn ->
      {:ok, {1, _}} =
        Repo.with_tenant(runner.tenant_id, fn ->
          from(d in DispatchRecord,
            where: d.tenant_id == ^runner.tenant_id and d.dispatch_id == ^dispatch_id
          )
          |> Repo.update_all(set: fields)
        end)
    end)
  end

  # The row write `Runners.revoke_runner/3` and the api-key trigger both make. Not the
  # function itself: its audit-chain entry cannot be deleted, so the sweep could not remove
  # the committed tenant.
  defp revoke(runner) do
    Sandbox.unboxed_run(AdminRepo, fn ->
      {1, _} =
        from(r in Runner, where: r.id == ^runner.id)
        |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])
    end)
  end

  defp heal(runner), do: unboxed(fn -> Runners.heal_capacity(runner.tenant_id, runner.id) end)

  describe "reserve_slot/2" do
    test "from more concurrent callers than slots, exactly max_sessions win" do
      runner = runner(%{max_sessions: 3})

      results = concurrently(10, fn _ -> Runners.reserve_slot(runner.tenant_id, runner.id) end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :runner_at_capacity})) == 7
      assert in_flight(runner) == 3
    end

    test "a revoked runner cannot reserve" do
      runner = runner(%{max_sessions: 3})
      revoke(runner)

      assert unboxed(fn -> Runners.reserve_slot(runner.tenant_id, runner.id) end) ==
               {:error, :runner_at_capacity}

      assert in_flight(runner) == 0
    end

    test "another tenant's runner cannot be reserved by id" do
      runner = runner(%{max_sessions: 3})
      other = runner(%{max_sessions: 3})

      assert unboxed(fn -> Runners.reserve_slot(other.tenant_id, runner.id) end) ==
               {:error, :runner_at_capacity}

      assert in_flight(runner) == 0
    end
  end

  describe "record_sent/3 reserves" do
    test "from more concurrent dispatches than slots, exactly max_sessions are recorded" do
      runner = runner(%{max_sessions: 3})
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

    test "a re-send of a dispatch holding its slot takes no second one" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)

      assert {:ok, _} = send_dispatch(runner, d)
      assert {:ok, _} = send_dispatch(runner, d)
      assert in_flight(runner) == 1
      assert unreleased(runner) == 1
    end

    test "a re-send of a dispatch whose slot was released takes a fresh one" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)

      assert {:ok, _} = send_dispatch(runner, d)

      assert {:ok, :released} =
               unboxed(fn -> Runners.release_slot(runner.tenant_id, d.dispatch_id) end)

      assert in_flight(runner) == 0

      assert {:ok, record} = send_dispatch(runner, d)
      assert is_nil(record.released_at)
      assert in_flight(runner) == 1
    end

    test "a revoked runner is refused and nothing is recorded" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      revoke(runner)

      assert send_dispatch(runner, d) == {:error, :runner_at_capacity}
      assert ledger_rows(runner) == 0
    end

    test "a lock wait that runs out is capacity_busy, and nothing is recorded" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      parent = self()

      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
                0x4105_0803,
                admission_key(runner.tenant_id)
              ])

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

  defp admission_key(tenant_id) do
    {:ok, <<key::signed-integer-32, _::binary>>} = Ecto.UUID.dump(tenant_id)
    key
  end

  describe "admission control" do
    test "caps a tenant's total across its runners, under concurrency" do
      # Two runners with 8 slots between them; the tenant may use only limit/0 = 6.
      a = runner(%{max_sessions: 4})
      b = runner(%{max_sessions: 4, tenant_id: a.tenant_id})
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

    test "refuses a runner with free slots once the tenant is at its limit" do
      a = runner(%{max_sessions: 4})
      b = runner(%{max_sessions: 4, tenant_id: a.tenant_id})

      for _ <- 1..4, do: assert({:ok, _} = send_dispatch(a, dispatch(a.tenant_id)))
      for _ <- 1..2, do: assert({:ok, _} = send_dispatch(b, dispatch(a.tenant_id)))

      assert send_dispatch(b, dispatch(a.tenant_id)) == {:error, :admission_limit_reached}
      assert in_flight(b) == 2

      assert unboxed(fn -> Runners.admission(a.tenant_id) end) ==
               {:error, :admission_limit_reached}
    end

    test "a different tenant is unaffected by one at its limit" do
      a = runner(%{max_sessions: 6})
      other = runner(%{max_sessions: 2})

      for _ <- 1..6, do: assert({:ok, _} = send_dispatch(a, dispatch(a.tenant_id)))
      assert send_dispatch(a, dispatch(a.tenant_id)) == {:error, :admission_limit_reached}

      assert {:ok, _} = send_dispatch(other, dispatch(other.tenant_id))

      assert unboxed(fn -> Runners.admission(other.tenant_id) end) ==
               {:ok, %{in_flight: 1, limit: 6}}
    end

    test "a revoked runner's slots stop counting against the tenant at once" do
      a = runner(%{max_sessions: 5})
      b = runner(%{max_sessions: 4, tenant_id: a.tenant_id})

      for _ <- 1..5, do: assert({:ok, _} = send_dispatch(a, dispatch(a.tenant_id)))
      revoke(a)

      for _ <- 1..4, do: assert({:ok, _} = send_dispatch(b, dispatch(a.tenant_id)))
    end
  end

  describe "release, exactly once" do
    test "release_slot replayed for the same dispatch decrements once" do
      runner = runner(%{max_sessions: 3})
      d1 = dispatch(runner.tenant_id)
      d2 = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d1)
      {:ok, _} = send_dispatch(runner, d2)

      release = fn ->
        unboxed(fn -> Runners.release_slot(runner.tenant_id, d1.dispatch_id) end)
      end

      assert release.() == {:ok, :released}
      assert release.() == {:ok, :already_released}
      # d2's slot keeps the counter off the zero floor, so a double decrement would show.
      assert in_flight(runner) == 1
    end

    test "concurrent releases of one dispatch decrement once" do
      runner = runner(%{max_sessions: 3})
      d1 = dispatch(runner.tenant_id)
      d2 = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d1)
      {:ok, _} = send_dispatch(runner, d2)

      results =
        concurrently(6, fn _ -> Runners.release_slot(runner.tenant_id, d1.dispatch_id) end)

      assert Enum.count(results, &(&1 == {:ok, :released})) == 1
      assert in_flight(runner) == 1
    end

    test "a refusal releases the slot, and its identical repeat does not release again" do
      runner = runner(%{max_sessions: 3})
      d1 = dispatch(runner.tenant_id)
      d2 = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d1)
      {:ok, _} = send_dispatch(runner, d2)

      refusal = %{"decision" => "refused", "reason" => "at_capacity"}
      assert {:ok, %{status: "refused"}} = reply(runner, d1, refusal)
      assert in_flight(runner) == 1
      assert {:ok, _} = reply(runner, d1, refusal)
      assert in_flight(runner) == 1
    end

    test "an accepted reply keeps the slot" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)

      assert {:ok, %{status: "accepted"}} = reply(runner, d, %{})
      assert in_flight(runner) == 1
    end

    test "a supersede releases the slot, once, however often the stale runner writes" do
      runner = runner(%{max_sessions: 3})
      s = story(runner.tenant_id)
      d1 = dispatch(runner.tenant_id, %{"story_id" => s.id})
      d2 = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d1)
      {:ok, _} = send_dispatch(runner, d2)
      {:ok, _} = reply(runner, d1, %{})

      bump_epoch(runner.tenant_id, s.id)

      assert reply(runner, d1, %{}) == {:error, :stale_claim_epoch}
      assert in_flight(runner) == 1
      assert reply(runner, d1, %{}) == {:error, :stale_claim_epoch}
      assert in_flight(runner) == 1

      assert unboxed(fn -> DispatchLedger.get_record(runner.tenant_id, d1.dispatch_id) end).status ==
               "superseded"
    end

    test "another tenant cannot release a dispatch by id" do
      runner = runner(%{max_sessions: 3})
      other = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)

      assert unboxed(fn -> Runners.release_slot(other.tenant_id, d.dispatch_id) end) ==
               {:error, :unknown_dispatch}

      assert in_flight(runner) == 1
    end
  end

  defp bump_epoch(tenant_id, story_id) do
    unboxed(fn ->
      {:ok, _} =
        Repo.with_tenant(tenant_id, fn ->
          story = Repo.get!(Story, story_id)

          story
          |> Ecto.Changeset.change(Loopctl.Progress.claim_release_change(story))
          |> Repo.update!()
        end)
    end)
  end

  describe "heal" do
    test "gives back a slot no dispatch holds" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      {:ok, _} = unboxed(fn -> Runners.reserve_slot(runner.tenant_id, runner.id) end)
      assert in_flight(runner) == 2

      assert heal(runner) == {:ok, %{released: 0, in_flight: 1}}
      assert in_flight(runner) == 1
    end

    test "releases a dispatch whose claim ended with nothing reported" do
      runner = runner(%{max_sessions: 3})
      s = story(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id, %{"story_id" => s.id}))
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id))

      bump_epoch(runner.tenant_id, s.id)

      assert heal(runner) == {:ok, %{released: 1, in_flight: 1}}
      assert unreleased(runner) == 1
      assert heal(runner) == {:ok, %{released: 0, in_flight: 1}}
    end

    test "releases a dispatch whose story is gone" do
      runner = runner(%{max_sessions: 3})
      s = story(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id, %{"story_id" => s.id}))

      unboxed(fn ->
        {:ok, _} =
          Repo.with_tenant(runner.tenant_id, fn -> Repo.delete!(Repo.get!(Story, s.id)) end)
      end)

      assert heal(runner) == {:ok, %{released: 1, in_flight: 0}}
    end

    test "releases a session past its wall clock and grace, and keeps one inside it" do
      runner = runner(%{max_sessions: 3})
      expired = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 600})
      live = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 600})
      {:ok, _} = send_dispatch(runner, expired)
      {:ok, _} = send_dispatch(runner, live)
      {:ok, _} = reply(runner, expired, %{})
      {:ok, _} = reply(runner, live, %{})

      grace = Capacity.release_grace_seconds()
      now = DateTime.utc_now()

      force_dispatch(runner, expired.dispatch_id,
        replied_at: DateTime.add(now, -(600 + grace + 60))
      )

      # Inserted long ago but accepted recently: the clock runs from acceptance.
      force_dispatch(runner, live.dispatch_id,
        inserted_at: DateTime.add(now, -(600 + grace + 60)),
        replied_at: DateTime.add(now, -(600 + grace - 60))
      )

      assert heal(runner) == {:ok, %{released: 1, in_flight: 1}}

      assert unboxed(fn -> DispatchLedger.get_record(runner.tenant_id, live.dispatch_id) end).released_at ==
               nil
    end

    test "a dispatch never replied to is timed from its last push" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 600})
      {:ok, _} = send_dispatch(runner, d)

      grace = Capacity.release_grace_seconds()
      now = DateTime.utc_now()
      old = DateTime.add(now, -(600 + grace + 60))

      force_dispatch(runner, d.dispatch_id, inserted_at: old, pushed_at: now)
      assert heal(runner) == {:ok, %{released: 0, in_flight: 1}}

      force_dispatch(runner, d.dispatch_id, pushed_at: old)
      assert heal(runner) == {:ok, %{released: 1, in_flight: 0}}
    end

    test "releases every slot of a revoked runner" do
      runner = runner(%{max_sessions: 3})
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id))
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id))
      revoke(runner)

      assert heal(runner) == {:ok, %{released: 2, in_flight: 0}}
      assert unreleased(runner) == 0
    end

    test "leaves another tenant's runner alone" do
      runner = runner(%{max_sessions: 3})
      other = runner(%{max_sessions: 3})
      {:ok, _} = unboxed(fn -> Runners.reserve_slot(runner.tenant_id, runner.id) end)

      assert unboxed(fn -> Runners.heal_capacity(other.tenant_id, runner.id) end) ==
               {:ok, %{released: 0, in_flight: nil}}

      assert in_flight(runner) == 1
    end

    test "releases a refused dispatch whose inline release never happened" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      {:ok, _} = reply(runner, d, %{"decision" => "refused", "reason" => "at_capacity"})
      # As if the release had been lost: the row unreleased, its slot still counted.
      force_dispatch(runner, d.dispatch_id, released_at: nil)
      {:ok, _} = unboxed(fn -> Runners.reserve_slot(runner.tenant_id, runner.id) end)

      assert heal(runner) == {:ok, %{released: 1, in_flight: 0}}
    end

    test "the worker finds a runner by its counter alone and by an unreleased dispatch alone" do
      leaked = runner(%{max_sessions: 3})
      {:ok, _} = unboxed(fn -> Runners.reserve_slot(leaked.tenant_id, leaked.id) end)

      # An unreleased dead dispatch on a runner whose counter already reads zero.
      dead = runner(%{max_sessions: 3})
      s = story(dead.tenant_id)
      {:ok, _} = send_dispatch(dead, dispatch(dead.tenant_id, %{"story_id" => s.id}))
      bump_epoch(dead.tenant_id, s.id)

      Sandbox.unboxed_run(AdminRepo, fn ->
        {1, _} =
          from(r in Runner, where: r.id == ^dead.id) |> AdminRepo.update_all(set: [in_flight: 0])
      end)

      unboxed(fn ->
        Sandbox.unboxed_run(AdminRepo, fn ->
          assert :ok = HealRunnerCapacityWorker.perform(%Oban.Job{args: %{}})
        end)
      end)

      assert in_flight(leaked) == 0
      assert unreleased(dead) == 0
    end

    test "the worker heals a leaked slot and a dead reservation" do
      runner = runner(%{max_sessions: 3})
      s = story(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id, %{"story_id" => s.id}))
      {:ok, _} = unboxed(fn -> Runners.reserve_slot(runner.tenant_id, runner.id) end)
      bump_epoch(runner.tenant_id, s.id)
      assert in_flight(runner) == 2

      unboxed(fn ->
        Sandbox.unboxed_run(AdminRepo, fn ->
          assert :ok = HealRunnerCapacityWorker.perform(%Oban.Job{args: %{}})
        end)
      end)

      assert in_flight(runner) == 0
      assert unreleased(runner) == 0
    end
  end
end
