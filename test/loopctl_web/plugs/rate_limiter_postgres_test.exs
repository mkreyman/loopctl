defmodule LoopctlWeb.Plugs.RateLimiterPostgresTest do
  @moduledoc """
  TC-52.26.3 / AC-52.26.4: the pipeline's tenant bucket is counted on
  `Loopctl.RateLimiter.Postgres`, so requests served by two nodes draw on one budget.

  `async: false` because the subject is a COMMITTED `rate_limit_counters` row that two
  independent connections share: each "node" is a Task on its own unsandboxed AdminRepo
  connection (`Loopctl.Test.ProductionTopology`). Two processes on one sandbox connection
  would share a transaction and prove nothing about a counter two nodes see. The tenant
  bucket id is a fresh UUID nothing else touches, and its rows are deleted afterwards.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Test.ProductionTopology
  alias LoopctlWeb.Plugs.RateLimiter

  # A fixed instant, so all four requests fall in one 60s window wherever the run lands.
  @fixed_now ~U[2026-11-21 12:00:30Z]

  setup do
    Mox.set_mox_private()
    Mox.stub(Loopctl.MockClock, :utc_now, fn -> @fixed_now end)

    tenant = %Tenant{
      id: Ecto.UUID.generate(),
      settings: %{"rate_limit_tenant_requests_per_minute" => 3}
    }

    bucket = "tenant:#{tenant.id}"
    on_exit(fn -> on_own_connection(fn -> delete_bucket(bucket) end) end)

    %{tenant: tenant, bucket: bucket}
  end

  defp on_own_connection(fun) do
    Task.async(fn ->
      :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
      fun.()
    end)
    |> Task.await(15_000)
  end

  defp delete_bucket(bucket),
    do: AdminRepo.query!("DELETE FROM rate_limit_counters WHERE bucket = $1", [bucket])

  # Two requests from one node: a holder credential, so only the tenant bucket is
  # checked, on the Postgres limiter passed as the plug's tenant limiter. `:rate_limiter`
  # (the per-key seam) is left at whatever config says; it is never reached.
  defp two_requests(tenant, node) do
    api_key = %ApiKey{
      id: Ecto.UUID.generate(),
      role: :agent,
      tenant_id: tenant.id,
      holder_id: Ecto.UUID.generate(),
      name: "holder:interactive:#{node}"
    }

    on_own_connection(fn ->
      for _ <- 1..2 do
        Phoenix.ConnTest.build_conn()
        |> assign(:current_api_key, api_key)
        |> assign(:current_tenant, tenant)
        |> RateLimiter.call(tenant_limiter: Loopctl.RateLimiter.Postgres)
        |> then(&(&1.status || 200))
      end
    end)
  end

  test "two nodes' requests draw on one tenant budget", %{tenant: tenant, bucket: bucket} do
    assert two_requests(tenant, "node-a") == [200, 200]
    assert two_requests(tenant, "node-b") == [200, 429]

    %{rows: [[count]]} =
      on_own_connection(fn ->
        AdminRepo.query!(
          "SELECT count FROM rate_limit_counters WHERE bucket = $1 ORDER BY window_start DESC LIMIT 1",
          [bucket]
        )
      end)

    assert count == 4
  end
end
