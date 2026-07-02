defmodule LoopctlWeb.EndpointWebsocketTest do
  # Guards the transport-layer DoS backstop for the public, pre-auth `/live`
  # websocket. `max_frame_size` (socket DSL) caps a SINGLE frame; this file
  # covers the complementary `max_fragmented_message_size` (Bandit server-level)
  # cap on a REASSEMBLED multi-frame message. Without it, N sub-cap continuation
  # frames coalesce into one message up to Bandit's 8 MB default.
  use ExUnit.Case, async: true

  @cap 64_000

  describe "endpoint websocket configuration" do
    test "the endpoint carries the fragmented-message cap (regression guard)" do
      ws_opts = LoopctlWeb.Endpoint.config(:http)[:websocket_options]

      assert is_list(ws_opts),
             "expected http[:websocket_options] on LoopctlWeb.Endpoint; the fragmented-message DoS backstop is missing"

      assert Keyword.get(ws_opts, :max_fragmented_message_size) == @cap
    end
  end

  describe "Bandit fragmented-message enforcement (real transport)" do
    @describetag :websocket_transport

    defmodule Sock do
      @moduledoc false
      @behaviour WebSock

      @impl true
      def init(_opts), do: {:ok, nil}

      # Never reached for the oversize case: Bandit rejects during reassembly,
      # before delivering the message to the handler.
      @impl true
      def handle_in(_frame, state), do: {:ok, state}

      @impl true
      def handle_info(_msg, state), do: {:ok, state}

      @impl true
      def terminate(_reason, _state), do: :ok
    end

    defmodule UpgradePlug do
      @moduledoc false
      @behaviour Plug

      @impl true
      def init(opts), do: opts

      @impl true
      def call(conn, _opts), do: WebSockAdapter.upgrade(conn, Sock, [], [])
    end

    test "a fragmented message over the cap is closed with 1009, not delivered" do
      {:ok, server} =
        start_supervised(
          {Bandit,
           plug: UpgradePlug,
           scheme: :http,
           port: 0,
           startup_log: false,
           websocket_options: [max_fragmented_message_size: @cap]}
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

      sock = ws_handshake(port)

      # Two sub-cap continuation frames whose reassembled length exceeds the cap.
      half = String.duplicate("A", 40_000)
      :ok = :gen_tcp.send(sock, client_frame(0x1, false, half))
      :ok = :gen_tcp.send(sock, client_frame(0x0, true, half))

      assert {:ok, resp} = :gen_tcp.recv(sock, 0, 5000)
      # Server -> client close frame is unmasked: <<0x88, len, code::16, reason>>.
      assert <<0x88, _len, code::16, _reason::binary>> = resp
      assert code == 1009

      :gen_tcp.close(sock)
    end
  end

  # --- raw websocket client helpers ---

  defp ws_handshake(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET / HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    :ok = :gen_tcp.send(sock, req)
    {:ok, resp} = :gen_tcp.recv(sock, 0, 5000)
    assert resp =~ "101 Switching Protocols"
    sock
  end

  # Build a masked client frame (clients MUST mask, RFC6455§5.3).
  defp client_frame(opcode, fin?, payload) do
    mask_key = :crypto.strong_rand_bytes(4)
    masked = apply_mask(payload, mask_key)
    fin = if fin?, do: 1, else: 0
    len = byte_size(payload)

    header =
      cond do
        len <= 125 -> <<fin::1, 0::3, opcode::4, 1::1, len::7>>
        len <= 0xFFFF -> <<fin::1, 0::3, opcode::4, 1::1, 126::7, len::16>>
        true -> <<fin::1, 0::3, opcode::4, 1::1, 127::7, len::64>>
      end

    header <> mask_key <> masked
  end

  defp apply_mask(payload, mask_key) do
    len = byte_size(payload)
    keystream = binary_part(:binary.copy(mask_key, div(len, 4) + 1), 0, len)
    :crypto.exor(payload, keystream)
  end
end
