defmodule LoopctlWeb.Plugs.PublicProofThrottleTest do
  @moduledoc """
  US-41.7 (AC-41.7.4) — the PUBLIC inclusion-proof route is the only unauthenticated
  route whose work is O(chain length) rather than a single indexed lookup, and the
  `:api` pipeline carries no limiter at all (`AuthPathThrottle` and `RateLimiter`
  live exclusively in `:authenticated`). This pins the per-IP gate that keeps it
  from becoming an anonymous CPU amplifier.

  Uses the same `:rate_limiter` behaviour DI (config/test.exs ->
  `Loopctl.MockRateLimiter`) and the same stateful counting stub as
  `auth_path_throttle_test.exs`.
  """

  use LoopctlWeb.ConnCase, async: true

  import Mox

  setup :verify_on_exit!

  alias LoopctlWeb.Plugs.PublicProofThrottle

  # Drive the client IP through the real `LoopctlWeb.Plugs.ClientIp` endpoint plug
  # via the unspoofable `fly-client-ip` header (203.0.113.0/24 is TEST-NET-3, NOT
  # the configured proxy range), so the bucket is a stable client identity.
  defp from_ip(conn, ip), do: put_req_header(conn, "fly-client-ip", ip)

  defp stub_counting_limiter(deny_after) do
    {:ok, counts} = Agent.start_link(fn -> %{} end)

    stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window_ms, _limit ->
      count =
        Agent.get_and_update(counts, fn m ->
          c = Map.get(m, bucket, 0) + 1
          {c, Map.put(m, bucket, c)}
        end)

      if count <= deny_after, do: {:allow, count}, else: {:deny, deny_after}
    end)
  end

  test "a burst of proof requests from one IP is throttled once the budget is spent", %{
    conn: conn
  } do
    stub_counting_limiter(2)
    tenant = fixture(:tenant)

    request = fn ->
      conn
      |> from_ip("203.0.113.41")
      |> get(~p"/api/v1/audit/sth/#{tenant.id}/inclusion/0")
    end

    # Within budget the route runs normally (404 — there is no chain here).
    assert request.().status == 404
    assert request.().status == 404

    denied = request.()
    assert denied.status == 429
    assert [retry_after] = get_resp_header(denied, "retry-after")
    assert String.to_integer(retry_after) > 0
    assert denied.resp_body =~ "verify it offline"
  end

  test "the budget is PER IP — one caller cannot deny the endpoint to everyone else", %{
    conn: conn
  } do
    stub_counting_limiter(1)
    tenant = fixture(:tenant)

    hot = fn ->
      conn |> from_ip("203.0.113.42") |> get(~p"/api/v1/audit/sth/#{tenant.id}/inclusion/0")
    end

    assert hot.().status == 404
    assert hot.().status == 429

    other =
      conn |> from_ip("203.0.113.43") |> get(~p"/api/v1/audit/sth/#{tenant.id}/inclusion/0")

    assert other.status == 404
  end

  test "the gate is FAIL-CLOSED: a limiter fault denies rather than unlocking the endpoint",
       %{conn: conn} do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      {:error, :limiter_down}
    end)

    tenant = fixture(:tenant)

    denied =
      conn |> from_ip("203.0.113.44") |> get(~p"/api/v1/audit/sth/#{tenant.id}/inclusion/0")

    assert denied.status == 429
  end

  test "an unresolvable client IP degrades to a no-op rather than a shared bucket" do
    # Keying a shared bucket on a proxy address would collapse every visitor onto
    # ONE bucket — a cross-client denial worse than the amplification it prevents.
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:remote_ip, :not_a_tuple)

    refute PublicProofThrottle.call(conn, []).halted
  end
end
