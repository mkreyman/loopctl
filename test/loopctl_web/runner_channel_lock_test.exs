defmodule LoopctlWeb.RunnerChannelLockTest do
  @moduledoc """
  Issue #846.4 and the channel's lock_timeout paths: what the runner channel does when a
  database lock it needs is held by ANOTHER connection. The rest of dispatch, reply and trace
  is in `LoopctlWeb.RunnerChannelDispatchTest`, async.

  ## Why `async: false` and COMMITTED

  The SUBJECT of every test here is a lock held against the channel's connection: a holder
  takes `FOR UPDATE` on a row from its own unsandboxed connection, in a transaction of its own,
  and the channel's write on the test's sandbox connection really waits on it (until a
  statement timeout or `Capacity.lock_timeout_ms/0`). One sandbox connection cannot block
  itself, so the holder needs a second, and a row two connections both see must be COMMITTED:
  the runner (`fixture(:committed_runner)`) and, where a test locks it, the dispatch. A
  committed row is visible to every concurrently running test, so the module runs alone and
  `sweep_committed_runner_tenants/0` removes its rows at the module boundary. Every lock is on
  this test's own rows.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  # A BOUND on a real round trip, never a delay.
  @reply_timeout 2_000

  defp connect_info(token) do
    %{
      x_headers: [{RunnerSocket.token_header(), token}],
      peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
    }
  end

  defp join_payload(machine, overrides) do
    Map.merge(
      %{
        "contract_version" => RunnerContract.version(),
        "machine" => machine,
        "cores" => 16,
        "memory_mb" => 28_000,
        "repos" => ["mkreyman/home_care_billing"],
        "max_sessions" => 2,
        "in_flight" => 0,
        "draining" => false
      },
      overrides
    )
  end

  defp connect_runner(token), do: connect(RunnerSocket, %{}, connect_info: connect_info(token))

  # Joins and waits for the channel to process :after_join (the Presence track).
  defp topic(socket), do: "runner:" <> socket.assigns.runner.id

  defp join_pool(socket, machine, overrides) do
    {:ok, reply, channel} =
      subscribe_and_join(socket, topic(socket), join_payload(machine, overrides))

    _ = :sys.get_state(channel.channel_pid)
    {reply, channel}
  end

  defp in_pool?(tenant_id, name), do: Map.has_key?(Runners.pool(tenant_id), name)

  # The capacity loopctl DECIDES from, read on the sandbox connection the channel writes on:
  # the channel's write is uncommitted, so the holder's connection cannot see it.
  defp held_capacity(runner) do
    {:ok, held} =
      Repo.with_tenant(runner.tenant_id, fn ->
        Repo.one!(
          from r in Runner,
            where: r.id == ^runner.id,
            select: %{
              max_sessions: r.max_sessions,
              in_flight: r.in_flight,
              updated_at: r.updated_at
            }
        )
      end)

    held
  end

  # The machine drops its socket and connects again declaring `overrides`. Capacity is
  # per-CONNECTION, so a rejoin is the only way to change one.
  defp rejoin(runner, raw, channel, overrides) do
    Process.unlink(channel.channel_pid)
    ref = leave(channel)
    assert_reply ref, :ok, _, @reply_timeout
    assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end, @reply_timeout)

    {:ok, socket} = connect_runner(raw)
    {_reply, channel} = join_pool(socket, "minis", overrides)
    channel
  end

  # Moves the capacity Postgres holds, COMMITTED, with no channel involved — see the caller
  # for why a join would not do. `max_sessions` only; `enrolled_max_sessions` is the grant and
  # nothing but an enrollment writes it.
  defp hold_capacity_at!(runner, max_sessions) do
    Sandbox.unboxed_run(Loopctl.Repo, fn ->
      {1, _} =
        Loopctl.AdminRepo.update_all(
          from(r in Runner, where: r.id == ^runner.id and r.tenant_id == ^runner.tenant_id),
          set: [max_sessions: max_sessions, updated_at: DateTime.utc_now()]
        )
    end)

    :ok
  end

  # Holds `FOR UPDATE` on the runner's row from a COMMITTED transaction on its own connection,
  # so a write from the channel's connection really blocks. Returns the holder and a ref to
  # release it with.
  defp lock_runner_row(runner) do
    test = self()
    ref = make_ref()

    locker = Task.async(fn -> hold_then_release(runner, test, ref) end)

    assert_receive {:locked, ^ref}, @reply_timeout
    {locker, ref}
  end

  defp hold_then_release(runner, test, ref) do
    Sandbox.unboxed_run(Loopctl.Repo, fn ->
      Loopctl.AdminRepo.transaction(fn -> hold_runner_row(runner, test, ref) end)
    end)

    # AFTER `unboxed_run/2` has checked the connection back in. Exiting straight out of the
    # transaction tears the connection down under Postgrex and logs a disconnect that has
    # nothing to do with what is under test.
    send(test, {:released, ref})
  end

  defp hold_runner_row(runner, test, ref) do
    Loopctl.AdminRepo.one!(
      from r in Runner, where: r.id == ^runner.id, lock: "FOR UPDATE", select: r.id
    )

    send(test, {:locked, ref})

    receive do
      {:release, ^ref} -> :ok
    after
      30_000 -> :ok
    end
  end

  # AWAITED, not merely signalled: the holder's connection is checked back in as its task
  # ends, and letting the test run on while that happens tears the connection down under
  # Postgrex and logs a disconnect that has nothing to do with what is under test.
  defp release_runner_row(%Task{} = locker, ref) do
    send(locker.pid, {:release, ref})
    assert_receive {:released, ^ref}, @reply_timeout
    Task.await(locker, @reply_timeout)
  end

  # A row every connection can see, and a transaction of its own to lock it from — the only
  # way to make the channel's own writes WAIT on something inside a test.
  defp committed(fun), do: Sandbox.unboxed_run(Loopctl.Repo, fun)

  defp committed_dispatch(runner) do
    committed(fn ->
      story = fixture(:ledger_story, %{tenant_id: runner.tenant_id, claim_epoch: 0})
      payload = build(:runner_dispatch, %{"story_id" => story.id})
      {:ok, dispatch} = RunnerContract.cast_dispatch(payload)
      {:ok, _record} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      %{story: story, payload: payload, dispatch: dispatch}
    end)
  end

  # Holds `lock_query` in a committed transaction until `finish/1` is called, so a channel
  # write that needs the same row runs into its lock_timeout for real.
  defp hold_lock(tenant_id, lock_query) do
    test = self()

    task =
      Task.async(fn -> committed(fn -> hold_until_finished(tenant_id, lock_query, test) end) end)

    assert_receive :holding, 5_000
    task
  end

  defp hold_until_finished(tenant_id, lock_query, test) do
    Loopctl.Repo.with_tenant(tenant_id, fn ->
      Loopctl.Repo.one!(lock_query)
      send(test, :holding)
      await_finish()
    end)
  end

  defp await_finish do
    receive do
      :finish -> :ok
    after
      30_000 -> :timeout
    end
  end

  defp finish(task) do
    send(task.pid, :finish)
    Task.await(task, 30_000)
  end

  describe "the capacity a joining machine declares" do
    test "survives a database failure and re-applies the declaration on the next recheck" do
      # #846.4 review findings 4 and 5, together, because they are two halves of one event.
      #
      # Before this, the capacity write rescued `Postgrex.Error` and only the RETRYABLE codes
      # at that; anything else — a dropped connection, a pool checkout timeout, a database
      # restarting, a statement cancelled like the one below — propagated out of
      # `handle_info(:after_join, ...)`, KILLED THE CHANNEL and took the runner out of the
      # pool. The runner then reconnects, which under a database blip is a crash/reconnect
      # loop across the whole fleet. `:after_join` touched no database at all before capacity
      # followed the declaration, so this failure mode came in with it.
      #
      # And the write was never retried. The machine stayed dispatchable against the STALE
      # LARGER number until it happened to reconnect: `Capacity.heal/3` recomputes `in_flight`
      # and never `max_sessions`, so nothing else reconciles it.
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 2})

      # A real committed transaction on its OWN connection holding the runners row, so the
      # channel's UPDATE genuinely waits on a lock rather than on a stub.
      {locker, lock_ref} = lock_runner_row(runner)

      # Cancelled at 50ms instead of waiting out `Capacity.lock_timeout_ms/0`, which also
      # makes it the NON-retryable class (`query_canceled`) — the one that used to be
      # re-raised. `SET LOCAL`, so it lasts this test's sandbox transaction and no longer.
      Repo.query!("SET LOCAL statement_timeout = '50ms'")

      log =
        capture_log(fn ->
          {:ok, socket} = connect_runner(raw)
          {_reply, channel} = join_pool(socket, "minis", %{"max_sessions" => 1})

          # THE CHANNEL IS ALIVE AND THE RUNNER IS IN THE POOL. That is the whole of finding 4:
          # the documented fallback is to keep the capacity the row holds, and it only runs if
          # nothing escapes.
          assert Process.alive?(channel.channel_pid)
          assert in_pool?(runner.tenant_id, "minis")

          Repo.query!("SET LOCAL statement_timeout = 0")
          release_runner_row(locker, lock_ref)

          # The stale number is still held, and nothing but this retry will move it.
          assert held_capacity(runner).max_sessions == 2

          send(channel.channel_pid, :recheck)
          _ = :sys.get_state(channel.channel_pid)

          assert held_capacity(runner).max_sessions == 1
        end)

      assert log =~ "could not apply runner minis's declared max_sessions 1"
      assert log =~ "will retry on this socket's next recheck"
    end

    test "is not re-asserted on recheck by a socket that is no longer the runner's only one" do
      # #846.4 review ROUND 2, finding 3. `declaration_pending` stays true until a write lands,
      # and the retry re-applied THIS socket's `meta` with no check that the socket is still
      # the one the runner is dispatched through — unlike the join-time write, whose whole
      # ordering argument is that the socket is not yet dispatchable. Two sockets can be live
      # at once (`Loopctl.Runners`' moduledoc, the reconnect window), so an older socket on a
      # silent node re-asserted its stale declaration over a newer connection's, every 30
      # seconds, leaving the machine dispatched against a capacity it no longer declares — the
      # defect this story exists to end.
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 4})

      # The row starts at 1 under a ceiling of 4, so the socket under test has something to
      # write. Done as a COMMITTED update rather than by joining a first socket: a channel's
      # capacity write lands in the shared sandbox transaction, which never commits, and the
      # `runners` row would then stay locked for the rest of the test — the lock this test
      # needs to hand to `lock_runner_row/1` deliberately, at a moment of its own choosing.
      hold_capacity_at!(runner, 1)
      assert held_capacity(runner).max_sessions == 1

      # SOCKET A declares 4 and loses the runner row's lock, so its declaration is PENDING.
      # Cancelled at 50ms rather than waiting out `Capacity.lock_timeout_ms/0`.
      {locker, lock_ref} = lock_runner_row(runner)
      Repo.query!("SET LOCAL statement_timeout = '50ms'")

      {socket_a, log} =
        with_log(fn ->
          {:ok, socket} = connect_runner(raw)
          {_reply, channel} = join_pool(socket, "minis", %{"max_sessions" => 4})
          channel
        end)

      assert log =~ "will retry on this socket's next recheck"

      Repo.query!("SET LOCAL statement_timeout = 0")
      release_runner_row(locker, lock_ref)

      # A never landed its 4, and A is still alive and tracked.
      assert held_capacity(runner).max_sessions == 1
      assert Process.alive?(socket_a.channel_pid)

      # SOCKET B — the machine reconnected after being reconfigured — declares 1, which is
      # what the row already holds, so B's own write is a no-op and the row stands at B's
      # number. Both sockets are now live.
      {:ok, socket} = connect_runner(raw)
      {_reply, socket_b} = join_pool(socket, "minis", %{"max_sessions" => 1})
      assert length(Runners.live_metas(runner.tenant_id, runner.id)) == 2

      # A's recheck. Ungated it writes 4 back over B's 1 and re-asserts it every 30 seconds.
      send(socket_a.channel_pid, :recheck)
      _ = :sys.get_state(socket_a.channel_pid)

      assert held_capacity(runner).max_sessions == 1

      # AND IT IS STILL REFUSED ONCE B IS GONE (#846.4 review ROUND 3, finding 5). The check
      # above is `sole_live_socket?/1`, which reads the pool AT THIS INSTANT — so B leaving
      # makes A sole again and, on that check alone, free to write its 4 over the
      # configuration the machine now runs. Nothing A can read tells it that a newer
      # connection existed and has ended; B could equally have joined, written and gone
      # between two of A's 30-second rechecks, never overlapping A at all. What holds instead
      # is that the retry may only LOWER: A's 4 is a raise and is refused whether or not B is
      # visible when A asks.
      Process.unlink(socket_b.channel_pid)
      ref = leave(socket_b)
      assert_reply ref, :ok, _, @reply_timeout

      assert eventually(
               fn -> length(Runners.live_metas(runner.tenant_id, runner.id)) == 1 end,
               @reply_timeout
             )

      send(socket_a.channel_pid, :recheck)
      _ = :sys.get_state(socket_a.channel_pid)

      assert held_capacity(runner).max_sessions == 1

      # And it stays refused rather than being retried for ever: the machine gets its 4 back
      # by RECONNECTING, which is a join and carries no such bound.
      send(socket_a.channel_pid, :recheck)
      _ = :sys.get_state(socket_a.channel_pid)
      assert held_capacity(runner).max_sessions == 1

      socket_c = rejoin(runner, raw, socket_a, %{"max_sessions" => 4})
      assert held_capacity(runner).max_sessions == 4
      assert Process.alive?(socket_c.channel_pid)
    end
  end

  describe "a database lock the channel cannot get" do
    setup do
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 4})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis", %{"max_sessions" => 4})
      %{runner: runner, channel: channel}
    end

    @lock_timeout_reply 15_000

    test "a reply blocked behind a claim release is answered rate_limited, and the channel lives",
         %{runner: runner, channel: channel} do
      %{story: story, dispatch: dispatch} = committed_dispatch(runner)
      _ = story

      blocker =
        hold_lock(
          runner.tenant_id,
          from(s in Loopctl.WorkBreakdown.Story,
            where: s.id == ^story.id,
            lock: "FOR UPDATE",
            select: s.claim_epoch
          )
        )

      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => dispatch.dispatch_id,
          "claim_epoch" => 0,
          "decision" => "accepted"
        })

      # Never invalid_payload: the message is fine and the runner must send it AGAIN.
      assert_reply ref,
                   :error,
                   %{reason: "rate_limited", min_interval_ms: interval},
                   @lock_timeout_reply

      # Longer than the wait that just ran out, so the retry is not straight back into the
      # same queue.
      assert interval == Capacity.busy_retry_ms()
      assert interval > Capacity.lock_timeout_ms()
      assert Process.alive?(channel.channel_pid)
      assert finish(blocker) == {:ok, :ok}

      assert DispatchLedger.get_record(runner.tenant_id, dispatch.dispatch_id).status == "sent"
    end

    test "a drop whose decision cannot be recorded logs and keeps the channel alive",
         %{runner: runner, channel: channel} do
      %{dispatch: dispatch} = committed_dispatch(runner)
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      blocker =
        hold_lock(
          runner.tenant_id,
          from(d in DispatchRecord,
            where: d.tenant_id == ^runner.tenant_id and d.dispatch_id == ^dispatch.dispatch_id,
            lock: "FOR UPDATE",
            select: d.id
          )
        )

      log =
        capture_log(fn ->
          Phoenix.PubSub.broadcast(
            Loopctl.PubSub,
            Runners.dispatch_topic(runner.id),
            {:runner_dispatch, dispatch}
          )

          # The drop's own decision runs into the lock timeout. An orderly refusal, not a
          # crash: the slot is left to the sweep's undelivered grace.
          refute_push "dispatch", _, Capacity.lock_timeout_ms() + 3_000
        end)

      assert log =~ "not delivered"
      assert log =~ "capacity_busy"
      assert Process.alive?(channel.channel_pid)
      assert finish(blocker) == {:ok, :ok}
    end

    test "a push whose stamp cannot be written is dropped, not pushed unrecorded",
         %{runner: runner, channel: channel} do
      %{dispatch: dispatch} = committed_dispatch(runner)

      blocker =
        hold_lock(
          runner.tenant_id,
          from(d in DispatchRecord,
            where: d.tenant_id == ^runner.tenant_id and d.dispatch_id == ^dispatch.dispatch_id,
            lock: "FOR UPDATE",
            select: d.id
          )
        )

      Phoenix.PubSub.broadcast(
        Loopctl.PubSub,
        Runners.dispatch_topic(runner.id),
        {:runner_dispatch, dispatch}
      )

      # The stamp runs into its lock_timeout, so the dispatch is NOT pushed: a push the
      # ledger does not record would lose its slot to the heal sweep mid-session.
      # Long enough for the stamp's lock_timeout to expire, short enough that the blocker's
      # own connection checkout (15 s) does not.
      refute_push "dispatch", _, Capacity.lock_timeout_ms() + 3_000
      assert Process.alive?(channel.channel_pid)
      assert finish(blocker) == {:ok, :ok}

      record = DispatchLedger.get_record(runner.tenant_id, dispatch.dispatch_id)
      refute record.pushed_at
    end
  end
end
