defmodule Loopctl.E2E.ServiceContractJourneyTest do
  @moduledoc """
  End-to-end journey for the service contract every client depends on BEFORE it can
  do anything useful: is the service up, is it ready, and does it refuse the
  unauthenticated?

  Why this is an e2e test and not (only) a production probe. These exact checks live
  in `scripts/smoke.sh`, which probes the DEPLOYED release over HTTP. That probe is a
  good detector and a bad gate: it can only run after a release is already serving
  traffic, it cannot run against a pull request at all, and it fails whenever the
  network between the runner and the app misbehaves — on 2026-08-11 it reported all
  eight checks down against an app that was demonstrably healthy, because the runner
  had no working IPv6 route. A required check that can be felled by network weather
  wedges the repository shut.

  These assertions are hermetic: same contract, no network, runs on every PR, and
  therefore can gate a merge. The probe still runs against production, where it
  answers the different question of whether the live release is serving.

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e`.
  """
  use LoopctlWeb.ConnCase, async: true

  @moduletag :e2e

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "liveness and readiness" do
    test "GET /health answers unauthenticated, and reports its dependency checks",
         %{conn: conn} do
      body = conn |> get(~p"/health") |> json_response(200)

      # The smoke's hard requirement: a 200 whose database check is "ok". Oban-only
      # degradation is deliberately NOT a rollback signal there, so it is not asserted
      # as healthy here either — only that the field is reported at all.
      assert body["status"] in ["ok", "degraded"]
      assert is_map(body["checks"])
      assert body["checks"]["database"] == "ok"

      # #461 item 5: the running build is deliberately NOT disclosed on this
      # unauthenticated endpoint. A regression that starts leaking it should fail here.
      refute Map.has_key?(body, "version")
    end

    test "GET /health/ready answers, and says whether it is ready", %{conn: conn} do
      conn = get(conn, ~p"/health/ready")

      # Readiness legitimately reports 503 when a dependency is down — the contract is
      # that it ANSWERS with a boolean verdict, not that it is always ready.
      assert conn.status in [200, 503]
      assert is_boolean(json_response(conn, conn.status)["ready"])
    end
  end

  describe "auth boundary" do
    test "an API route refuses an unauthenticated caller with 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/count")

      assert json_response(conn, 401)
    end

    test "a garbage bearer token is refused with 401, not a 500", %{conn: conn} do
      # Distinguishes "rejected" from "crashed while rejecting" — a 500 here would mean
      # an unparseable credential reaches code that assumes a well-formed one.
      conn =
        conn
        |> auth_conn("lc_not_a_real_key_#{System.unique_integer([:positive])}")
        |> get(~p"/api/v1/knowledge/count")

      assert json_response(conn, 401)
    end

    test "a valid key from tenant A cannot read tenant B's counts", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      marker = "svcjrny#{System.unique_integer([:positive])}"

      for _ <- 1..2 do
        fixture(:article, %{
          tenant_id: tenant_b.id,
          title: "#{marker} #{System.unique_integer([:positive])}",
          body: "tenant B only",
          category: :pattern,
          status: :published
        })
      end

      body =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/count")
        |> json_response(200)

      # A's count must not include B's articles. Asserting on the SEARCH surface too
      # would only prove the query missed; the count proves the scope.
      assert body["count"] == 0
    end
  end
end
