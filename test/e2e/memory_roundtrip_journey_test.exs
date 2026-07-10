defmodule Loopctl.E2E.MemoryRoundtripJourneyTest do
  @moduledoc """
  End-to-end journey for the epic-28 agent-memory remember → recall/list path.

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e`
  or `mix test --only e2e`. The smoke script only checks memory recall read-only
  (an empty result passes), so this journey proves the FULL round-trip over the
  real HTTP `/api/v1/memory` endpoints and the real DB: remember a fact carrying
  a unique marker, then get it back via BOTH `list` (deterministic, chronological)
  and `recall` (semantic), and prove tenant isolation.

  Ranking is NOT asserted: under test all embeddings are a constant (the mock
  embedding client), so every memory sits at cosine distance 0 — recall proves
  the endpoint retrieves the persisted row, not that it ranks. `list` is the
  order-independent backbone; `recall` mirrors the proven controller round-trip.
  """
  use LoopctlWeb.ConnCase, async: true

  @moduletag :e2e

  alias Loopctl.Knowledge

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # A fresh conn carrying the witness STH header. ConnCase adds it to the shared
  # `conn`, but each independently-built request needs its own.
  defp fresh_conn do
    build_conn()
    |> put_req_header("x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")
  end

  # api_keys.agent_id is an FK to agents, and the agent id becomes the memory
  # subject_id (Memory.subject_id_for/1), so mint a real agent per key.
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    raw
  end

  describe "agent memory round-trip journey" do
    test "remember then recall/list returns the fact; another tenant cannot see it",
         %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      raw_a = agent_key(tenant_a.id)
      raw_b = agent_key(tenant_b.id)

      # Reset the embedding circuit breaker so the semantic recall leg uses the
      # (mock) embedding path rather than degrading to the text fallback.
      Knowledge.reset_circuit_breaker(tenant_a.id)

      marker = "zqmemory#{System.unique_integer([:positive])}"
      fact = "The agent #{marker} prefers Req over Tesla for HTTP."

      # Remember (write a long_term memory) via the real HTTP endpoint.
      created =
        conn
        |> auth_conn(raw_a)
        |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => fact})
        |> json_response(201)

      assert created["data"]["tier"] == "long_term"
      assert created["data"]["text"] == fact
      memory_id = created["data"]["id"]

      # List (chronological, order-independent) — the deterministic proof of
      # persistence + retrieval within the caller's own scope.
      list_body =
        fresh_conn()
        |> auth_conn(raw_a)
        |> get(~p"/api/v1/memory")
        |> json_response(200)

      list_ids = Enum.map(list_body["data"], & &1["id"])
      assert memory_id in list_ids
      assert Enum.any?(list_body["data"], &(&1["text"] == fact))

      # Recall (semantic) — mirrors the proven controller round-trip; returns the
      # persisted fact with meta.fallback == false under the mock embedder.
      recall_body =
        fresh_conn()
        |> auth_conn(raw_a)
        |> post(~p"/api/v1/memory/recall", %{"query" => marker})
        |> json_response(200)

      assert recall_body["meta"]["fallback"] == false
      assert Enum.any?(recall_body["data"], &(&1["memory"]["text"] == fact))

      # Tenant isolation — a DIFFERENT tenant's agent key sees none of it.
      Knowledge.reset_circuit_breaker(tenant_b.id)

      b_list =
        fresh_conn()
        |> auth_conn(raw_b)
        |> get(~p"/api/v1/memory")
        |> json_response(200)

      refute memory_id in Enum.map(b_list["data"], & &1["id"])

      b_recall =
        fresh_conn()
        |> auth_conn(raw_b)
        |> post(~p"/api/v1/memory/recall", %{"query" => marker})
        |> json_response(200)

      refute Enum.any?(b_recall["data"], &(&1["memory"]["text"] == fact))
    end
  end
end
