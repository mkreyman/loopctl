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
      assert %{"data" => mem_data, "meta" => _} = memory
      assert Enum.any?(mem_data, &(&1["memory"]["text"] == "prefers reshipments"))

      assert %{"data" => know_data, "meta" => _} = knowledge
      assert Enum.any?(know_data, &(&1["id"] == article.id))

      assert meta["query"] == "reshipments"
      assert meta["degraded"] == false
      assert meta["memory_count"] >= 1
      assert meta["knowledge_count"] >= 1
      assert meta["total_count"] == length(data)
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
