defmodule LoopctlWeb.EndpointWebsocketTest do
  # Guards the transport-layer DoS backstop for the public, pre-auth `/live`
  # websocket. `max_frame_size` (socket DSL) caps a SINGLE frame; this file
  # covers the complementary `max_fragmented_message_size` (Bandit server-level)
  # cap on a REASSEMBLED multi-frame message. Without it, N sub-cap continuation
  # frames coalesce into one message up to Bandit's 8 MB default.
  use ExUnit.Case, async: true

  @cap 64_000

  # One deadline for every blocking :gen_tcp leg here - the connect and both
  # recvs. The sibling real-socket test, pinned_host_header_test.exs, measured
  # this exact class: a 2s budget flaked the commit gate at load 36.9 on a
  # 16-thread box, and hammering that round-trip 400x under deliberate BEAM
  # scheduler starvation reproduced it 16/400. Nothing this file asserts is
  # timing-dependent - it asserts a close code - so a slow loopback carries no
  # information about the code under test, and 5s was simply exposure.
  @deadline 30_000

  # A backstop so the flunk diagnostics below print instead of an
  # ExUnit.TimeoutError swallowing them. It only has to outlast ONE leg.
  @suite_deadline 4 * @deadline
  if @suite_deadline <= @deadline,
    do: raise("@suite_deadline must outlast one leg's @deadline")

  @moduletag timeout: @suite_deadline

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

      resp = recv!(sock, "the close frame for the oversize fragmented message")
      # Server -> client close frame is unmasked: <<0x88, len, code::16, reason>>.
      assert <<0x88, _len, code::16, _reason::binary>> = resp
      assert code == 1009

      :gen_tcp.close(sock)
    end
  end

  # --- raw websocket client helpers ---

  defp ws_handshake(port) do
    # A bare match here reported a starved-box timeout as an unexplained
    # MatchError with the reason discarded, which is what makes this class of
    # flake cost a diagnosis instead of being read off the log.
    sock =
      case :gen_tcp.connect(
             ~c"127.0.0.1",
             port,
             [:binary, active: false, packet: :raw],
             @deadline
           ) do
        {:ok, sock} ->
          sock

        {:error, reason} ->
          flunk("never connected to the test server on port #{port}: #{inspect(reason)}")
      end

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET / HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    :ok = :gen_tcp.send(sock, req)
    resp = recv!(sock, "the 101 handshake response")
    assert resp =~ "101 Switching Protocols"
    sock
  end

  # inspect/1, not :inet.format_error/1: a recv reason is :timeout or :closed as
  # often as it is a POSIX atom, and format_error renders those as
  # "unknown POSIX error".
  defp recv!(sock, what) do
    case :gen_tcp.recv(sock, 0, @deadline) do
      {:ok, resp} -> resp
      {:error, reason} -> flunk("never received #{what}: #{inspect(reason)}")
    end
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
