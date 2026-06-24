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

    # --- #132: partial success — publish the valid drafts, report the rest ---

    test "publishes valid drafts and reports per-id outcomes for the rest", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      already = fixture(:article, %{tenant_id: tenant.id, status: :published})
      archived = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      missing = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => [draft.id, already.id, archived.id, missing]
        })

      body = json_response(conn, 200)

      # Only the genuine draft is published; the call does NOT fail.
      assert body["meta"]["count"] == 1
      assert body["meta"]["counts"]["published"] == 1
      assert body["meta"]["counts"]["skipped"] == 2
      assert body["meta"]["counts"]["not_found"] == 1
      assert body["meta"]["counts"]["requested"] == 4

      outcomes = Map.new(body["meta"]["results"], &{&1["id"], &1["outcome"]})
      assert outcomes[draft.id] == "published"
      assert outcomes[already.id] == "skipped"
      assert outcomes[archived.id] == "skipped"
      assert outcomes[missing] == "not_found"

      # The draft really published; the others are untouched.
      assert AdminRepo.get!(Article, draft.id).status == :published
      assert AdminRepo.get!(Article, already.id).status == :published
      assert AdminRepo.get!(Article, archived.id).status == :archived
    end

    test "already-published ids are an idempotent no-op (skipped, not 422)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      published = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{"article_ids" => [published.id]})

      body = json_response(conn, 200)
      assert body["meta"]["count"] == 0
      assert body["meta"]["counts"]["skipped"] == 1
      [result] = body["meta"]["results"]
      assert result["outcome"] == "skipped"
      assert result["reason"] == "already_published"
    end

    test "duplicate ids are de-duplicated", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => [draft.id, draft.id, draft.id]
        })

      body = json_response(conn, 200)
      assert body["meta"]["counts"]["requested"] == 1
      assert body["meta"]["counts"]["published"] == 1
      assert length(body["meta"]["results"]) == 1
    end

    test "another tenant's article id is reported not_found, not a hard failure", %{conn: conn} do
      tenant = fixture(:tenant)
      other_tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      a1 = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      a2 = fixture(:article, %{tenant_id: other_tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{"article_ids" => [a1.id, a2.id]})

      body = json_response(conn, 200)
      assert body["meta"]["counts"]["published"] == 1
      assert body["meta"]["counts"]["not_found"] == 1
      # The other tenant's article is untouched.
      assert AdminRepo.get!(Article, a2.id).status == :draft
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

    test "rejects a request above the 5000-id ceiling with 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      ids = Enum.map(1..5001, fn _ -> Ecto.UUID.generate() end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{"article_ids" => ids})

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "5000"
    end

    test "malformed (non-UUID) ids resolve to not_found, never a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{
          "article_ids" => [draft.id, "not-a-uuid", "also bad"]
        })

      body = json_response(conn, 200)
      outcomes = Map.new(body["meta"]["results"], &{&1["id"], &1["outcome"]})
      assert outcomes[draft.id] == "published"
      assert outcomes["not-a-uuid"] == "not_found"
      assert outcomes["also bad"] == "not_found"
    end

    test "accepts more than 100 ids (auto-chunked server-side)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      drafts =
        for n <- 1..105 do
          fixture(:article, %{tenant_id: tenant.id, status: :draft, title: "Bulk #{n}"})
        end

      ids = Enum.map(drafts, & &1.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-publish", %{"article_ids" => ids})

      body = json_response(conn, 200)
      assert body["meta"]["count"] == 105
      assert body["meta"]["counts"]["published"] == 105
      assert Enum.all?(drafts, &(AdminRepo.get!(Article, &1.id).status == :published))
    end
  end

  describe "POST /api/v1/knowledge/bulk-unpublish (#148 M3)" do
    test "unpublishes published articles and reports per-id outcomes for the rest", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      published = fixture(:article, %{tenant_id: tenant.id, status: :published})
      already_draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      archived = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      missing = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-unpublish", %{
          "article_ids" => [published.id, already_draft.id, archived.id, missing]
        })

      body = json_response(conn, 200)

      assert body["meta"]["count"] == 1
      assert body["meta"]["counts"]["unpublished"] == 1
      assert body["meta"]["counts"]["skipped"] == 2
      assert body["meta"]["counts"]["not_found"] == 1
      assert body["meta"]["counts"]["requested"] == 4

      outcomes = Map.new(body["meta"]["results"], &{&1["id"], &1["outcome"]})
      assert outcomes[published.id] == "unpublished"
      assert outcomes[already_draft.id] == "skipped"
      assert outcomes[archived.id] == "skipped"
      assert outcomes[missing] == "not_found"

      # The published article is now a draft; the rest are untouched.
      assert AdminRepo.get!(Article, published.id).status == :draft
      assert AdminRepo.get!(Article, already_draft.id).status == :draft
      assert AdminRepo.get!(Article, archived.id).status == :archived

      # data carries body-less summaries of the affected set.
      [summary] = body["data"]
      assert summary["id"] == published.id
      refute Map.has_key?(summary, "body")

      # Audit event recorded.
      audit_count =
        AuditLog
        |> where([a], a.tenant_id == ^tenant.id and a.action == "article.unpublished")
        |> AdminRepo.aggregate(:count, :id)

      assert audit_count == 1
    end

    test "already-draft ids are an idempotent no-op (skipped)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-unpublish", %{"article_ids" => [draft.id]})
        |> json_response(200)

      assert body["meta"]["count"] == 0
      assert body["meta"]["counts"]["skipped"] == 1
      [result] = body["meta"]["results"]
      assert result["outcome"] == "skipped"
      assert result["reason"] == "already_draft"
    end

    test "requires user role (agent forbidden)", %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      published = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/knowledge/bulk-unpublish", %{"article_ids" => [published.id]})

      assert json_response(conn, 403)
      # Unchanged.
      assert AdminRepo.get!(Article, published.id).status == :published
    end

    test "empty article_ids returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-unpublish", %{"article_ids" => []})

      assert json_response(conn, 400)
    end
  end

  describe "POST /api/v1/knowledge/bulk-delete" do
    test "archives valid ids and reports per-id outcomes for the rest", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      published = fixture(:article, %{tenant_id: tenant.id, status: :published})
      already = fixture(:article, %{tenant_id: tenant.id, status: :archived})
      superseded = fixture(:article, %{tenant_id: tenant.id, status: :superseded})
      missing = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "article_ids" => [draft.id, published.id, already.id, superseded.id, missing]
        })

      body = json_response(conn, 200)
      assert body["meta"]["count"] == 2
      assert body["meta"]["counts"]["archived"] == 2
      assert body["meta"]["counts"]["skipped"] == 2
      assert body["meta"]["counts"]["not_found"] == 1

      by_id = Map.new(body["meta"]["results"], &{&1["id"], &1})
      assert by_id[draft.id]["outcome"] == "archived"
      assert by_id[published.id]["outcome"] == "archived"
      assert by_id[already.id]["outcome"] == "skipped"
      assert by_id[already.id]["reason"] == "already_archived"
      assert by_id[superseded.id]["outcome"] == "skipped"
      assert by_id[superseded.id]["reason"] == "not_archivable_from_superseded"
      assert by_id[missing]["outcome"] == "not_found"

      assert AdminRepo.get!(Article, draft.id).status == :archived
      assert AdminRepo.get!(Article, published.id).status == :archived
      assert AdminRepo.get!(Article, superseded.id).status == :superseded
    end

    test "supplying more than one selector is rejected (no silent confirm bypass)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["dupe"]})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "article_ids" => [a.id],
          "tag" => "dupe",
          "confirm" => true
        })
        |> json_response(400)

      assert body["error"]["message"] =~ "exactly ONE"
      assert AdminRepo.get!(Article, a.id).status == :published
    end

    test "a half-specified source selector returns a clear pairing error", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"source_type" => "web_article"})
        |> json_response(400)

      assert body["error"]["message"] =~ "provided together"
    end

    test "already-archived ids are idempotent (skipped, not errored)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      archived = fixture(:article, %{tenant_id: tenant.id, status: :archived})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"article_ids" => [archived.id]})
        |> json_response(200)

      assert body["meta"]["count"] == 0
      [r] = body["meta"]["results"]
      assert r["outcome"] == "skipped"
      assert r["reason"] == "already_archived"
    end

    test "deletes by source_type + source_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      src = Ecto.UUID.generate()

      a =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          source_type: "web_article",
          source_id: src
        })

      b =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :draft,
          source_type: "web_article",
          source_id: src
        })

      other = fixture(:article, %{tenant_id: tenant.id, status: :published})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "source_type" => "web_article",
          "source_id" => src
        })
        |> json_response(200)

      assert body["meta"]["count"] == 2
      assert AdminRepo.get!(Article, a.id).status == :archived
      assert AdminRepo.get!(Article, b.id).status == :archived
      assert AdminRepo.get!(Article, other.id).status == :published
    end

    test "delete by tag requires confirm: true", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      tagged = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["dupe"]})

      # Without confirm → 400, nothing archived.
      refused =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"tag" => "dupe"})
        |> json_response(400)

      assert refused["error"]["message"] =~ "confirm"
      assert AdminRepo.get!(Article, tagged.id).status == :published

      # With confirm → archived.
      ok =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"tag" => "dupe", "confirm" => true})
        |> json_response(200)

      assert ok["meta"]["count"] == 1
      assert AdminRepo.get!(Article, tagged.id).status == :archived
    end

    test "an ambiguous/empty selector returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{})
        |> json_response(400)

      assert body["error"]["message"] =~ "Selectors"
    end

    test "an empty article_ids list returns 400 (not a no-op 200)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"article_ids" => []})
        |> json_response(400)

      assert body["error"]["message"] =~ "empty"
    end

    test "an empty tag with confirm archives nothing (zero-match 400, not everything)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["real"]})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"tag" => "", "confirm" => true})
        |> json_response(400)

      assert body["error"]["message"] =~ "No active articles"
      # An empty-tag selector must NOT archive real articles.
      assert AdminRepo.get!(Article, a.id).status == :published
    end

    test "agent role is forbidden (destructive, user+)", %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      a = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn
      |> auth_conn(agent_key)
      |> post(~p"/api/v1/knowledge/bulk-delete", %{"article_ids" => [a.id]})
      |> json_response(403)

      assert AdminRepo.get!(Article, a.id).status == :published
    end

    test "cannot archive another tenant's articles (reported not_found)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      b_article = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      body =
        conn
        |> auth_conn(key_a)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"article_ids" => [b_article.id]})
        |> json_response(200)

      assert body["meta"]["counts"]["not_found"] == 1
      assert AdminRepo.get!(Article, b_article.id).status == :published
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

    test "rejects a limit above the maximum page size with 400 (no silent clamp) (#148 A1)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/drafts?limit=1001")
        |> json_response(400)

      assert resp["error"]["status"] == 400
      assert resp["error"]["message"] =~ "maximum page size"
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

    test "bulk publish cannot see or touch other tenant's articles", %{conn: conn} do
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

      body = json_response(conn, 200)
      outcomes = Map.new(body["meta"]["results"], &{&1["id"], &1["outcome"]})
      assert outcomes[a_own.id] == "published"
      # The other tenant's article is invisible → reported not_found and untouched.
      assert outcomes[a_other.id] == "not_found"
      assert AdminRepo.get!(Article, a_other.id).status == :draft
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
