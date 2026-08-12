defmodule LoopctlWeb.KnowledgeSearchControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/knowledge/search" do
    test "keyword search returns snippets without body", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic multi-step database operations.",
        category: :pattern,
        status: :published,
        tags: ["ecto", "transactions"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "Ecto", mode: "keyword"})

      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["data"] != []

      result = List.first(body["data"])
      assert result["id"]
      assert result["title"] == "Ecto Multi Pattern"
      assert result["category"] == "pattern"
      assert result["tags"] == ["ecto", "transactions"]
      assert is_number(result["score"])
      assert result["score"] > 0

      # Snippet is present, body is not
      assert is_binary(result["snippet"]) or is_nil(result["snippet"])
      refute Map.has_key?(result, "body")

      # Meta is present, and total_count is self-described as keyword matches.
      assert body["meta"]["total_count"] >= 1
      assert body["meta"]["limit"] == 10
      assert body["meta"]["offset"] == 0
      assert body["meta"]["total_count_scope"] == "keyword_matches"
      assert body["meta"]["search_mode"] == "keyword"
    end

    test "combined mode is default when mode param is omitted", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Test Pattern",
        body: "A test body for combined search default mode.",
        category: :pattern,
        status: :published,
        tags: ["test"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "test"})

      body = json_response(conn, 200)

      # Should succeed (combined is default)
      assert is_list(body["data"])
      assert is_map(body["meta"])
      # Combined total_count is the merged candidate pool, labeled as such.
      assert body["meta"]["total_count_scope"] == "merged_candidates"
      assert body["meta"]["search_mode"] == "combined"
    end

    test "missing q returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search")

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "q"
    end

    test "empty q returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: ""})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "q"
    end

    test "q exceeding 500 characters returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      long_query = String.duplicate("a", 501)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: long_query})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "500"
    end

    test "semantic mode returns 503 on embedding failure", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :service_unavailable}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "test query", mode: "semantic"})

      body = json_response(conn, 503)
      assert body["error"]["status"] == 503
      assert body["error"]["message"] =~ "Embedding service unavailable"
    end

    test "semantic mode degrades to keyword-only for a KEYLESS tenant (no 503) (review #8)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      Loopctl.Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Keyword Findable Article",
        body: "Content about pagination that keyword search can find.",
        category: :pattern,
        status: :published,
        tags: ["pagination"]
      })

      # Mandatory BYO: the embedding client reports the tenant has no key.
      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "pagination", mode: "semantic"})

      body = json_response(conn, 200)
      assert body["meta"]["fallback"] == true
      assert body["meta"]["search_mode"] == "keyword_only"
    end

    test "semantic mode labels total_count as ranked_corpus", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, [1.0 | List.duplicate(0.0, 1535)]}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "anything", mode: "semantic"})

      body = json_response(conn, 200)
      assert body["meta"]["search_mode"] == "semantic_only"
      assert body["meta"]["total_count_scope"] == "ranked_corpus"

      # The vector read's iterative-scan state REACHES the caller (the meta renderer is a
      # whitelist, so a field the context computes is invisible over HTTP until it is
      # listed). This pins the PASS-THROUGH, not the backend: `config/test.exs` pins
      # iterative scan ON, so the value is `applied` on a healthy probe and `unavailable`
      # when a live probe times out on a pool checkout and fails closed — an async file
      # cannot prime the VM-global verdict without bleeding into concurrent ANN readers.
      # The exact states are pinned in the sync `Loopctl.HeavyReadHnswEfSearchTest`.
      assert body["meta"]["ann_iterative_scan"] in ["applied", "unavailable"]
    end

    test "COMBINED mode carries the semantic half's iterative-scan disclosure", %{conn: conn} do
      # Combined is the DEFAULT mode, and its meta is an explicit literal map — a field the
      # semantic sub-search computes is dropped unless it is carried forward (the same
      # reason `pool_capped` is). Undisclosed here means undisclosed on the path almost
      # every caller uses.
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, [1.0 | List.duplicate(0.0, 1535)]}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "anything", mode: "combined"})

      body = json_response(conn, 200)
      assert body["meta"]["search_mode"] == "combined"
      # Same pass-through pin (and the same live-probe caveat) as the semantic test above.
      assert body["meta"]["ann_iterative_scan"] in ["applied", "unavailable"]
    end

    test "combined mode degrades to keyword-only when embedding fails, with real scores", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      Loopctl.Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic multi-step database operations.",
        category: :pattern,
        status: :published,
        tags: ["ecto"]
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :service_unavailable}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "Ecto"})

      body = json_response(conn, 200)

      assert body["meta"]["fallback"] == true
      assert body["meta"]["search_mode"] == "keyword_only"
      assert body["meta"]["total_count_scope"] == "keyword_matches"

      # Fallback results carry the keyword relevance score, not a misleading 0.0.
      result = List.first(body["data"])
      assert result["title"] == "Ecto Multi Pattern"
      assert result["score"] > 0
    end

    test "combined fallback surfaces meta.fallback_reason without leaking the provider body (#297)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      Loopctl.Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic multi-step database operations.",
        category: :pattern,
        status: :published,
        tags: ["ecto"]
      })

      fake_key = "sk-SECRET-DEADBEEF-must-not-leak"

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, "Incorrect API key provided: #{fake_key}"}}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "Ecto"})

      body = json_response(conn, 200)

      assert body["meta"]["fallback"] == true
      assert body["meta"]["search_mode"] == "keyword_only"
      assert body["meta"]["fallback_reason"] == "embedding_provider_error_401"
      refute inspect(body) =~ fake_key
      refute inspect(body) =~ "Incorrect API key"
    end

    test "semantic keyless fallback surfaces meta.fallback_reason \"no_embedding_key\" (#297)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      Loopctl.Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Keyword Findable Article",
        body: "Content about pagination that keyword search can find.",
        category: :pattern,
        status: :published,
        tags: ["pagination"]
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "pagination", mode: "semantic"})

      body = json_response(conn, 200)
      assert body["meta"]["fallback"] == true
      assert body["meta"]["search_mode"] == "keyword_only"
      assert body["meta"]["fallback_reason"] == "no_embedding_key"

      # Self-service remediation: the degraded response tells the agent how to enable
      # semantic ranking without a human — name the set_llm_config MCP tool + the
      # missing embedding credential, and NEVER a secret.
      remediation = body["meta"]["remediation"]
      assert remediation["action"] == "configure_llm"
      assert remediation["missing"] == ["embedding_api_key"]
      assert remediation["mcp_tool"] == "set_llm_config"
      assert remediation["api"] == "PATCH /api/v1/tenants/me/llm-config"
      assert remediation["example"] =~ "embedding_api_key"
      refute inspect(body) =~ ~r/sk-[A-Za-z0-9]{8}/
    end

    test "combined provider-error fallback carries NO remediation (a key IS configured)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      Loopctl.Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Keyword Findable Article",
        body: "Content about pagination that keyword search can find.",
        category: :pattern,
        status: :published,
        tags: ["pagination"]
      })

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, {:api_error, 401, "Incorrect API key provided: sk-SECRETDEADBEEF"}}
      end)

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "pagination"})
        |> json_response(200)

      assert body["meta"]["fallback_reason"] == "embedding_provider_error_401"
      # The key is configured but the provider rejected it — "configure a key" would
      # be the wrong advice, so no remediation is attached.
      refute Map.has_key?(body["meta"], "remediation")
    end

    test "filters by project_id, category, and tags", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Filtered Pattern Ecto",
        body: "Ecto pattern for filtering test.",
        category: :pattern,
        status: :published,
        tags: ["ecto", "filtering"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Unrelated Convention Ecto",
        body: "Ecto convention that should not match filters.",
        category: :convention,
        status: :published,
        tags: ["naming"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          q: "Ecto",
          mode: "keyword",
          project_id: project.id,
          category: "pattern",
          tags: "ecto"
        })

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert List.first(body["data"])["title"] == "Filtered Pattern Ecto"
    end

    test "invalid mode returns 400 listing valid modes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "test", mode: "invalid"})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "keyword"
      assert body["error"]["message"] =~ "semantic"
      assert body["error"]["message"] =~ "combined"
    end

    test "unknown category returns 400 instead of silently enumerating everything", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{tags: "hub", category: "bogus"})

      assert json_response(conn, 400)["error"]["message"] =~ "category"
    end

    test "a valid-but-non-category atom (e.g. published) returns 400, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "anything", category: "published"})

      assert json_response(conn, 400)["error"]["status"] == 400
    end

    test "pagination with limit and offset", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Create 5 articles with "pagination" in the body
      for i <- 1..5 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Pagination Article #{i}",
          body: "Content about pagination and testing for article number #{i}.",
          category: :pattern,
          status: :published,
          tags: ["pagination"]
        })
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          q: "pagination",
          mode: "keyword",
          limit: "2",
          offset: "1"
        })

      body = json_response(conn, 200)

      assert body["meta"]["limit"] == 2
      assert body["meta"]["offset"] == 1
      assert length(body["data"]) <= 2
    end

    test "clamps a relevance-mode limit above the relevance cap (never rejects) (#148 A1)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Relevance modes (here keyword) return a ranked top-N. An over-large limit
      # is clamped to the ranked-pool cap and surfaced in meta.limit — never
      # rejected. Full enumeration is reached by dropping `q` (list mode).
      over = Loopctl.Knowledge.max_relevance_page_size() + 1

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "anything", mode: "keyword", limit: "#{over}"})
        |> json_response(200)

      assert resp["meta"]["limit"] <= Loopctl.Knowledge.max_relevance_page_size()
    end

    test "honors a within-cap relevance limit (combined/default mode) (#148 A1)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Default (combined) mode used to silently clamp to 50; now a within-cap
      # limit is honored and reported faithfully.
      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "anything", limit: "90"})
        |> json_response(200)

      assert body["meta"]["limit"] == 90
    end

    test "tenant isolation — tenant A cannot see tenant B's articles", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "Tenant A Isolation Article",
        body: "Content for isolation test in tenant A.",
        category: :pattern,
        status: :published,
        tags: ["isolation"]
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "Tenant B Isolation Article",
        body: "Content for isolation test in tenant B.",
        category: :pattern,
        status: :published,
        tags: ["isolation"]
      })

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/search", %{q: "isolation", mode: "keyword"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert List.first(body["data"])["title"] == "Tenant A Isolation Article"
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/search", %{q: "test"})
      assert json_response(conn, 401)
    end

    test "whitespace-only q returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "   "})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
    end
  end

  describe "list mode enumeration (Issue #108)" do
    test "tags filter without q enumerates the complete tagged set", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Articles whose bodies share no common keyword, so only a query-less
      # enumeration can return all of them.
      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Hub #{i}",
          body: "wholly distinct prose number #{i} zzz#{i}",
          category: :reference,
          status: :published,
          tags: ["hub"]
        })
      end

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Not Tagged",
        body: "unrelated",
        category: :reference,
        status: :published,
        tags: ["other"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{tags: "hub", limit: "50"})

      body = json_response(conn, 200)

      assert body["meta"]["total_count"] == 3
      # List mode total_count is the complete filtered set — labeled as such.
      assert body["meta"]["total_count_scope"] == "filtered_set"
      assert body["meta"]["search_mode"] == "list"
      assert length(body["data"]) == 3
      titles = body["data"] |> Enum.map(& &1["title"]) |> Enum.sort()
      assert titles == ["Hub 1", "Hub 2", "Hub 3"]

      # List mode has no relevance ranking; score defaults to 0.0
      assert Enum.all?(body["data"], &(&1["score"] == 0.0))
    end

    test "honors a limit above the old 50 cap so list mode reaches every row (#148 A1)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # 60 > the previous silent controller clamp of 50.
      total = 60

      for i <- 1..total do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Listed #{i}",
          body: "distinct prose #{i}",
          category: :reference,
          status: :published,
          tags: ["listed148"]
        })
      end

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{tags: "listed148", limit: "60"})
        |> json_response(200)

      assert body["meta"]["total_count"] == total
      assert body["meta"]["limit"] == 60
      assert length(body["data"]) == total
    end

    test "clamps a list-mode limit above the maximum page size (never rejects) (#148 A1)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{tags: "anything", limit: "1001"})
        |> json_response(200)

      assert resp["meta"]["limit"] == 1000
    end

    test "category filter without q enumerates the category", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Reference Doc",
        body: "anything",
        category: :reference,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "A Pattern",
        body: "anything",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{category: "reference"})

      body = json_response(conn, 200)

      assert body["meta"]["total_count"] == 1
      assert List.first(body["data"])["title"] == "Reference Doc"
    end

    test "offset pagination over a tag reaches every article exactly once", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      for i <- 1..5 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Hub #{i}",
          body: "body #{i}",
          category: :reference,
          status: :published,
          tags: ["hub"]
        })
      end

      collect = fn offset ->
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{tags: "hub", limit: "2", offset: "#{offset}"})
        |> json_response(200)
      end

      ids =
        [0, 2, 4]
        |> Enum.flat_map(fn off -> collect.(off)["data"] |> Enum.map(& &1["id"]) end)

      assert length(ids) == 5
      assert length(Enum.uniq(ids)) == 5
    end

    test "blank q with a filter falls into list mode (not a 400)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Hub Only",
        body: "x",
        category: :reference,
        status: :published,
        tags: ["hub"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "   ", tags: "hub"})

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
    end

    test "tenant isolation holds in list mode", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "A Hub",
        body: "x",
        category: :reference,
        status: :published,
        tags: ["hub"]
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "B Hub",
        body: "x",
        category: :reference,
        status: :published,
        tags: ["hub"]
      })

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/search", %{tags: "hub"})

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert List.first(body["data"])["title"] == "A Hub"
    end

    test "list mode only returns published articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published Hub",
        body: "x",
        category: :reference,
        status: :published,
        tags: ["hub"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft Hub",
        body: "x",
        category: :reference,
        status: :draft,
        tags: ["hub"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{tags: "hub"})

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert List.first(body["data"])["title"] == "Published Hub"
    end
  end

  describe "GET /api/v1/knowledge/search project_id validation (kbweb-01)" do
    test "a malformed project_id returns 422, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "anything", project_id: "not-a-uuid"})

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] =~ "project_id"
    end

    test "a valid project_id returns 200 filtered to that project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Scoped Ecto Pattern",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          q: "Ecto",
          mode: "keyword",
          project_id: project.id
        })

      body = json_response(conn, 200)
      assert Enum.any?(body["data"], &(&1["title"] == "Scoped Ecto Pattern"))
    end

    test "a project_id carrying the repo directory name scopes the search (#652)",
         %{conn: conn} do
      # The measured failure: agents pass the checkout directory name, get a 422, and
      # then retry with project_id DROPPED — losing the scope silently. Resolving at
      # the boundary means the scope intent survives.
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id, slug: "home-care-billing"})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Scoped By Slug Ecto",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Other Project Ecto",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          q: "Ecto",
          mode: "keyword",
          project_id: "home_care_billing"
        })

      body = json_response(conn, 200)
      titles = Enum.map(body["data"], & &1["title"])
      assert "Scoped By Slug Ecto" in titles
      refute "Other Project Ecto" in titles
    end

    test "an absent project_id returns 200 tenant-wide", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide Ecto",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "Ecto", mode: "keyword"})

      assert json_response(conn, 200)["data"] != nil
    end

    test "a valid project_id from another tenant does not leak (empty, not 500)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      fixture(:article, %{
        tenant_id: tenant_b.id,
        project_id: project_b.id,
        title: "Tenant B Ecto Secret",
        body: "Use Ecto.Multi for atomic operations.",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          q: "Ecto",
          mode: "keyword",
          project_id: project_b.id
        })

      body = json_response(conn, 200)
      refute Enum.any?(body["data"], &(&1["title"] == "Tenant B Ecto Secret"))
    end
  end
end
