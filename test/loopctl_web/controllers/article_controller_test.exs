defmodule LoopctlWeb.ArticleControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.Article

  import Ecto.Query

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/articles" do
    test "creates and publishes a tenant-wide article with agent role by default", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Ecto Multi Pattern",
          "body" => "Use Ecto.Multi for atomic operations.",
          "category" => "pattern",
          "tags" => ["ecto", "transactions"]
        })

      body = json_response(conn, 201)
      assert body["data"]["title"] == "Ecto Multi Pattern"
      assert body["data"]["category"] == "pattern"
      assert body["data"]["tags"] == ["ecto", "transactions"]
      # Publish-on-create is the default for every role, including agent (#133).
      assert body["data"]["status"] == "published"
      assert is_nil(body["data"]["project_id"])
      assert body["note"] =~ "published"
    end

    test "agent can stage a draft via draft: true", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Staged Draft",
          "body" => "stage me for later review",
          "category" => "pattern",
          "draft" => true
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "draft"
      assert body["note"] =~ "draft"
      assert body["note"] =~ "publish"
    end

    test "status: \"draft\" is honoured as the draft opt-in", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Draft Via Status",
          "body" => "status draft also stages",
          "category" => "pattern",
          "status" => "draft"
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "draft"
    end

    test "a default create that dedups onto an existing draft is returned unchanged (still draft)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Dedup Draft",
        "body" => "identical body content",
        "category" => "pattern"
      }

      # First create stages a draft explicitly.
      conn
      |> auth_conn(agent_key)
      |> post(~p"/api/v1/articles", Map.put(payload, "draft", true))
      |> json_response(201)

      # A second (default publish) create of the same title+body dedups onto the
      # existing draft — a pure no-op, so it is returned unchanged and is NOT
      # published.
      resp =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", payload)
        |> json_response(200)

      assert resp["deduplicated"] == true
      assert resp["data"]["status"] == "draft"
      # The note honestly explains the publish intent did not apply (an identical
      # draft was staged earlier) and gives an actually-reachable remedy.
      assert resp["note"] =~ "did not change it"
      assert resp["note"] =~ "publish"
      refute resp["note"] =~ "Created"
    end

    test "draft: true that dedups onto an existing draft says the intent is satisfied", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Dedup Draft Intent",
        "body" => "identical staged body",
        "category" => "pattern",
        "draft" => true
      }

      conn |> auth_conn(agent_key) |> post(~p"/api/v1/articles", payload) |> json_response(201)

      resp =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", payload)
        |> json_response(200)

      assert resp["deduplicated"] == true
      assert resp["data"]["status"] == "draft"
      assert resp["note"] =~ "already existed"
    end

    test "dedup onto an existing published article does not claim it was 'created' now", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Dedup Published",
        "body" => "identical published body",
        "category" => "pattern"
      }

      # First call creates-and-publishes (default).
      first =
        conn |> auth_conn(agent_key) |> post(~p"/api/v1/articles", payload) |> json_response(201)

      assert first["data"]["status"] == "published"

      # Second identical call dedups onto the published article — a no-op.
      resp =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", payload)
        |> json_response(200)

      assert resp["deduplicated"] == true
      assert resp["data"]["status"] == "published"
      assert resp["note"] =~ "already existed"
      refute resp["note"] =~ "Created"
    end

    test "system scope is still gated to superadmin (agent gets system_scope_forbidden)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "System Scoped",
          "body" => "agent attempting a system-scoped article",
          "category" => "pattern",
          "scope" => "system"
        })

      body = json_response(conn, 403)
      assert body["error"]["code"] == "system_scope_forbidden"
    end

    test "another tenant's project_id returns 422 before any article is created", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      other_tenant = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other_tenant.id})
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Cross Tenant Project",
          "body" => "project ownership is validated before any side effect",
          "category" => "pattern",
          "project_id" => other_project.id
        })

      body = json_response(conn, 422)
      assert body["error"]["details"]["project_id"] != nil
    end

    test "a non-draft caller-supplied status is ignored; article publishes by default", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Cannot Create Archived",
          "body" => "archived is a workflow transition, not a create-time status",
          "category" => "pattern",
          "status" => "archived"
        })

      # archived/superseded are workflow transitions, not create-time statuses —
      # the server ignores them and applies the publish-on-create default.
      body = json_response(conn, 201)
      assert body["data"]["status"] == "published"
    end

    test "a legacy publish: true payload is harmless — it just publishes (the default)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Legacy Publish Flag",
          "body" => "old clients still send publish: true",
          "category" => "pattern",
          "publish" => true
        })

      # The `publish` flag is dropped server-side; the article publishes by default
      # anyway, so an old client gets a sensible result (no 403, no draft).
      body = json_response(conn, 201)
      assert body["data"]["status"] == "published"
    end

    test "status: \"draft\" wins over draft: false (explicit stage beats the absent opt-in)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Draft Precedence",
          "body" => "status draft is an explicit stage request; draft:false is not an opt-out",
          "category" => "pattern",
          "status" => "draft",
          "draft" => false
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "draft"
    end

    test "returns 422 on invalid input", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "",
          "body" => "",
          "category" => ""
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert body["error"]["details"]["title"] != nil
    end

    test "duplicate title with an identical body is idempotent (200, same id)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Captured Video",
        "body" => "the captured summary",
        "category" => "reference",
        "tags" => ["hub"]
      }

      first = conn |> auth_conn(raw_key) |> post(~p"/api/v1/articles", payload)
      first_body = json_response(first, 201)
      first_id = first_body["data"]["id"]
      refute first_body["deduplicated"]

      # A concurrent/retried publish of the same content returns the same row with
      # a 200 (not 201) AND deduplicated: true, so callers/observers (incl. the MCP
      # layer that only sees a 2xx) can distinguish a dedup from a create.
      second = conn |> auth_conn(raw_key) |> post(~p"/api/v1/articles", payload)
      second_body = json_response(second, 200)
      assert second_body["data"]["id"] == first_id
      assert second_body["deduplicated"] == true
    end

    test "duplicate title with different content returns a clear 409 (not a retried 422)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      _first =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Shared Heading",
          "body" => "first",
          "category" => "pattern"
        })
        |> json_response(201)

      second =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Shared Heading",
          "body" => "second",
          "category" => "convention"
        })

      body = json_response(second, 409)
      assert body["error"]["status"] == 409
      assert body["error"]["code"] == "title_conflict"
      assert body["error"]["details"]["existing_article_id"]
    end
  end

  describe "POST /api/v1/articles novelty gate" do
    import Mox

    defp gate_verdict(verdict, neighbors, score) do
      stub(Loopctl.MockProposalAssessor, :assess, fn _t, _a, _o ->
        %{verdict: verdict, score: score, neighbors: neighbors}
      end)
    end

    test "near-duplicate returns 200, creates nothing, points to the canonical", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Canonical", status: :published})

      gate_verdict(
        :duplicate,
        [%{id: existing.id, title: existing.title, similarity_score: 0.98}],
        0.98
      )

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Canonical reworded",
          "body" => "Same idea.",
          "category" => "finding"
        })

      body = json_response(conn, 200)
      assert body["deduplicated"] == true
      assert body["gate"]["verdict"] == "duplicate"
      assert body["data"]["id"] == existing.id
      assert body["note"] =~ "near-duplicate"
    end

    test "high-overlap proposal is created as a draft with gate metadata", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      existing = fixture(:article, %{tenant_id: tenant.id, title: "Adjacent", status: :published})

      gate_verdict(
        :low_novelty,
        [%{id: existing.id, title: existing.title, similarity_score: 0.91}],
        0.91
      )

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Overlapping",
          "body" => "Mostly covered already.",
          "category" => "finding"
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "draft"
      assert body["gate"]["verdict"] == "gated_to_draft"
      assert body["note"] =~ "DRAFT"
    end

    test "force: true bypasses the gate and publishes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      # Even if the assessor would call it a duplicate, force skips assessment entirely.
      gate_verdict(:duplicate, [], 0.99)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Forced through",
          "body" => "Intentionally near an existing article.",
          "category" => "finding",
          "force" => true
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "published"
      assert body["data"]["title"] == "Forced through"
    end
  end

  describe "POST /api/v1/articles idempotency_key (#137)" do
    test "re-create with the same idempotency_key is a no-op (returns existing, even with a different body)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      first =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Captured Note One",
          "body" => "first capture",
          "category" => "reference",
          "idempotency_key" => "book:42:note:1"
        })
        |> json_response(201)

      first_id = first["data"]["id"]
      assert first["data"]["idempotency_key"] == "book:42:note:1"

      # Same key, DIFFERENT title + body → still a no-op (the key is the identity),
      # so no partial duplicate is created.
      resp =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Captured Note One (re-titled)",
          "body" => "a re-capture with changed content",
          "category" => "reference",
          "idempotency_key" => "book:42:note:1"
        })
        |> json_response(200)

      assert resp["deduplicated"] == true
      assert resp["data"]["id"] == first_id
      # An idempotency_key hit returns a REFERENCE only — the existing body is NOT
      # echoed back, so a (possibly guessable) key can't read another agent's
      # content. The new body was not applied either.
      refute resp["data"]["body"]
      assert resp["note"] =~ "idempotency_key"
      assert resp["note"] =~ "NOT applied"

      # The original row is genuinely unchanged (verified via a direct read).
      reread =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{first_id}")
        |> json_response(200)

      assert reread["data"]["body"] == "first capture"
    end

    test "a create that carries an idempotency_key but dedups on TITLE gets the title note", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Title Dedup",
        "body" => "identical body",
        "category" => "reference"
      }

      # First create has NO idempotency_key.
      conn |> auth_conn(raw_key) |> post(~p"/api/v1/articles", payload) |> json_response(201)

      # Second create has the SAME title+body but a key that matches nothing — it
      # dedups on the title index, so it must get the title note (full body echoed,
      # since the caller supplied the identical body), NOT the idempotency note.
      resp =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", Map.put(payload, "idempotency_key", "unmatched-key"))
        |> json_response(200)

      assert resp["deduplicated"] == true
      refute resp["note"] =~ "idempotency_key"
      assert resp["data"]["body"] == "identical body"
    end

    test "different idempotency_keys create distinct articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      a =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Note A",
          "body" => "a",
          "category" => "reference",
          "idempotency_key" => "k-a"
        })
        |> json_response(201)

      b =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Note B",
          "body" => "b",
          "category" => "reference",
          "idempotency_key" => "k-b"
        })
        |> json_response(201)

      assert a["data"]["id"] != b["data"]["id"]
    end

    test "the same idempotency_key in two tenants does not collide", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      payload = %{
        "title" => "Shared Key Note",
        "body" => "content",
        "category" => "reference",
        "idempotency_key" => "shared"
      }

      a = conn |> auth_conn(key_a) |> post(~p"/api/v1/articles", payload) |> json_response(201)

      b =
        build_conn()
        |> auth_conn(key_b)
        |> post(~p"/api/v1/articles", payload)
        |> json_response(201)

      refute a["data"]["deduplicated"]
      refute b["data"]["deduplicated"]
      assert a["data"]["id"] != b["data"]["id"]
    end

    test "an over-long idempotency_key is rejected with 422", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Long Key",
          "body" => "x",
          "category" => "reference",
          "idempotency_key" => String.duplicate("a", 256)
        })

      body = json_response(conn, 422)
      assert body["error"]["details"]["idempotency_key"] != nil
    end
  end

  describe "POST /api/v1/projects/:project_id/articles" do
    test "creates a project-scoped article", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/articles", %{
          "title" => "Project Convention",
          "body" => "Follow these conventions for this project.",
          "category" => "convention"
        })

      body = json_response(conn, 201)
      assert body["data"]["title"] == "Project Convention"
      assert body["data"]["project_id"] == project.id
    end
  end

  describe "GET /api/v1/articles" do
    test "an invalid status returns 400 with the allowed values (not 404/500)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?status=active")

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["code"] == "invalid_status"
      assert body["error"]["message"] =~ "draft"
      assert body["error"]["message"] =~ "published"
    end

    test "an invalid category returns 400 with the allowed values", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?category=nonsense")

      body = json_response(conn, 400)
      assert body["error"]["code"] == "invalid_category"
      assert body["error"]["message"] =~ "pattern"
    end

    test "an empty status param is treated as no filter (not a 400/500)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, title: "P"})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?status=")
        |> json_response(200)

      assert body["meta"]["total_count"] == 1
    end

    test "malformed list/map query params don't 500 (treated as no filter)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, title: "X"})

      # ?project_id[]=x&limit[]=1&tags[]=a decode to lists; must degrade to
      # "no filter", never a FunctionClauseError / Ecto cast 500.
      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/articles?project_id[]=x&limit[]=1&source_id[]=y&tags[]=a")

      assert json_response(conn, 200)["meta"]["total_count"] == 1
    end

    test "a valid status filter still works", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Pub"})
      fixture(:article, %{tenant_id: tenant.id, status: :draft, title: "Draf"})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?status=published")
        |> json_response(200)

      assert body["meta"]["total_count"] == 1
      assert hd(body["data"])["status"] == "published"
    end

    test "filters by source_type, source_id, and idempotency_key (lag-free existence check)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      src = Ecto.UUID.generate()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "From Source",
        source_type: "web_article",
        source_id: src,
        idempotency_key: "ik-1"
      })

      fixture(:article, %{tenant_id: tenant.id, title: "Unrelated"})

      # by source_type
      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?source_type=web_article")
        |> json_response(200)

      assert body["meta"]["total_count"] == 1
      assert hd(body["data"])["title"] == "From Source"

      # by source_id
      body2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?source_id=#{src}")
        |> json_response(200)

      assert body2["meta"]["total_count"] == 1

      # by idempotency_key — the canonical existence check
      body3 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?idempotency_key=ik-1")
        |> json_response(200)

      assert body3["meta"]["total_count"] == 1
      assert hd(body3["data"])["idempotency_key"] == "ik-1"
    end

    test "a malformed source_id matches nothing (no 500)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, title: "X"})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?source_id=not-a-uuid")
        |> json_response(200)

      assert body["meta"]["total_count"] == 0
    end

    test "lists articles with category and tags filters", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern A",
        category: :pattern,
        tags: ["elixir", "ecto"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Decision B",
        category: :decision,
        tags: ["architecture"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern C",
        category: :pattern,
        tags: ["phoenix"]
      })

      # Filter by category
      conn_category =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?category=pattern")

      body = json_response(conn_category, 200)
      assert body["meta"]["total_count"] == 2
      assert length(body["data"]) == 2

      # Filter by tags
      conn_tags =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=elixir")

      body_tags = json_response(conn_tags, 200)
      assert body_tags["meta"]["total_count"] == 1
      assert hd(body_tags["data"])["title"] == "Pattern A"
    end

    test "match=all ANDs tags; default ORs them (#148 A2)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{tenant_id: tenant.id, title: "Book Hub", tags: ["book", "hub"]})
      fixture(:article, %{tenant_id: tenant.id, title: "Book Only", tags: ["book"]})
      fixture(:article, %{tenant_id: tenant.id, title: "Hub Only", tags: ["hub"]})

      # AND: only the article carrying BOTH tags
      and_body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=book,hub&match=all")
        |> json_response(200)

      assert and_body["meta"]["total_count"] == 1
      assert hd(and_body["data"])["title"] == "Book Hub"

      # OR (default): the union of all three
      or_body =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=book,hub")
        |> json_response(200)

      assert or_body["meta"]["total_count"] == 3
    end

    test "rejects an invalid match with 400 (#148 A2)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=book&match=nonsense")
        |> json_response(400)

      assert resp["error"]["status"] == 400
      assert resp["error"]["message"] =~ "match"
    end
  end

  describe "GET /api/v1/articles — pagination limit (#148 A1)" do
    test "honors a limit > 100 and paginates a large tag to exhaustion without skipping rows",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # N > 200 so a limit=200 page proves the old `min(100)` clamp is gone and
      # exhaustive offset pagination reaches every row (regression for the
      # by-tag cleanup that scanned only 1902 of 3802 rows).
      total = 205

      for i <- 1..total do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Bulk Article #{i}",
          category: :reference,
          tags: ["bulk148"]
        })
      end

      page1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=bulk148&limit=200&offset=0")
        |> json_response(200)

      # Larger page sizes must return MORE data, not less: the applied limit is
      # surfaced and honored (old code clamped to 100).
      assert page1["meta"]["total_count"] == total
      assert page1["meta"]["limit"] == 200
      assert length(page1["data"]) == 200

      page2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=bulk148&limit=200&offset=200")
        |> json_response(200)

      assert length(page2["data"]) == total - 200

      ids =
        (page1["data"] ++ page2["data"])
        |> Enum.map(& &1["id"])
        |> Enum.uniq()

      assert length(ids) == total
    end

    test "clamps a limit above the maximum page size (never rejects) and reports the effective limit",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?limit=1001")
        |> json_response(200)

      # No 400 — clamped to the max page size, surfaced in meta.limit so the
      # caller advances offset by the effective amount (no skipped rows).
      assert resp["meta"]["limit"] == 1000
    end

    test "honors the maximum limit exactly (1000) without clamping", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{tenant_id: tenant.id, title: "Edge", tags: ["edge148"]})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=edge148&limit=1000")
        |> json_response(200)

      assert body["meta"]["limit"] == 1000
    end
  end

  describe "GET /api/v1/articles — include_body & byte budget (#148 A1)" do
    test "returns a body-less summary by default (no body in list rows)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Summary Default",
        body: "this body must not appear in the default list response",
        tags: ["sum148"]
      })

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=sum148")
        |> json_response(200)

      row = hd(body["data"])
      assert row["title"] == "Summary Default"
      assert row["tags"] == ["sum148"]
      # Body-less summary: no body key, and meta says so.
      refute Map.has_key?(row, "body")
      assert body["meta"]["include_body"] == false
    end

    test "include_body=true returns full bodies with continuation meta", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "With Body",
        body: "the full body content is returned here",
        tags: ["wb148"]
      })

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=wb148&include_body=true")
        |> json_response(200)

      row = hd(body["data"])
      assert row["body"] == "the full body content is returned here"
      assert body["meta"]["include_body"] == true
      assert body["meta"]["returned"] == 1
      assert body["meta"]["has_more"] == false
      assert body["meta"]["byte_truncated"] == false
      assert body["meta"]["next_offset"] == 1
    end

    test "include_body=true bounds a page by the byte budget and continues via next_offset",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Test byte budget is 100_000 (config/test.exs). Three 40 KB bodies (120 KB)
      # exceed it, so the first page returns 2 (80 KB) and truncates; the 3rd is
      # reachable by continuing at next_offset.
      big = String.duplicate("x", 40_000)

      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Heavy #{i}",
          body: big,
          tags: ["heavy148"]
        })
      end

      page1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=heavy148&include_body=true&limit=1000")
        |> json_response(200)

      assert page1["meta"]["total_count"] == 3
      assert page1["meta"]["returned"] == 2
      assert length(page1["data"]) == 2
      assert page1["meta"]["byte_truncated"] == true
      assert page1["meta"]["has_more"] == true
      assert page1["meta"]["next_offset"] == 2

      page2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=heavy148&include_body=true&limit=1000&offset=2")
        |> json_response(200)

      assert page2["meta"]["returned"] == 1
      assert page2["meta"]["has_more"] == false

      all_ids =
        (page1["data"] ++ page2["data"]) |> Enum.map(& &1["id"]) |> Enum.uniq()

      assert length(all_ids) == 3
    end
  end

  describe "GET /api/v1/projects/:project_id/articles" do
    test "lists project-scoped articles only", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "In Project"
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        title: "Other Project"
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide"
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/articles")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert hd(body["data"])["title"] == "In Project"
    end
  end

  describe "GET /api/v1/articles/:id" do
    test "returns article with preloaded links", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      article_a = fixture(:article, %{tenant_id: tenant.id, title: "Article A"})
      article_b = fixture(:article, %{tenant_id: tenant.id, title: "Article B"})

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: article_a.id,
        target_article_id: article_b.id,
        relationship_type: :relates_to
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{article_a.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == article_a.id
      assert body["data"]["title"] == "Article A"
      assert length(body["data"]["outgoing_links"]) == 1

      outgoing = hd(body["data"]["outgoing_links"])
      assert outgoing["relationship_type"] == "relates_to"
      assert outgoing["target_article"]["id"] == article_b.id
      assert outgoing["target_article"]["title"] == "Article B"
    end

    test "returns 404 for non-existent article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/articles/:id" do
    # #331: KB content editing is agent-role curation (was user+).
    test "agent role can update article in place", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{
          "title" => "Updated Title",
          "body" => "Updated body",
          "category" => "decision",
          "tags" => ["e", "f"]
        })

      body = json_response(conn, 200)
      assert body["data"]["title"] == "Updated Title"
      assert body["data"]["body"] == "Updated body"
      assert body["data"]["category"] == "decision"
      assert body["data"]["tags"] == ["e", "f"]
    end

    # #331 privilege-bypass guard: `status` on PATCH is user+ only, so an agent
    # cannot publish a draft via PATCH (bypassing the orchestrator-gated publish
    # review) or drive lifecycle directly.
    test "agent PATCH {status: published} is 403 and leaves the draft unchanged", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"status" => "published"})

      body = json_response(conn, 403)
      assert body["error"]["code"] == "status_change_forbidden"
      # The draft was NOT published — the orchestrator-gated review is intact.
      assert AdminRepo.get!(Article, article.id).status == :draft
    end

    test "agent PATCH {status: superseded} is 403, unchanged", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"status" => "superseded"})

      assert json_response(conn, 403)["error"]["code"] == "status_change_forbidden"
      assert AdminRepo.get!(Article, article.id).status == :published
    end

    # Whole-request reject: a status field poisons the whole PATCH — the content
    # change (title) must NOT be applied either, so the caller isn't misled.
    test "agent PATCH mixing title + status is rejected whole (title unchanged)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :draft, title: "Before"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{
          "title" => "After",
          "status" => "published"
        })

      assert json_response(conn, 403)["error"]["code"] == "status_change_forbidden"

      reloaded = AdminRepo.get!(Article, article.id)
      assert reloaded.title == "Before"
      assert reloaded.status == :draft
    end

    # A content-only agent PATCH (no status key) still succeeds — the guard only
    # trips on a status field.
    test "agent PATCH with no status key still succeeds (content edited)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, title: "Old"})

      body =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"title" => "New", "body" => "New body"})
        |> json_response(200)

      assert body["data"]["title"] == "New"
      assert body["data"]["body"] == "New body"
    end

    # IDs are load-bearing (cited in CLAUDE.mds, cross-links) — an in-place edit
    # MUST preserve the article ID rather than churn a new row (#331).
    test "preserves the article ID across an edit", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, title: "Original"})

      body =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"body" => "tidied"})
        |> json_response(200)

      assert body["data"]["id"] == article.id
      # Exactly one row still exists — no churn.
      assert AdminRepo.aggregate(from(a in Article, where: a.tenant_id == ^tenant.id), :count) ==
               1
    end

    test "a partial (body-only) edit leaves other fields untouched", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      article =
        fixture(:article, %{tenant_id: tenant.id, title: "Keep Title", category: :pattern})

      body =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"body" => "new body only"})
        |> json_response(200)

      assert body["data"]["title"] == "Keep Title"
      assert body["data"]["category"] == "pattern"
      assert body["data"]["body"] == "new body only"
    end

    test "an invalid field value returns 422 (not a 500)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"category" => "not-a-category"})

      assert json_response(conn, 422)
      # Unchanged in the DB.
      assert AdminRepo.get!(Article, article.id).category == :pattern
    end

    test "records an article.updated audit entry", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, title: "Before"})

      conn
      |> auth_conn(raw_key)
      |> patch(~p"/api/v1/articles/#{article.id}", %{"title" => "After"})
      |> json_response(200)

      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id,
          where: a.action == "article.updated"
        )
        |> AdminRepo.one!()

      assert audit.tenant_id == tenant.id
    end

    # user role remains allowed (higher role, agent+).
    test "user role can still update article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id})

      body =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{
          "title" => "Updated Title",
          "status" => "published"
        })
        |> json_response(200)

      assert body["data"]["title"] == "Updated Title"
      assert body["data"]["status"] == "published"
    end

    # Tenant isolation: agent in tenant B cannot edit tenant A's article (404).
    test "an agent in another tenant cannot edit the article (404, unchanged)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant_a.id, title: "A-owned"})

      conn =
        conn
        |> auth_conn(key_b)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"title" => "Hijacked"})

      assert json_response(conn, 404)
      assert AdminRepo.get!(Article, article.id).title == "A-owned"
    end
  end

  describe "DELETE /api/v1/articles/:id" do
    # #331: soft-delete (archive) is agent-role curation (was user+).
    test "agent role archives article (soft delete)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      body =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/articles/#{article.id}")
        |> json_response(200)

      assert body["data"]["status"] == "archived"
      # Soft delete — the row is retained.
      assert AdminRepo.get!(Article, article.id).status == :archived
    end

    test "records an article.archived audit entry", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn
      |> auth_conn(raw_key)
      |> delete(~p"/api/v1/articles/#{article.id}")
      |> json_response(200)

      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id,
          where: a.action == "article.archived"
        )
        |> AdminRepo.one!()

      assert audit.tenant_id == tenant.id
    end

    test "user role can still archive article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      body =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/articles/#{article.id}")
        |> json_response(200)

      assert body["data"]["status"] == "archived"
    end

    # Tenant isolation: agent in tenant B cannot archive tenant A's article (404).
    test "an agent in another tenant cannot archive the article (404, unchanged)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant_a.id, status: :published})

      conn =
        conn
        |> auth_conn(key_b)
        |> delete(~p"/api/v1/articles/#{article.id}")

      assert json_response(conn, 404)
      assert AdminRepo.get!(Article, article.id).status == :published
    end
  end

  describe "tenant isolation" do
    test "cross-tenant access returns 404", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant_a.id})

      # GET returns 404
      conn_get =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{article.id}")

      assert json_response(conn_get, 404)

      # PATCH returns 404
      conn_patch =
        build_conn()
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"title" => "Hijacked"})

      assert json_response(conn_patch, 404)

      # DELETE returns 404
      conn_delete =
        build_conn()
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/articles/#{article.id}")

      assert json_response(conn_delete, 404)
    end
  end

  describe "GET /api/v1/articles project_id validation (kbweb-01)" do
    test "a malformed project_id returns 422, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/articles", %{project_id: "not-a-uuid"})

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] =~ "project_id"
    end

    test "a valid project_id returns 200 filtered to that project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      in_project =
        fixture(:article, %{
          tenant_id: tenant.id,
          project_id: project.id,
          title: "In Project",
          status: :published
        })

      _tenant_wide =
        fixture(:article, %{tenant_id: tenant.id, title: "Tenant Wide", status: :published})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/articles", %{project_id: project.id})

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      assert in_project.id in ids
      refute Enum.any?(body["data"], &(&1["title"] == "Tenant Wide"))
    end

    test "an absent project_id returns 200 tenant-wide", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:article, %{tenant_id: tenant.id, title: "Tenant Wide", status: :published})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/articles")

      body = json_response(conn, 200)
      assert Enum.any?(body["data"], &(&1["title"] == "Tenant Wide"))
    end

    test "a valid project_id belonging to another tenant does not leak (empty, not 500)", %{
      conn: conn
    } do
      tenant_a = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      fixture(:article, %{
        tenant_id: tenant_b.id,
        project_id: project_b.id,
        title: "Tenant B Secret",
        status: :published
      })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/articles", %{project_id: project_b.id})

      body = json_response(conn, 200)
      refute Enum.any?(body["data"], &(&1["title"] == "Tenant B Secret"))
    end
  end

  describe "POST/PATCH /api/v1/articles project_id validation (kbweb-01)" do
    test "create with a malformed body project_id returns 422, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/articles", %{
          "title" => "Bad Project",
          "body" => "body",
          "category" => "pattern",
          "project_id" => "not-a-uuid"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "create via the project-scoped path with a malformed project_id returns 422", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post("/api/v1/projects/not-a-uuid/articles", %{
          "title" => "Bad Project Path",
          "body" => "body",
          "category" => "pattern"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "create with a valid project_id still works (201, scoped)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/articles", %{
          "title" => "Good Project",
          "body" => "body",
          "category" => "pattern",
          "project_id" => project.id
        })

      body = json_response(conn, 201)
      assert body["data"]["project_id"] == project.id
    end

    test "update with a malformed body project_id returns 422, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/articles/#{article.id}", %{"project_id" => "not-a-uuid"})

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "update with a valid project_id still works (200)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/articles/#{article.id}", %{"project_id" => project.id})

      body = json_response(conn, 200)
      assert body["data"]["project_id"] == project.id
    end
  end
end
