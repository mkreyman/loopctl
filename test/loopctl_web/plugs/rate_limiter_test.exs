defmodule LoopctlWeb.Plugs.RateLimiterTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.ApiSpec.Schemas.RateLimitError
  alias Loopctl.Auth.ApiKey
  alias Loopctl.RateLimiter.FailOpenLog
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

      # sec-4: the `:authenticated` pipeline now runs the fail-CLOSED
      # `AuthPathThrottle` gate FIRST (bucket `auth_ip:*`). Let it pass so this
      # test exercises the per-key limiter's OWN fail-OPEN handling in isolation
      # (a partial fault). A total limiter outage that also faults `auth_ip:*`
      # would be denied 429 by that earlier gate — the deliberate sec-4 tradeoff.
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "auth_ip:" <> _, _window_ms, _limit -> {:allow, 1}
        _bucket, _window_ms, _limit -> raise "limiter store is down"
      end)

      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # The fail-open warning is throttled per `(source, family)` in a shared,
      # node-local ETS window that lives for the whole run. A concurrent async
      # test whose pipeline plug tripped a `(:plug, "key")`/`(:plug, "tenant")`
      # fail-open within the last 60s would otherwise suppress THIS test's warning
      # and make the log assertion flaky. Clear our two families so the emission
      # is deterministic (the plug checks the key bucket, then the tenant bucket).
      FailOpenLog.reset(:plug, "key")
      FailOpenLog.reset(:plug, "tenant")

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

  # US-52.26: a holder credential meets only the tenant-wide bucket.
  describe "holder credentials (US-52.26)" do
    defp holder_and_plain_keys(settings) do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored, settings: settings})
      {plain_raw, _plain_key, agent} = fixture(:agent_key, %{tenant_id: tenant.id})

      {:ok, %{raw_key: holder_raw, api_key: holder_key}} =
        Loopctl.Holders.register(tenant.id, agent.id, %{
          "kind" => "interactive",
          "session_id" => "s1",
          "host" => "minis"
        })

      %{tenant: tenant, holder_raw: holder_raw, holder_key: holder_key, plain_raw: plain_raw}
    end

    # TC-52.26.1
    test "a holder credential skips the per-key check; a plain key keeps it", %{conn: conn} do
      counts = stub_counting_limiter()

      ctx =
        holder_and_plain_keys(%{
          "rate_limit_requests_per_minute" => 2,
          "rate_limit_tenant_requests_per_minute" => 100
        })

      assert is_binary(ctx.holder_key.holder_id)

      holder =
        for _ <- 1..3 do
          build_conn() |> auth_conn(ctx.holder_raw) |> get(~p"/api/v1/tenants/me")
        end

      assert Enum.map(holder, & &1.status) == [200, 200, 200]

      assert Enum.map(holder, &get_resp_header(&1, "x-ratelimit-limit")) == [
               ["100"],
               ["100"],
               ["100"]
             ]

      assert Enum.map(holder, &get_resp_header(&1, "x-ratelimit-remaining")) ==
               [["99"], ["98"], ["97"]]

      # The holder's key bucket was never counted.
      refute Map.has_key?(Agent.get(counts, & &1), "key:#{ctx.holder_key.id}")

      plain =
        for _ <- 1..3 do
          build_conn() |> auth_conn(ctx.plain_raw) |> get(~p"/api/v1/tenants/me")
        end

      assert Enum.map(plain, & &1.status) == [200, 200, 429]
      assert get_resp_header(hd(plain), "x-ratelimit-limit") == ["2"]

      # Both keys drew on the one tenant bucket: 3 holder checks + 2 plain ones (the
      # plain key's third request stopped at its own key bucket).
      assert Agent.get(counts, &Map.get(&1, "tenant:#{ctx.tenant.id}")) == 5

      # The superadmin key reaches no limiter at all, on 300 calls.
      test_pid = self()

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _w, _l ->
        send(test_pid, {:checked, bucket})
        {:allow, 1}
      end)

      superadmin = %ApiKey{id: Ecto.UUID.generate(), role: :superadmin, tenant_id: nil}

      for _ <- 1..300 do
        result =
          conn
          |> assign(:current_api_key, superadmin)
          |> assign(:current_tenant, nil)
          |> RateLimiter.call(
            tenant_limiter: Loopctl.MockRateLimiter,
            key_limiter: Loopctl.MockRateLimiter
          )

        refute result.halted
      end

      refute_received {:checked, _}
    end
  end

  # TC-52.26.6
  test "the OpenAPI RateLimitError names the tenant setting and the holder exemption" do
    description = RateLimitError.schema().description

    assert description =~ "rate_limit_tenant_requests_per_minute"
    assert description =~ "no per-key limit"
  end

  describe "tenant-wide limit (US-52.26)" do
    defp call_plug(tenant, api_key_attrs \\ %{}) do
      test_pid = self()

      stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window_ms, limit ->
        send(test_pid, {:limit, bucket, limit})
        {:allow, 1}
      end)

      api_key =
        struct(
          ApiKey,
          Map.merge(
            %{id: Ecto.UUID.generate(), role: :agent, tenant_id: tenant.id, holder_id: nil},
            api_key_attrs
          )
        )

      build_conn()
      |> assign(:current_api_key, api_key)
      |> assign(:current_tenant, tenant)
      |> RateLimiter.call(
        tenant_limiter: Loopctl.MockRateLimiter,
        key_limiter: Loopctl.MockRateLimiter
      )
    end

    defp tenant_limit_seen(tenant_id) do
      bucket = "tenant:#{tenant_id}"
      assert_received {:limit, ^bucket, limit}
      limit
    end

    # TC-52.26.2
    test "the tenant limit is its own setting, not per_key_limit * 3" do
      decoupled = fixture(:tenant, %{settings: %{"rate_limit_requests_per_minute" => 100}})
      set = fixture(:tenant, %{settings: %{"rate_limit_tenant_requests_per_minute" => 50}})

      call_plug(decoupled)
      assert tenant_limit_seen(decoupled.id) == 900
      assert_received {:limit, "key:" <> _, 100}

      call_plug(set)
      assert tenant_limit_seen(set.id) == 50
    end

    test "a tenant setting stored as a string is coerced; garbage falls back to 900" do
      string = fixture(:tenant, %{settings: %{"rate_limit_tenant_requests_per_minute" => "40"}})
      garbage = fixture(:tenant, %{settings: %{"rate_limit_tenant_requests_per_minute" => 0}})

      call_plug(string)
      assert tenant_limit_seen(string.id) == 40

      call_plug(garbage)
      assert tenant_limit_seen(garbage.id) == RateLimiter.default_tenant_limit()
    end

    test "a holder credential's call checks the tenant bucket only" do
      tenant = fixture(:tenant)
      call_plug(tenant, %{holder_id: Ecto.UUID.generate()})

      assert tenant_limit_seen(tenant.id) == 900
      refute_received {:limit, "key:" <> _, _}
    end

    test "the tenant bucket resolves through tenant_impl/0, the per-key bucket through impl/0" do
      assert Loopctl.RateLimiter.default_tenant_impl() == Loopctl.RateLimiter.Postgres
      assert Loopctl.RateLimiter.default_impl() == Loopctl.RateLimiter.Hammer
      # config/test.exs points both at the mock.
      assert Loopctl.RateLimiter.tenant_impl() == Loopctl.MockRateLimiter
    end

    # TC-52.26.5
    test "over the tenant limit: 429 with retry-after and the error body" do
      tenant = fixture(:tenant)

      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window_ms, _limit ->
        {:deny, 900}
      end)

      holder_key = %ApiKey{
        id: Ecto.UUID.generate(),
        role: :agent,
        tenant_id: tenant.id,
        holder_id: Ecto.UUID.generate()
      }

      conn =
        build_conn()
        |> assign(:current_api_key, holder_key)
        |> assign(:current_tenant, tenant)
        |> RateLimiter.call(tenant_limiter: Loopctl.MockRateLimiter)

      assert conn.halted
      assert conn.status == 429
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) >= 1
      assert get_resp_header(conn, "x-ratelimit-limit") == ["900"]

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{"status" => 429, "message" => "Rate limit exceeded"}
             }
    end

    test "a raising, exiting or throwing limiter fails open with one warning per family" do
      import ExUnit.CaptureLog

      tenant = fixture(:tenant)
      {:ok, faults} = Agent.start_link(fn -> [:raise, :exit, :throw] end)

      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window_ms, _limit ->
        case Agent.get(faults, &hd/1) do
          :raise -> raise "limiter store is down"
          :exit -> exit(:pool_timeout)
          :throw -> throw(:boom)
        end
      end)

      FailOpenLog.reset(:plug, "key")
      FailOpenLog.reset(:plug, "tenant")

      api_key = %ApiKey{id: Ecto.UUID.generate(), role: :agent, tenant_id: tenant.id}

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            conn =
              build_conn()
              |> assign(:current_api_key, api_key)
              |> assign(:current_tenant, tenant)
              |> RateLimiter.call(
                tenant_limiter: Loopctl.MockRateLimiter,
                key_limiter: Loopctl.MockRateLimiter
              )

            refute conn.halted
            assert conn.status == nil
            Agent.update(faults, &tl/1)
          end
        end)

      assert length(Regex.scan(~r/fail-open \[plug\].*family=key;/, log)) == 1
      assert length(Regex.scan(~r/fail-open \[plug\].*family=tenant;/, log)) == 1
    end
  end
end
