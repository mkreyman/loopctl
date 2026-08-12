defmodule LoopctlWeb.KnowledgeHybridSearchControllerTest do
  @moduledoc """
  US-31.4: HTTP surface for the hybrid retrieval entrypoint.

  - TC-31.4.1: curated article answers -> 200 with provenance=curated, confidence, meta.
  - TC-31.4.3: a key for tenant B never sees tenant A's curated content (isolation).

  Plus progressive-disclosure index/drill coverage (US-31.3 surfaced by US-31.4) and
  a `retrieved` provenance case. Mirrors the embedding stub setup in
  test/loopctl/knowledge_hybrid_test.exs.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleAccessEvent

  # Two orthogonal directions; identical directions cosine to 1.0 (clears the 0.75 curated
  # threshold), orthogonal to 0.0. Sourced per-test from `Loopctl.DataCase.test_vec/2`
  # (functions, not compile-time attributes) so each test's vectors occupy a DISJOINT window
  # of the shared HNSW index — dissolving the all-ties clique that flakes recall.
  defp direction_a, do: test_vec(1536, :primary)
  defp direction_b, do: test_vec(1536, :orthogonal)

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp curated_article(tenant_id, attrs) do
    article = fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))
    {:ok, marked} = Knowledge.mark_curated(tenant_id, article.id, actor_label: "user:admin")
    marked
  end

  defp set_embedding(tenant_id, article, vector) do
    {:ok, updated} = Knowledge.update_embedding(tenant_id, article.id, vector)
    updated
  end

  # Stub the embedding client to return a fixed vector for a specific query text,
  # falling back to the DataCase default for anything else.
  defp stub_embeddings_by_query(mapping) do
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
      case Map.fetch(mapping, text) do
        {:ok, vector} -> {:ok, vector}
        :error -> {:ok, List.duplicate(0.1, 1536)}
      end
    end)
  end

  describe "POST /api/v1/knowledge/hybrid_search" do
    test "TC-31.4.1: curated refund-policy article wins provenance=curated with confidence + meta",
         %{conn: conn} do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      curated =
        tenant.id
        |> curated_article(%{
          title: "Refund Policy",
          body: "Our refund policy allows returns within 30 days for a full refund."
        })
        |> then(&set_embedding(tenant.id, &1, direction_a()))

      # A fuzzy, non-curated chunk on a different axis (does not clear the bar).
      _fuzzy =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Shipping Timelines",
          body: "How long orders take to ship.",
          status: :published
        })
        |> then(&set_embedding(tenant.id, &1, direction_b()))

      query = "refund policy"
      stub_embeddings_by_query(%{query => direction_a()})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/hybrid_search", %{query: query})

      body = json_response(conn, 200)

      assert body["meta"]["provenance"] == "curated"
      assert body["meta"]["curated_article_id"] == curated.id
      assert is_number(body["meta"]["confidence"])
      assert body["meta"]["confidence"] > 0
      assert is_integer(body["meta"]["limit"])
      assert is_integer(body["meta"]["offset"])

      # Curated answer is present and FIRST, and carries no body (snippet only).
      assert is_list(body["data"])
      first = List.first(body["data"])
      assert first["id"] == curated.id
      refute Map.has_key?(first, "body")
      assert Enum.any?(body["data"], &(&1["id"] == curated.id))
    end

    test "returns provenance=retrieved when no curated source answers", %{conn: conn} do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      _plain =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Onboarding Notes",
          body: "Some general onboarding notes for the team.",
          status: :published
        })
        |> then(&set_embedding(tenant.id, &1, direction_a()))

      query = "onboarding notes"
      stub_embeddings_by_query(%{query => direction_a()})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/hybrid_search", %{query: query})

      body = json_response(conn, 200)
      assert body["meta"]["provenance"] == "retrieved"
      assert body["meta"]["curated_article_id"] == nil
    end

    test "empty query is a 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/hybrid_search", %{query: "   "})

      assert json_response(conn, 400)
    end

    test "keyless combined fallback surfaces meta.remediation, parity with knowledge_search", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Keyword Findable Refund Article",
        body: "Content about refund policy that keyword search can find.",
        category: :pattern,
        status: :published,
        tags: ["refund"]
      })

      # Tenant has no embedding key -> hybrid's combined pool degrades to
      # keyword-only with fallback_reason "no_embedding_key".
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/hybrid_search", %{query: "refund policy"})

      body = json_response(conn, 200)
      assert body["meta"]["fallback"] == true
      assert body["meta"]["fallback_reason"] == "no_embedding_key"

      # The MCP wrapper's withRemediationNotice reads exactly meta.remediation; it
      # MUST be present here so knowledge_hybrid_search shows the same
      # "ACTION REQUIRED — configure LLM key" banner knowledge_search does.
      remediation = body["meta"]["remediation"]
      assert remediation["action"] == "configure_llm"
      assert remediation["missing"] == ["embedding_api_key"]
      assert remediation["mcp_tool"] == "set_llm_config"
      assert remediation["api"] == "PATCH /api/v1/tenants/me/llm-config"
      refute inspect(body) =~ ~r/sk-[A-Za-z0-9]{8}/
    end

    test "TC-31.4.3: a tenant B key never sees tenant A's curated content", %{conn: conn} do
      tenant_a = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_a.id)

      secret =
        tenant_a.id
        |> curated_article(%{
          title: "Tenant A Refund Policy",
          body: "Tenant A's confidential refund policy details."
        })
        |> then(&set_embedding(tenant_a.id, &1, direction_a()))

      # A key for a DIFFERENT tenant, seeded with its OWN decoy content so the
      # search pool is NON-EMPTY. This proves tenant A's curated article does not
      # intermingle into a populated tenant-B result set (a stronger assertion than
      # an empty pool, which would pass even if RLS merge/order logic were wrong).
      tenant_b = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_b.id)
      {raw_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      decoy =
        tenant_b.id
        |> curated_article(%{
          title: "Tenant B Refund Policy",
          body: "Tenant B's own refund policy on the same axis as tenant A's."
        })
        |> then(&set_embedding(tenant_b.id, &1, direction_a()))

      query = "refund policy"
      stub_embeddings_by_query(%{query => direction_a()})

      conn =
        conn
        |> auth_conn(raw_key_b)
        |> post(~p"/api/v1/knowledge/hybrid_search", %{query: query})

      body = json_response(conn, 200)

      # Tenant A's secret never leaks into tenant B's populated pool...
      refute Enum.any?(body["data"], &(&1["id"] == secret.id))
      assert body["meta"]["curated_article_id"] != secret.id
      # ...and tenant B sees only its OWN curated decoy as the answer.
      assert Enum.any?(body["data"], &(&1["id"] == decoy.id))
      assert body["meta"]["provenance"] == "curated"
      assert body["meta"]["curated_article_id"] == decoy.id
    end
  end

  describe "GET /api/v1/knowledge/progressive_index and /progressive/:id" do
    test "index returns capped compact stubs; drill returns the full body", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      topic = "ProgressiveHttpTopicQZX"

      hub =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Overview",
          body: "An overview that links to many curated sources."
        })

      for n <- 1..5 do
        target =
          curated_article(tenant.id, %{
            title: "Curated Target #{n} #{topic}",
            body: "# Curated Target #{n}\nBody content for target #{n}."
          })

        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: hub.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })

        target
      end

      index_conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/progressive_index", %{topic: topic})

      index_body = json_response(index_conn, 200)

      assert length(index_body["data"]) <= Knowledge.progressive_top_k()
      assert index_body["meta"]["truncated"] == true

      first_stub = List.first(index_body["data"])
      assert first_stub["id"]
      assert first_stub["title"]
      assert is_binary(first_stub["summary"])
      refute Map.has_key?(first_stub, "body")

      # Drill into the first stub -> full article with a body.
      drill_conn =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/progressive/#{first_stub["id"]}")

      drill_body = json_response(drill_conn, 200)
      assert drill_body["data"]["id"] == first_stub["id"]
      assert is_binary(drill_body["data"]["body"])
    end

    test "a drill bounds an oversized body the same way knowledge_get does (#652)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      big = String.duplicate("z", 80_000)

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "Oversized Drill Target",
          body: big
        })

      data =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/progressive/#{article.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      budget = LoopctlWeb.ArticleJSON.article_body_byte_budget()
      assert byte_size(data["body"]) == budget
      assert data["body_bytes"] == 80_000
      assert data["body_truncated"] == true
      assert data["next_body_offset"] == budget

      whole =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/progressive/#{article.id}?body_max_bytes=0")
        |> json_response(200)
        |> Map.fetch!("data")

      assert whole["body"] == big
      assert whole["body_truncated"] == false
    end

    test "a non-binary topic param (array syntax) is a clean 400, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # `?topic[]=x` makes Plug parse topic as a list. Unguarded, that would raise
      # in String.trim/1 -> 500. It must be coerced to a clean empty-query 400.
      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/progressive_index", %{"topic" => ["x"]})

      assert json_response(conn, 400)
    end

    test "drill attributes the body read to the caller's api_key (analytics/audit)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      article =
        curated_article(tenant.id, %{
          title: "Attributed Drill Target",
          body: "# Target\nBody the drill reads and must attribute."
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/progressive/#{article.id}")

      assert json_response(conn, 200)

      # Analytics runs synchronously in test; the drill must record a "get" access
      # event carrying the caller's api_key_id (parity with GET /articles/:id).
      events = AdminRepo.all(ArticleAccessEvent)
      assert Enum.any?(events, &(&1.article_id == article.id and &1.api_key_id == api_key.id))
    end

    test "drill on an unknown id is a 404", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/progressive/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "a tenant B key drilling tenant A's tenant-owned article gets 404 (isolation)",
         %{conn: conn} do
      tenant_a = fixture(:tenant)

      secret =
        curated_article(tenant_a.id, %{
          title: "Tenant A Progressive Secret",
          body: "# Secret\nTenant A confidential body that tenant B must never open."
        })

      tenant_b = fixture(:tenant)
      {raw_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      # Tenant B drills tenant A's tenant-owned article id directly. get_article is
      # tenant-scoped; the AdminRepo system-canonical fallback only matches
      # scope == :system rows, which a tenant-owned article never is -> 404, no leak.
      conn =
        conn
        |> auth_conn(raw_key_b)
        |> get(~p"/api/v1/knowledge/progressive/#{secret.id}")

      assert json_response(conn, 404)
    end

    test "a tenant B index for tenant A's topic returns none of tenant A's stubs (isolation)",
         %{conn: conn} do
      tenant_a = fixture(:tenant)
      topic = "TenantAOnlyProgressiveTopicQZX"

      hub =
        fixture(:article, %{
          tenant_id: tenant_a.id,
          status: :published,
          title: "#{topic} Overview",
          body: "Tenant A overview linking to tenant A curated sources."
        })

      secret_ids =
        for n <- 1..3 do
          target =
            curated_article(tenant_a.id, %{
              title: "Tenant A Curated #{n} #{topic}",
              body: "# Tenant A Curated #{n}\nConfidential body #{n}."
            })

          fixture(:article_link, %{
            tenant_id: tenant_a.id,
            source_article_id: hub.id,
            target_article_id: target.id,
            relationship_type: :relates_to
          })

          target.id
        end

      tenant_b = fixture(:tenant)
      {raw_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      index_conn =
        conn
        |> auth_conn(raw_key_b)
        |> get(~p"/api/v1/knowledge/progressive_index", %{topic: topic})

      index_body = json_response(index_conn, 200)

      returned_ids = Enum.map(index_body["data"], & &1["id"])

      for secret_id <- secret_ids do
        refute secret_id in returned_ids,
               "tenant B index must not surface tenant A's stub #{secret_id}"
      end
    end
  end
end
