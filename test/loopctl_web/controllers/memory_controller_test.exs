defmodule LoopctlWeb.MemoryControllerTest do
  @moduledoc """
  US-28.3 — HTTP JSON API for agent memory (`/api/v1/memory*`).

  Covers the scope-from-key invariant (body tenant_id/subject_id ignored),
  cross-subject and cross-tenant isolation, superadmin oversight, the custody-halt
  write block, and subject-unresolvable rejection.

  Async: every path routes through `Loopctl.AdminRepo` / `Loopctl.HeavyRead` (which
  points at `AdminRepo` in test), so all queries share the one sandbox connection
  the fixtures insert through, and inline Oban embeds long-term writes during the
  request.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias Loopctl.Knowledge
  alias LoopctlWeb.MemoryController

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # A fresh conn carrying the witness STH header (ConnCase adds it to the shared
  # `conn`, but each dispatched request needs its own conn).
  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  # api_keys.agent_id is a FK to agents, so mint a real agent per agent key. The
  # agent's id becomes the memory subject_id (subject_id_for/1).
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  # --- TC-28.3.1: remember + recall round-trip over HTTP ---

  describe "POST /api/v1/memory + POST /api/v1/memory/recall (TC-28.3.1)" do
    test "round-trips a long-term memory within the key's scope", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      create_conn =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "prefers reshipments"})

      created = json_response(create_conn, 201)
      assert created["data"]["tier"] == "long_term"
      assert created["data"]["text"] == "prefers reshipments"

      recall_conn =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/memory/recall", %{"query" => "handling delayed orders"})

      body = json_response(recall_conn, 200)
      assert %{"data" => [entry | _], "meta" => meta} = body
      assert entry["memory"]["text"] == "prefers reshipments"
      assert is_map(meta)
      assert Map.has_key?(meta, "total_count")
      assert meta["fallback"] == false
    end
  end

  # --- TC-28.3.2: body-supplied subject ignored; cross-subject read impossible ---

  describe "cross-subject isolation (TC-28.3.2)" do
    test "a body subject_id is ignored and B never sees A's memory", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_a, _key_a, agent_a} = agent_key(tenant.id)
      {raw_b, _key_b, _agent_b} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      conn
      |> auth(raw_a)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "alpha secret note"})
      |> json_response(201)

      # B recalls, spoofing A's subject in the body — must be ignored.
      recall_body =
        base_conn()
        |> auth(raw_b)
        |> post(~p"/api/v1/memory/recall", %{
          "query" => "alpha secret",
          "subject_id" => to_string(agent_a.id)
        })
        |> json_response(200)

      refute Enum.any?(recall_body["data"], &(&1["memory"]["text"] == "alpha secret note"))

      # B lists — A's memory never appears, no 500, no existence leak.
      list_body =
        base_conn()
        |> auth(raw_b)
        |> get(~p"/api/v1/memory")
        |> json_response(200)

      assert list_body["data"] == []
    end
  end

  # --- TC-28.3.3: cross-tenant read impossible + body tenant_id ignored ---

  describe "cross-tenant isolation (TC-28.3.3)" do
    test "body tenant_id is ignored; writes land under the key's tenant", %{conn: conn} do
      tenant_t = fixture(:tenant)
      tenant_u = fixture(:tenant)
      {raw_t, _key_t, _agent_t} = agent_key(tenant_t.id)
      Knowledge.reset_circuit_breaker(tenant_t.id)

      # A memory under tenant_u, distinct subject.
      fixture(:memory, %{tenant_id: tenant_u.id, subject_id: "u-subject", text: "unicorn fact"})

      # Write as the tenant_t key, spoofing tenant_u in the body — must land under tenant_t.
      created =
        conn
        |> auth(raw_t)
        |> post(~p"/api/v1/memory", %{
          "tier" => "long_term",
          "text" => "tango fact",
          "tenant_id" => tenant_u.id
        })
        |> json_response(201)

      assert created["data"]["tenant_id"] == tenant_t.id

      # List as tenant_t — sees only its own tenant/subject rows; tenant_u never leaks.
      list_body =
        base_conn()
        |> auth(raw_t)
        |> get(~p"/api/v1/memory")
        |> json_response(200)

      texts = Enum.map(list_body["data"], & &1["text"])
      assert "tango fact" in texts
      refute "unicorn fact" in texts
      assert Enum.all?(list_body["data"], &(&1["tenant_id"] == tenant_t.id))
    end
  end

  # --- TC-28.3.4: superadmin lists across subjects, agent cannot ---

  describe "superadmin oversight (TC-28.3.4)" do
    test "superadmin sees all subjects; agent is confined to its own", %{conn: conn} do
      tenant = fixture(:tenant)
      # Superadmin keys are tenant-less; the tenant scope is supplied via
      # X-Impersonate-Tenant (Impersonate keeps role :superadmin, sets tenant_id).
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})
      {raw_agent, _agent_key, agent} = agent_key(tenant.id)

      fixture(:memory, %{tenant_id: tenant.id, subject_id: "other-subject", text: "other note"})
      fixture(:memory, %{tenant_id: tenant.id, subject_id: to_string(agent.id), text: "own note"})

      # Superadmin with all_subjects=true sees BOTH subjects.
      super_body =
        conn
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> get(~p"/api/v1/memory?all_subjects=true")
        |> json_response(200)

      subjects = super_body["data"] |> Enum.map(& &1["subject_id"]) |> Enum.uniq()
      assert "other-subject" in subjects
      assert to_string(agent.id) in subjects

      # Agent requesting all_subjects=true is IGNORED — sees only its own subject.
      agent_body =
        base_conn()
        |> auth(raw_agent)
        |> get(~p"/api/v1/memory?all_subjects=true")
        |> json_response(200)

      assert Enum.all?(agent_body["data"], &(&1["subject_id"] == to_string(agent.id)))
      refute Enum.any?(agent_body["data"], &(&1["text"] == "other note"))
    end

    test "superadmin may delete any subject's memory; agent may not", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_super, _super_key} = fixture(:api_key, %{role: :superadmin})
      {raw_agent, _agent_key, _agent} = agent_key(tenant.id)

      foreign = fixture(:memory, %{tenant_id: tenant.id, subject_id: "foreign-subject"})

      # Agent cannot delete a foreign subject's memory — 404, no existence leak.
      conn
      |> auth(raw_agent)
      |> delete(~p"/api/v1/memory/#{foreign.id}")
      |> json_response(404)

      # Superadmin (impersonating the tenant) can delete any memory in it.
      del_body =
        base_conn()
        |> put_req_header("x-impersonate-tenant", tenant.id)
        |> auth(raw_super)
        |> delete(~p"/api/v1/memory/#{foreign.id}")
        |> json_response(200)

      assert del_body["data"]["deleted"] == true
    end
  end

  # --- TC-28.3.5: custody-halted key cannot write ---

  describe "custody halt (TC-28.3.5)" do
    test "a custody-halted tenant's key cannot write memory (503)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      {:ok, _} = Loopctl.Tenants.halt_custody(tenant.id)

      body =
        conn
        |> auth(raw)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "should not persist"})
        |> json_response(503)

      assert body["error"]["code"] == "tenant_halted"
    end
  end

  # --- Own-subject delete + not-found (no existence leak) ---

  describe "DELETE /api/v1/memory/:id" do
    test "deletes the caller's own memory and 404s an unknown id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)
      mine = fixture(:memory, %{tenant_id: tenant.id, subject_id: to_string(agent.id)})

      conn
      |> auth(raw)
      |> delete(~p"/api/v1/memory/#{mine.id}")
      |> json_response(200)

      base_conn()
      |> auth(raw)
      |> delete(~p"/api/v1/memory/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end
  end

  # --- Subject-unresolvable rejection (AC-28.3.2) ---

  describe "subject_id_unresolvable" do
    test "an identity-less key is refused with a deterministic 422" do
      tenant = fixture(:tenant)

      # subject_id_for/1 cannot resolve a key with no id AND no agent_id — the
      # controller must refuse rather than operate on a null scope. (Unreachable
      # through the real pipeline; exercised by calling the action directly.)
      conn =
        build_conn()
        |> Plug.Conn.assign(:current_api_key, %ApiKey{
          id: nil,
          tenant_id: tenant.id,
          role: :agent,
          agent_id: nil
        })

      result = MemoryController.index(conn, %{})
      assert json_response(result, 422)["error"]["code"] == "subject_id_unresolvable"
    end
  end
end
