defmodule Loopctl.Memory.PromotionE2ETest do
  @moduledoc """
  US-29.6 end-to-end promotion integration (TC-29.6.1 / AC-29.6.3).

  The TERMINAL proof of the epic-29 auto-promotion loop across the HTTP + context
  surfaces: seed a multi-turn `:session` memory, trigger promotion through the real
  `POST /api/v1/memory/promote` endpoint, then recall the resulting durable memory
  through BOTH `Loopctl.Memory` (the context) AND `POST /api/v1/memory/recall`,
  asserting the SAME promoted memory is reachable via each surface carrying
  `source: :promoted`, `source_session_id`, and a real `confidence`.

  Async: every Memory read/write routes through `Loopctl.AdminRepo` (BYPASSRLS,
  explicitly scoped by `(tenant_id, subject_id)`) / `Loopctl.HeavyRead` (AdminRepo
  in test), so the fixtures' seeded turns and the request-inline promotion share the
  one sandbox connection. Oban runs `:inline` in test (`config/test.exs`), so
  `POST /promote` executes the `MemoryPromotionWorker` SYNCHRONOUSLY inside the
  request — which compiles the session (Promoter LLM stubbed via Mox), then writes
  each `:promoted` row with its embedding synchronously (embedding stubbed via the
  DataCase default) — no async drain needed; the promoted row is reachable the
  moment the 202 returns.
  """
  use LoopctlWeb.ConnCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # A fresh conn carrying the witness STH header the `:authenticated` write chain
  # (ValidateWitnessHeader) requires — each dispatched request needs its own conn.
  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  # api_keys.agent_id is a FK to agents; the agent id becomes the memory subject_id
  # (Loopctl.Memory.subject_id_for/1), so session turns must be seeded under it.
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  # Stub the promoter LLM to compile the session into ONE durable candidate above the
  # confidence gate. `extract/3` is the Promoter.LLMBehaviour callback the inline worker
  # invokes; the DataCase default returns "[]" (nothing durable), so tests that want a
  # survivor override it here.
  defp stub_durable_candidate(text, confidence) do
    json =
      JSON.encode!([
        %{
          "text" => text,
          "when_to_apply" => "when relevant",
          "tags" => ["e2e"],
          "confidence" => confidence,
          "cross_links" => []
        }
      ])

    Mox.stub(Loopctl.MockPromoterLLM, :extract, fn _tenant_id, _content, _opts -> {:ok, json} end)
  end

  test "a session promoted via POST /promote is recall-able via BOTH the context and the API",
       %{conn: conn} do
    tenant = fixture(:tenant)
    {raw, _key, agent} = agent_key(tenant.id)
    subject_id = to_string(agent.id)
    Knowledge.reset_circuit_breaker(tenant.id)

    durable_fact = "the customer prefers expedited reship over a refund"
    stub_durable_candidate(durable_fact, 0.91)

    # Seed a multi-turn session (> 1 turn, so the worker does not short-circuit) under
    # the SAME (tenant, subject) the agent key derives server-side.
    for content <- ["opened a ticket about a delayed order", "agreed to an expedited reship"] do
      fixture(:session_memory,
        tenant_id: tenant.id,
        subject_id: subject_id,
        session_id: "s1",
        role: :user,
        content: content
      )
    end

    # 1) Trigger promotion through the real endpoint. Oban `:inline` runs the promotion
    #    worker synchronously inside this request, so the `:promoted` row (embedded
    #    synchronously) exists by the time the 202 returns.
    accepted =
      conn
      |> auth(raw)
      |> post(~p"/api/v1/memory/promote", %{"session_id" => "s1"})
      |> json_response(202)

    assert accepted["data"]["session_id"] == "s1"
    assert accepted["data"]["status"] == "enqueued"

    query = "how should we handle this customer's delayed order"

    # 2) Recall via the CONTEXT (the same scope the key derives: subject_id = agent.id).
    scope = %Scope{tenant_id: tenant.id, subject_id: subject_id, project_id: nil}
    ctx = Memory.recall(scope, query: query, limit: 5)

    assert %{results: [{ctx_memory, ctx_score} | _], meta: %{fallback: false}} = ctx
    assert ctx_memory.text == durable_fact
    assert ctx_memory.source == :promoted
    assert ctx_memory.source_session_id == "s1"
    assert ctx_memory.confidence == 0.91
    assert is_float(ctx_score)

    promoted_id = ctx_memory.id

    # 3) Recall via the HTTP API with the same query.
    api =
      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/memory/recall", %{"query" => query})
      |> json_response(200)

    assert %{"data" => [%{"memory" => api_memory} | _], "meta" => %{"fallback" => false}} = api
    assert api_memory["id"] == promoted_id
    assert api_memory["text"] == durable_fact
    # Ecto.Enum `:promoted` renders as the string "promoted" over JSON.
    assert api_memory["source"] == "promoted"
    assert api_memory["source_session_id"] == "s1"
    assert api_memory["confidence"] == 0.91

    # 4) The two surfaces AGREE: the same promoted memory id is reachable through each.
    assert ctx_memory.id == api_memory["id"]

    # 5) It is genuinely provenance-tagged as a promotion in the index surface too.
    index =
      base_conn()
      |> auth(raw)
      |> get(~p"/api/v1/memory?source=promoted")
      |> json_response(200)

    assert [row] = index["data"]
    assert row["id"] == promoted_id
    assert row["source"] == "promoted"
  end
end
