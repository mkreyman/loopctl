defmodule LoopctlWeb.RunnerChannelDispatchTest do
  @moduledoc """
  Issues #801 and #803: a dispatch reaches exactly one runner's socket and is recorded in the
  dispatch ledger first; the runner's `dispatch_reply`, `trace` and `trace_cursor` are applied
  as that runner in its tenant; and the rate limits the contract publishes are the ones the
  channel enforces. Connect, join, status and revocation are in `LoopctlWeb.RunnerChannelTest`.

  ## Why `async: false`

  A dispatch, a reply and a trace write the dispatch ledger on the RLS `Loopctl.Repo`, while
  the socket authenticates its runner through `Loopctl.AdminRepo` — separate sandbox
  connections that cannot see each other's uncommitted rows. The `dispatch`,
  `dispatch_reply` and `trace` tests therefore use COMMITTED runners
  (`fixture(:committed_runner)`), swept at module boundaries, which no concurrently running
  test may see. That is a property of the sandbox, not of this code: `Loopctl.Repo` and
  `Loopctl.AdminRepo` each check out their OWN connection and open their OWN transaction for
  a test, and a row inserted in one uncommitted transaction is invisible to the other — a
  foreign key check against it fails. No sandbox mode shares one transaction across two
  repos, so the only rows both can see are committed ones, and a committed row is visible to
  every async test running at the same time (anything counting tenants or runners would
  flake). ExUnit runs `async: false` modules after the async ones, alone.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.Kinds
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceBatch
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceEvent
  alias Loopctl.Auth
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Presence
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  # A BOUND on a real round trip, never a delay: every dispatch, reply and trace below waits
  # on a database transaction in the channel process, and the assertion returns the moment
  # the reply lands. ExUnit's 100 ms default is shorter than that under a loaded full suite.
  # Also the deadline of every `eventually/2` poll.
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

  defp join_pool(socket, machine, overrides \\ %{}) do
    {:ok, reply, channel} =
      subscribe_and_join(socket, topic(socket), join_payload(machine, overrides))

    _ = :sys.get_state(channel.channel_pid)
    {reply, channel}
  end

  defp in_pool?(tenant_id, name), do: Map.has_key?(Runners.pool(tenant_id), name)

  # The channel's own view of the runner's meta — what Presence replicates and what both
  # `Runners.declared_kinds/1` and `Runners.suppressed_kinds/1` read at the decision.
  defp socket_meta(channel), do: :sys.get_state(channel.channel_pid).assigns.meta

  # Reconnects a runner, joining with a different payload. The old channel must be GONE from
  # the pool first: two live sockets on one credential are `:runner_ambiguous`, which would
  # refuse a dispatch for a reason that has nothing to do with the kind under test. The unlink
  # is because a channel shutting down with `:left` takes the linked test process with it.
  defp rejoin_declaring(channel, raw, runner, kinds) do
    Process.unlink(channel.channel_pid)
    ref = leave(channel)
    assert_reply ref, :ok, _, @reply_timeout
    assert eventually(fn -> not in_pool?(runner.tenant_id, runner.name) end, @reply_timeout)

    {:ok, socket} = connect_runner(raw)
    {_reply, channel} = join_pool(socket, runner.name, %{"kinds" => kinds})
    channel
  end

  # A dispatch RECORDED in the ledger, as `Runners.dispatch/3` records one before it
  # broadcasts. Tests that broadcast by hand need it: the channel takes the delivery decision
  # on the row, so a dispatch with no row is never pushed.
  defp recorded_dispatch(runner, attrs \\ %{}) do
    {:ok, dispatch} =
      RunnerContract.cast_dispatch(dispatch_payload(runner.tenant_id, Map.new(attrs)))

    {:ok, _record} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
    dispatch
  end

  # A dispatch payload for a real story at the dispatch's epoch, on the RLS connection the
  # ledger's claim fence reads.
  defp dispatch_payload(tenant_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    epoch = Map.get(attrs, "claim_epoch", 0)
    story = fixture(:ledger_story, %{tenant_id: tenant_id, claim_epoch: epoch})
    build(:runner_dispatch, Map.put(attrs, "story_id", story.id))
  end

  # The capacity loopctl DECIDES from — read on the RLS connection, because `Loopctl.Repo`
  # and `Loopctl.AdminRepo` hold separate sandbox transactions and the channel's write lands
  # in the first (see this module's "Why `async: false`").
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
    Sandbox.unboxed_run(Loopctl.AdminRepo, fn ->
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
    Sandbox.unboxed_run(Loopctl.AdminRepo, fn ->
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

  describe "the capacity a joining machine declares" do
    test "is what loopctl reserves against, downward from what the machine was enrolled with" do
      # The defect this closes (846.4): minis was enrolled at two, its own runner.json says one,
      # and every rejoin left the held row at two. loopctl then placed a SECOND concurrent
      # dispatch on a machine that refuses it `at_capacity` — and a refused dispatch costs the
      # story's claim and parks it, which is the failure #865 built an escalation for.
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 2})
      assert held_capacity(runner).max_sessions == 2

      {:ok, socket} = connect_runner(raw)
      {_reply, _channel} = join_pool(socket, "minis", %{"max_sessions" => 1})

      assert held_capacity(runner).max_sessions == 1

      assert :ok =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      assert_push "dispatch", _, @reply_timeout

      assert {:error, :runner_at_capacity} =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      refute_push "dispatch", _
    end

    test "and upward again, within the ceiling it was enrolled with, without re-enrolling" do
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 3})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis", %{"max_sessions" => 1})
      assert held_capacity(runner).max_sessions == 1

      rejoin(runner, raw, channel, %{"max_sessions" => 3})
      assert held_capacity(runner).max_sessions == 3

      for _ <- 1..3 do
        assert :ok =
                 Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

        assert_push "dispatch", _, @reply_timeout
      end
    end

    test "and never above it: the enrolled value is a ceiling the machine cannot raise" do
      # #846.4 review finding 2. Believing the declaration OUTRIGHT let a compromised or
      # misconfigured runner enlarge its own share of the tenant's admission budget, which it
      # could not do before capacity followed the declaration at all. The asymmetry that makes
      # the machine's number right downward is exactly what makes it wrong upward: holding too
      # many parks stories, holding too few only under-uses a machine.
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 2})
      {:ok, socket} = connect_runner(raw)
      {_reply, _channel} = join_pool(socket, "minis", %{"max_sessions" => 64})

      assert held_capacity(runner).max_sessions == 2

      for _ <- 1..2 do
        assert :ok =
                 Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

        assert_push "dispatch", _, @reply_timeout
      end

      assert {:error, :runner_at_capacity} =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))
    end

    test "is held as one when the machine declares zero, and the join is not refused" do
      # Zero is inside `RunnerJoin`'s range and outside the column's. Ignoring it would leave
      # the enrolled two standing — the exact over-reservation this path exists to end. A
      # machine that wants NO work sets `draining`.
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 2})
      {:ok, socket} = connect_runner(raw)

      log =
        capture_log(fn ->
          {reply, _channel} = join_pool(socket, "minis", %{"max_sessions" => 0})
          assert reply == %{contract_version: RunnerContract.version()}
        end)

      assert held_capacity(runner).max_sessions == 1
      assert log =~ "declared max_sessions 0"

      # #846.4 review ROUND 2, finding 4: the held number (1, asserted above) and the one the
      # pool reports are NOT equal here, and this is the one case where that is correct rather
      # than drift — `Runners.capacity/1`'s docstring claimed they always match for a machine
      # declaring at or below its grant, and a declared `0` is both. This is what makes the
      # corrected sentence checkable. Read through `held_capacity/1` rather than
      # `Runners.capacity/1`, which is the same column and the same query but on `AdminRepo` —
      # a second sandbox connection that cannot see the channel's uncommitted write (see this
      # module's "Why `async: false`").
      #
      # The ONE live meta is what `LoopctlWeb.RunnerController`'s `pool_entry/2` renders
      # `reported_max_sessions` from.
      assert [meta] = Runners.live_metas(runner.tenant_id, runner.id)
      assert meta.max_sessions == 0
      refute Runners.accepting_work?(meta)
    end

    test "leaves the row untouched when a rejoin declares what is already held" do
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 4})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis", %{"max_sessions" => 2})

      written_at = held_capacity(runner).updated_at
      assert held_capacity(runner).max_sessions == 2

      channel = rejoin(runner, raw, channel, %{"max_sessions" => 2})

      # No write at all, so a reconnect never takes the lock on the row every dispatch in the
      # tenant contends on.
      assert held_capacity(runner).updated_at == written_at

      # And the same holds for a machine declaring ABOVE its ceiling on every join: the
      # predicate compares what would be WRITTEN, not the raw declaration, so this is a no-op
      # too rather than a rewrite of the same clamped number for ever.
      channel = rejoin(runner, raw, channel, %{"max_sessions" => 64})
      assert held_capacity(runner).max_sessions == 4
      capped_at = held_capacity(runner).updated_at

      _ = rejoin(runner, raw, channel, %{"max_sessions" => 64})
      assert held_capacity(runner).updated_at == capped_at
    end

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

    test "lowering it under the slots the machine already holds sends no more work" do
      {raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 2})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis", %{"max_sessions" => 2})

      for _ <- 1..2 do
        assert :ok =
                 Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

        assert_push "dispatch", _, @reply_timeout
      end

      assert held_capacity(runner).in_flight == 2

      Process.unlink(channel.channel_pid)
      ref = leave(channel)
      assert_reply ref, :ok, _, @reply_timeout
      assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end, @reply_timeout)

      {:ok, socket} = connect_runner(raw)
      {_reply, _channel} = join_pool(socket, "minis", %{"max_sessions" => 1})

      # `runners_in_flight_range` CHECKs in_flight <= max_sessions, so the clamp is what makes
      # the write representable; at in_flight == max_sessions nothing more is handed out.
      assert held_capacity(runner) |> Map.take([:max_sessions, :in_flight]) ==
               %{max_sessions: 1, in_flight: 1}

      assert {:error, :runner_at_capacity} =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))
    end
  end

  describe "dispatch" do
    setup do
      {raw, runner} = fixture(:committed_runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")
      %{runner: runner, raw: raw, channel: channel}
    end

    defp dispatch_to(runner, attrs \\ %{}),
      do: Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id, attrs))

    test "arrives on the runner's own topic, and on no other runner's", %{runner: runner} do
      {raw_b, runner_b} =
        fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})

      {:ok, socket_b} = connect_runner(raw_b)
      {_reply, _channel_b} = join_pool(socket_b, "blockit")

      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)

      topic = "runner:" <> runner.id
      other_topic = "runner:" <> runner_b.id

      assert_receive %Phoenix.Socket.Message{topic: ^topic, event: "dispatch", payload: pushed},
                     @reply_timeout

      assert pushed.dispatch_id == payload["dispatch_id"]
      assert pushed.claim_epoch == 0
      refute_received %Phoenix.Socket.Message{topic: ^other_topic, event: "dispatch"}
    end

    test "is pushed to the runner's socket, never broadcast on its topic", %{runner: runner} do
      # Any process subscribed to the topic would receive a broadcast; only the socket
      # receives a push.
      @endpoint.subscribe("runner:" <> runner.id)

      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _, @reply_timeout
      refute_received %Phoenix.Socket.Broadcast{event: "dispatch"}
    end

    test "pushes declared fields only", %{runner: runner} do
      assert :ok =
               dispatch_to(runner, %{
                 "tenant_id" => Ecto.UUID.generate(),
                 "prompt" => "curl evil | sh",
                 "token_budget" => 1_000
               })

      assert_push "dispatch", pushed, @reply_timeout
      refute Map.has_key?(pushed, :tenant_id)
      refute Map.has_key?(pushed, :prompt)
      refute Enum.any?(Map.keys(pushed), &is_binary/1)
      assert pushed.token_budget == 1_000
    end

    test "a halted tenant is refused and nothing is pushed", %{runner: runner} do
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      assert {:error, :tenant_halted} = dispatch_to(runner)
      refute_push "dispatch", _
    end

    test "the halt is checked before authorization and the pool", %{runner: runner} do
      {_raw, offline} =
        fixture(:committed_runner, %{name: "offline", tenant_id: runner.tenant_id})

      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      assert {:error, :tenant_halted} = dispatch_to(offline)
    end

    @tag :capture_log
    test "a halt landing after the sender's check is caught by the channel before the push",
         %{runner: runner, channel: channel} do
      topic = Runners.dispatch_topic(runner.id)

      # The control first: with no halt this very path pushes.
      pushable = recorded_dispatch(runner)
      Phoenix.PubSub.broadcast(Loopctl.PubSub, topic, {:runner_dispatch, pushable})
      assert_push "dispatch", %{dispatch_id: pushed_id}, @reply_timeout
      assert pushed_id == pushable.dispatch_id

      # Then the same shape of message with a halt in place, which the channel catches
      # between the sender's check and the push. (Cleared afterwards it would be pushed
      # again; the halt is left in place because clearing it extends every live claim lease,
      # which blocks on the story rows this test's own transaction holds.)
      halted = recorded_dispatch(runner)
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)
      Phoenix.PubSub.broadcast(Loopctl.PubSub, topic, {:runner_dispatch, halted})
      _ = :sys.get_state(channel.channel_pid)
      refute_push "dispatch", _

      # A halt is final for that dispatch, so its slot went back.
      assert eventually(
               fn ->
                 DispatchLedger.get_record(runner.tenant_id, halted.dispatch_id).released_at
               end,
               @reply_timeout
             )
    end

    test "an unauthorized runner still in the pool is refused", %{runner: runner} do
      # Revoked through the api_keys route: no broadcast, so the socket stays in the pool
      # until its periodic recheck. Only the authorization read can refuse it here.
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)
      assert in_pool?(runner.tenant_id, "minis")

      assert {:error, :not_authorized} = dispatch_to(runner)
      refute_push "dispatch", _
    end

    test "a runner that is not connected is refused", %{runner: runner} do
      {_raw, offline} =
        fixture(:committed_runner, %{name: "offline", tenant_id: runner.tenant_id})

      assert {:error, :runner_not_connected} = dispatch_to(offline)
      refute_push "dispatch", _
    end

    test "a runner whose socket left the pool is refused", %{runner: runner, channel: channel} do
      Process.unlink(channel.channel_pid)
      ref = leave(channel)
      assert_reply ref, :ok, _, @reply_timeout
      assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end, @reply_timeout)

      assert {:error, :runner_not_connected} = dispatch_to(runner)
    end

    test "a credential live on two sockets is refused", %{runner: runner, raw: raw} do
      {:ok, second} = connect_runner(raw)
      {_reply, _channel} = join_pool(second, "minis")

      assert {:error, :runner_ambiguous} = dispatch_to(runner)
      refute_push "dispatch", _
    end

    @tag :capture_log
    test "a second subscribed socket missing from the pool read gets no push; one push happens",
         %{runner: runner, raw: raw} do
      # The state a socket is in when `dispatch/3`'s pool read cannot see it: subscribed to
      # the runner's dispatches but absent from the pool (not yet tracked, or not yet in this
      # node's Presence view). Produced here by untracking a joined second socket.
      {:ok, second} = connect_runner(raw)
      {_reply, channel_b} = join_pool(second, "minis")
      :ok = Presence.untrack(channel_b.channel_pid, Runners.pool_topic(runner.tenant_id), "minis")

      assert eventually(
               fn -> length(Runners.live_metas(runner.tenant_id, runner.id)) == 1 end,
               @reply_timeout
             )

      assert :ok = dispatch_to(runner)

      # Both channels receive the broadcast; only the socket that is the pool's sole live
      # meta pushes. Both transports are this test process, so count every push.
      assert_receive %Phoenix.Socket.Message{event: "dispatch"}, @reply_timeout
      refute_receive %Phoenix.Socket.Message{event: "dispatch"}
    end

    @tag :capture_log
    test "a live meta the sender did not see stops the push", %{runner: runner} do
      dispatch = recorded_dispatch(runner)
      topic = Runners.dispatch_topic(runner.id)

      # A second live socket for this runner, as another node's Presence would report it.
      other =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, _ref} =
        Presence.track(other, Runners.pool_topic(runner.tenant_id), "minis", %{
          runner_id: runner.id
        })

      Phoenix.PubSub.broadcast(Loopctl.PubSub, topic, {:runner_dispatch, dispatch})
      refute_push "dispatch", _

      # Once it is gone the same message is pushed, so the refusal above was the second meta.
      send(other, :stop)

      assert eventually(
               fn -> length(Runners.live_metas(runner.tenant_id, runner.id)) == 1 end,
               @reply_timeout
             )

      Phoenix.PubSub.broadcast(Loopctl.PubSub, topic, {:runner_dispatch, dispatch})
      assert_push "dispatch", _, @reply_timeout
    end

    test "still pushes after a status update re-issues the socket's Presence ref",
         %{runner: runner, channel: channel} do
      ref = push(channel, "status", %{"in_flight" => 1})
      assert_reply ref, :ok, _, @reply_timeout

      assert eventually(
               fn ->
                 match?([%{in_flight: 1}], Runners.live_metas(runner.tenant_id, runner.id))
               end,
               @reply_timeout
             )

      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _, @reply_timeout
    end

    test "is recorded in the ledger as sent, and a re-send of the same id adds no row",
         %{runner: runner} do
      payload = dispatch_payload(runner.tenant_id, %{"claim_epoch" => 4})

      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      record = DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"])
      assert %DispatchRecord{status: "sent", claim_epoch: 4} = record
      assert record.runner_id == runner.id

      # The retry of a push the channel may have dropped is sent again, onto the same row.
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout
      assert DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]).id == record.id
    end

    test "a runner at max_sessions is refused before anything is recorded or pushed; a re-send is not",
         %{runner: runner} do
      # The setup runner is enrolled with the default of two slots.
      first = dispatch_payload(runner.tenant_id)

      for payload <- [first, dispatch_payload(runner.tenant_id)] do
        assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
        assert_push "dispatch", _, @reply_timeout
      end

      third = dispatch_payload(runner.tenant_id)
      assert {:error, :runner_at_capacity} = Runners.dispatch(runner.tenant_id, runner.id, third)
      refute_push "dispatch", _
      assert is_nil(DispatchLedger.get_record(runner.tenant_id, third["dispatch_id"]))

      # The retry of a dispatch that already holds its slot needs no new one.
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, first)
      assert_push "dispatch", _, @reply_timeout
    end

    test "the tenant's admission limit refuses a runner that still has free slots",
         %{runner: runner} do
      {raw_b, runner_b} =
        fixture(:committed_runner, %{
          name: "blockit",
          tenant_id: runner.tenant_id,
          max_sessions: 8
        })

      {:ok, socket_b} = connect_runner(raw_b)
      # DECLARED on the join, not merely enrolled: since contract 1.13.0 the join is what sets
      # the capacity loopctl reserves against, so a payload declaring the default 2 would give
      # this runner two slots and the tenant limit below would never be what refuses it.
      {_reply, _channel_b} = join_pool(socket_b, "blockit", %{"max_sessions" => 8})

      for _ <- 1..Capacity.limit() do
        assert :ok =
                 Runners.dispatch(
                   runner.tenant_id,
                   runner_b.id,
                   dispatch_payload(runner.tenant_id)
                 )
      end

      over = dispatch_payload(runner.tenant_id)

      assert {:error, :admission_limit_reached} =
               Runners.dispatch(runner.tenant_id, runner_b.id, over)

      assert is_nil(DispatchLedger.get_record(runner.tenant_id, over["dispatch_id"]))
    end

    test "is broadcast in the shape every deployed node understands", %{runner: runner} do
      # A node of the PREVIOUS release has no clause for a three-element message and crashes
      # on it, dropping the dispatch. This release therefore keeps sending the two-element
      # one; the channel accepts both so a later release can move.
      Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.dispatch_topic(runner.id))
      payload = dispatch_payload(runner.tenant_id)

      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)

      assert_receive {:runner_dispatch, broadcast}, @reply_timeout
      assert broadcast.dispatch_id == payload["dispatch_id"]
      refute_received {:runner_dispatch, _, _}
    end

    test "a three-element message from a newer node is pushed like any other",
         %{runner: runner} do
      dispatch = recorded_dispatch(runner)

      Phoenix.PubSub.broadcast(
        Loopctl.PubSub,
        Runners.dispatch_topic(runner.id),
        {:runner_dispatch, dispatch, 7}
      )

      assert_push "dispatch", pushed, @reply_timeout
      assert pushed.dispatch_id == dispatch.dispatch_id
    end

    test "a message shape the channel does not know is ignored, logged once, and the socket lives",
         %{runner: runner, channel: channel} do
      log =
        capture_log(fn ->
          # The rolling-deploy case arrives at dispatch rate on every channel, so the log is
          # gated even though every message is ignored.
          for _ <- 1..5 do
            send(channel.channel_pid, {:runner_dispatch_v3, %{}, %{}, %{}})
            _ = :sys.get_state(channel.channel_pid)
          end
        end)

      assert [_one] = Regex.scan(~r/ignored an unknown channel message/, log)
      assert Process.alive?(channel.channel_pid)

      # And the channel still serves its runner.
      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _, @reply_timeout
    end

    test "a dispatch the channel DROPS before any push gives its slot back at once",
         %{runner: runner, channel: channel} do
      payload = dispatch_payload(runner.tenant_id)
      {:ok, dispatch} = RunnerContract.cast_dispatch(payload)
      assert {:ok, record} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      refute record.released_at
      refute record.pushed_at

      # Delivered to the channel with a halt in place: it drops it instead of pushing, so the
      # slot is holding no session and goes back.
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      Phoenix.PubSub.broadcast(
        Loopctl.PubSub,
        Runners.dispatch_topic(runner.id),
        {:runner_dispatch, dispatch}
      )

      _ = :sys.get_state(channel.channel_pid)
      refute_push "dispatch", _

      assert eventually(
               fn ->
                 DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]).released_at
               end,
               @reply_timeout
             )
    end

    test "a dispatch DROPPED after an earlier push keeps the running session's slot",
         %{runner: runner, channel: channel} do
      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      record = DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"])
      assert record.pushed_at
      {:ok, dispatch} = RunnerContract.cast_dispatch(payload)

      # The retry of a dispatch whose slot is already in use, dropped: the session started by
      # the first push still holds that slot.
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      Phoenix.PubSub.broadcast(
        Loopctl.PubSub,
        Runners.dispatch_topic(runner.id),
        {:runner_dispatch, dispatch}
      )

      _ = :sys.get_state(channel.channel_pid)
      refute_push "dispatch", _
      refute DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]).released_at
    end

    test "a dispatch_id whose ledger row disagrees is refused before anything is pushed",
         %{runner: runner} do
      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      # A DIFFERENT story under the same dispatch_id. It used to be a different `kind`, which
      # since contract 1.5.0 is refused by the cast before the ledger sees it — a real
      # refusal, but not the one this test is about.
      other = fixture(:ledger_story, %{tenant_id: runner.tenant_id, claim_epoch: 0})

      assert {:error, :dispatch_id_conflict} =
               Runners.dispatch(runner.tenant_id, runner.id, %{payload | "story_id" => other.id})

      refute_push "dispatch", _
    end

    test "a dispatch whose epoch is not the story's current one is refused and nothing is pushed",
         %{runner: runner} do
      payload = dispatch_payload(runner.tenant_id, %{"claim_epoch" => 3})

      assert {:error, :stale_claim_epoch} =
               Runners.dispatch(runner.tenant_id, runner.id, %{payload | "claim_epoch" => 2})

      refute_push "dispatch", _
      assert DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]) == nil
    end

    test "a dispatch the runner already answered is not pushed again",
         %{runner: runner, channel: channel} do
      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      ref = push(channel, "dispatch_reply", accept(payload))
      assert_reply ref, :ok, _, @reply_timeout

      assert {:error, :dispatch_already_replied} =
               Runners.dispatch(runner.tenant_id, runner.id, payload)

      refute_push "dispatch", _
    end

    test "a malformed payload is refused and nothing is pushed", %{runner: runner} do
      assert {:error, {:invalid, details}} =
               Runners.dispatch(
                 runner.tenant_id,
                 runner.id,
                 Map.delete(build(:runner_dispatch), "claim_epoch")
               )

      assert Enum.any?(details, &String.contains?(&1, "claim_epoch"))
      assert {:error, {:invalid, _}} = dispatch_to(runner, %{"kind" => "shell"})
      assert {:error, {:invalid, _}} = Runners.dispatch(runner.tenant_id, runner.id, nil)
      refute_push "dispatch", _
    end

    test "another tenant cannot reach this runner by id", %{runner: runner} do
      tenant_b = fixture(:committed_tenant, %{})
      {raw_b, runner_b} = fixture(:committed_runner, %{name: "minis", tenant_id: tenant_b.id})
      {:ok, socket_b} = connect_runner(raw_b)
      {_reply, _channel_b} = join_pool(socket_b, "minis")

      assert {:error, :not_authorized} =
               Runners.dispatch(tenant_b.id, runner.id, build(:runner_dispatch))

      # Tenant B's own runner, joined under the same machine name, is still reachable by B.
      assert :ok = Runners.dispatch(tenant_b.id, runner_b.id, dispatch_payload(tenant_b.id))
      topic = "runner:" <> runner.id
      topic_b = "runner:" <> runner_b.id
      assert_receive %Phoenix.Socket.Message{topic: ^topic_b, event: "dispatch"}, @reply_timeout
      refute_received %Phoenix.Socket.Message{topic: ^topic, event: "dispatch"}
    end

    test "a halt on another tenant does not stop this one", %{runner: runner} do
      tenant_b = fixture(:committed_tenant, %{})
      {:ok, _} = Tenants.halt_custody(tenant_b.id)

      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _, @reply_timeout
    end

    test "malformed ids address no runner", %{runner: runner} do
      assert {:error, :not_authorized} =
               Runners.dispatch("not-a-uuid", runner.id, build(:runner_dispatch))

      assert {:error, :not_authorized} =
               Runners.dispatch(runner.tenant_id, "not-a-uuid", build(:runner_dispatch))
    end

    test "kind_not_supported is permanent for that runner and that kind",
         %{runner: runner, channel: channel} do
      first = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, first)
      assert_push "dispatch", _, @reply_timeout

      held = in_flight_of(runner)
      assert held >= 1

      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => first["dispatch_id"],
          "claim_epoch" => first["claim_epoch"],
          "decision" => "refused",
          "reason" => "kind_not_supported"
        })

      assert_reply ref, :ok, _, @reply_timeout
      assert status_of(runner, first) == "refused"

      # A capability statement costs the runner no capacity: the refusal gave the slot back
      # in the same transaction that recorded it, exactly as every other refusal does.
      assert in_flight_of(runner) == held - 1

      assert DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")

      # And the next one of that kind never reaches the machine, never takes a slot and never
      # writes a ledger row.
      second = dispatch_payload(runner.tenant_id)

      assert {:error, :kind_not_supported} =
               Runners.dispatch(runner.tenant_id, runner.id, second)

      refute_push "dispatch", _
      assert DispatchLedger.get_record(runner.tenant_id, second["dispatch_id"]) == nil
      assert in_flight_of(runner) == held - 1
    end

    test "an ordinary refusal does not make a kind unsupported",
         %{runner: runner, channel: channel} do
      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "at_capacity"
        })

      assert_reply ref, :ok, _, @reply_timeout

      refute DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")
      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _, @reply_timeout
    end

    test "one runner's kind_not_supported binds neither another runner nor another tenant",
         %{runner: runner, channel: channel} do
      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "kind_not_supported"
        })

      assert_reply ref, :ok, _, @reply_timeout

      {raw_b, runner_b} =
        fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})

      {:ok, socket_b} = connect_runner(raw_b)
      {_reply, _channel_b} = join_pool(socket_b, "blockit")

      refute DispatchLedger.kind_unsupported?(runner.tenant_id, runner_b.id, "implement")
      assert :ok = dispatch_to(runner_b)

      tenant_b = fixture(:committed_tenant, %{})
      refute DispatchLedger.kind_unsupported?(tenant_b.id, runner.id, "implement")
    end

    # Contract 1.6.0. The ledger's `kind_not_supported` memory has no expiry and no clearing
    # path, so before the declaration a machine that GAINED a kind by being upgraded stayed
    # ineligible for the life of its runners row — the operator's only remedy was revoke and
    # re-enrol. Reconnecting with the kind declared is now the remedy, and this is that.
    test "a runner that DECLARES a kind is sent it despite a recorded kind_not_supported",
         %{runner: runner, raw: raw, channel: channel} do
      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "kind_not_supported"
        })

      assert_reply ref, :ok, _, @reply_timeout
      assert DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")

      # Undeclared, the next one is refused — the behaviour the declaration overrides.
      assert {:error, :kind_not_supported} =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      # The machine reconnects declaring the kind. Nothing about the runners row, the ledger
      # row or the recorded refusal changed: the ONLY new fact is what it said on join.
      _channel = rejoin_declaring(channel, raw, runner, ["implement"])

      assert :ok =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      assert_push "dispatch", _, @reply_timeout

      # And the record itself is untouched — it is the audit trail of what the machine
      # refused, which a later declaration does not rewrite.
      assert DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")
    end

    # #834 round 1, finding 4. The declaration beating the ledger is the point of 1.6.0, and
    # its cost is that a runner which DECLARES a kind and then refuses it has nothing stopping
    # the next dispatch — each one takes a slot, is refused, releases it, forever. The
    # motivating failure is precisely a runner mapping a transient local condition to
    # `kind_not_supported`, and such a runner keeps declaring the kind.
    test "a runner that refuses a kind it DECLARED is not sent it again on that connection",
         %{runner: runner, raw: raw, channel: channel} do
      channel = rejoin_declaring(channel, raw, runner, ["triage", "implement"])

      first = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, first)
      assert_push "dispatch", _, @reply_timeout
      held = in_flight_of(runner)

      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => first["dispatch_id"],
          "claim_epoch" => first["claim_epoch"],
          "decision" => "refused",
          "reason" => "kind_not_supported"
        })

      assert_reply ref, :ok, _, @reply_timeout
      assert in_flight_of(runner) == held - 1

      # Without the brake this is :ok and the loop has no bound at all.
      second = dispatch_payload(runner.tenant_id)

      assert {:error, :kind_not_supported} =
               Runners.dispatch(runner.tenant_id, runner.id, second)

      refute_push "dispatch", _
      assert DispatchLedger.get_record(runner.tenant_id, second["dispatch_id"]) == nil
      assert in_flight_of(runner) == held - 1

      # #834 round 2, finding 4. The DECLARATION is untouched — a suppression is loopctl
      # withholding work, not the runner revising what it said. Folding the two made the
      # pool report a machine that declared two kinds as a one-kind machine, and one that
      # declared a single kind as having declared nothing at all.
      assert {:declared, ["triage", "implement"]} = Runners.declared_kinds(socket_meta(channel))
      assert Runners.suppressed_kinds(socket_meta(channel)) == ["implement"]

      # PER CONNECTION, and that is the whole design: the declaration it contradicts is
      # per-connection too, so reconnecting re-declares the kind and clears the suppression
      # — the same unlock as everywhere else in 1.6.0.
      _channel = rejoin_declaring(channel, raw, runner, ["implement"])

      assert :ok =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      assert_push "dispatch", _, @reply_timeout
    end

    # #834 round 3, finding 4. `record_reply/3` fences on (tenant, runner, dispatch_id) and
    # claim_epoch, never on a socket, so a reply is accepted on ANY of the runner's channels.
    # A refusal that crosses a reconnect would otherwise suppress the FRESH connection, which
    # contradicted nothing — and defeat the "reconnecting clears it" remedy for the very
    # connection that just performed it.
    test "a refusal that crosses a reconnect does not suppress the new connection",
         %{runner: runner, raw: raw, channel: channel} do
      channel = rejoin_declaring(channel, raw, runner, ["implement"])

      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      # The socket drops with the reply unflushed, and the runner reconnects declaring the
      # same kind. This connection has been sent nothing.
      channel = rejoin_declaring(channel, raw, runner, ["implement"])

      # The queued refusal arrives here, naming the dispatch the PREVIOUS connection carried.
      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "kind_not_supported"
        })

      assert_reply ref, :ok, _, @reply_timeout

      # It is still recorded — the ledger is where the refusal durably lives.
      assert DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")

      # But THIS connection is not suppressed, and still gets work.
      assert Runners.suppressed_kinds(socket_meta(channel)) == []

      assert :ok =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      assert_push "dispatch", _, @reply_timeout
    end

    # The blind spot a peer session found in round 3's own fix: the counter lived inside
    # suppress_kind, which runs ONLY for a declaring runner, so it read zero during the
    # incident that is live on the fleet today. No runner declares yet, so every machine
    # takes the UNDECLARING path where one refusal is permanent for the life of its runners
    # row — the worst outcome, and the one the instrument could not see.
    test "an UNDECLARING runner's refusal is counted as permanent", %{
      runner: runner,
      channel: channel
    } do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loopctl, :runners, :declared_kind_refused]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      reply_ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "kind_not_supported"
        })

      assert_reply reply_ref, :ok, _, @reply_timeout

      assert_receive {[:loopctl, :runners, :declared_kind_refused], ^ref, %{count: 1}, meta},
                     @reply_timeout

      # `permanent` is the tag an operator alerts on — this machine now gets no work at all
      # and stays connected looking healthy.
      assert meta.outcome == "permanent"
      assert meta.kind == "implement"
    end

    test "a DECLARING runner's self-contradiction is counted as suppressed, not permanent",
         %{runner: runner, raw: raw, channel: channel} do
      channel = rejoin_declaring(channel, raw, runner, ["implement"])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loopctl, :runners, :declared_kind_refused]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      reply_ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "kind_not_supported"
        })

      assert_reply reply_ref, :ok, _, @reply_timeout

      assert_receive {[:loopctl, :runners, :declared_kind_refused], ^ref, %{count: 1}, meta},
                     @reply_timeout

      assert meta.outcome == "suppressed"
    end

    # Found by the loopctl-runner session: a runner may declare a kind its accept path cannot
    # run, refusing every dispatch of it as a FAULT rather than a capability statement.
    #
    # Round 2 then scoped the counter to kinds BEYOND implied_kinds, because `other` is the
    # contract's residual reason and `implement` is dispatchable and universally declared —
    # counting faults there would drown the series in ordinary transient failures.
    #
    # THE CONSEQUENCE, ASSERTED RATHER THAN HIDDEN: the positive case is unreachable today.
    # `implement` is the only dispatchable kind and it is in the implied set, so nothing can
    # currently produce a fault on a kind outside it. What is testable now is the scoping
    # decision itself — a fault on `implement` emits NOTHING — and that is what this asserts.
    # The positive case becomes reachable when `triage` joins dispatchable_kinds, which is
    # also when the failure mode it watches for becomes possible.
    test "a FAULT on a declared kind inside the implied set is NOT counted",
         %{runner: runner, raw: raw, channel: channel} do
      channel = rejoin_declaring(channel, raw, runner, ["implement"])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loopctl, :runners, :declared_kind_refused]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      reply_ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "other",
          "detail" => "the runner failed deciding this dispatch"
        })

      assert_reply reply_ref, :ok, _, @reply_timeout

      refute_receive {[:loopctl, :runners, :declared_kind_refused], ^ref, _, _}, 300

      # And a fault suppresses nothing either way — it is transient by assumption, so the
      # next dispatch is still sent.
      assert Runners.suppressed_kinds(socket_meta(channel)) == []

      assert :ok =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      assert_push "dispatch", _, @reply_timeout
    end

    test "an ordinary refusal does not suppress a declared kind",
         %{runner: runner, raw: raw, channel: channel} do
      channel = rejoin_declaring(channel, raw, runner, ["implement"])

      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      ref =
        push(channel, "dispatch_reply", %{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => payload["claim_epoch"],
          "decision" => "refused",
          "reason" => "at_capacity"
        })

      assert_reply ref, :ok, _, @reply_timeout

      assert :ok =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      assert_push "dispatch", _, @reply_timeout
    end

    # #834 round 2, finding 1. A runner upgraded ahead of loopctl passes the version check
    # (same major) and may name a kind this server has never heard of. Refusing the PAYLOAD
    # would drop that machine out of the fleet over a field whose whole purpose is to ADD
    # capability — the opposite of the rolling-deploy discipline the dispatch message keeps.
    test "a kind this server does not know is ignored, and the runner still joins",
         %{runner: runner, raw: raw, channel: channel} do
      channel = rejoin_declaring(channel, raw, runner, ["implement", "review"])

      # It JOINED — the assertion `rejoin_declaring` would have failed on otherwise — and
      # the known half of its declaration still decides. The unknown kind is kept VERBATIM
      # rather than filtered out: membership already ignores it, and the pool should show
      # what the machine actually said.
      assert in_pool?(runner.tenant_id, runner.name)

      assert {:declared, ["implement", "review"]} = Runners.declared_kinds(socket_meta(channel))

      assert :ok =
               Runners.dispatch(runner.tenant_id, runner.id, dispatch_payload(runner.tenant_id))

      assert_push "dispatch", _, @reply_timeout
    end

    test "a declaration of ONLY unknown kinds is sent nothing, and is NOT read as silence",
         %{runner: runner, raw: raw, channel: channel} do
      # The case the intersection must not fold into `:implied`: the runner DID speak, and
      # named nothing this server can send. Reading that as silence would dispatch
      # `implement` to a machine that just said it does something else entirely.
      _channel = rejoin_declaring(channel, raw, runner, ["review"])

      payload = dispatch_payload(runner.tenant_id)

      assert {:error, :kind_not_supported} =
               Runners.dispatch(runner.tenant_id, runner.id, payload)

      refute_push "dispatch", _
      assert DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]) == nil
    end

    test "a kind the runner did not declare is refused, and takes no slot or ledger row",
         %{runner: runner, raw: raw, channel: channel} do
      # A declaration that does NOT include `implement`. `triage` is in the contract's
      # vocabulary and is what a triage-only machine would say.
      _channel = rejoin_declaring(channel, raw, runner, ["triage"])

      held = in_flight_of(runner)
      payload = dispatch_payload(runner.tenant_id)

      assert {:error, :kind_not_supported} =
               Runners.dispatch(runner.tenant_id, runner.id, payload)

      refute_push "dispatch", _
      assert DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]) == nil
      assert in_flight_of(runner) == held

      # Refused on the declaration alone: the ledger holds no refusal for this pair, so
      # nothing but the join payload can have decided it.
      refute DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")
    end
  end

  describe "declared_kinds/1" do
    test "a runner that sent kinds declared them" do
      assert Runners.declared_kinds(%{kinds: ["implement"]}) == {:declared, ["implement"]}

      assert Runners.declared_kinds(%{kinds: ["triage", "implement"]}) ==
               {:declared, ["triage", "implement"]}
    end

    # The tag, not just the list. `dispatch/3` reads the ledger's cached negative for an
    # `:implied` runner and NOT for a `:declared` one, so a meta that fell back to `:implied`
    # by accident would put a runner that has just declared a kind back behind the very cache
    # it declared its way out of.
    test "a runner that sent none is read as declaring what loopctl sent before the field" do
      implied = Kinds.implied_by_silence()

      assert Runners.declared_kinds(%{}) == {:implied, implied}
      assert Runners.declared_kinds(%{machine: "minis"}) == {:implied, implied}

      # NOT "everything": a kind loopctl never sent before 1.6.0 is outside the implied set,
      # so an undeclaring machine is never tried with one it has said nothing about.
      assert "implement" in implied
      refute "triage" in implied
    end

    # `cast_join/1` refuses these before a meta is built. The guard is against a meta built
    # some other way reading as a declaration it is not — which would be a SILENT widening,
    # since the `:declared` tag is what skips the ledger.
    test "a malformed kinds value is not a declaration" do
      implied = Kinds.implied_by_silence()

      assert Runners.declared_kinds(%{kinds: []}) == {:implied, implied}
      assert Runners.declared_kinds(%{kinds: ["implement", :triage]}) == {:implied, implied}
      assert Runners.declared_kinds(%{kinds: "implement"}) == {:implied, implied}
    end
  end

  describe "declared_max_sessions/1" do
    test "passes a declaration the column can already hold" do
      assert Runners.declared_max_sessions(%{max_sessions: 1}) == {:ok, 1}
      assert Runners.declared_max_sessions(%{max_sessions: 64}) == {:ok, 64}
    end

    # A meta built without passing `cast_join/1` is the only way these reach here — the join
    # schema bounds the field 0..64 — and this is the last thing between the wire and a
    # `runners_max_sessions_range` violation.
    test "clamps a declaration outside the column's range rather than dropping it" do
      assert Runners.declared_max_sessions(%{max_sessions: 0}) == {:clamped, 1, 0}
      assert Runners.declared_max_sessions(%{max_sessions: -3}) == {:clamped, 1, -3}
      assert Runners.declared_max_sessions(%{max_sessions: 9_999}) == {:clamped, 64, 9_999}
    end

    test "a meta with no integer declaration says so, and never guesses a number" do
      assert Runners.declared_max_sessions(%{}) == :undeclared
      assert Runners.declared_max_sessions(%{machine: "minis"}) == :undeclared
      assert Runners.declared_max_sessions(%{max_sessions: "2"}) == :undeclared
      assert Runners.declared_max_sessions(%{max_sessions: nil}) == :undeclared
    end

    # The clamp is bound to the CHECK constraint's range, not to a number retyped here: a
    # migration that widened the column and left this reading 1..64 would silently keep
    # refusing values the column had started accepting.
    test "clamps to the range the schema declares, whatever it is" do
      range = Runner.max_sessions_range()

      assert Runners.declared_max_sessions(%{max_sessions: range.first - 1}) ==
               {:clamped, range.first, range.first - 1}

      assert Runners.declared_max_sessions(%{max_sessions: range.last + 1}) ==
               {:clamped, range.last, range.last + 1}
    end
  end

  # The minimum intervals are per channel process; a test that sends several messages in a
  # row resets them rather than sleeping, so the rate-limit tests below are what cover them.
  defp reset_intervals(channel) do
    :sys.replace_state(channel.channel_pid, fn socket ->
      assigns = %{
        socket.assigns
        | reply_bucket: :full,
          last_trace_at: :never,
          last_cursor_at: :never
      }

      %{socket | assigns: assigns}
    end)
  end

  defp pin_interval(channel, key) do
    :sys.replace_state(channel.channel_pid, fn socket ->
      at = System.monotonic_time(:millisecond) + 60_000
      %{socket | assigns: Map.put(socket.assigns, key, at)}
    end)
  end

  defp drain_reply_bucket(channel) do
    :sys.replace_state(channel.channel_pid, fn socket ->
      at = System.monotonic_time(:millisecond) + 60_000
      %{socket | assigns: Map.put(socket.assigns, :reply_bucket, {0, at})}
    end)
  end

  defp send_trace(channel, payload) do
    reset_intervals(channel)
    push(channel, "trace", payload)
  end

  defp accept(dispatch, attrs \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => dispatch["dispatch_id"],
        "claim_epoch" => dispatch["claim_epoch"],
        "decision" => "accepted"
      },
      attrs
    )
  end

  defp status_of(runner, dispatch),
    do: DispatchLedger.get_record(runner.tenant_id, dispatch["dispatch_id"]).status

  # The runner's `in_flight` as Postgres holds it, read on the RLS connection the dispatch
  # path reserves on — `Runners.capacity/1` reads AdminRepo, which is a different connection
  # and cannot see this sandbox's uncommitted reservation.
  defp in_flight_of(runner) do
    {:ok, in_flight} =
      Loopctl.Repo.with_tenant(runner.tenant_id, fn ->
        Loopctl.Repo.one!(
          from r in Loopctl.Runners.Runner,
            where: r.id == ^runner.id and r.tenant_id == ^runner.tenant_id,
            select: r.in_flight
        )
      end)

    in_flight
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

  describe "dispatch_reply" do
    setup do
      {raw, runner} = fixture(:committed_runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")
      dispatch = dispatch_payload(runner.tenant_id, %{"claim_epoch" => 2})
      :ok = Runners.dispatch(runner.tenant_id, runner.id, dispatch)
      assert_push "dispatch", _, @reply_timeout
      %{runner: runner, channel: channel, dispatch: dispatch}
    end

    test "accepted is recorded", %{runner: runner, channel: channel, dispatch: dispatch} do
      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout
      assert status_of(runner, dispatch) == "accepted"
    end

    test "refused is recorded with its reason",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      ref =
        push(
          channel,
          "dispatch_reply",
          accept(dispatch, %{"decision" => "refused", "reason" => "repo_not_allowed"})
        )

      assert_reply ref, :ok, _, @reply_timeout

      assert %DispatchRecord{status: "refused", reason: "repo_not_allowed"} =
               DispatchLedger.get_record(runner.tenant_id, dispatch["dispatch_id"])
    end

    test "an identical repeat is ok; a conflicting one is already_replied",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout

      reset_intervals(channel)
      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout

      reset_intervals(channel)
      refusal = accept(dispatch, %{"decision" => "refused", "reason" => "draining"})
      ref = push(channel, "dispatch_reply", refusal)
      assert_reply ref, :error, %{reason: "already_replied"}, @reply_timeout
      assert status_of(runner, dispatch) == "accepted"
    end

    test "a stale claim_epoch is refused",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      ref = push(channel, "dispatch_reply", accept(dispatch, %{"claim_epoch" => 1}))
      assert_reply ref, :error, %{reason: "stale_claim_epoch"}, @reply_timeout
      assert status_of(runner, dispatch) == "sent"
    end

    test "another runner's dispatch is unknown", %{runner: runner, channel: channel} do
      {raw_b, runner_b} =
        fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})

      {:ok, socket_b} = connect_runner(raw_b)
      {_reply, _channel_b} = join_pool(socket_b, "blockit")
      theirs = dispatch_payload(runner.tenant_id)
      :ok = Runners.dispatch(runner.tenant_id, runner_b.id, theirs)

      ref = push(channel, "dispatch_reply", accept(theirs))
      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
      assert status_of(runner_b, theirs) == "sent"
    end

    test "another tenant's dispatch is unknown", %{channel: channel} do
      tenant_b = fixture(:committed_tenant, %{})
      {raw_b, runner_b} = fixture(:committed_runner, %{name: "minis", tenant_id: tenant_b.id})
      {:ok, socket_b} = connect_runner(raw_b)
      {_reply, _channel_b} = join_pool(socket_b, "minis")
      theirs = dispatch_payload(tenant_b.id)
      :ok = Runners.dispatch(tenant_b.id, runner_b.id, theirs)

      ref = push(channel, "dispatch_reply", accept(theirs))
      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
      assert status_of(runner_b, theirs) == "sent"
    end

    test "an invalid reply is refused", %{channel: channel, dispatch: dispatch} do
      ref = push(channel, "dispatch_reply", accept(dispatch, %{"decision" => "refused"}))
      assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout
    end

    test "replies to several dispatches back to back are all applied, and each dispatch's trace is accepted",
         %{runner: runner, channel: channel, dispatch: first} do
      second = dispatch_payload(runner.tenant_id, %{"claim_epoch" => 2})
      :ok = Runners.dispatch(runner.tenant_id, runner.id, second)
      assert_push "dispatch", _, @reply_timeout

      # No reset between them: a single per-runner gap used to refuse the second reply.
      for dispatch <- [first, second] do
        ref = push(channel, "dispatch_reply", accept(dispatch))
        assert_reply ref, :ok, _, @reply_timeout
      end

      for dispatch <- [first, second] do
        assert status_of(runner, dispatch) == "accepted"

        run_id = Ecto.UUID.generate()

        ref =
          send_trace(channel, %{
            "run_id" => run_id,
            "dispatch_id" => dispatch["dispatch_id"],
            "claim_epoch" => 2,
            "events" => [build(:runner_trace_event, %{"run_id" => run_id, "seq" => 0})]
          })

        assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout
      end
    end

    test "a reply past the burst is refused with the refill interval, and a refused reply is not applied",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      drain_reply_bucket(channel)

      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :error, %{reason: "rate_limited", min_interval_ms: ms}, @reply_timeout
      assert ms == RunnerContract.dispatch_reply_burst()["refill_interval_ms"]
      assert status_of(runner, dispatch) == "sent"
    end

    test "an invalid reply spends no reply", %{channel: channel, dispatch: dispatch} do
      ref = push(channel, "dispatch_reply", accept(dispatch, %{"decision" => "refused"}))
      assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout
      assert :sys.get_state(channel.channel_pid).assigns.reply_bucket == :full
    end

    test "a NUL in a refusal's detail is invalid_payload, and the channel carries on",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      nul =
        accept(dispatch, %{"decision" => "refused", "reason" => "other", "detail" => "a\u0000b"})

      ref = push(channel, "dispatch_reply", nul)
      assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout
      assert Process.alive?(channel.channel_pid)

      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout
      assert status_of(runner, dispatch) == "accepted"
    end

    test "a halted tenant can still record a reply and its trace",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout
      assert status_of(runner, dispatch) == "accepted"

      batch =
        build(:runner_trace_batch, %{
          :seqs => [0],
          "dispatch_id" => dispatch["dispatch_id"],
          "claim_epoch" => 2
        })

      ref = push(channel, "trace", batch)
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout
    end
  end

  describe "trace" do
    setup do
      {raw, runner} = fixture(:committed_runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")
      dispatch = dispatch_payload(runner.tenant_id)
      :ok = Runners.dispatch(runner.tenant_id, runner.id, dispatch)
      assert_push "dispatch", _, @reply_timeout
      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout
      reset_intervals(channel)

      %{runner: runner, channel: channel, dispatch: dispatch, run_id: Ecto.UUID.generate()}
    end

    defp batch(dispatch, run_id, seqs, attrs \\ %{}) do
      build(
        :runner_trace_batch,
        Map.merge(
          %{
            :seqs => seqs,
            "run_id" => run_id,
            "dispatch_id" => dispatch["dispatch_id"],
            "claim_epoch" => dispatch["claim_epoch"]
          },
          attrs
        )
      )
    end

    test "stores a batch once, and acks the contiguous seqs",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      ref = send_trace(channel, batch(dispatch, run_id, [0, 1, 3]))
      assert_reply ref, :ok, %{acked_seq: 1}, @reply_timeout

      ref = send_trace(channel, batch(dispatch, run_id, [0, 1, 3]))
      assert_reply ref, :ok, %{acked_seq: 1}, @reply_timeout

      ref = send_trace(channel, batch(dispatch, run_id, [2]))
      assert_reply ref, :ok, %{acked_seq: 3}, @reply_timeout
    end

    test "trace_cursor is -1 before anything is stored, then the acked seq",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      ref = push(channel, "trace_cursor", %{"run_id" => run_id})
      assert_reply ref, :ok, %{acked_seq: -1}, @reply_timeout

      ref = send_trace(channel, batch(dispatch, run_id, [0, 1, 2]))
      assert_reply ref, :ok, %{acked_seq: 2}, @reply_timeout

      reset_intervals(channel)
      ref = push(channel, "trace_cursor", %{"run_id" => run_id})
      assert_reply ref, :ok, %{acked_seq: 2}, @reply_timeout
    end

    test "a batch for an unknown dispatch, or at a wrong epoch, is refused",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      unknown = %{dispatch | "dispatch_id" => Ecto.UUID.generate()}
      ref = send_trace(channel, batch(unknown, run_id, [0]))
      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout

      ref = send_trace(channel, batch(dispatch, run_id, [0], %{"claim_epoch" => 7}))
      assert_reply ref, :error, %{reason: "stale_claim_epoch"}, @reply_timeout

      reset_intervals(channel)
      ref = push(channel, "trace_cursor", %{"run_id" => run_id})
      assert_reply ref, :ok, %{acked_seq: -1}, @reply_timeout
    end

    test "a second run for the dispatch is refused",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      ref = send_trace(channel, batch(dispatch, run_id, [0]))
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout

      ref = send_trace(channel, batch(dispatch, Ecto.UUID.generate(), [0]))
      assert_reply ref, :error, %{reason: "run_mismatch"}, @reply_timeout
    end

    test "a batch within the event count but over the byte budget is batch_too_large, and the channel carries on",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      max_bytes = RunnerTraceBatch.max_bytes()
      astral = <<0x1F600::utf8>>

      # Every string at its character limit in 12-byte-escaped characters: about 5 KB an
      # event, so the byte budget binds long before the event count does.
      heavy =
        update_in(
          batch(dispatch, run_id, Enum.to_list(0..(RunnerTraceBatch.max_events() - 1))),
          ["events", Access.all()],
          &Map.merge(&1, %{
            "event_id" => String.duplicate(astral, 128),
            "parent" => String.duplicate(astral, 128),
            "type" => String.duplicate(astral, 64)
          })
        )

      ref = send_trace(channel, heavy)

      assert_reply ref,
                   :error,
                   %{reason: "batch_too_large", max_bytes: ^max_bytes},
                   @reply_timeout

      ref = send_trace(channel, batch(dispatch, run_id, [0]))
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout
    end

    test "an oversize batch and an oversize event are refused with their limits",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      max_events = RunnerTraceBatch.max_events()
      ref = send_trace(channel, batch(dispatch, run_id, Enum.to_list(0..max_events)))

      assert_reply ref,
                   :error,
                   %{reason: "batch_too_large", max_events: ^max_events},
                   @reply_timeout

      max_bytes = RunnerTraceEvent.max_data_bytes()
      big = %{"k" => String.duplicate("x", max_bytes)}
      oversize = put_in(batch(dispatch, run_id, [0]), ["events", Access.at(0), "data"], big)
      ref = send_trace(channel, oversize)

      assert_reply ref,
                   :error,
                   %{reason: "event_data_too_large", seq: 0, max_data_bytes: ^max_bytes},
                   @reply_timeout
    end

    test "the resume sequence is never rate limited: cursor, then batches, back to back",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      # The setup's reply spent no trace or cursor floor, and no reset happens here.
      ref = push(channel, "trace_cursor", %{"run_id" => run_id})
      assert_reply ref, :ok, %{acked_seq: -1}, @reply_timeout

      ref = push(channel, "trace", batch(dispatch, run_id, [0, 1]))
      assert_reply ref, :ok, %{acked_seq: 1}, @reply_timeout
    end

    test "an invalid batch starts no floor, so its corrected resend is accepted at once",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      too_many = Enum.to_list(0..RunnerTraceBatch.max_events())
      ref = push(channel, "trace", batch(dispatch, run_id, too_many))
      assert_reply ref, :error, %{reason: "batch_too_large"}, @reply_timeout
      assert :sys.get_state(channel.channel_pid).assigns.last_trace_at == :never

      ref = push(channel, "trace", batch(dispatch, run_id, [0]))
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout
    end

    test "an uppercase run_id is one run across batches",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      upper = String.upcase(run_id)

      ref = send_trace(channel, batch(dispatch, upper, [0]))
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout

      ref = send_trace(channel, batch(dispatch, upper, [1]))
      assert_reply ref, :ok, %{acked_seq: 1}, @reply_timeout

      reset_intervals(channel)
      ref = push(channel, "trace_cursor", %{"run_id" => upper})
      assert_reply ref, :ok, %{acked_seq: 1}, @reply_timeout
    end

    test "a NUL in any runner-supplied string is invalid_payload, and the channel carries on",
         %{channel: channel, dispatch: dispatch, run_id: run_id} do
      nul = "a\u0000b"

      for change <- [
            %{"event_id" => nul},
            %{"parent" => nul},
            %{"type" => nul},
            %{"data" => %{"k" => nul}},
            %{"data" => %{nul => "v"}},
            %{"data" => %{"k" => ["ok", %{"deep" => nul}]}}
          ] do
        payload =
          update_in(
            batch(dispatch, run_id, [0]),
            ["events", Access.at(0)],
            &Map.merge(&1, change)
          )

        ref = send_trace(channel, payload)
        assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout

        assert Process.alive?(channel.channel_pid),
               "a NUL in #{inspect(change)} crashed the channel"
      end

      ref = send_trace(channel, batch(dispatch, run_id, [0]))
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout
    end

    test "a batch records its time; a batch or cursor inside its OWN minimum interval is refused",
         %{runner: runner, channel: channel, dispatch: dispatch, run_id: run_id} do
      ref = send_trace(channel, batch(dispatch, run_id, [0]))
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout
      assert is_integer(:sys.get_state(channel.channel_pid).assigns.last_trace_at)

      pin_interval(channel, :last_trace_at)
      ref = push(channel, "trace", batch(dispatch, run_id, [1]))
      assert_reply ref, :error, %{reason: "rate_limited", min_interval_ms: _}, @reply_timeout

      # trace_cursor has its own floor, so a held-back trace does not hold it back.
      ref = push(channel, "trace_cursor", %{"run_id" => run_id})
      assert_reply ref, :ok, %{acked_seq: 0}, @reply_timeout

      pin_interval(channel, :last_cursor_at)
      ref = push(channel, "trace_cursor", %{"run_id" => run_id})
      assert_reply ref, :error, %{reason: "rate_limited"}, @reply_timeout
      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, run_id) == 0
    end
  end

  describe "the published rate floors" do
    setup do
      {raw, runner} = fixture(:committed_runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")
      dispatch = dispatch_payload(runner.tenant_id)
      :ok = Runners.dispatch(runner.tenant_id, runner.id, dispatch)
      assert_push "dispatch", _, @reply_timeout
      %{runner: runner, channel: channel, dispatch: dispatch}
    end

    # The message each event is exercised with, and the assign its floor is timed from.
    defp floor_cases(dispatch) do
      run_id = Ecto.UUID.generate()

      # {published key, event pushed, assign the floor is timed from, payload}
      [
        {"status", "status", :last_status_at, %{"in_flight" => 1}},
        {"trace", "trace", :last_trace_at,
         build(:runner_trace_batch, %{
           :seqs => [],
           "run_id" => run_id,
           "dispatch_id" => dispatch["dispatch_id"],
           "claim_epoch" => dispatch["claim_epoch"]
         })},
        {"trace_cursor", "trace_cursor", :last_cursor_at, %{"run_id" => run_id}}
      ]
    end

    test "the export publishes every inbound event's floor, and the channel refuses with that value",
         %{channel: channel, dispatch: dispatch} do
      published = RunnerContract.json_schema()["x-connection"]["limits"]["min_interval_ms"]
      keys = for {key, _, _, _} <- floor_cases(dispatch), do: key
      assert Enum.sort(Map.keys(published)) == Enum.sort(keys)

      for {event, pushed, assign, payload} <- floor_cases(dispatch) do
        assert published[event] == RunnerContract.min_interval_ms(event)

        pin_interval(channel, assign)
        ref = push(channel, pushed, payload)

        assert_reply ref,
                     :error,
                     %{reason: "rate_limited", min_interval_ms: refused_with},
                     @reply_timeout

        assert refused_with == published[event], "#{event} refuses with a different floor"
      end
    end

    test "a message just past its published floor is accepted",
         %{channel: channel, dispatch: dispatch} do
      published = RunnerContract.json_schema()["x-connection"]["limits"]["min_interval_ms"]
      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout

      for {event, pushed, assign, payload} <- floor_cases(dispatch) do
        # Timed exactly one millisecond past the published floor: an enforced floor longer
        # than the published one refuses it.
        :sys.replace_state(channel.channel_pid, fn socket ->
          at = System.monotonic_time(:millisecond) - published[event] - 1
          %{socket | assigns: Map.put(socket.assigns, assign, at)}
        end)

        ref = push(channel, pushed, payload)
        assert_reply ref, status, reply, @reply_timeout
        refute match?(%{reason: "rate_limited"}, reply), "#{event} (#{status}) was rate limited"
      end
    end

    test "the export publishes the dispatch_reply burst, and the channel wires exactly it",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      # The refill arithmetic is LoopctlWeb.RunnerChannel.ReplyBucketTest's, at fixed times.
      # Here only what does not depend on how long the round trips take: the channel's bucket
      # starts at the published capacity, a drained bucket refuses with the published
      # refill interval, and one published interval later it admits again.
      published = RunnerContract.json_schema()["x-connection"]["limits"]["dispatch_reply_burst"]
      assert published == RunnerContract.dispatch_reply_burst()
      %{"capacity" => capacity, "refill_interval_ms" => refill} = published

      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout
      # From `:full`, one reply leaves capacity - 1 whenever it lands.
      assert {left, _} = :sys.get_state(channel.channel_pid).assigns.reply_bucket
      assert left == capacity - 1

      drain_reply_bucket(channel)
      ref = push(channel, "dispatch_reply", accept(dispatch))

      assert_reply ref,
                   :error,
                   %{reason: "rate_limited", min_interval_ms: ^refill},
                   @reply_timeout

      :sys.replace_state(channel.channel_pid, fn socket ->
        at = System.monotonic_time(:millisecond) - refill - 1
        %{socket | assigns: Map.put(socket.assigns, :reply_bucket, {0, at})}
      end)

      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout
      assert status_of(runner, dispatch) == "accepted"
    end
  end
end
