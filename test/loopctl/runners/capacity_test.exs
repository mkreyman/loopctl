defmodule Loopctl.Runners.CapacityTest do
  @moduledoc """
  Issue #803: runner capacity reservation, exactly-once release, tenant admission control
  and the heal sweep.

  Each test here is one transaction at a time on the test's sandbox connection, which in
  test AdminRepo shares (`Loopctl.AdminRepo.Route`), so nothing here commits. Everything whose
  subject is how Postgres arbitrates CONCURRENT transactions (racing reservations, a lock
  wait that runs out, the delivery decision's overlap, the lock order) needs separate
  connections and is `Loopctl.Runners.CapacityConcurrencyTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

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

  # A runner in a tenant of its own unless `attrs` names one. The tenant is `:agent_rooted`,
  # the column's own default.
  defp runner(attrs) do
    attrs =
      Map.put_new_lazy(attrs, :tenant_id, fn ->
        fixture(:tenant, %{trust_tier: :agent_rooted}).id
      end)

    {_raw, runner} = fixture(:runner, attrs)
    runner
  end

  defp in_flight(runner) do
    AdminRepo.one!(from r in Runner, where: r.id == ^runner.id, select: r.in_flight)
  end

  defp held(runner) do
    AdminRepo.one!(
      from r in Runner,
        where: r.id == ^runner.id,
        select: %{
          max_sessions: r.max_sessions,
          enrolled_max_sessions: r.enrolled_max_sessions,
          in_flight: r.in_flight,
          updated_at: r.updated_at
        }
    )
  end

  defp apply_declared(runner, declared, opts \\ []) do
    {tenant_id, opts} = Keyword.pop(opts, :tenant_id, runner.tenant_id)

    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        Capacity.apply_declared(Repo, tenant_id, runner.id, declared, opts)
      end)

    result
  end

  defp unreleased(runner) do
    {:ok, count} =
      Repo.with_tenant(runner.tenant_id, fn ->
        Repo.aggregate(
          from(d in DispatchRecord, where: d.runner_id == ^runner.id and is_nil(d.released_at)),
          :count
        )
      end)

    count
  end

  defp ledger_rows(runner) do
    {:ok, count} =
      Repo.with_tenant(runner.tenant_id, fn ->
        Repo.aggregate(from(d in DispatchRecord, where: d.runner_id == ^runner.id), :count)
      end)

    count
  end

  defp story(tenant_id, epoch \\ 0) do
    fixture(:ledger_story, %{tenant_id: tenant_id, claim_epoch: epoch})
  end

  defp dispatch(tenant_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    story_id = Map.get_lazy(attrs, "story_id", fn -> story(tenant_id).id end)

    {:ok, dispatch} =
      RunnerContract.cast_dispatch(build(:runner_dispatch, Map.put(attrs, "story_id", story_id)))

    dispatch
  end

  defp send_dispatch(runner, dispatch),
    do: DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)

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
    DispatchLedger.record_reply(runner.tenant_id, runner.id, reply)
  end

  defp force_dispatch(runner, dispatch_id, fields) do
    {:ok, {1, _}} =
      Repo.with_tenant(runner.tenant_id, fn ->
        from(d in DispatchRecord,
          where: d.tenant_id == ^runner.tenant_id and d.dispatch_id == ^dispatch_id
        )
        |> Repo.update_all(set: fields)
      end)
  end

  # The row write `Runners.revoke_runner/3` and the api-key trigger both make, and nothing
  # else: the function's own side effects are not what these tests are about.
  defp revoke(runner) do
    {1, _} =
      from(r in Runner, where: r.id == ^runner.id)
      |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])
  end

  defp heal(runner), do: Runners.heal_capacity(runner.tenant_id, runner.id)

  defp record(runner, dispatch_id),
    do: DispatchLedger.get_record(runner.tenant_id, dispatch_id)

  defp generation(runner, dispatch_id), do: record(runner, dispatch_id).slot_generation

  # The release a caller with no transaction of its own makes, naming the slot it holds.
  defp release(runner, dispatch_id, generation \\ nil) do
    generation = generation || generation(runner, dispatch_id)
    Runners.release_slot(runner.tenant_id, dispatch_id, generation)
  end

  describe "reserve_slot/2" do
    test "a revoked runner cannot reserve" do
      runner = runner(%{max_sessions: 3})
      revoke(runner)

      assert Runners.reserve_slot(runner.tenant_id, runner.id) ==
               {:error, :runner_at_capacity}

      assert in_flight(runner) == 0
    end

    test "another tenant's runner cannot be reserved by id, at either layer" do
      runner = runner(%{max_sessions: 3})
      other = runner(%{max_sessions: 3})

      # RLS refuses it on the app role...
      assert Runners.reserve_slot(other.tenant_id, runner.id) ==
               {:error, :runner_at_capacity}

      assert in_flight(runner) == 0

      # ...and `reserve/3`'s explicit `tenant_id` predicate refuses it again on the BYPASSRLS
      # repo, which is the only layer where that second predicate is observable at all. Without
      # this call the test passes with the predicate DELETED, since `with_tenant/2` has already
      # set the RLS context and the policy filtered the row — a defence-in-depth claim nothing
      # proved (#846.4 review finding 9, mutation-checked, the same shape as the
      # `apply_declared/4` case below).
      assert Capacity.reserve(AdminRepo, other.tenant_id, runner.id) ==
               {:error, :runner_at_capacity}

      assert in_flight(runner) == 0
    end
  end

  describe "apply_declared/4" do
    test "raises the held capacity back up to what the machine declares, and the slots follow at once" do
      runner = runner(%{max_sessions: 3})

      # The machine took itself down to one on an earlier connection...
      assert {:ok, %{max_sessions: 1, in_flight: 0}} = apply_declared(runner, 1)
      assert {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id))

      assert send_dispatch(runner, dispatch(runner.tenant_id)) ==
               {:error, :runner_at_capacity}

      # ...and puts itself back up, which is allowed because 3 is what it was ENROLLED with.
      # The one session it is running is still counted, which is what the recount preserves:
      # the raise reconciles the counter with the live rows, it does not zero it.
      assert {:ok, %{max_sessions: 3, in_flight: 1}} = apply_declared(runner, 3)
      assert unreleased(runner) == 1
      assert {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id))
      assert in_flight(runner) == 2
    end

    test "a declaration ABOVE what the machine was enrolled with is held at the enrolled ceiling" do
      runner = runner(%{max_sessions: 2})

      # A machine may lower itself freely...
      assert {:ok, %{max_sessions: 1}} = apply_declared(runner, 1)

      # ...and may not raise itself past the operator's grant. Without the ceiling this writes
      # 64, and the runner has just enlarged its own share of the tenant's admission budget.
      assert {:ok, %{max_sessions: 2}} = apply_declared(runner, 64)
      assert held(runner).max_sessions == 2
      assert held(runner).enrolled_max_sessions == 2

      # And the slots follow the CEILING, not the declaration.
      assert {:ok, 1} = Runners.reserve_slot(runner.tenant_id, runner.id)
      assert {:ok, 2} = Runners.reserve_slot(runner.tenant_id, runner.id)

      assert Runners.reserve_slot(runner.tenant_id, runner.id) ==
               {:error, :runner_at_capacity}
    end

    test "re-declaring above the ceiling while already held there writes nothing at all" do
      runner = runner(%{max_sessions: 2})
      before = held(runner)

      # The predicate compares what would be WRITTEN, not the raw declaration, so a machine
      # that declares 8 on every reconnect does not take the runner row's lock every time.
      assert apply_declared(runner, 8) == :unchanged
      assert held(runner) == before
    end

    test "lowering it under the machine's live slots clamps in_flight, releases nothing, and stops new work" do
      runner = runner(%{max_sessions: 3})

      for _ <- 1..2 do
        assert {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id))
      end

      assert in_flight(runner) == 2
      assert unreleased(runner) == 2

      # `runners_in_flight_range` CHECKs in_flight <= max_sessions, so the clamp is what makes
      # this write representable at all — a bare one would raise.
      assert {:ok, %{max_sessions: 1, in_flight: 1}} = apply_declared(runner, 1)

      # The two sessions the machine is still running keep their ledger rows; only the number
      # loopctl will hand out moved.
      assert unreleased(runner) == 2

      assert Runners.reserve_slot(runner.tenant_id, runner.id) ==
               {:error, :runner_at_capacity}
    end

    test "after the clamp, releasing ONE of the machine's live sessions frees NO slot" do
      runner = runner(%{max_sessions: 2})
      [first, second] = for _ <- 1..2, do: dispatch(runner.tenant_id)
      for d <- [first, second], do: assert({:ok, _} = send_dispatch(runner, d))

      assert in_flight(runner) == 2
      assert unreleased(runner) == 2

      # The machine rejoins declaring one while still running two. The clamp is the only
      # representable write (`runners_in_flight_range`), and it leaves the row deliberately
      # BELOW its own unreleased count — the one place the module's invariant is false.
      assert {:ok, %{max_sessions: 1, in_flight: 1}} = apply_declared(runner, 1)
      assert unreleased(runner) == 2

      # THE DEFECT THIS TEST EXISTS FOR IS ONE STEP PAST THE CLAMP. The first session ends.
      # A release that DECREMENTED wrote in_flight 0 here while the second session was still
      # running, and the reserve below then succeeded — putting two concurrent dispatches on a
      # machine that declares one, which is the over-dispatch this whole path removes.
      assert release(runner, first.dispatch_id) == {:ok, :released}
      assert unreleased(runner) == 1
      assert in_flight(runner) == 1

      assert Runners.reserve_slot(runner.tenant_id, runner.id) ==
               {:error, :runner_at_capacity}

      # Only when the machine is genuinely under its declared capacity does a slot come back.
      assert release(runner, second.dispatch_id) == {:ok, :released}
      assert unreleased(runner) == 0
      assert in_flight(runner) == 0
      assert {:ok, 1} = Runners.reserve_slot(runner.tenant_id, runner.id)
    end

    test "a declaration equal to the held capacity writes nothing at all" do
      runner = runner(%{max_sessions: 2})
      before = held(runner)

      assert apply_declared(runner, 2) == :unchanged
      assert held(runner) == before
    end

    test "a revoked runner is left alone" do
      runner = runner(%{max_sessions: 4})
      revoke(runner)

      assert apply_declared(runner, 1) == :unchanged
      assert held(runner).max_sessions == 4
    end

    test "another tenant cannot move a runner's capacity by id, at either layer" do
      runner = runner(%{max_sessions: 4})
      other = runner(%{max_sessions: 4})

      # RLS refuses it on the app role...
      assert apply_declared(runner, 1, tenant_id: other.tenant_id) == :unchanged
      assert held(runner).max_sessions == 4

      # ...and the explicit `tenant_id` predicate refuses it again on the BYPASSRLS repo,
      # which is the only place that second layer can be observed at all. Asserted here
      # because on `Repo` alone the predicate is inert: drop it and this describe still
      # passes, since the policy has already filtered the row (mutation-checked).
      assert Capacity.apply_declared(AdminRepo, other.tenant_id, runner.id, 1) == :unchanged

      assert held(runner).max_sessions == 4
    end

    test "raising the declaration back does NOT hand out a slot the machine is already using" do
      # #846.4 review ROUND 3, finding 1. The clamp in the UPDATE only ever LOWERS, so nothing
      # in the statement reconciles the counter when `max_sessions` goes back UP while the
      # clamped sessions are still running. This is the sequence the contract's own promise
      # walks into — "lowering it below the sessions loopctl currently holds sends no more work
      # until those drain, rather than cancelling them" — and the operator reverting the
      # configuration is the second half of it.
      runner = runner(%{max_sessions: 2})

      for _ <- 1..2, do: assert({:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id)))
      assert in_flight(runner) == 2
      assert unreleased(runner) == 2

      # The machine rejoins declaring 1 while still holding both. The counter is now SHORT of
      # its own live rows, deliberately and stably (`heal/3` writes the same 1).
      assert {:ok, %{max_sessions: 1, in_flight: 1}} = apply_declared(runner, 1)
      assert unreleased(runner) == 2

      # The configuration is reverted and the machine rejoins declaring 2. BOTH sessions are
      # still running. Without the recount the row reads `in_flight: 1` against
      # `max_sessions: 2` and the reserve below is a THIRD concurrent dispatch on a machine
      # already running its declared maximum — the over-dispatch this whole path removes,
      # reinstated by the other direction of the same clamp.
      # The OVER-DISPATCH is asserted first, and on its own line, so it is this behaviour that
      # goes red when the recount is removed rather than the bookkeeping that explains it.
      assert {:ok, %{max_sessions: 2}} = apply_declared(runner, 2)
      assert unreleased(runner) == 2

      assert send_dispatch(runner, dispatch(runner.tenant_id)) ==
               {:error, :runner_at_capacity}

      assert in_flight(runner) == 2
    end

    test "`only_lower: true` refuses a write that would RAISE the held capacity" do
      # #846.4 review ROUND 3, finding 5. The channel's `:recheck` retry re-applies a
      # declaration ITS OWN connection carried, and that connection can have been superseded by
      # a newer socket which already wrote a smaller number and then gone again — no check made
      # at the moment of the retry can see a connection that is already over. So the retry is
      # allowed to be wrong only in the direction the module's asymmetry calls cheap.
      runner = runner(%{max_sessions: 4})

      # A newer socket declared 1 and wrote it.
      assert {:ok, %{max_sessions: 1}} = apply_declared(runner, 1)

      # The older socket, still live and still pending, retries ITS declaration of 4.
      assert apply_declared(runner, 4, only_lower: true) == :unchanged
      assert held(runner).max_sessions == 1

      # Unbounded, the same call raises the machine straight back to a capacity it no longer
      # declares — which is what this option exists to refuse.
      assert {:ok, %{max_sessions: 4}} = apply_declared(runner, 4)
    end

    test "`only_lower: true` still applies the lowering the retry exists for" do
      runner = runner(%{max_sessions: 4})

      # The state the retry repairs: the row holds a LARGER stale number because the join's
      # write never landed, so the machine is dispatchable against a capacity it did not
      # declare. Bounding the retry downward costs it nothing here.
      assert {:ok, %{max_sessions: 1, in_flight: 0}} = apply_declared(runner, 1, only_lower: true)
      assert held(runner).max_sessions == 1

      # And an equal declaration is a no-op under the bound, exactly as it is without it.
      assert apply_declared(runner, 1, only_lower: true) == :unchanged
    end
  end

  describe "record_sent/3 reserves" do
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

      first_slot = generation(runner, d.dispatch_id)
      assert release(runner, d.dispatch_id, first_slot) == {:ok, :released}
      assert in_flight(runner) == 0

      assert {:ok, reserved} = send_dispatch(runner, d)
      assert is_nil(reserved.released_at)
      assert reserved.slot_generation == first_slot + 1
      assert in_flight(runner) == 1

      # The release meant for the FIRST slot, retried after the re-send, must not free the
      # second one — it is a different session.
      assert release(runner, d.dispatch_id, first_slot) == {:ok, :already_released}
      assert in_flight(runner) == 1

      assert release(runner, d.dispatch_id, first_slot + 1) == {:ok, :released}
      assert in_flight(runner) == 0
    end

    test "a revoked runner is refused and nothing is recorded" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      revoke(runner)

      assert send_dispatch(runner, d) == {:error, :runner_at_capacity}
      assert ledger_rows(runner) == 0
    end
  end

  describe "admission control" do
    test "refuses a runner with free slots once the tenant is at its limit" do
      a = runner(%{max_sessions: 4})
      b = runner(%{max_sessions: 4, tenant_id: a.tenant_id})

      for _ <- 1..4, do: assert({:ok, _} = send_dispatch(a, dispatch(a.tenant_id)))
      for _ <- 1..2, do: assert({:ok, _} = send_dispatch(b, dispatch(a.tenant_id)))

      assert send_dispatch(b, dispatch(a.tenant_id)) == {:error, :admission_limit_reached}
      assert in_flight(b) == 2

      assert Runners.admission(a.tenant_id) ==
               {:error, :admission_limit_reached}
    end

    test "a different tenant is unaffected by one at its limit" do
      a = runner(%{max_sessions: 6})
      other = runner(%{max_sessions: 2})

      for _ <- 1..6, do: assert({:ok, _} = send_dispatch(a, dispatch(a.tenant_id)))
      assert send_dispatch(a, dispatch(a.tenant_id)) == {:error, :admission_limit_reached}

      assert {:ok, _} = send_dispatch(other, dispatch(other.tenant_id))

      assert Runners.admission(other.tenant_id) ==
               {:ok, %{in_flight: 1, limit: 6}}
    end

    test "a machine that clamped its counter still counts its live sessions against the tenant" do
      # #846.4 review ROUND 2, finding 2. `apply_declared/4` clamps `in_flight` DOWN without
      # releasing a single reservation, and `write_count/5` pins the counter at
      # `min(live, max_sessions)` so the gap persists until those sessions drain. That break is
      # right for `reserve/3` and WRONG for `admit/2`: summed raw, one machine could lower the
      # tenant's visible load by up to 63 and the tenant would run that many more concurrent
      # sessions than `RUNNER_MAX_IN_FLIGHT_SESSIONS` allows, stably — `heal/3`'s
      # `min(3, 1) = 1` equals the drifted value. Newly reachable with this change: before it,
      # the only route to `live > max` was re-enrolment at a smaller value, which makes a NEW
      # row.
      a = runner(%{max_sessions: 3})
      b = runner(%{max_sessions: 4, tenant_id: a.tenant_id})
      assert Capacity.limit() == 6

      for _ <- 1..3, do: assert({:ok, _} = send_dispatch(a, dispatch(a.tenant_id)))
      assert in_flight(a) == 3

      # The machine rejoins declaring 1 while three of its sessions are still running.
      assert {:ok, %{max_sessions: 1, in_flight: 1}} = apply_declared(a, 1)
      assert ledger_rows(a) == 3

      # Three sessions ARE running on `a`, so that is what the tenant is running.
      assert Runners.admission(a.tenant_id) == {:ok, %{in_flight: 3, limit: 6}}

      for _ <- 1..3, do: assert({:ok, _} = send_dispatch(b, dispatch(a.tenant_id)))

      # The limit binds at 6. Reading `a`'s counter instead, the tenant would have admitted a
      # fourth here and run 8 concurrent sessions against a cap of 6.
      assert send_dispatch(b, dispatch(a.tenant_id)) == {:error, :admission_limit_reached}
      assert in_flight(b) == 3
    end

    test "a slot taken with no dispatch row of its own still counts against the tenant" do
      # The other half of the same sum, and the reason it is `GREATEST` rather than a count of
      # live reservations: `Runners.reserve_slot/2` increments the counter and ties the slot to
      # no `runner_dispatches` row at all, so counting rows alone would have made it free.
      a = runner(%{max_sessions: 2})

      assert {:ok, 1} = Runners.reserve_slot(a.tenant_id, a.id)
      assert ledger_rows(a) == 0

      assert Runners.admission(a.tenant_id) == {:ok, %{in_flight: 1, limit: 6}}
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

      slot = generation(runner, d1.dispatch_id)

      assert release(runner, d1.dispatch_id, slot) == {:ok, :released}
      assert release(runner, d1.dispatch_id, slot) == {:ok, :already_released}
      # d2's slot keeps the counter off the zero floor, so a double decrement would show.
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

      assert DispatchLedger.get_record(runner.tenant_id, d1.dispatch_id).status ==
               "superseded"
    end

    test "another tenant cannot release a dispatch by id" do
      runner = runner(%{max_sessions: 3})
      other = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)

      assert Runners.release_slot(other.tenant_id, d.dispatch_id, 1) ==
               {:error, :unknown_dispatch}

      assert in_flight(runner) == 1
    end
  end

  defp bump_epoch(tenant_id, story_id) do
    {:ok, _} =
      Repo.with_tenant(tenant_id, fn ->
        story = Repo.get!(Story, story_id)

        story
        |> Ecto.Changeset.change(Loopctl.Progress.claim_release_change(story))
        |> Repo.update!()
      end)
  end

  describe "the delivery decision" do
    test "a push refreshes the wall clock to the dispatch actually delivered" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 600})
      {:ok, _} = send_dispatch(runner, d)

      longer = %{d | wall_clock_seconds: 3_600}

      assert DispatchLedger.record_push(runner.tenant_id, longer) ==
               {:ok, :pushed}

      assert record(runner, d.dispatch_id).wall_clock_seconds == 3_600
    end

    test "a DROPPED re-send does not move the bound of the session already running" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 3_600})
      {:ok, _} = send_dispatch(runner, d)
      assert DispatchLedger.record_push(runner.tenant_id, d) == {:ok, :pushed}
      {:ok, _} = reply(runner, d, %{})

      # A dispatcher deriving the clock from what is left of the lease naturally sends a
      # SHORTER one; dropped, it must not shrink the running session's bound.
      shorter = %{d | wall_clock_seconds: 60}

      assert DispatchLedger.record_drop(runner.tenant_id, shorter.dispatch_id) ==
               {:ok, {:already, "pushed"}}

      assert record(runner, d.dispatch_id).wall_clock_seconds == 3_600
      assert in_flight(runner) == 1
    end

    test "another tenant cannot decide a dispatch by id" do
      runner = runner(%{max_sessions: 3})
      other = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)

      assert DispatchLedger.record_drop(other.tenant_id, d.dispatch_id) ==
               {:error, :unknown_dispatch}

      assert in_flight(runner) == 1
    end

    test "a new reservation clears the decision, so the re-send can be delivered" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)

      assert DispatchLedger.record_drop(runner.tenant_id, d.dispatch_id) ==
               {:ok, :released}

      {:ok, reserved} = send_dispatch(runner, d)
      assert is_nil(reserved.delivery)

      assert DispatchLedger.record_push(runner.tenant_id, d) == {:ok, :pushed}
    end
  end

  describe "retryable?/1" do
    # What a caller answers `:capacity_busy` on. A deadlock is as transient as a lock
    # timeout and just as pointless to raise: the transaction is already gone, and the
    # alternative is a crashed channel or a 500 out of dispatch/3.
    test "a lock timeout and a broken deadlock are retryable; nothing else is" do
      for code <- [:lock_not_available, :deadlock_detected] do
        assert Capacity.retryable?(%Postgrex.Error{postgres: %{code: code}})
      end

      for code <- [:unique_violation, :check_violation, :serialization_failure] do
        refute Capacity.retryable?(%Postgrex.Error{postgres: %{code: code}})
      end

      refute Capacity.retryable?(%RuntimeError{message: "not a database error"})
    end
  end

  describe "release_slot_in/4 — the caller's own transaction" do
    test "releases inside an AdminRepo transaction, so it commits with the caller's work" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      slot = generation(runner, d.dispatch_id)

      outcome =
        AdminRepo.transaction(fn ->
          DispatchLedger.release_slot_in(AdminRepo, runner.tenant_id, d.dispatch_id, slot)
        end)

      assert outcome == {:ok, {:ok, :released}}
      assert in_flight(runner) == 0
      assert record(runner, d.dispatch_id).released_at
    end

    test "releases inside a Repo transaction that carries the tenant's RLS context" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      slot = generation(runner, d.dispatch_id)

      outcome =
        Repo.with_tenant(runner.tenant_id, fn ->
          DispatchLedger.release_slot_in(Repo, runner.tenant_id, d.dispatch_id, slot)
        end)

      assert outcome == {:ok, {:ok, :released}}
      assert in_flight(runner) == 0
    end

    test "refuses to run outside a transaction rather than opening one of its own" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      slot = generation(runner, d.dispatch_id)

      assert_raise ArgumentError, ~r/must run inside the caller's/, fn ->
        DispatchLedger.release_slot_in(AdminRepo, runner.tenant_id, d.dispatch_id, slot)
      end

      assert in_flight(runner) == 1
    end

    test "a rolled-back caller transaction takes the release with it" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      slot = generation(runner, d.dispatch_id)

      AdminRepo.transaction(fn ->
        {:ok, :released} =
          DispatchLedger.release_slot_in(AdminRepo, runner.tenant_id, d.dispatch_id, slot)

        AdminRepo.rollback(:caller_changed_its_mind)
      end)

      assert in_flight(runner) == 1
      refute record(runner, d.dispatch_id).released_at
    end
  end

  describe "heal" do
    test "gives back a slot no dispatch holds" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, d)
      {:ok, _} = Runners.reserve_slot(runner.tenant_id, runner.id)
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

      {:ok, _} =
        Repo.with_tenant(runner.tenant_id, fn -> Repo.delete!(Repo.get!(Story, s.id)) end)

      assert heal(runner) == {:ok, %{released: 1, in_flight: 0}}
    end

    test "releases an accepted session past its wall clock and grace, and keeps one inside it" do
      runner = runner(%{max_sessions: 3})
      expired = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 600})
      live = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 600})

      for d <- [expired, live] do
        {:ok, _} = send_dispatch(runner, d)

        assert DispatchLedger.record_push(runner.tenant_id, d) ==
                 {:ok, :pushed}

        {:ok, _} = reply(runner, d, %{})
      end

      grace = Capacity.release_grace_seconds()
      now = DateTime.utc_now()

      force_dispatch(runner, expired.dispatch_id,
        replied_at: DateTime.add(now, -(600 + grace + 60))
      )

      force_dispatch(runner, live.dispatch_id, replied_at: DateTime.add(now, -(600 + grace - 60)))

      assert heal(runner) == {:ok, %{released: 1, in_flight: 1}}
      assert record(runner, live.dispatch_id).released_at == nil
    end

    test "a SHORTER resumed push does not free the slot of the session the longer one started" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 3_600})
      {:ok, _} = send_dispatch(runner, d)
      assert DispatchLedger.record_push(runner.tenant_id, d) == {:ok, :pushed}

      # A resume: re-sent, which clears the delivery, then pushed with a shorter clock.
      shorter = %{d | wall_clock_seconds: 600}
      {:ok, _} = send_dispatch(runner, shorter)

      assert DispatchLedger.record_push(runner.tenant_id, shorter) ==
               {:ok, :pushed}

      assert record(runner, d.dispatch_id).wall_clock_seconds == 600
      {:ok, _} = reply(runner, d, %{})

      # Past the SHORTER clock and the grace, well inside the longer one.
      grace = Capacity.release_grace_seconds()

      force_dispatch(runner, d.dispatch_id,
        replied_at: DateTime.add(DateTime.utc_now(), -(600 + grace + 60))
      )

      assert heal(runner) == {:ok, %{released: 0, in_flight: 1}}
    end

    test "releases a PUSHED dispatch the runner never answered, on the reply grace" do
      runner = runner(%{max_sessions: 3})
      # A wall clock far longer than the reply grace: a push that did not land — a stamp whose
      # commit ack was lost, a channel that died — must not pin the slot for a whole session.
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 3_600})
      {:ok, _} = send_dispatch(runner, d)
      assert DispatchLedger.record_push(runner.tenant_id, d) == {:ok, :pushed}

      reply_grace = Capacity.reply_grace_seconds()
      now = DateTime.utc_now()

      force_dispatch(runner, d.dispatch_id, pushed_at: DateTime.add(now, -(reply_grace - 30)))
      assert heal(runner) == {:ok, %{released: 0, in_flight: 1}}

      force_dispatch(runner, d.dispatch_id, pushed_at: DateTime.add(now, -(reply_grace + 30)))
      assert heal(runner) == {:ok, %{released: 1, in_flight: 0}}
    end

    test "a DELIVERED reservation is not released by the undelivered bound, however old" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 3_600})
      {:ok, _} = send_dispatch(runner, d)
      assert DispatchLedger.record_push(runner.tenant_id, d) == {:ok, :pushed}
      {:ok, _} = reply(runner, d, %{})

      # Reserved long ago, pushed and answered: a session is running on this slot, and only
      # its wall clock ends it.
      old = DateTime.add(DateTime.utc_now(), -(Capacity.unpushed_grace_seconds() + 600))
      force_dispatch(runner, d.dispatch_id, reserved_at: old, pushed_at: old)

      assert heal(runner) == {:ok, %{released: 0, in_flight: 1}}
    end

    test "an UNDELIVERED reservation is released on the short bound, not the wall clock" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 3_600})
      {:ok, _} = send_dispatch(runner, d)

      unpushed = Capacity.unpushed_grace_seconds()
      now = DateTime.utc_now()

      force_dispatch(runner, d.dispatch_id, reserved_at: DateTime.add(now, -(unpushed - 30)))
      assert heal(runner) == {:ok, %{released: 0, in_flight: 1}}

      force_dispatch(runner, d.dispatch_id, reserved_at: DateTime.add(now, -(unpushed + 30)))
      assert heal(runner) == {:ok, %{released: 1, in_flight: 0}}
    end

    test "a decision from an EARLIER reservation does not count as this one's" do
      runner = runner(%{max_sessions: 3})
      d = dispatch(runner.tenant_id, %{"wall_clock_seconds" => 3_600})
      {:ok, _} = send_dispatch(runner, d)
      assert DispatchLedger.record_push(runner.tenant_id, d) == {:ok, :pushed}

      # Released and re-sent: the new slot has never been delivered under, so the short bound
      # applies to it even though the row was pushed under the previous one.
      assert release(runner, d.dispatch_id) == {:ok, :released}
      {:ok, _} = send_dispatch(runner, d)

      unpushed = Capacity.unpushed_grace_seconds()
      old = DateTime.add(DateTime.utc_now(), -(unpushed + 30))
      force_dispatch(runner, d.dispatch_id, reserved_at: old, pushed_at: old)

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
      {:ok, _} = Runners.reserve_slot(runner.tenant_id, runner.id)

      assert Runners.heal_capacity(other.tenant_id, runner.id) ==
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
      {:ok, _} = Runners.reserve_slot(runner.tenant_id, runner.id)

      assert heal(runner) == {:ok, %{released: 1, in_flight: 0}}
    end

    test "the worker finds a runner by its counter alone and by an unreleased dispatch alone" do
      leaked = runner(%{max_sessions: 3})
      {:ok, _} = Runners.reserve_slot(leaked.tenant_id, leaked.id)

      # A dead reservation whose runner's COUNTER agrees with its rows, so only the
      # dead-reservation candidate query can find it.
      dead = runner(%{max_sessions: 3})
      s = story(dead.tenant_id)
      {:ok, _} = send_dispatch(dead, dispatch(dead.tenant_id, %{"story_id" => s.id}))
      bump_epoch(dead.tenant_id, s.id)
      assert in_flight(dead) == 1
      assert unreleased(dead) == 1

      assert :ok = HealRunnerCapacityWorker.perform(%Oban.Job{args: %{}})

      assert in_flight(leaked) == 0
      assert unreleased(dead) == 0
    end

    test "the worker leaves a healthy runner's live reservation alone" do
      runner = runner(%{max_sessions: 3})
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id))

      assert :ok = HealRunnerCapacityWorker.perform(%Oban.Job{args: %{}})

      assert in_flight(runner) == 1
      assert unreleased(runner) == 1
    end

    test "the worker heals a leaked slot and a dead reservation" do
      runner = runner(%{max_sessions: 3})
      s = story(runner.tenant_id)
      {:ok, _} = send_dispatch(runner, dispatch(runner.tenant_id, %{"story_id" => s.id}))
      {:ok, _} = Runners.reserve_slot(runner.tenant_id, runner.id)
      bump_epoch(runner.tenant_id, s.id)
      assert in_flight(runner) == 2

      assert :ok = HealRunnerCapacityWorker.perform(%Oban.Job{args: %{}})

      assert in_flight(runner) == 0
      assert unreleased(runner) == 0
    end
  end
end
