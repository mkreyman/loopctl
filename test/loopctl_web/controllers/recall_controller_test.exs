defmodule LoopctlWeb.RecallControllerTest do
  @moduledoc """
  #411 Gap 2 (PR B): the merged recall endpoint `POST /api/v1/recall`
  (`MemoryController.context/2`). Covers the 200 merged shape, the reused 422 envelopes
  (invalid_query / invalid_project_id), and the subject-unresolvable guard.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias Loopctl.Knowledge
  alias LoopctlWeb.MemoryController

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  defp published_article(tenant_id, title) do
    art =
      fixture(:article, %{
        tenant_id: tenant_id,
        status: :published,
        title: title,
        body: "reshipment policy for #{title}"
      })

    {:ok, updated} = Knowledge.update_embedding(tenant_id, art.id, List.duplicate(0.1, 1536))
    updated
  end

  describe "POST /api/v1/recall (merged memory ∪ knowledge)" do
    test "returns the merged shape with per-source envelopes and meta", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      # A long-term memory (embedded inline) + a knowledge article.
      conn
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "prefers reshipments"})
      |> json_response(201)

      article = published_article(tenant.id, "reshipment guide")

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)

      assert %{"data" => data, "memory" => memory, "knowledge" => knowledge, "meta" => meta} =
               body

      # Merged data is tagged per-source.
      sources = data |> Enum.map(& &1["source"]) |> Enum.uniq() |> Enum.sort()
      assert sources == ["knowledge", "memory"]

      # Sorted by score DESC (nulls ranked as 0.0 by the context; here all are numbers).
      scores = Enum.map(data, & &1["score"])
      assert scores == Enum.sort(scores, :desc)

      # Per-source envelopes present and shaped.
      assert %{"data" => mem_data, "meta" => mem_meta} = memory
      assert Enum.any?(mem_data, &(&1["memory"]["text"] == "prefers reshipments"))

      # BOTH halves disclose the vector read's iterative-scan state, under the SAME field
      # name and value vocabulary (#631 for knowledge, #634 for memory) — an agent reading
      # this one envelope must not have to learn two. Each half resolves the backend
      # capability independently, so they are asserted independently against the valid
      # set rather than against `applied`: iterative scan is pinned ON in `config/test.exs`
      # but the live probe fails closed to `unavailable` on a pool-checkout timeout, and an
      # async file cannot prime the VM-global verdict. The exact states live in the sync
      # `Loopctl.HeavyReadHnswEfSearchTest`.
      assert %{"data" => know_data, "meta" => know_meta} = knowledge
      assert mem_meta["ann_iterative_scan"] in ["applied", "unavailable"]
      assert know_meta["ann_iterative_scan"] in ["applied", "unavailable"]
      assert Enum.any?(know_data, &(&1["id"] == article.id))

      assert meta["query"] == "reshipments"
      assert meta["degraded"] == false
      assert meta["memory_count"] >= 1
      assert meta["knowledge_count"] >= 1
      assert meta["total_count"] == length(data)
      # The merged ordering is a documented cross-source heuristic, surfaced so callers
      # don't read it as calibrated relevance.
      assert meta["results_ranking"] == "heuristic_cross_source"

      # Knowledge items are the whitelisted combined-search SUMMARY — never the raw
      # result map's internal scoring fields, status, tenant_id, project_id, timestamps.
      know_item = Enum.find(know_data, &(&1["id"] == article.id))

      assert Map.keys(know_item)
             |> Enum.sort()
             |> Enum.all?(&(&1 in ~w(id title category tags score snippet)))

      refute Map.has_key?(know_item, "tenant_id")
      refute Map.has_key?(know_item, "status")
      refute Map.has_key?(know_item, "final_score")
      refute Map.has_key?(know_item, "inserted_at")

      merged_know = Enum.find(data, &(&1["source"] == "knowledge"))["article"]
      refute Map.has_key?(merged_know, "tenant_id")
      refute Map.has_key?(merged_know, "status")
    end

    test "a missing or blank/whitespace-only query is rejected with a 422 invalid_query" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      for q <- [nil, "", "   ", "\t\n"] do
        params = if is_nil(q), do: %{}, else: %{"query" => q}

        body =
          base_conn()
          |> auth(raw)
          |> post(~p"/api/v1/recall", params)
          |> json_response(422)

        assert body["error"]["code"] == "invalid_query"
        assert body["error"]["status"] == 422
      end
    end

    test "an over-length (>500 char) query is rejected up front with a 422 query_too_long" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      # 501 chars: rejected at the boundary BEFORE any embedding is generated, so the
      # knowledge half never half-degrades to an empty, spuriously-`degraded` 200.
      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => String.duplicate("a", 501)})
        |> json_response(422)

      assert body["error"]["code"] == "query_too_long"
      assert body["error"]["status"] == 422
    end

    test "a query of exactly 500 chars is accepted (boundary, returns 200)" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => String.duplicate("a", 500)})
        |> json_response(200)

      assert %{"meta" => _meta} = body
    end

    test "the knowledge envelope meta is the whitelisted search shape (no raw error atom)" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      _ = published_article(tenant.id, "reshipment guide")

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)

      know_meta = body["knowledge"]["meta"]

      # Projected through KnowledgeSearchJSON.render_meta: the canonical counters are
      # present and the merged-recall `degraded` flag is re-attached...
      assert Map.has_key?(know_meta, "total_count")
      assert Map.has_key?(know_meta, "limit")
      assert Map.has_key?(know_meta, "offset")
      assert know_meta["degraded"] == false
      # ...and the raw internal reason atom is NEVER passed through (unlike the old raw
      # passthrough), matching what /knowledge/search would serialize.
      refute Map.has_key?(know_meta, "error")

      # The merged meta names why on degradation; healthy => null.
      assert Map.has_key?(body["meta"], "degraded_reason")
      assert body["meta"]["degraded_reason"] == nil
    end

    test "a non-string query is rejected with a deterministic 422 invalid_query" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => %{"nested" => "object"}})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_query"
      assert body["error"]["status"] == 422
    end

    test "a malformed project_id is rejected with a deterministic 422 invalid_project_id" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments", "project_id" => "not-a-uuid"})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_project_id"
      assert body["error"]["status"] == 422
    end

    test "an identity-less key is refused with a deterministic 422 (subject_id_unresolvable)" do
      tenant = fixture(:tenant)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_api_key, %ApiKey{
          id: nil,
          tenant_id: tenant.id,
          role: :agent,
          agent_id: nil
        })

      result = MemoryController.context(conn, %{"query" => "reshipments"})
      assert json_response(result, 422)["error"]["code"] == "subject_id_unresolvable"
    end
  end
end
