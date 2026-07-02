defmodule Loopctl.Net.PinnedHostHeaderTest do
  @moduledoc """
  Real Req/Finch round-trip test for the IP-pinning `Host` header (FIX 1).

  This CANNOT use `Req.Test` — that stub adapter bypasses `Req.Finch.run/1`,
  which is exactly where the bug lived: for an IPv6-pinned target the rewritten
  URL host contains `:`, so Req pre-injects `host` = the bracketed IPv6 literal
  and (before the fix) it won over Mint's default. We therefore stand up a real
  loopback HTTP server (IPv4 and IPv6) and assert the SERVER-OBSERVED `Host`
  header is the original hostname, not the pinned IP.

  Both `Loopctl.Webhooks.ReqDelivery` and the content-ingestion worker build their
  request via the same `UrlGuard.pinned_request_opts/2`, so exercising that opts
  builder end-to-end covers both call sites.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Net.UrlGuard

  @ipv4_loopback {127, 0, 0, 1}
  @ipv6_loopback {0, 0, 0, 0, 0, 0, 0, 1}

  setup context do
    # Skip IPv6 tests on systems without IPv6 loopback bindability
    if context[:requires_ipv6] do
      case :gen_udp.open(0, [:inet6, {:ip, @ipv6_loopback}]) do
        {:ok, socket} ->
          :gen_udp.close(socket)
          :ok

        {:error, _reason} ->
          {:skip, "IPv6 loopback not available on this system"}
      end
    else
      :ok
    end
  end

  test "IPv4-pinned request sends the original hostname as Host" do
    port = start_echo_server(@ipv4_loopback, :echo_v4)

    assert observed_host("webhook.example.com", @ipv4_loopback, port) ==
             "webhook.example.com:#{port}"
  end

  @tag :requires_ipv6
  test "IPv6-pinned request sends the original hostname as Host, not [::1] (FIX 1)" do
    port = start_echo_server(@ipv6_loopback, :echo_v6)

    observed = observed_host("webhook.example.com", @ipv6_loopback, port)

    assert observed == "webhook.example.com:#{port}"
    # The regression: before the fix the server saw the bracketed IPv6 literal.
    refute observed =~ "::1"
    refute observed =~ "["
  end

  # Build the request exactly as the delivery/ingestion paths do — via
  # UrlGuard.pinned_request_opts/2 — but pointed at a loopback IP the guard would
  # normally block, so we assemble the `pinned` struct directly. Then make a REAL
  # request (no Req.Test plug) so Req.Finch.run/1 runs.
  defp observed_host(original_host, ip, port) do
    pinned = %{
      uri: URI.parse("http://#{original_host}:#{port}/"),
      host: original_host,
      ip: ip
    }

    req_opts =
      UrlGuard.pinned_request_opts(pinned)
      |> Keyword.merge(method: :get, retry: false, redirect: false, receive_timeout: 2_000)

    {:ok, %Req.Response{status: 200, body: body}} = Req.request(req_opts)
    body
  end

  defp start_echo_server(ip, id) do
    transport_options = [ip: ip] ++ if(tuple_size(ip) == 8, do: [:inet6], else: [])

    pid =
      start_supervised!(
        {Bandit,
         plug: Loopctl.Test.EchoHostPlug,
         scheme: :http,
         port: 0,
         thousand_island_options: [transport_options: transport_options]},
        id: id
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end
end
