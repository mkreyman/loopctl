defmodule LoopctlWeb.RunnerObservabilityTest do
  @moduledoc """
  Issue #815: what the runner control plane records about itself — the channel's Logger
  metadata, its close and refusal logs, the refusal telemetry, the `disconnecting` push
  before a server-initiated close, the socket's refusal line, and dispatch delivery.

  Every test here authenticates a runner through `LoopctlWeb.RunnerSocket`, which reads on
  `Loopctl.AdminRepo`; in test that runs on the test's one sandbox connection
  (`Loopctl.AdminRepo.Route`), so every runner is sandboxed. The `:info` module levels the log
  assertions need are raised once in `test/test_helper.exs`.

  Two things are shared with every concurrently running test, and each is scoped to this
  test's own runner rather than read whole: a captured log holds other tests' lines too
  (`ExUnit.CaptureLog`), so `capture_runner_log/3` keeps the lines naming this runner; and the
  refusal telemetry handler forwards only this runner's events. The node-wide drain notice
  reaches every runner channel in the VM, so it is in `LoopctlWeb.RunnerShutdownNoticeTest`,
  sync.
  """

  use LoopctlWeb.ChannelCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Tenants
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  # A bound, never a delay. 10 s because this module runs in the ASYNC phase of the full
  # suite, where a channel reply missed a 2 s bound under load (commit gate, 2026-10-07).
  @reply_timeout 10_000

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

  defp topic(socket), do: "runner:" <> socket.assigns.runner.id

  defp join_pool(socket, machine) do
    {:ok, _reply, channel} = subscribe_and_join(socket, topic(socket), join_payload(machine))
    _ = :sys.get_state(channel.channel_pid)
    channel
  end

  defp joined_runner(name \\ "minis") do
    {raw, runner} = fixture(:runner, %{name: name})
    {:ok, socket} = connect_runner(raw)
    %{runner: runner, raw: raw, channel: join_pool(socket, name)}
  end

  defp dispatch_payload(tenant_id, attrs \\ %{}) do
    attrs = Map.new(attrs)

    story =
      fixture(:ledger_story, %{
        tenant_id: tenant_id,
        claim_epoch: Map.get(attrs, "claim_epoch", 0)
      })

    build(:runner_dispatch, Map.put(attrs, "story_id", story.id))
  end

  defp process_metadata(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    dictionary |> Keyword.get(:"$logger_metadata$", %{}) |> Map.new()
  end

  # The handler is VM-global: every runner channel's refusal reaches it, so it forwards only
  # those of `runner_id`, this test's runner.
  defp attach_refusals(runner_id) do
    handler = "runner-refusals-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:loopctl, :runners, :message_refused],
      fn _event, measurements, metadata, _ ->
        if Map.get(metadata, :runner_id) == runner_id,
          do: send(test_pid, {:refused, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Under `async: true` a capture also holds lines other tests logged meanwhile, so a refute or
  # a count over it would judge them too. Every line the runner control plane logs names its
  # runner, as Logger metadata or in the message, so this keeps the lines naming `id`.
  defp capture_runner_log(id, opts \\ [level: :info], fun) do
    opts
    |> capture_log(fun)
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, id))
    |> Enum.join("\n")
  end

  describe "Logger metadata in the channel process" do
    test "join sets the runner's identity, node and machine" do
      %{runner: runner, channel: channel} = joined_runner()

      metadata = process_metadata(channel.channel_pid)
      assert metadata[:runner_id] == runner.id
      assert metadata[:runner_name] == runner.name
      assert metadata[:tenant_id] == runner.tenant_id
      assert metadata[:node] == Runners.node_name()
      assert Map.has_key?(metadata, :machine) or Runners.machine_id() == nil
    end

    test "a message's correlation ids label the lines logged while it is handled, then are cleared" do
      %{runner: runner, channel: channel} = joined_runner()
      dispatch_id = Ecto.UUID.generate()
      run_id = Ecto.UUID.generate()

      batch = %{
        "run_id" => run_id,
        "dispatch_id" => dispatch_id,
        "claim_epoch" => 7,
        "events" => []
      }

      log =
        capture_runner_log(runner.id, fn ->
          ref = push(channel, "trace", batch)
          assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
        end)

      # The refusal line (logged while handling) carries them as metadata.
      assert log =~ "dispatch_id=#{dispatch_id} run_id=#{run_id} claim_epoch=7"

      metadata = process_metadata(channel.channel_pid)
      refute Map.has_key?(metadata, :dispatch_id)
      refute Map.has_key?(metadata, :run_id)
      refute Map.has_key?(metadata, :claim_epoch)
      assert metadata[:runner_id]
    end

    test "a pushed dispatch's story does not label the channel's later disconnect and close lines" do
      %{runner: runner, channel: channel} = joined_runner()
      Process.unlink(channel.channel_pid)
      payload = dispatch_payload(runner.tenant_id)

      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout
      _ = :sys.get_state(channel.channel_pid)
      refute Map.has_key?(process_metadata(channel.channel_pid), :story_id)

      # An EXPIRED key fails the same `authorized?/2` recheck a revoked one does.
      {1, _} =
        from(k in ApiKey, where: k.id == ^runner.api_key_id)
        |> AdminRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)])

      log =
        capture_runner_log(runner.id, fn ->
          send(channel.channel_pid, :recheck)
          assert eventually(fn -> not Process.alive?(channel.channel_pid) end, @reply_timeout)
        end)

      assert log =~ "runner disconnecting: reason=no_longer_authorized"
      assert log =~ "runner channel closed"
      refute log =~ "story_id="
      refute log =~ "dispatch_id="
      refute log =~ payload["story_id"]
    end

    test "a runner-supplied id or epoch not in its claimed shape is logged as :invalid, never its value" do
      %{runner: runner, channel: channel} = joined_runner()
      junk = "JUNKID" <> String.duplicate("x", 5_000)
      # What the JSON decoder makes of a many-thousand-digit number.
      bignum = Integer.pow(10, 5_000)

      log =
        capture_runner_log(runner.id, fn ->
          for epoch <- [bignum, -1] do
            # An invalid trace spends no floor, so every one of these is refused and logged.
            ref =
              push(channel, "trace", %{
                "dispatch_id" => junk,
                "run_id" => %{"nested" => junk},
                "claim_epoch" => epoch,
                "events" => "not a list"
              })

            assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout
          end
        end)

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "runner message refused"))
      assert length(lines) == 2

      for line <- lines do
        assert line =~ "dispatch_id=:invalid run_id=:invalid"
        assert line =~ "claim_epoch=invalid"
        refute line =~ "JUNKID"
        refute line =~ "nested"
        refute line =~ "0000000000"
        refute line =~ "claim_epoch=-1"
      end
    end

    test "a message whose handling raises keeps its correlation ids on the crash and close lines" do
      %{runner: runner, channel: channel} = joined_runner()
      Process.unlink(channel.channel_pid)
      _ = :sys.get_state(channel.channel_pid)
      payload = dispatch_payload(runner.tenant_id, %{"claim_epoch" => 7})
      {:ok, dispatch} = RunnerContract.cast_dispatch(payload)
      # Not a UUID, so the ledger's pushed_at write raises a cast error after the push.
      dispatch = %{dispatch | dispatch_id: "not-a-uuid"}

      log =
        capture_runner_log(runner.id, fn ->
          send(channel.channel_pid, {:runner_dispatch, dispatch})
          assert eventually(fn -> not Process.alive?(channel.channel_pid) end, @reply_timeout)
        end)

      lines = String.split(log, "\n")
      failed = Enum.find(lines, &(&1 =~ "runner message handling failed"))
      closed = Enum.find(lines, &(&1 =~ "runner channel closed"))
      assert failed, log
      assert closed, log

      for line <- [failed, closed] do
        assert line =~ "dispatch_id=not-a-uuid"
        assert line =~ "story_id=#{dispatch.story_id}"
        assert line =~ "claim_epoch=7"
      end
    end
  end

  describe "terminate/2" do
    test "logs why the channel closed, which runner, where, for how long, and its presence ref" do
      %{runner: runner, channel: channel} = joined_runner()
      ref = :sys.get_state(channel.channel_pid).assigns.presence_ref
      Process.unlink(channel.channel_pid)

      log =
        capture_runner_log(runner.id, fn ->
          ref = leave(channel)
          assert_reply ref, :ok, _, @reply_timeout
          assert eventually(fn -> not Process.alive?(channel.channel_pid) end, @reply_timeout)
        end)

      for fragment <- [
            "runner channel closed",
            "reason={:shutdown, :left}",
            "runner_id=#{runner.id}",
            "runner_name=#{runner.name}",
            "tenant_id=#{runner.tenant_id}",
            "node=#{Runners.node_name()}",
            "connected_ms=",
            "presence_ref=#{inspect(ref)}"
          ] do
        assert log =~ fragment, "missing #{inspect(fragment)} in #{log}"
      end
    end
  end

  describe "refusals" do
    test "a refused message emits telemetry with its ids and is logged with its reason" do
      %{runner: runner, channel: channel} = joined_runner()
      attach_refusals(runner.id)
      dispatch_id = Ecto.UUID.generate()

      log =
        capture_runner_log(runner.id, fn ->
          reply = %{"dispatch_id" => dispatch_id, "claim_epoch" => 0, "decision" => "accepted"}
          ref = push(channel, "dispatch_reply", reply)
          assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
        end)

      assert_received {:refused, %{count: 1}, metadata}

      assert metadata == %{
               event: "dispatch_reply",
               reason: "unknown_dispatch",
               tenant_id: runner.tenant_id,
               runner_id: runner.id,
               dispatch_id: dispatch_id,
               run_id: nil
             }

      assert log =~ "runner message refused: event=dispatch_reply reason=unknown_dispatch"
      assert log =~ dispatch_id
    end

    test "rate_limited is counted but not logged" do
      %{runner: runner, channel: channel} = joined_runner()
      attach_refusals(runner.id)

      :sys.replace_state(channel.channel_pid, fn socket ->
        at = System.monotonic_time(:millisecond) + 60_000
        %{socket | assigns: Map.put(socket.assigns, :last_status_at, at)}
      end)

      log =
        capture_runner_log(runner.id, fn ->
          ref = push(channel, "status", %{"in_flight" => 1})
          assert_reply ref, :error, %{reason: "rate_limited"}, @reply_timeout
        end)

      assert_received {:refused, _, %{event: "status", reason: "rate_limited"}}
      refute log =~ "reason=rate_limited"
    end

    test "an unknown event is counted under a fixed event name, never the runner's string" do
      %{runner: runner, channel: channel} = joined_runner()
      attach_refusals(runner.id)

      ref = push(channel, "made-up-#{System.unique_integer()}", %{})
      assert_reply ref, :error, %{reason: "unknown_event"}, @reply_timeout
      assert_received {:refused, _, %{event: "unknown", reason: "unknown_event"}}
    end

    test "ten unknown events in one interval: ten unknown_event replies, ten telemetry events, one log line" do
      %{runner: runner, channel: channel} = joined_runner()
      attach_refusals(runner.id)

      log =
        capture_runner_log(runner.id, fn ->
          ref = push(channel, "made-up-1", %{})
          assert_reply ref, :error, %{reason: "unknown_event"}, @reply_timeout

          # Pinned, so the other nine land inside the interval however long the first took.
          :sys.replace_state(channel.channel_pid, fn socket ->
            at = System.monotonic_time(:millisecond) + 60_000
            %{socket | assigns: Map.put(socket.assigns, :last_unknown_at, at)}
          end)

          for n <- 2..10 do
            ref = push(channel, "made-up-#{n}", %{})
            assert_reply ref, :error, reply, @reply_timeout
            assert reply == %{reason: "unknown_event"}
          end
        end)

      assert "unknown_event" in RunnerContract.error_reasons()["unknown_event"]

      for _ <- 1..10 do
        assert_received {:refused, _, %{event: "unknown", reason: "unknown_event"}}
      end

      refute_received {:refused, _, _}
      assert length(String.split(log, "reason=unknown_event")) == 2
    end

    test "a refused join is counted and logged with its reason" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      attach_refusals(runner.id)
      {:ok, socket} = connect_runner(raw)

      log =
        capture_runner_log(runner.id, fn ->
          assert {:error, %{reason: "machine_mismatch"}} =
                   subscribe_and_join(socket, topic(socket), join_payload("mac-mini"))
        end)

      assert_received {:refused, _,
                       %{event: "join", reason: "machine_mismatch", runner_id: runner_id}}

      assert runner_id == runner.id
      assert "machine_mismatch" in RunnerContract.error_reasons()["join"]
      assert log =~ "runner message refused: event=join reason=machine_mismatch"
    end
  end

  describe "disconnecting" do
    # The push and the socket-disconnect broadcast both land in this test process (it is the
    # transport); this reads whichever comes first.
    defp first_of_disconnecting_or_close do
      receive do
        %Phoenix.Socket.Message{event: "disconnecting", payload: payload} ->
          {:disconnecting, payload}

        %Phoenix.Socket.Broadcast{event: "disconnect"} ->
          :closed
      after
        @reply_timeout -> :nothing
      end
    end

    test "a revoked runner is told runner_revoked before its socket is closed" do
      %{runner: runner, channel: channel} = joined_runner()
      Process.unlink(channel.channel_pid)
      @endpoint.subscribe(RunnerSocket.socket_id(runner.id))

      log =
        capture_runner_log(runner.id, fn ->
          {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)

          assert first_of_disconnecting_or_close() ==
                   {:disconnecting, %{reason: "runner_revoked"}}

          assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, @reply_timeout
        end)

      assert log =~ "runner disconnecting: reason=runner_revoked runner_id=#{runner.id}"
    end

    test "a runner the recheck finds unauthorized is told no_longer_authorized before the close" do
      %{runner: runner, channel: channel} = joined_runner()
      Process.unlink(channel.channel_pid)
      @endpoint.subscribe(RunnerSocket.socket_id(runner.id))
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      send(channel.channel_pid, :recheck)

      assert first_of_disconnecting_or_close() ==
               {:disconnecting, %{reason: "no_longer_authorized"}}
    end

    test "a join refused as not_authorized carries the reason in its reply, and it is logged" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, socket} = connect_runner(raw)
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      log =
        capture_runner_log(runner.id, fn ->
          assert {:error,
                  %{reason: "not_authorized", disconnecting: "join_refused_not_authorized"}} =
                   subscribe_and_join(socket, topic(socket), join_payload("minis"))
        end)

      assert log =~ "runner disconnecting: reason=join_refused_not_authorized"
    end

    test "draining another socket tells the runners nothing" do
      _ = joined_runner()

      :telemetry.execute(
        [:phoenix, :socket_drain],
        %{count: 1, total: 1, index: 1, rounds: 1},
        %{endpoint: @endpoint, socket: Phoenix.LiveView.Socket, interval: 1_000, log: :info}
      )

      refute_push "disconnecting", _
    end
  end

  describe "the socket's refusal line" do
    test "names the reason, the client IP and what the credential resolved to — never the token" do
      {raw, runner} = fixture(:runner, %{name: "minis"})
      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)

      # Unfiltered: a token that resolves to nothing names no runner. The positive match is
      # this module's own line shape and the refute is over a token no other test holds.
      log = capture_log([level: :info], fn -> assert :error = connect_runner(raw) end)

      assert log =~ "runner socket refused: reason=:invalid_token client_ip=127.0.0.1"
      refute log =~ raw
    end

    test "a key that resolved but is not a runner's is named by id" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      log = capture_runner_log(key.id, fn -> assert :error = connect_runner(raw) end)

      assert log =~ "reason=:not_a_runner"
      assert log =~ "api_key_id=#{inspect(key.id)}"
      assert log =~ "tenant_id=#{inspect(tenant.id)}"
      refute log =~ raw
    end
  end

  describe "dispatch delivery" do
    test "a pushed dispatch is stamped pushed_at; the presence meta names the node" do
      %{runner: runner} = joined_runner()
      payload = dispatch_payload(runner.tenant_id)

      assert :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
      assert_push "dispatch", _, @reply_timeout

      assert eventually(
               fn ->
                 DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]).pushed_at
               end,
               @reply_timeout
             )

      assert [meta] = Runners.live_metas(runner.tenant_id, runner.id)
      assert meta.node == Runners.node_name()
      assert Map.has_key?(meta, :machine_id)
    end

    test "a dispatch the channel drops is not stamped, and the drop names tenant, story and epoch" do
      %{runner: runner, channel: channel} = joined_runner()
      payload = dispatch_payload(runner.tenant_id, %{"claim_epoch" => 0})
      {:ok, dispatch} = RunnerContract.cast_dispatch(payload)
      {:ok, _} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      log =
        capture_runner_log(runner.id, [level: :warning], fn ->
          send(channel.channel_pid, {:runner_dispatch, dispatch})
          _ = :sys.get_state(channel.channel_pid)
        end)

      refute_push "dispatch", _
      assert DispatchLedger.get_record(runner.tenant_id, dispatch.dispatch_id).pushed_at == nil
      assert log =~ "dropped: tenant custody halted"
      assert log =~ "tenant_id=#{runner.tenant_id} story_id=#{dispatch.story_id} claim_epoch=0"
    end

    test "a refused dispatch/3 is logged with its reason and ids" do
      %{runner: runner} = joined_runner()
      payload = dispatch_payload(runner.tenant_id)
      {:ok, _} = Tenants.halt_custody(runner.tenant_id)

      log =
        capture_runner_log(runner.id, fn ->
          assert {:error, :tenant_halted} = Runners.dispatch(runner.tenant_id, runner.id, payload)
        end)

      assert log =~ "runner dispatch refused: reason=:tenant_halted"
      assert log =~ payload["dispatch_id"]
      assert log =~ payload["story_id"]
    end

    test "a refused dispatch/3's malformed ids and epoch are logged as :invalid, never their values" do
      %{runner: runner} = joined_runner()
      junk = "DISPATCHJUNK" <> String.duplicate("z", 2_000)

      payload =
        runner.tenant_id
        |> dispatch_payload()
        |> Map.merge(%{"dispatch_id" => junk, "claim_epoch" => Integer.pow(10, 500)})

      log =
        capture_runner_log(runner.id, fn ->
          assert {:error, _} = Runners.dispatch(junk, runner.id, payload)
        end)

      assert log =~ "runner dispatch refused"
      assert log =~ "tenant_id=:invalid"
      assert log =~ "dispatch_id=:invalid"
      assert log =~ "claim_epoch=:invalid"
      refute log =~ "DISPATCHJUNK"
      refute log =~ "0000000000"
    end
  end
end
