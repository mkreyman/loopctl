defmodule LoopctlWeb.AuditSthControllerTest do
  @moduledoc """
  Tests for the public, unauthenticated STH endpoint. In particular the `at`
  param must never hand an out-of-bigint-range value to Postgrex (which would
  raise DBConnection.EncodeError -> uncaught 500 on an anonymous, unrate-limited
  route).
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.SignedTreeHead

  defp insert_sth(tenant_id, position) do
    %SignedTreeHead{tenant_id: tenant_id}
    |> SignedTreeHead.changeset(%{
      chain_position: position,
      merkle_root: :crypto.strong_rand_bytes(32),
      signed_at: DateTime.utc_now(),
      signature: :crypto.strong_rand_bytes(64)
    })
    |> AdminRepo.insert!()
  end

  describe "GET /api/v1/audit/sth/:tenant_id" do
    test "returns the latest STH", %{conn: conn} do
      tenant = fixture(:tenant)
      insert_sth(tenant.id, 1)
      insert_sth(tenant.id, 5)

      body = conn |> get(~p"/api/v1/audit/sth/#{tenant.id}") |> json_response(200)
      assert body["data"]["chain_position"] == 5
      assert body["data"]["tenant_id"] == tenant.id
    end

    test "returns the smallest STH at/after a position", %{conn: conn} do
      tenant = fixture(:tenant)
      insert_sth(tenant.id, 1)
      insert_sth(tenant.id, 5)

      body = conn |> get(~p"/api/v1/audit/sth/#{tenant.id}?#{[at: 3]}") |> json_response(200)
      assert body["data"]["chain_position"] == 5
    end

    test "404 when the tenant has no STH", %{conn: conn} do
      tenant = fixture(:tenant)
      assert conn |> get(~p"/api/v1/audit/sth/#{tenant.id}") |> json_response(404)
    end

    test "rejects an oversized `at` with 404 instead of a Postgrex encode 500", %{conn: conn} do
      tenant = fixture(:tenant)
      insert_sth(tenant.id, 1)

      # > 2^63-1: arbitrary-precision Elixir int that would crash Postgrex's int8
      # encoder if it reached the query. The AuditChain bound short-circuits to
      # nil -> 404.
      body =
        conn
        |> get(~p"/api/v1/audit/sth/#{tenant.id}?#{[at: "99999999999999999999999999999"]}")
        |> json_response(404)

      assert body["error"]["status"] == 404
    end

    test "rejects a negative `at` with 404", %{conn: conn} do
      tenant = fixture(:tenant)
      insert_sth(tenant.id, 1)

      assert conn |> get(~p"/api/v1/audit/sth/#{tenant.id}?#{[at: "-5"]}") |> json_response(404)
    end

    test "non-numeric `at` yields 404 (not a crash)", %{conn: conn} do
      tenant = fixture(:tenant)
      insert_sth(tenant.id, 1)

      assert conn
             |> get(~p"/api/v1/audit/sth/#{tenant.id}?#{[at: "notanumber"]}")
             |> json_response(404)
    end
  end
end
