defmodule LoopctlWeb.Plugs.RateLimiterTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias LoopctlWeb.Plugs.RateLimiter

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # US-38.2: the plug now resolves the limiter through the `:rate_limiter`
  # behaviour DI (config/test.exs -> Loopctl.MockRateLimiter), the SAME seam
  # Provider.Admission uses, so it becomes cluster-global when the Postgres impl
  # is selected. This stateful stub reproduces the fixed-window counter contract
  # (post-increment count per bucket, allow while count <= limit) so the plug's
  # allow/deny/header behaviour is byte-for-byte what the ETS impl produced.
  defp stub_counting_limiter do
    {:ok, counts} = Agent.start_link(fn -> %{} end)

    stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window_ms, limit ->
      count =
        Agent.get_and_update(counts, fn m ->
          c = Map.get(m, bucket, 0) + 1
          {c, Map.put(m, bucket, c)}
        end)

      if count <= limit, do: {:allow, count}, else: {:deny, limit}
    end)

    counts
  end

  describe "rate limiting" do
    test "request within limit succeeds with headers", %{conn: conn} do
      stub_counting_limiter()
      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")

      assert conn.status == 200
      assert get_resp_header(conn, "x-ratelimit-limit") != []
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
      assert get_resp_header(conn, "x-ratelimit-reset") != []
    end

    test "request exceeding limit returns 429", %{conn: _conn} do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"rate_limit_requests_per_minute" => 3}})
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # First 3 requests should succeed
      for _ <- 1..3 do
        resp = build_conn() |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")
        assert resp.status == 200
      end

      # 4th request should be rate limited
      resp = build_conn() |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")
      assert resp.status == 429
      body = json_response(resp, 429)
      assert body["error"]["message"] == "Rate limit exceeded"
      assert get_resp_header(resp, "retry-after") != []
    end

    test "tenant-level custom rate limit is respected", %{conn: conn} do
      stub_counting_limiter()
      tenant = fixture(:tenant, %{settings: %{"rate_limit_requests_per_minute" => 5}})
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")

      [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert limit == "5"
    end

    test "superadmin key bypasses rate limiting", %{conn: conn} do
      api_key = %ApiKey{
        id: Ecto.UUID.generate(),
        role: :superadmin,
        tenant_id: nil
      }

      # Test the plug directly rather than going through a full endpoint
      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> assign(:current_tenant, nil)
        |> RateLimiter.call([])

      refute conn.halted
      # No rate limit headers for superadmin
      assert get_resp_header(conn, "x-ratelimit-limit") == []
    end
  end

  describe "cluster-global DI seam (US-38.2)" do
    test "the plug resolves the limiter through the :rate_limiter behaviour DI (TC-38.2.3)" do
      # Proof the plug routes through the SAME config-selected behaviour as
      # Provider.Admission: when we swap the DI-resolved impl (here the mock,
      # standing in for the Postgres impl), the plug invokes it. Selecting the
      # Postgres impl therefore makes this plug cluster-global with no call-site
      # change. We assert on the bucket keys the plug hands the limiter.
      test_pid = self()

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, window_ms, _limit ->
        send(test_pid, {:checked, bucket, window_ms})
        {:allow, 1}
      end)

      tenant = fixture(:tenant)
      {raw_key, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      resp = build_conn() |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")
      assert resp.status == 200

      # Both the per-key and per-tenant checks go through the resolved behaviour,
      # each with the fixed 60s window.
      assert_received {:checked, "key:" <> key_id, 60_000}
      assert_received {:checked, "tenant:" <> tenant_id, 60_000}
      assert key_id == key.id
      assert tenant_id == tenant.id
    end

    test "the plug FAILS OPEN when the limiter raises (limiter outage never blocks all traffic)" do
      import ExUnit.CaptureLog

      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window_ms, _limit ->
        raise "limiter store is down"
      end)

      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      log =
        capture_log(fn ->
          resp = build_conn() |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")
          # Fail-open: the request is allowed through, not 429'd.
          assert resp.status == 200
        end)

      # Throttled, PII-safe fail-open log: the bucket is reduced to its
      # non-identifying family ("key"/"tenant"), never the raw UUID.
      assert log =~ "fail-open"
      assert log =~ "family=key"
    end
  end
end
