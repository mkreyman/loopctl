defmodule LoopctlWeb.KnowledgeEmbeddingControllerTest do
  @moduledoc """
  US-41.1 review #4 — the per-tenant embedding DIMENSION surface.

  Every US-41.1 entry point used to have ZERO production callers:
  `recall_availability/1`, `enqueue_reembed/2` and
  `enqueue_system_corpus_materialization/2` were reachable only from IEx, and
  `tenants.tenant_embedding_dimension` appeared in no view or serializer — so
  AC-41.1.4's per-tenant read, AC-41.1.7's on-demand materialization and
  AC-41.1.10's agent-triggerable re-embed were all dead code. These tests are the
  standing proof that they are wired.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Embeddings

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  describe "GET /api/v1/knowledge/embeddings (AC-41.1.4 / AC-41.1.8)" do
    test "an AGENT can read the tenant's dimension and the supported set", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/embeddings")
        |> json_response(200)

      assert body["dimension"] == 1536
      assert body["default_dimension"] == 1536
      assert 1536 in body["supported_dimensions"]
      assert body["semantic_available"] == true
      assert is_nil(body["reason"])
    end

    test "a non-default dimension SAYS why semantic recall is unavailable", %{conn: conn} do
      tenant = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 768)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/embeddings")
        |> json_response(200)

      assert body["dimension"] == 768
      assert body["semantic_available"] == false
      assert body["reason"] =~ "keyword-only"
    end

    test "requires authentication", %{conn: conn} do
      assert conn |> get(~p"/api/v1/knowledge/embeddings") |> json_response(401)
    end
  end

  describe "POST /api/v1/knowledge/embeddings/system-corpus (AC-41.1.7)" do
    test "an AGENT can trigger the per-tenant materialization", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/embeddings/system-corpus")
        |> json_response(202)

      assert body["enqueued"] == true
      assert body["dimension"] == 1536
    end
  end

  describe "POST /api/v1/knowledge/embeddings/reembed (AC-41.1.10)" do
    test "an ORCHESTRATOR can trigger a re-embed onto a supported dimension", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/embeddings/reembed", %{target_dimension: 768})
        |> json_response(202)

      assert body["enqueued"] == true
      assert body["target_dimension"] == 768
      assert body["progress"]["target_dimension"] == 768
    end

    test "an unsupported dimension is rejected NAMING both sides", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/embeddings/reembed", %{target_dimension: 3072})
        |> json_response(422)

      assert body["error"] == "unsupported_dimension"
      assert body["requested"] == 3072
      assert 1536 in body["supported_dimensions"]
    end

    test "a non-integer target is rejected", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/embeddings/reembed", %{target_dimension: "not-a-number"})
        |> json_response(422)

      assert body["error"] == "invalid_target_dimension"
    end

    # The re-embed re-bills the tenant for its whole corpus and its completion DELETES
    # the stale-dimension rows, so it is deliberately NOT an agent-role lever.
    test "a bare AGENT key cannot trigger it", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/embeddings/reembed", %{target_dimension: 768})

      assert conn.status == 403
    end
  end
end
