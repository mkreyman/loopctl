defmodule LoopctlWeb.Plugs.GithubIntakeThrottleTest do
  @moduledoc """
  Issue #803 — the GitHub intake webhook is public and authenticates by HMAC, so every
  request costs a source lookup and an HMAC before it can be refused. This pins the per-IP,
  fail-closed gate on its pipeline, using the `:rate_limiter` behaviour DI
  (`Loopctl.MockRateLimiter`) as `public_proof_throttle_test.exs` does.
  """

  use LoopctlWeb.ConnCase, async: true

  import Mox

  alias Loopctl.Intake
  alias Loopctl.Intake.Signature
  alias LoopctlWeb.Plugs.GithubIntakeThrottle

  setup :verify_on_exit!

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

  defp deliver(conn, ip, secret, source) do
    raw = Jason.encode!(build(:github_issues_payload, %{}))

    conn
    |> put_req_header("fly-client-ip", ip)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "issues")
    |> put_req_header("x-github-delivery", Ecto.UUID.generate())
    |> put_req_header("x-hub-signature-256", Signature.header(secret, raw))
    |> post("/api/v1/intake/github/#{source.id}", raw)
  end

  test "a burst from one IP is throttled once the budget is spent, per IP", %{conn: conn} do
    stub_counting_limiter(1)
    {secret, source} = fixture(:intake_source, %{})

    assert deliver(conn, "203.0.113.51", secret, source).status == 200

    denied = deliver(conn, "203.0.113.51", secret, source)
    assert denied.status == 429
    assert [_retry_after] = get_resp_header(denied, "retry-after")

    assert deliver(conn, "203.0.113.52", secret, source).status == 200
    assert length(Intake.list_deliveries(source.tenant_id, source.id)) == 2
  end

  test "the gate is FAIL-CLOSED: a limiter fault denies and records nothing", %{conn: conn} do
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      {:error, :limiter_down}
    end)

    {secret, source} = fixture(:intake_source, %{})

    assert deliver(conn, "203.0.113.53", secret, source).status == 429
    assert Intake.list_deliveries(source.tenant_id, source.id) == []
  end

  test "an unresolvable client IP degrades to a no-op rather than a shared bucket" do
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:remote_ip, :not_a_tuple)
    refute GithubIntakeThrottle.call(conn, []).halted
  end
end
