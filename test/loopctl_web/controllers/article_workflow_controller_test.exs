defmodule LoopctlWeb.ArticleWorkflowControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.Article

  import Ecto.Query

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # --- TC-21.3.1: Publish draft -> published with audit ---

  describe "POST /api/v1/articles/:id/publish" do
    test "publishes a draft article and records audit event", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/publish")

      body = json_response(conn, 200)
      assert body["data"]["id"] == article.id
      assert body["data"]["status"] == "published"

      # Verify DB state
      updated = AdminRepo.get!(Article, article.id)
      assert updated.status == :published

      # Verify audit log
      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id,
          where: a.action == "article.published"
        )
        |> AdminRepo.one!()

      assert audit.tenant_id == tenant.id
      assert audit.old_state == %{"status" => "draft"}
      assert audit.new_state == %{"status" => "published"}
    end

    # --- TC-21.3.2: Reject publish of non-draft (422) ---

    test "returns 422 when article is already published", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/publish")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cannot transition from published to published"
    end

    test "returns 422 when article is archived", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :archived})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/publish")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cannot transition from archived to published"
    end

    test "returns 404 for non-existent article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fake_id = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{fake_id}/publish")

      assert json_response(conn, 404)
    end

    test "rejects agent role (requires user+)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/publish")

      assert json_response(conn, 403)
    end
  end

  # --- TC-21.3.7: Unpublish returns to draft with audit ---

  describe "POST /api/v1/articles/:id/unpublish" do
    test "unpublishes a published article and records audit event", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/unpublish")

      body = json_response(conn, 200)
      assert body["data"]["id"] == article.id
      assert body["data"]["status"] == "draft"

      # Verify audit log
      audit =
        from(a in AuditLog,
          where: a.entity_type == "article" and a.entity_id == ^article.id,
          where: a.action == "article.unpublished"
        )
        |> AdminRepo.one!()

      assert audit.old_state == %{"status" => "published"}
      assert audit.new_state == %{"status" => "draft"}
    end

    test "returns 422 when article is a draft (invalid transition)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/unpublish")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cannot transition from draft to draft"
    end
  end

  # --- TC-21.3.8: Archive published article ---

  describe "POST /api/v1/articles/:id/archive" do
    test "archives a published article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/archive")

      body = json_response(conn, 200)
      assert body["data"]["status"] == "archived"

      updated = AdminRepo.get!(Article, article.id)
      assert updated.status == :archived
    end

    test "archives a draft article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/archive")

      body = json_response(conn, 200)
      assert body["data"]["status"] == "archived"
    end

    test "returns 422 when article is superseded", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :superseded})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/archive")

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cannot transition from superseded to archived"
    end
  end

  # --- TC-21.3.3: Bulk publish 3 drafts atomically ---

  describe "POST /api/v1/knowledge/bulk-publish" do
    test "bulk publishes multiple draft articles atomically", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      a1 = fixture(:article, %{tenant_id: tenant.id, status: :draft, title: "Draft One"})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :draft, title: "Draft Two"})
      a3 = fixture(:article, %{tenant_id: tenant.id, status: :draft, title: "Draft Three"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => [a1.id, a2.id, a3.id]
        })

      body = json_response(conn, 200)
      assert body["meta"]["count"] == 3
      assert length(body["data"]) == 3

      # Verify all published in DB
      for id <- [a1.id, a2.id, a3.id] do
        article = AdminRepo.get!(Article, id)
        assert article.status == :published
      end

      # Verify audit logs
      audit_count =
        AuditLog
        |> where([a], a.tenant_id == ^tenant.id and a.action == "article.published")
        |> AdminRepo.aggregate(:count, :id)

      assert audit_count == 3
    end

    # --- TC-21.3.4: Bulk publish fails atomically when one is non-draft ---

    test "fails atomically when one article is not a draft", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      a1 = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :published})
      a3 = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => [a1.id, a2.id, a3.id]
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "expected draft"

      # None should have changed (atomic rollback)
      assert AdminRepo.get!(Article, a1.id).status == :draft
      assert AdminRepo.get!(Article, a2.id).status == :published
      assert AdminRepo.get!(Article, a3.id).status == :draft
    end

    test "returns 404 when an article ID does not belong to tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      other_tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      a1 = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      # Article belongs to a different tenant
      a2 = fixture(:article, %{tenant_id: other_tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => [a1.id, a2.id]
        })

      assert json_response(conn, 404)
    end

    test "returns 400 when article_ids is empty", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => []
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "must not be empty"
    end

    test "returns 400 when article_ids exceeds 100", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      ids = Enum.map(1..101, fn _ -> Ecto.UUID.generate() end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => ids
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "Maximum 100"
    end
  end

  # --- TC-21.3.5: Drafts listing excludes published, includes source info ---

  describe "GET /api/v1/knowledge/drafts" do
    test "lists only draft articles with source info", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      draft =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :draft,
          title: "Draft Article",
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })

      _published =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "Published Article"
        })

      _archived =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :archived,
          title: "Archived Article"
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/drafts")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert length(body["data"]) == 1

      article_data = hd(body["data"])
      assert article_data["id"] == draft.id
      assert article_data["title"] == "Draft Article"
      assert article_data["source_type"] == "review_finding"
      assert article_data["source_id"] != nil
    end

    test "supports pagination", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      for i <- 1..5 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :draft,
          title: "Draft #{i}"
        })
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/drafts?limit=2&offset=0")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 5
      assert length(body["data"]) == 2
    end

    test "filters by project_id", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        status: :draft,
        title: "Project Draft"
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        status: :draft,
        title: "Tenant Draft"
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/drafts?project_id=#{project.id}")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert hd(body["data"])["title"] == "Project Draft"
    end
  end

  # --- TC-21.3.6: Tenant isolation on publish ---

  describe "tenant isolation" do
    test "cannot publish article from another tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      article_b = fixture(:article, %{tenant_id: tenant_b.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> post(~p"/api/v1/articles/#{article_b.id}/publish")

      assert json_response(conn, 404)
    end

    test "cannot unpublish article from another tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      article_b = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> post(~p"/api/v1/articles/#{article_b.id}/unpublish")

      assert json_response(conn, 404)
    end

    test "cannot archive article from another tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      article_b = fixture(:article, %{tenant_id: tenant_b.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> post(~p"/api/v1/articles/#{article_b.id}/archive")

      assert json_response(conn, 404)
    end

    test "bulk publish cannot see other tenant's articles", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})

      a_own = fixture(:article, %{tenant_id: tenant_a.id, status: :draft})
      a_other = fixture(:article, %{tenant_id: tenant_b.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => [a_own.id, a_other.id]
        })

      # The other tenant's article is not found
      assert json_response(conn, 404)
    end

    test "drafts listing is tenant-scoped", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})

      fixture(:article, %{tenant_id: tenant_a.id, status: :draft, title: "A Draft"})
      fixture(:article, %{tenant_id: tenant_b.id, status: :draft, title: "B Draft"})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/drafts")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert hd(body["data"])["title"] == "A Draft"
    end
  end
end
