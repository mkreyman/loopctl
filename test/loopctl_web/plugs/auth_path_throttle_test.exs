defmodule LoopctlWeb.Plugs.AuthPathThrottleTest do
  @moduledoc """
  sec-4 — fail-CLOSED per-IP throttle on the API-key authentication path.

  The gate is placed FIRST in the `:authenticated` pipeline (before
  `ExtractApiKey`), so a flood of missing/invalid-key requests from one IP is
  counted and throttled (429) even though the key-resolution plugs reject them
  401 first. It resolves the limiter through the SAME `:rate_limiter` behaviour
  DI (config/test.exs -> `Loopctl.MockRateLimiter`) as the per-key limiter, but
  via the fail-CLOSED `Loopctl.RateLimiter.gate_ok?/3` helper.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.RemoteIp

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Drive the client IP through the real `LoopctlWeb.Plugs.ClientIp` endpoint
  # plug via the unspoofable `fly-client-ip` header (203.0.113.0/24 is TEST-NET-3,
  # NOT the configured proxy range 198.51.100.0/24), so `conn.remote_ip` — and
  # therefore the `auth_ip:<ip>` bucket — is a stable trusted client identity.
  defp from_ip(conn, ip), do: put_req_header(conn, "fly-client-ip", ip)

  # Stateful per-bucket counting stub mirroring `rate_limiter_test.exs`. Allows
  # while the post-increment count for a bucket is <= `deny_after`, then denies.
  # Both limiter call sites in the pipeline (this gate's `auth_ip:*` bucket AND
  # the per-key limiter's `key:*`/`tenant:*` buckets) share this stub; each
  # bucket counts independently, so exercising the auth-path gate never trips the
  # per-key limiter and vice versa.
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

    counts
  end

  describe "per-IP auth-path throttle (AC-1: counts 401s)" do
    test "a burst of invalid-key requests from one IP is throttled after the budget", %{
      conn: _conn
    } do
      # Budget of 3: the first 3 bad-key requests get 401 (auth plugs reject the
      # invalid key), and the 4th is throttled 429 by the gate — proving the 401s
      # are counted against the per-IP budget.
      stub_counting_limiter(3)

      req = fn ->
        build_conn() |> from_ip("203.0.113.10") |> auth_conn("lc_totally_invalid_key")
      end

      for _ <- 1..3 do
        assert req.() |> get(~p"/api/v1/tenants/me") |> Map.get(:status) == 401
      end

      resp = req.() |> get(~p"/api/v1/tenants/me")
      assert resp.status == 429
      body = json_response(resp, 429)
      assert body["error"]["status"] == 429
      assert get_resp_header(resp, "retry-after") != []
    end

    test "a burst of MISSING-key requests from one IP is also throttled", %{conn: _conn} do
      # No Authorization header at all — RequireAuth 401s these, but the gate runs
      # first and counts them, so the flood is still throttled.
      stub_counting_limiter(2)

      req = fn ->
        build_conn() |> from_ip("203.0.113.11") |> delete_req_header("authorization")
      end

      for _ <- 1..2 do
        assert req.() |> get(~p"/api/v1/tenants/me") |> Map.get(:status) == 401
      end

      assert req.() |> get(~p"/api/v1/tenants/me") |> Map.get(:status) == 429
    end
  end

  describe "valid traffic (AC-2 / AC-5: unaffected)" do
    test "a valid authenticated request is not throttled by the new gate", %{conn: _conn} do
      # Generous budget: the handful of valid requests stay well under it.
      stub_counting_limiter(1000)

      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      for _ <- 1..5 do
        resp =
          build_conn()
          |> from_ip("203.0.113.20")
          |> auth_conn(raw_key)
          |> get(~p"/api/v1/tenants/me")

        assert resp.status == 200
      end
    end

    test "the existing per-key limiter still runs alongside the new gate", %{conn: _conn} do
      # Prove BOTH gates fire: the auth-path gate hits an `auth_ip:*` bucket and
      # the per-key limiter hits `key:*`/`tenant:*` buckets, all via the DI seam.
      test_pid = self()

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window_ms, _limit ->
        send(test_pid, {:checked, bucket})
        {:allow, 1}
      end)

      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      resp =
        build_conn()
        |> from_ip("203.0.113.21")
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/tenants/me")

      assert resp.status == 200
      assert_received {:checked, "auth_ip:203.0.113.21"}
      assert_received {:checked, "key:" <> _}
      assert_received {:checked, "tenant:" <> _}
    end
  end

  describe "per-IP isolation (AC-4)" do
    test "throttling one IP does not throttle another", %{conn: _conn} do
      stub_counting_limiter(2)

      req = fn ip -> build_conn() |> from_ip(ip) |> auth_conn("lc_totally_invalid_key") end

      # Exhaust IP A: 2 x 401, then 429.
      assert req.("203.0.113.30") |> get(~p"/api/v1/tenants/me") |> Map.get(:status) == 401
      assert req.("203.0.113.30") |> get(~p"/api/v1/tenants/me") |> Map.get(:status) == 401
      assert req.("203.0.113.30") |> get(~p"/api/v1/tenants/me") |> Map.get(:status) == 429

      # IP B is on a fresh bucket — its first request is NOT throttled (still the
      # auth plugs' 401 for the invalid key, not the gate's 429).
      assert req.("203.0.113.31") |> get(~p"/api/v1/tenants/me") |> Map.get(:status) == 401
    end
  end

  describe "fail-closed on limiter-store fault (AC-3)" do
    test "a limiter raise denies (429) instead of failing open", %{conn: _conn} do
      # gate_ok?/3 normalises a raise to `false` (denied), so a store outage
      # DENIES the auth path rather than silently unlocking the volumetric gate.
      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window_ms, _limit ->
        raise "limiter store is down"
      end)

      resp =
        build_conn()
        |> from_ip("203.0.113.40")
        |> delete_req_header("authorization")
        |> get(~p"/api/v1/tenants/me")

      assert resp.status == 429
      assert json_response(resp, 429)["error"]["status"] == 429
    end

    test "a limiter error-tuple also denies (429)", %{conn: _conn} do
      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window_ms, _limit ->
        {:error, :store_down}
      end)

      resp =
        build_conn()
        |> from_ip("203.0.113.41")
        |> delete_req_header("authorization")
        |> get(~p"/api/v1/tenants/me")

      assert resp.status == 429
    end

    test "a request bearing a VALID authenticated key is ALSO denied (429) on a store fault",
         %{conn: _conn} do
      # Pins the deliberate blast radius: because the gate runs FIRST in the
      # :authenticated pipeline (before ExtractApiKey), a limiter-store fault
      # denies ALL authenticated traffic — not just missing/invalid-key requests.
      # A future change that accidentally scoped the fail-CLOSED gate to only
      # unauthenticated requests would flip this valid-key case to 200 and be
      # caught here.
      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window_ms, _limit ->
        raise "limiter store is down"
      end)

      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      resp =
        build_conn()
        |> from_ip("203.0.113.42")
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/tenants/me")

      assert resp.status == 429
      assert json_response(resp, 429)["error"]["status"] == 429
    end
  end

  describe "operator-configurable ceiling (sec-4 fix)" do
    test "the default ceiling/window flow through to the limiter unchanged", %{conn: _conn} do
      # Regression guard for the refactor from fixed module attributes to an
      # Application-env-overridable ceiling: with no override configured, the gate
      # must still pass the coarse DEFAULTS (3000 req / 60_000 ms) to the limiter.
      # Observed via the DI stub's own arguments — no Application.put_env (test
      # conventions forbid it); the default config leaves the knob unset.
      test_pid = self()

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, window_ms, limit ->
        # Report only the auth-path gate's args; the per-key limiter's
        # key:*/tenant:* buckets pass through allowed.
        if String.starts_with?(bucket, "auth_ip:") do
          send(test_pid, {:auth_gate_args, bucket, window_ms, limit})
        end

        {:allow, 1}
      end)

      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      resp =
        build_conn()
        |> from_ip("203.0.113.43")
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/tenants/me")

      assert resp.status == 200
      assert_received {:auth_gate_args, "auth_ip:203.0.113.43", 60_000, 3_000}
    end
  end

  describe "RemoteIp.bucket_key/1 (shared trusted-IP helper)" do
    test "a resolved public client yields a stable IP-keyed bucket" do
      assert RemoteIp.bucket_key({203, 0, 113, 50}) == "203.0.113.50"
    end

    test "a proxy IP falls back to a unique, non-shared per-request key" do
      # 198.51.100.0/24 is the configured proxy range (config/test.exs): keying a
      # shared bucket on it would collapse every proxy-fronted visitor onto one
      # bucket, so the helper returns a per-request key instead.
      key1 = RemoteIp.bucket_key({198, 51, 100, 5})
      key2 = RemoteIp.bucket_key({198, 51, 100, 5})

      assert String.starts_with?(key1, "req:")
      assert String.starts_with?(key2, "req:")
      refute key1 == key2
    end

    test "a non-tuple address falls back to a unique per-request key" do
      assert RemoteIp.bucket_key(nil) |> String.starts_with?("req:")
      assert RemoteIp.bucket_key("not-an-ip") |> String.starts_with?("req:")
    end
  end
end
