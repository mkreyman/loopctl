defmodule Loopctl.Memory.E2ETest do
  @moduledoc """
  US-28.5 end-to-end integration (TC-28.5.1 / AC-28.5.3).

  Writes a long-term memory through the HTTP API, then recalls it through BOTH
  `Loopctl.Memory` (the context) AND the HTTP API, asserting the SAME memory id
  is reachable via each surface with the pinned `%{results, meta}` /
  `%{"data", "meta"}` envelope — one coherent write→embed→recall path across the
  context and API surfaces.

  Async: every path routes through `Loopctl.AdminRepo` / `Loopctl.HeavyRead`
  (which points at `AdminRepo` in test), so all queries share the one sandbox
  connection the fixtures insert through, and the `:inline` Oban engine embeds the
  long-term write synchronously inside the POST request (the embeddings queue runs
  inline in test — no async drain needed; the row carries its embedding the moment
  the request returns).
  """
  use LoopctlWeb.ConnCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope

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

  test "a memory written via the API is recalled identically via BOTH the context and the API",
       %{conn: conn} do
    tenant = fixture(:tenant)
    {raw, _key, agent} = agent_key(tenant.id)
    Knowledge.reset_circuit_breaker(tenant.id)

    fact = "the deploy runbook lives in docs/runbooks/deploy.md"

    # 1) Write via the HTTP API (embedded inline by the :inline Oban engine).
    created =
      conn
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => fact})
      |> json_response(201)

    memory_id = created["data"]["id"]
    assert is_binary(memory_id)

    query = "where is the deployment guide"

    # 2) Recall via the CONTEXT (the same scope the key derives server-side:
    #    subject_id = agent.id).
    scope = %Scope{tenant_id: tenant.id, subject_id: to_string(agent.id), project_id: nil}

    context_result = Memory.recall(scope, query: query, limit: 5)

    assert %{results: [{ctx_memory, ctx_score} | _], meta: ctx_meta} = context_result
    assert %{total_count: ctx_total, fallback: false, reason: nil, underfilled: _} = ctx_meta
    assert ctx_total == length(context_result.results)
    assert ctx_memory.id == memory_id
    assert is_float(ctx_score)

    # 3) Recall via the HTTP API with the same query.
    api_body =
      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/memory/recall", %{"query" => query})
      |> json_response(200)

    assert %{"data" => [%{"memory" => api_memory, "score" => api_score} | _], "meta" => api_meta} =
             api_body

    assert api_memory["id"] == memory_id
    assert api_meta["fallback"] == false
    assert is_number(api_score)

    # 4) The two surfaces AGREE: the same memory id is the top hit through each,
    #    under the pinned envelope shape.
    assert ctx_memory.id == api_memory["id"]
    assert api_memory["text"] == fact
  end
end
