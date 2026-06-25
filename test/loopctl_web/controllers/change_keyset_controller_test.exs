defmodule LoopctlWeb.ChangeKeysetControllerTest do
  @moduledoc """
  HTTP integration tests for the KEYSET cursor on the change feed (US-27.9b),
  exercised through `GET /api/v1/changes` with `?cursor=`.

  Covers the tie-safe walk to exhaustion (AC-27.9b.1), the forged cross-tenant
  cursor (AC-27.9b.4), tampered/garbage cursors → 400, and that the legacy
  `?since=` token still works (back-compat).
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Audit.ChangesCursor

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Insert `n` audit rows for a tenant at one shared timestamp (a tied batch).
  defp insert_tied(tenant_id, n, ts) do
    rows =
      for i <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: Ecto.UUID.generate(),
          action: "story.updated",
          actor_type: "api_key",
          new_state: %{"n" => i},
          metadata: %{},
          inserted_at: ts
        }
      end

    {_n, returned} = AdminRepo.insert_all(AuditLog, rows, returning: [:id])
    Enum.map(returned, & &1.id)
  end

  defp walk_http(conn, raw_key, first_params) do
    do_walk_http(conn, raw_key, first_params, [], 0)
  end

  defp do_walk_http(_conn, _key, _params, _acc, n) when n > 1_000 do
    flunk("HTTP change-feed keyset walk did not terminate")
  end

  defp do_walk_http(conn, raw_key, params, acc, n) do
    resp =
      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/changes", params)
      |> json_response(200)

    acc = acc ++ Enum.map(resp["data"], & &1["id"])

    case resp["next_cursor"] do
      nil -> acc
      next -> do_walk_http(conn, raw_key, %{"cursor" => next}, acc, n + 1)
    end
  end

  describe "tie-safe keyset walk (AC-27.9b.1)" do
    test "walks a tied-timestamp batch gap-free, ending with next_cursor null",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      ts = ~U[2026-06-24 09:00:00.000000Z]

      ids = insert_tied(tenant.id, 10, ts)

      past = DateTime.from_unix!(0) |> DateTime.to_iso8601()
      seen = walk_http(conn, raw_key, %{"since" => past, "limit" => "3"})

      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(seen) == 10
      assert length(seen) == length(Enum.uniq(seen)), "no duplicate across the tie boundary"
    end

    test "first page exposes next_cursor and (back-compat) next_since", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      ts = ~U[2026-06-24 10:00:00.000000Z]
      insert_tied(tenant.id, 6, ts)

      past = DateTime.from_unix!(0) |> DateTime.to_iso8601()

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes", %{"since" => past, "limit" => "3"})
        |> json_response(200)

      assert resp["has_more"] == true
      assert resp["next_cursor"]
      # next_since retained for back-compat (the tied timestamp).
      assert resp["next_since"]
    end
  end

  describe "forged / tampered cursor → 400 (AC-27.9b.4)" do
    test "tenant A using a cursor forged with tenant B's key is rejected", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})

      ts = ~U[2026-06-24 11:00:00.000000Z]
      [b_id | _] = insert_tied(tenant_b.id, 1, ts)
      insert_tied(tenant_a.id, 3, ts)

      forged = ChangesCursor.encode(tenant_b.id, {ts, b_id})

      resp =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/changes", %{"cursor" => forged})

      assert resp.status == 400

      garbage =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/changes", %{"cursor" => "garbage"})

      assert json_response(garbage, 400) == json_response(resp, 400)
    end

    test "garbage cursor returns 400, not 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      insert_tied(tenant.id, 1, ~U[2026-06-24 12:00:00.000000Z])

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes", %{"cursor" => "not-a-cursor!!!"})

      assert resp.status == 400
      assert json_response(resp, 400)["error"]["message"] =~ "cursor"
    end

    test "non-string cursor returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?cursor[]=x", %{})

      assert resp.status == 400
    end
  end

  describe "back-compat since token" do
    test "since-only request still works and emits next_cursor too", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      base = ~U[2026-06-24 13:00:00.000000Z]

      for i <- 0..4 do
        insert_tied(tenant.id, 1, DateTime.add(base, i, :second))
      end

      since = DateTime.add(base, -1, :second) |> DateTime.to_iso8601()

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes", %{"since" => since, "limit" => "2"})
        |> json_response(200)

      assert length(resp["data"]) == 2
      assert resp["has_more"] == true
      assert resp["next_cursor"]
      assert resp["next_since"]
    end

    test "missing both since and cursor returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes")

      assert resp.status == 400
    end
  end
end
