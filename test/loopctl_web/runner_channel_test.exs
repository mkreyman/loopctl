defmodule LoopctlWeb.RunnerChannelTest do
  @moduledoc """
  Issue #801 acceptance: a runner joins with a valid token, appears in the pool, and
  vanishes when its process dies — with no sweeper involved — and an invalid or revoked
  token is refused.
  """

  use LoopctlWeb.ChannelCase, async: true

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Auth
  alias Loopctl.Runners
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

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
