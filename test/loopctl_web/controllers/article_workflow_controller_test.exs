defmodule LoopctlWeb.ArticleWorkflowControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.BulkDeleteToken

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

      # data carries body-less summaries — never the full bodies (#158).
      assert Enum.all?(body["data"], &(not Map.has_key?(&1, "body")))
      assert Enum.all?(body["data"], &Map.has_key?(&1, "id"))

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

    test "tenant isolation: cannot unpublish another tenant's article", %{conn: conn} do
      tenant_a = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      tenant_b = fixture(:tenant)
      b_article = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      body =
        conn
        |> auth_conn(key_a)
        |> post(~p"/api/v1/knowledge/bulk-unpublish", %{"article_ids" => [b_article.id]})
        |> json_response(200)

      # B's id is invisible to tenant A → resolves to not_found, stays published.
      assert body["meta"]["counts"]["not_found"] == 1
      assert body["meta"]["counts"]["unpublished"] == 0
      assert AdminRepo.get!(Article, b_article.id).status == :published
    end
  end

  describe "POST /api/v1/knowledge/bulk-delete (set-based soft archive, US-27.12)" do
    test "archives the active matched ids set-based; foreign/inactive ids untouched", %{
      conn: conn
    } do
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
      # Set-based: returns the affected count (active rows only), one update_all.
      assert body["data"]["affected"] == 2
      assert body["meta"]["affected"] == 2
      assert body["meta"]["op"] == "archive"
      assert body["meta"]["set_based"] == true

      # Backward-compatible SUPERSET (#7): the original shipped MCP client reads
      # meta.counts.{requested,archived,skipped,not_found,errored} + meta.results.
      # The 5 ids resolve to 2 ACTIVE (draft+published); the archived/superseded/
      # foreign-missing never resolve, so requested == 2 (resolved), archived == 2,
      # skipped == 0, not_found/errored == 0, results == [].
      assert body["meta"]["count"] == 2
      assert body["meta"]["counts"]["requested"] == 2
      assert body["meta"]["counts"]["archived"] == 2
      assert body["meta"]["counts"]["skipped"] == 0
      assert body["meta"]["counts"]["not_found"] == 0
      assert body["meta"]["counts"]["errored"] == 0
      assert body["meta"]["results"] == []

      assert AdminRepo.get!(Article, draft.id).status == :archived
      assert AdminRepo.get!(Article, published.id).status == :archived
      # archived/superseded/foreign-missing are left as-is.
      assert AdminRepo.get!(Article, already.id).status == :archived
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

    test "already-archived ids are idempotent (affected: 0)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      archived = fixture(:article, %{tenant_id: tenant.id, status: :archived})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"article_ids" => [archived.id]})
        |> json_response(200)

      assert body["data"]["affected"] == 0
    end

    test "archives by source_type + source_id (source_id drives the selector)", %{conn: conn} do
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

      assert body["data"]["affected"] == 2
      assert AdminRepo.get!(Article, a.id).status == :archived
      assert AdminRepo.get!(Article, b.id).status == :archived
      assert AdminRepo.get!(Article, other.id).status == :published
    end

    test "source selector ANDs source_type: a mismatched source_type matches nothing (#6)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      src = Ecto.UUID.generate()

      # Article exists under source_id=src with source_type "web_article".
      web =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          source_type: "web_article",
          source_id: src
        })

      # Same source_id but a DIFFERENT source_type → must match nothing (affected 0).
      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "source_type" => "manual",
          "source_id" => src
        })
        |> json_response(200)

      assert body["data"]["affected"] == 0
      assert AdminRepo.get!(Article, web.id).status == :published
    end

    test "archive by tag requires confirm: true", %{conn: conn} do
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

      assert ok["data"]["affected"] == 1
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

    test "agent role is forbidden (destructive, user+) — AC-27.12.7", %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      a = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn
      |> auth_conn(agent_key)
      |> post(~p"/api/v1/knowledge/bulk-delete", %{"article_ids" => [a.id]})
      |> json_response(403)

      assert AdminRepo.get!(Article, a.id).status == :published
    end

    test "cannot archive another tenant's articles (affected 0, AC-27.12.6)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      b_article = fixture(:article, %{tenant_id: tenant_b.id, status: :published})

      body =
        conn
        |> auth_conn(key_a)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"article_ids" => [b_article.id]})
        |> json_response(200)

      assert body["data"]["affected"] == 0
      assert AdminRepo.get!(Article, b_article.id).status == :published
    end
  end

  describe "POST /api/v1/knowledge/bulk-delete dry-run + hard delete (US-27.12)" do
    test "dry_run previews would_affect, mints a token, mutates nothing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["hd"]})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["hd"]})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "tag" => "hd",
          "confirm" => true,
          "dry_run" => true,
          "hard" => true
        })
        |> json_response(200)

      assert body["data"]["would_affect"] == 2
      assert body["meta"]["dry_run"] == true
      assert body["meta"]["op"] == "delete"
      assert is_binary(body["meta"]["token"])

      # nothing mutated
      assert AdminRepo.get!(Article, a1.id).status == :published
      assert AdminRepo.get!(Article, a2.id).status == :published
    end

    test "soft (non-hard) dry_run previews would_affect, mints NO token, op=archive (#BUG2)", %{
      conn: conn
    } do
      # A dry-run of the DEFAULT soft/archive call (no hard: true) must NOT mint a
      # delete-scoped token the archive will never use, and must be self-describing
      # via meta.op. (Previously dry_run unconditionally previewed :delete.)
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["softdry"]})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "tag" => "softdry",
          "confirm" => true,
          "dry_run" => true
        })
        |> json_response(200)

      assert body["data"]["would_affect"] == 1
      assert body["meta"]["dry_run"] == true
      assert body["meta"]["op"] == "archive"
      # No delete token minted for the soft path.
      assert body["meta"]["token"] == nil
      assert AdminRepo.aggregate(BulkDeleteToken, :count, :id) == 0

      # Nothing mutated.
      assert AdminRepo.get!(Article, a1.id).status == :published
    end

    test "hard delete with a token permanently removes the frozen set", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a1 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["hd2"]})
      a2 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["hd2"]})

      token =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "tag" => "hd2",
          "confirm" => true,
          "dry_run" => true,
          "hard" => true
        })
        |> json_response(200)
        |> get_in(["meta", "token"])

      # a NEW matching article appears after the dry-run (TOCTOU)
      a3 = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["hd2"]})

      body =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"hard" => true, "token" => token})
        |> json_response(200)

      assert body["data"]["affected"] == 2
      assert body["meta"]["op"] == "delete"

      refute AdminRepo.get(Article, a1.id)
      refute AdminRepo.get(Article, a2.id)
      # the frozen set excluded the post-preview article
      assert AdminRepo.get(Article, a3.id)
    end

    test "hard delete with a stale/used token is refused (400)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["hd3"]})

      token =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "tag" => "hd3",
          "confirm" => true,
          "dry_run" => true,
          "hard" => true
        })
        |> json_response(200)
        |> get_in(["meta", "token"])

      # first use succeeds
      build_conn()
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/knowledge/bulk-delete", %{"hard" => true, "token" => token})
      |> json_response(200)

      # second use refused
      body =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{"hard" => true, "token" => token})
        |> json_response(400)

      assert body["error"]["message"] =~ "token"
    end

    test "hard delete without a token or confirm_hash is refused (400)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["hd4"]})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "hard" => true,
          "tag" => "hd4",
          "confirm" => true
        })
        |> json_response(400)

      assert body["error"]["message"] =~ "token"
      assert AdminRepo.get!(Article, a.id).status == :published
    end

    test "agent role cannot hard-delete (403, AC-27.12.7)", %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn
      |> auth_conn(agent_key)
      |> post(~p"/api/v1/knowledge/bulk-delete", %{
        "hard" => true,
        "token" => Ecto.UUID.generate()
      })
      |> json_response(403)
    end

    # config/test.exs sets :bulk_delete_frozen_max to 3, so >3 matches is oversized.
    test "oversized selector: dry-run returns no token + confirm_hash; re-confirm deletes", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      ids =
        for _ <- 1..4 do
          fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["over"]}).id
        end

      dry =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "tag" => "over",
          "confirm" => true,
          "dry_run" => true,
          "hard" => true
        })
        |> json_response(200)

      assert dry["data"]["would_affect"] == 4
      assert dry["meta"]["token"] == nil
      assert dry["meta"]["oversized"] == true
      assert is_binary(dry["meta"]["confirm_hash"])

      # Re-confirm with the same selector + the echoed confirm_hash → deletes.
      body =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "hard" => true,
          "tag" => "over",
          "confirm" => true,
          "confirm_hash" => dry["meta"]["confirm_hash"]
        })
        |> json_response(200)

      assert body["data"]["affected"] == 4
      Enum.each(ids, fn id -> refute AdminRepo.get(Article, id) end)
    end

    test "oversized re-confirm refuses on drift (confirm_hash mismatch)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      survivors =
        for _ <- 1..4 do
          fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["drift"]}).id
        end

      dry =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "tag" => "drift",
          "confirm" => true,
          "dry_run" => true,
          "hard" => true
        })
        |> json_response(200)

      # The id-set changes after the dry-run (a new matching article appears).
      new_id = fixture(:article, %{tenant_id: tenant.id, status: :published, tags: ["drift"]}).id

      body =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "hard" => true,
          "tag" => "drift",
          "confirm" => true,
          "confirm_hash" => dry["meta"]["confirm_hash"]
        })
        |> json_response(400)

      assert body["error"]["message"] =~ "drift"
      # nothing deleted
      Enum.each([new_id | survivors], fn id -> assert AdminRepo.get(Article, id) end)
    end

    @tag :capture_log
    test "reconfirm path: a DB abort surfaces as a structured DB error, NOT a 400 'drift' (M5/BUG1)",
         %{conn: conn} do
      # BUG 1: a real {:error, %Postgrex.Error{}} (FK abort / statement-timeout)
      # from the delete must NOT fall through to the drift clause and be mislabeled
      # a 400. It must route through US-27.3's DBError/FallbackController. We force
      # a deterministic FK abort with a cross-tenant stray link the tenant-scoped
      # link cleanup can't pre-delete, so the :restrict FK aborts the article delete.
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})

      # 4 matching articles → oversized (frozen_max is 3 in test config) → reconfirm path.
      victims =
        for _ <- 1..4 do
          fixture(:article, %{tenant_id: tenant_a.id, status: :published, tags: ["abort"]}).id
        end

      partner = fixture(:article, %{tenant_id: tenant_a.id, status: :published})
      [v1 | _] = victims

      # A link owned by tenant_b pointing at tenant_a's victim. The tenant_a-scoped
      # link cleanup does NOT remove it, so the :restrict FK aborts the delete.
      %ArticleLink{tenant_id: tenant_b.id}
      |> ArticleLink.changeset(%{
        source_article_id: partner.id,
        target_article_id: v1,
        relationship_type: :relates_to
      })
      |> Ecto.Changeset.put_change(:tenant_id, tenant_b.id)
      |> AdminRepo.insert!()

      dry =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "tag" => "abort",
          "confirm" => true,
          "dry_run" => true,
          "hard" => true
        })
        |> json_response(200)

      assert dry["meta"]["oversized"] == true
      confirm_hash = dry["meta"]["confirm_hash"]

      # Re-confirm (hash matches, no drift) → the delete fires and FK-aborts. The
      # response must be a DB-error status (>= 500), NOT a 400 "drift" mislabel.
      conn =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/bulk-delete", %{
          "hard" => true,
          "tag" => "abort",
          "confirm" => true,
          "confirm_hash" => confirm_hash
        })

      assert conn.status >= 500
      body = json_response(conn, conn.status)
      # The message is NOT the drift message — a real DB error was surfaced.
      refute body["error"]["message"] =~ "drift"

      # Atomic: the victim is still present (the whole delete rolled back).
      assert AdminRepo.get(Article, v1)
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

    test "clamps a limit above the maximum page size (never rejects), reporting effective meta.limit (#148 A1)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/drafts?limit=1001")
        |> json_response(200)

      assert resp["meta"]["limit"] == 1000
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

  describe "GET /api/v1/knowledge/conflicts" do
    test "lists potential-conflict pairs (agent role), highest overlap first", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      a = fixture(:article, %{tenant_id: tenant.id, title: "A", status: :published})
      b = fixture(:article, %{tenant_id: tenant.id, title: "B", status: :published})

      %ArticleLink{tenant_id: tenant.id}
      |> ArticleLink.changeset(%{
        source_article_id: a.id,
        target_article_id: b.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.97}
      })
      |> AdminRepo.insert!()

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/knowledge/conflicts")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert [pair] = body["data"]
      assert pair["similarity"] == 0.97
      assert length(pair["articles"]) == 2
    end
  end

  describe "POST /api/v1/knowledge/conflicts/resolve" do
    setup %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a = fixture(:article, %{tenant_id: tenant.id, title: "A", status: :published})
      b = fixture(:article, %{tenant_id: tenant.id, title: "B", status: :published})

      %ArticleLink{tenant_id: tenant.id}
      |> ArticleLink.changeset(%{
        source_article_id: a.id,
        target_article_id: b.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
      })
      |> AdminRepo.insert!()

      %{
        conn: auth_conn(conn, agent_key),
        user_conn: auth_conn(conn, user_key),
        tenant: tenant,
        a: a,
        b: b
      }
    end

    test "an agent can dismiss a conflict (takes effect immediately)", ctx do
      %{conn: conn, a: a, b: b} = ctx

      conn =
        post(conn, ~p"/api/v1/knowledge/conflicts/resolve", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "dismiss",
          "classification" => "complementary"
        })

      body = json_response(conn, 201)
      assert body["data"]["disposition"] == "dismiss"
      assert body["data"]["executed"] == true
    end

    # kb-02: a user (destructive role) records a high-confidence supersede on a REAL
    # potential conflict, and the nightly executor then retires the loser end-to-end.
    test "a user records a high-confidence supersede applied by the executor (loser retired)",
         ctx do
      %{user_conn: conn, tenant: tenant, a: a, b: b} = ctx

      conn =
        post(conn, ~p"/api/v1/knowledge/conflicts/resolve", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "supersede",
          "authoritative_article_id" => a.id,
          "confidence" => "high"
        })

      body = json_response(conn, 201)
      assert body["data"]["disposition"] == "supersede"
      assert body["data"]["executed"] == false
      assert body["note"] =~ "nightly executor"

      # Executor retires the loser.
      assert 1 == Loopctl.Knowledge.execute_conflict_resolutions(tenant.id)
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :superseded
    end

    # kb-02 (GHSA-9gqg-9r6p-658v): an :agent may NOT record a destructive verdict.
    test "an agent recording a supersede is forbidden (403); no row, executor retires nothing",
         ctx do
      %{conn: conn, tenant: tenant, a: a, b: b} = ctx

      conn =
        post(conn, ~p"/api/v1/knowledge/conflicts/resolve", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "supersede",
          "authoritative_article_id" => a.id,
          "confidence" => "high"
        })

      body = json_response(conn, 403)
      assert body["error"]["status"] == 403

      # No verdict row was persisted, so the nightly executor has nothing to apply.
      assert is_nil(
               Loopctl.AdminRepo.get_by(Loopctl.Knowledge.ConflictResolution,
                 tenant_id: tenant.id
               )
             )

      assert 0 == Loopctl.Knowledge.execute_conflict_resolutions(tenant.id)
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published
    end

    # kb-02: an agent may not have the nightly executor MERGE (retire + synthesize) either.
    test "an agent recording a merge is forbidden (403)", ctx do
      %{conn: conn, a: a, b: b} = ctx

      conn =
        post(conn, ~p"/api/v1/knowledge/conflicts/resolve", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "merge",
          "authoritative_article_id" => a.id,
          "confidence" => "high"
        })

      assert json_response(conn, 403)
    end

    # kb-02: fabrication guard — resolving a pair the system never flagged is rejected,
    # even for a privileged user, so no arbitrary pair can be retired via the executor.
    test "422 when the pair has no potential-conflict link (fabricated pair)", ctx do
      %{user_conn: conn, tenant: tenant} = ctx
      x = fixture(:article, %{tenant_id: tenant.id, title: "X", status: :published})
      y = fixture(:article, %{tenant_id: tenant.id, title: "Y", status: :published})

      conn =
        post(conn, ~p"/api/v1/knowledge/conflicts/resolve", %{
          "source_article_id" => x.id,
          "target_article_id" => y.id,
          "disposition" => "supersede",
          "authoritative_article_id" => x.id,
          "confidence" => "high"
        })

      assert json_response(conn, 422)
      # No verdict row for the fabricated pair.
      assert 0 ==
               Loopctl.AdminRepo.aggregate(
                 Loopctl.Knowledge.ConflictResolution,
                 :count,
                 :id
               )
    end

    test "422 when supersede omits the authoritative article", ctx do
      %{user_conn: conn, a: a, b: b} = ctx

      conn =
        post(conn, ~p"/api/v1/knowledge/conflicts/resolve", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "supersede"
        })

      assert json_response(conn, 422)
    end

    # Tenant isolation: a user in tenant B cannot resolve tenant A's flagged pair —
    # from B's perspective the potential_conflict link does not exist (422).
    test "a caller in another tenant cannot resolve the pair (422)", ctx do
      %{tenant: tenant_a, a: a, b: b, conn: base_conn} = ctx
      tenant_b = fixture(:tenant)
      {user_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})

      conn =
        base_conn
        |> auth_conn(user_key_b)
        |> post(~p"/api/v1/knowledge/conflicts/resolve", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "disposition" => "supersede",
          "authoritative_article_id" => a.id,
          "confidence" => "high"
        })

      assert json_response(conn, 422)
      # Tenant A's article is untouched.
      assert Loopctl.AdminRepo.get(Loopctl.Knowledge.Article, b.id).status == :published
      _ = tenant_a
    end
  end
end
