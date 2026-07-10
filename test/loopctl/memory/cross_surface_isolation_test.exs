defmodule Loopctl.Memory.CrossSurfaceIsolationTest do
  @moduledoc """
  US-28.5 cross-surface isolation suite (TC-28.5.4 / AC-28.5.4).

  Proves a long-term memory written under `(tenant T, subject A)` is NEITHER
  retrievable NOR mutable as:

    * a DIFFERENT tenant U, nor
    * a DIFFERENT subject B of the SAME tenant T,

  through EVERY surface it can be reached on — the `Loopctl.Memory` context AND
  the HTTP API — on BOTH the healthy semantic-recall path AND the degraded
  ILIKE-fallback path, with NO response leaking the memory's existence. This
  closes the cross-tenant AND the cross-subject leak surfaces epic-wide.

  The MCP surface (US-28.4) is covered "where testable" in
  `mcp-server/test/memory_tools.test.js`: the four `memory_*` tool inputSchemas
  expose NO `tenant_id`/`subject_id`, and the handlers never forward a
  body-supplied scope — so a cross-scope read is not even EXPRESSIBLE at the MCP
  layer (scope is key-derived server-side, enforced here at the API/context).

  Async: all paths route through `Loopctl.AdminRepo` / `Loopctl.HeavyRead`
  (AdminRepo in test), sharing the one sandbox connection; the `:inline` Oban
  engine embeds the write during the POST.
  """
  use LoopctlWeb.ConnCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope

  @secret "T/A embedding-secret: the vault master rotation key rotates on Sundays"

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  # api_keys.agent_id is a FK to agents; the agent id becomes the subject_id.
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  defp recall_texts(body), do: Enum.map(body["data"], & &1["memory"]["text"])

  test "a (tenant T, subject A) memory is invisible + immutable cross-tenant AND cross-subject on the context and API",
       %{conn: conn} do
    tenant_t = fixture(:tenant)
    tenant_u = fixture(:tenant)

    {raw_a, _key_a, agent_a} = agent_key(tenant_t.id)
    {raw_tb, _key_tb, agent_b} = agent_key(tenant_t.id)
    {raw_u, _key_u, agent_u} = agent_key(tenant_u.id)
    Knowledge.reset_circuit_breaker(tenant_t.id)
    Knowledge.reset_circuit_breaker(tenant_u.id)

    # --- Write the secret as (tenant T, subject A), embedded inline. ---
    created =
      conn
      |> auth(raw_a)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => @secret})
      |> json_response(201)

    secret_id = created["data"]["id"]
    assert is_binary(secret_id)

    scope_a = %Scope{tenant_id: tenant_t.id, subject_id: to_string(agent_a.id), project_id: nil}
    scope_b = %Scope{tenant_id: tenant_t.id, subject_id: to_string(agent_b.id), project_id: nil}
    scope_u = %Scope{tenant_id: tenant_u.id, subject_id: to_string(agent_u.id), project_id: nil}

    # --- Sanity: the OWNER can genuinely recall it (so "invisible to others" is a
    #     real isolation result, not a NULL-embedding no-op). ---
    assert %{results: [{owned, _} | _]} =
             Memory.recall(scope_a, query: "vault rotation key", limit: 5)

    assert owned.id == secret_id

    # === Cross-subject B of tenant T =========================================
    # API: recall never surfaces it, list is empty, forget 404s (no existence leak).
    b_recall =
      base_conn()
      |> auth(raw_tb)
      |> post(~p"/api/v1/memory/recall", %{"query" => "vault rotation key"})
      |> json_response(200)

    refute @secret in recall_texts(b_recall)

    assert base_conn()
           |> auth(raw_tb)
           |> get(~p"/api/v1/memory")
           |> json_response(200)
           |> Map.fetch!("data") ==
             []

    base_conn()
    |> auth(raw_tb)
    |> delete(~p"/api/v1/memory/#{secret_id}")
    |> json_response(404)

    # Context: recall empty, list total_count 0, forget :not_found.
    assert %{results: []} = Memory.recall(scope_b, query: "vault rotation key", limit: 5)
    assert %{results: [], meta: %{total_count: 0}} = Memory.list(scope_b)
    assert {:error, :not_found} = Memory.forget(scope_b, secret_id)

    # === Cross-tenant U ======================================================
    u_recall =
      base_conn()
      |> auth(raw_u)
      |> post(~p"/api/v1/memory/recall", %{"query" => "vault rotation key"})
      |> json_response(200)

    refute @secret in recall_texts(u_recall)

    assert base_conn()
           |> auth(raw_u)
           |> get(~p"/api/v1/memory")
           |> json_response(200)
           |> Map.fetch!("data") ==
             []

    base_conn()
    |> auth(raw_u)
    |> delete(~p"/api/v1/memory/#{secret_id}")
    |> json_response(404)

    assert %{results: []} = Memory.recall(scope_u, query: "vault rotation key", limit: 5)
    assert {:error, :not_found} = Memory.forget(scope_u, secret_id)

    # === Degraded (ILIKE fallback) path: isolation still holds =================
    # Force embedding generation to fail so recall takes the recent-first ILIKE
    # fallback — which is ALSO scoped by (tenant_id, subject_id). Even querying the
    # EXACT secret text, neither the cross-subject nor the cross-tenant caller sees
    # it; owner still does.
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
      {:error, :no_api_key}
    end)

    b_fallback =
      base_conn()
      |> auth(raw_tb)
      |> post(~p"/api/v1/memory/recall", %{"query" => @secret})
      |> json_response(200)

    assert b_fallback["meta"]["fallback"] == true
    assert b_fallback["data"] == []

    u_fallback =
      base_conn()
      |> auth(raw_u)
      |> post(~p"/api/v1/memory/recall", %{"query" => @secret})
      |> json_response(200)

    assert u_fallback["data"] == []

    assert %{results: []} = Memory.recall(scope_b, query: @secret, limit: 5)
    assert %{results: []} = Memory.recall(scope_u, query: @secret, limit: 5)

    # Owner's fallback still finds it (proves the empties above are ISOLATION, not a
    # blanket-empty fallback).
    assert %{results: [{owned_fb, nil} | _], meta: %{fallback: true}} =
             Memory.recall(scope_a, query: @secret, limit: 5)

    assert owned_fb.id == secret_id

    # === Nothing was mutated: the memory survives every cross-scope forget attempt.
    assert %{results: [{still_owned, _} | _]} =
             Memory.recall(scope_a, query: @secret, limit: 5)

    assert still_owned.id == secret_id
    assert %{meta: %{total_count: 1}} = Memory.list(scope_a)
  end
end
