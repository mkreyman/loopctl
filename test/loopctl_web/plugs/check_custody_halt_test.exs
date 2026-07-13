defmodule LoopctlWeb.Plugs.CheckCustodyHaltTest do
  @moduledoc """
  US-33.2 — CheckCustodyHalt reuses the tenant already preloaded by
  ResolveApiKey (`current_tenant` assign) instead of issuing a redundant
  AdminRepo SELECT via `Tenants.get_tenant/1`.

  Covers: a custody-halted tenant is still blocked (503 tenant_halted), a
  non-halted tenant still passes, per-tenant isolation drives the decision from
  each request's own loaded tenant, and (telemetry proof) the redundant
  `tenants` SELECT is gone — a halted request issues exactly ONE query against
  the `tenants` source (the ResolveApiKey preload), not two.

  Async: every path routes through `Loopctl.AdminRepo`, so all queries share the
  one sandbox connection the fixtures insert through.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Auth.ApiKey
  alias LoopctlWeb.Plugs.CheckCustodyHalt

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # Attaches a `tenants`-SELECT probe SCOPED to one tenant_id so it never catches
  # parallel async tests' queries (the handler is attached VM-globally). Sends
  # `{ref, :tenants_query}` to the test process for each matching AdminRepo query.
  defp attach_tenants_probe(tenant_id) do
    {:ok, tenant_id_bin} = Ecto.UUID.dump(tenant_id)
    test_pid = self()
    ref = make_ref()
    handler_id = "check-custody-halt-probe-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:loopctl, :admin_repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "tenants" and
             tenant_id_bin in List.wrap(metadata[:params]) do
          send(test_pid, {ref, :tenants_query})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # api_keys.agent_id is a FK to agents, so mint a real agent per agent key.
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    raw
  end

  describe "custody halt enforcement (US-33.2)" do
    test "TC-33.2.1: a custody-halted tenant's request is blocked (503 tenant_halted)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      raw = agent_key(tenant.id)
      {:ok, _} = Loopctl.Tenants.halt_custody(tenant.id)

      body =
        conn
        |> auth(raw)
        |> get(~p"/api/v1/memory")
        |> json_response(503)

      assert body["error"]["code"] == "tenant_halted"
    end

    test "TC-33.2.2: a non-halted tenant's request proceeds normally (non-503)", %{conn: conn} do
      tenant = fixture(:tenant)
      raw = agent_key(tenant.id)

      conn
      |> auth(raw)
      |> get(~p"/api/v1/memory")
      |> json_response(200)
    end

    test "TC-33.2.3: tenant isolation — tenant A halted is blocked, tenant B passes", %{
      conn: conn
    } do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      raw_a = agent_key(tenant_a.id)
      raw_b = agent_key(tenant_b.id)
      {:ok, _} = Loopctl.Tenants.halt_custody(tenant_a.id)

      blocked =
        conn
        |> auth(raw_a)
        |> get(~p"/api/v1/memory")
        |> json_response(503)

      assert blocked["error"]["code"] == "tenant_halted"

      base_conn()
      |> auth(raw_b)
      |> get(~p"/api/v1/memory")
      |> json_response(200)
    end

    test "TC-33.2.4: no redundant tenants SELECT — halted request queries tenants exactly once",
         %{conn: conn} do
      tenant = fixture(:tenant)
      raw = agent_key(tenant.id)
      {:ok, _} = Loopctl.Tenants.halt_custody(tenant.id)

      # Scope the handler to THIS tenant's queries only — the handler is attached
      # VM-globally and would otherwise catch parallel async tests' `tenants`
      # SELECTs (flaky). Ecto dumps the UUID PK to a 16-byte binary in params.
      {:ok, tenant_id_bin} = Ecto.UUID.dump(tenant.id)

      test_pid = self()
      ref = make_ref()
      handler_id = "check-custody-halt-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :admin_repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "tenants" and
               tenant_id_bin in List.wrap(metadata[:params]) do
            send(test_pid, {ref, :tenants_query})
          end
        end,
        nil
      )

      try do
        body =
          conn
          |> auth(raw)
          |> get(~p"/api/v1/memory")
          |> json_response(503)

        assert body["error"]["code"] == "tenant_halted"
      after
        :telemetry.detach(handler_id)
      end

      # Exactly one `tenants` SELECT (the ResolveApiKey preload). The removed
      # CheckCustodyHalt re-SELECT would make this two.
      assert_receive {^ref, :tenants_query}
      refute_receive {^ref, :tenants_query}
    end
  end

  # Direct `call/2` unit tests (SetTenantTest / RequireHumanAnchorTest style) for
  # the two AC-enumerated branches the integration tests above cannot reach: every
  # minted-key request preloads a tenant, so those only exercise the `%Tenant{}`
  # fast path (check_custody_halt.ex:79). These drive the defensive DB fallback and
  # the tenant-less early return directly.
  describe "call/2 branch coverage (US-33.2)" do
    test "TC-33.2.5: refetch fallback enforces the halt via a DB read when no current_tenant is assigned",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {:ok, _} = Loopctl.Tenants.halt_custody(tenant.id)
      ref = attach_tenants_probe(tenant.id)

      # AC-33.2.1 defensive path: current_api_key carries the tenant_id, but NO
      # current_tenant struct is in assigns — the plug must fall back to
      # Tenants.get_tenant/1 and STILL enforce the halt (guards the "silently
      # returns conn without enforcing" regression).
      api_key = %ApiKey{tenant_id: tenant.id, role: :agent}

      result =
        conn
        |> assign(:current_api_key, api_key)
        |> CheckCustodyHalt.call([])

      assert result.halted
      assert result.status == 503
      assert Jason.decode!(result.resp_body)["error"]["code"] == "tenant_halted"

      # Proves the fallback actually hit the DB (contrast: TC-33.2.4's fast path
      # issues the SELECT via the ResolveApiKey preload, not here).
      assert_receive {^ref, :tenants_query}
    end

    test "TC-33.2.6: refetch fallback passes a non-halted tenant through (DB read, no halt)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      ref = attach_tenants_probe(tenant.id)
      api_key = %ApiKey{tenant_id: tenant.id, role: :agent}

      result =
        conn
        |> assign(:current_api_key, api_key)
        |> CheckCustodyHalt.call([])

      refute result.halted
      assert is_nil(result.status)
      assert_receive {^ref, :tenants_query}
    end

    test "TC-33.2.7: a tenant-less superadmin key passes the halt check untouched (nil tenant_id early return)",
         %{conn: conn} do
      # AC-33.2.3: standalone superadmin (nil tenant_id, current_tenant nil) hits the
      # is_nil(tenant_id) -> conn guard BEFORE check_tenant_halt/2 — so it reaches the
      # controller and, structurally, issues no tenants SELECT for the halt check.
      api_key = %ApiKey{tenant_id: nil, role: :superadmin}

      result =
        conn
        |> assign(:current_api_key, api_key)
        |> assign(:current_tenant, nil)
        |> CheckCustodyHalt.call([])

      # Returned unchanged (not halted, no status/body set) — proceeds to the controller.
      refute result.halted
      assert is_nil(result.status)
      assert is_nil(result.resp_body)
    end
  end

  # A fresh conn carrying the witness STH header (ConnCase adds it to the shared
  # `conn`, but a second dispatched request needs its own conn).
  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")
end
