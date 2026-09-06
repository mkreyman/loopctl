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

  # One deadline for the two legs Req can set: pool checkout (Finch defaults to
  # 5s) and each socket read (15s). Connect is NOT one of them - Req/Mint
  # already default it to 30_000, and overriding it changes the md5 Req names
  # its Finch pool from, diverging this test's pool from the production one.
  @request_deadline 30_000

  # The ONLY total bound: receive_timeout is per-CHUNK and Req forwards just
  # :receive_timeout/:pool_timeout to Finch, so Finch's :request_timeout stays
  # :infinity. A backstop, not a derived worst case - it only has to outlast one
  # leg so the flunk diagnostics print instead of an ExUnit.TimeoutError.
  @suite_deadline 4 * @request_deadline
  if @suite_deadline <= @request_deadline,
    do: raise("@suite_deadline must outlast one leg's @request_deadline")

  @moduletag timeout: @suite_deadline

  @ipv4_loopback {127, 0, 0, 1}
  @ipv6_loopback {0, 0, 0, 0, 0, 0, 0, 1}

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

    pinned_opts = UrlGuard.pinned_request_opts(pinned)

    req_opts =
      Keyword.merge(pinned_opts,
        method: :get,
        retry: false,
        redirect: false,
        pool_timeout: @request_deadline,
        receive_timeout: @request_deadline
      )

    # The verdict depends on a real socket completing inside a deadline. A 2s
    # budget flaked the commit gate at load 36.9 on a 16-thread box; hammering
    # the round-trip 400x under deliberate scheduler starvation reproduced it
    # 16/400, every one a Req.TransportError reason :timeout - box weather, not
    # a defect, but a bare match reported it as an unexplained MatchError.
    # inspect/1, not Exception.message/1: it keeps the error MODULE, and cannot
    # itself raise on a non-exception term.
    # A pool-checkout timeout does NOT return {:error, _}: Finch reraises a bare
    # RuntimeError (deps/finch/lib/finch/http1/pool.ex), so rescue it into the
    # same diagnostic instead of letting it escape as an unexplained raise.
    try do
      case Req.request(req_opts) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          body

        {:ok, %Req.Response{status: status}} ->
          flunk("echo server answered #{status}, expected 200")

        {:error, error} ->
          flunk("pinned request never completed: #{inspect(error)}")
      end
    rescue
      error in RuntimeError ->
        flunk("pinned request never completed: " <> Exception.message(error))
    end
  end

  defp start_echo_server(ip, id) do
    transport_options = [ip: ip] ++ if(tuple_size(ip) == 8, do: [:inet6], else: [])

    # Bind once ourselves: start_supervised! reports a failed bind as an opaque
    # :eaddrnotavail child-start exit. test_helper.exs excludes :requires_ipv6
    # after its own probe, but --include/--only OVERRIDE that exclude, and a
    # setup returning {:skip, _} raises - so this is the only guard left.
    case :gen_tcp.listen(0, [{:active, false} | transport_options]) do
      {:ok, probe} -> :gen_tcp.close(probe)
      {:error, reason} -> flunk("cannot bind #{:inet.ntoa(ip)}: #{:inet.format_error(reason)}")
    end

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
