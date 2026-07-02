defmodule LoopctlWeb.ArticleLinkControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/article_links" do
    test "creates link with valid data (201)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article_a = fixture(:article, %{tenant_id: tenant.id, title: "Source Article"})
      article_b = fixture(:article, %{tenant_id: tenant.id, title: "Target Article"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => article_a.id,
          "target_article_id" => article_b.id,
          "relationship_type" => "relates_to",
          "metadata" => %{"reason" => "related topic"}
        })

      body = json_response(conn, 201)
      assert body["data"]["source_article_id"] == article_a.id
      assert body["data"]["target_article_id"] == article_b.id
      assert body["data"]["relationship_type"] == "relates_to"
      assert body["data"]["metadata"] == %{"reason" => "related topic"}
      assert body["data"]["id"] != nil
      assert body["data"]["inserted_at"] != nil
    end

    # kb-01 (GHSA-9g2g-cm9x-9r2p): a "supersedes" link retires (hides) the target, so
    # it is a destructive op — creating one requires role: user+ (was previously agent+,
    # which let any agent hide an arbitrary published article).
    test ":supersedes link at user role sets target article status to :superseded", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article_a = fixture(:article, %{tenant_id: tenant.id, title: "New Version"})

      article_b =
        fixture(:article, %{tenant_id: tenant.id, title: "Old Version", status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => article_a.id,
          "target_article_id" => article_b.id,
          "relationship_type" => "supersedes"
        })

      assert json_response(conn, 201)

      # Verify the target article is now superseded
      {:ok, updated_target} = Loopctl.Knowledge.get_article(tenant.id, article_b.id)
      assert updated_target.status == :superseded
    end

    test "an agent creating a :supersedes link is forbidden (403), target stays published",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article_a = fixture(:article, %{tenant_id: tenant.id, title: "New Version"})

      article_b =
        fixture(:article, %{tenant_id: tenant.id, title: "Old Version", status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => article_a.id,
          "target_article_id" => article_b.id,
          "relationship_type" => "supersedes"
        })

      body = json_response(conn, 403)
      assert body["error"]["status"] == 403

      # The target must NOT have been hidden — still published/visible.
      {:ok, target} = Loopctl.Knowledge.get_article(tenant.id, article_b.id)
      assert target.status == :published

      # And no supersedes link was created.
      refute Loopctl.AdminRepo.get_by(Loopctl.Knowledge.ArticleLink,
               tenant_id: tenant.id,
               source_article_id: article_a.id,
               target_article_id: article_b.id,
               relationship_type: :supersedes
             )
    end

    test "an agent can still create a non-destructive link (derived_from) (201)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article_a = fixture(:article, %{tenant_id: tenant.id, title: "Derived"})
      article_b = fixture(:article, %{tenant_id: tenant.id, title: "Source"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => article_a.id,
          "target_article_id" => article_b.id,
          "relationship_type" => "derived_from"
        })

      body = json_response(conn, 201)
      assert body["data"]["relationship_type"] == "derived_from"
    end

    # kb-02 FIX A: potential_conflict is SYSTEM-generated only. An agent must not be able
    # to plant the "system flagged this pair" evidence the conflict-resolution guard trusts.
    test "an agent creating a :potential_conflict link is rejected (422), no link created",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      a = fixture(:article, %{tenant_id: tenant.id})
      b = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "relationship_type" => "potential_conflict"
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422

      refute Loopctl.AdminRepo.get_by(Loopctl.Knowledge.ArticleLink,
               tenant_id: tenant.id,
               source_article_id: a.id,
               target_article_id: b.id,
               relationship_type: :potential_conflict
             )
    end

    test "even a user cannot create a :potential_conflict link (system-only, 422)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      a = fixture(:article, %{tenant_id: tenant.id})
      b = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "relationship_type" => "potential_conflict"
        })

      assert json_response(conn, 422)
    end

    # kb-02: system-reserved provenance/score metadata is stripped from caller input, so
    # an agent cannot plant the auto_generated/similarity_score markers via the API.
    test "strips system-reserved metadata keys from an agent-created link", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      a = fixture(:article, %{tenant_id: tenant.id})
      b = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "relationship_type" => "relates_to",
          "metadata" => %{
            "auto_generated" => true,
            "similarity_score" => 0.99,
            "reason" => "kept"
          }
        })

      body = json_response(conn, 201)
      refute Map.has_key?(body["data"]["metadata"], "auto_generated")
      refute Map.has_key?(body["data"]["metadata"], "similarity_score")
      assert body["data"]["metadata"]["reason"] == "kept"

      # Confirm at the persistence layer too.
      link = Loopctl.AdminRepo.get(Loopctl.Knowledge.ArticleLink, body["data"]["id"])
      refute Map.has_key?(link.metadata, "auto_generated")
      refute Map.has_key?(link.metadata, "similarity_score")
    end

    # kb-02 FIX C: a non-scalar relationship_type must 422, not crash to_string/1 (500).
    test "a non-scalar relationship_type value is a 422, not a 500 crash", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      a = fixture(:article, %{tenant_id: tenant.id})
      b = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => a.id,
          "target_article_id" => b.id,
          "relationship_type" => %{"nested" => "object"}
        })

      assert json_response(conn, 422)
    end

    test "rejects self-link (422)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => article.id,
          "target_article_id" => article.id,
          "relationship_type" => "relates_to"
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
    end

    test "rejects cross-tenant link (422)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      article_a = fixture(:article, %{tenant_id: tenant_a.id})
      article_b = fixture(:article, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/article_links", %{
          "source_article_id" => article_a.id,
          "target_article_id" => article_b.id,
          "relationship_type" => "relates_to"
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
    end
  end

  describe "GET /api/v1/articles/:article_id/links" do
    test "lists links for article (both outgoing and incoming)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article_a = fixture(:article, %{tenant_id: tenant.id, title: "Article A"})
      article_b = fixture(:article, %{tenant_id: tenant.id, title: "Article B"})
      article_c = fixture(:article, %{tenant_id: tenant.id, title: "Article C"})

      # Outgoing link from A -> B
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: article_a.id,
        target_article_id: article_b.id,
        relationship_type: :relates_to
      })

      # Incoming link from C -> A
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: article_c.id,
        target_article_id: article_a.id,
        relationship_type: :derived_from
      })

      # Unrelated link B -> C (should not appear)
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: article_b.id,
        target_article_id: article_c.id,
        relationship_type: :relates_to
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{article_a.id}/links")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2

      # Verify preloaded article data
      link_ids = Enum.map(body["data"], & &1["id"])
      assert length(link_ids) == 2

      Enum.each(body["data"], fn link ->
        assert link["source_article"] != nil
        assert link["target_article"] != nil
        assert link["source_article"]["id"] != nil
        assert link["source_article"]["title"] != nil
      end)
    end
  end

  describe "DELETE /api/v1/article_links/:id" do
    test "agent role gets 403 on delete", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      link =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          relationship_type: :relates_to
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/article_links/#{link.id}")

      assert json_response(conn, 403)
    end

    test "user role can delete link (204)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      link =
        fixture(:article_link, %{
          tenant_id: tenant.id,
          relationship_type: :relates_to
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/article_links/#{link.id}")

      assert response(conn, 204)
    end
  end

  describe "tenant isolation" do
    test "cross-tenant delete returns 404", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})

      link =
        fixture(:article_link, %{
          tenant_id: tenant_a.id,
          relationship_type: :relates_to
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/article_links/#{link.id}")

      assert json_response(conn, 404)
    end

    test "cross-tenant index returns empty list", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})
      article_a = fixture(:article, %{tenant_id: tenant_a.id})

      fixture(:article_link, %{
        tenant_id: tenant_a.id,
        source_article_id: article_a.id,
        relationship_type: :relates_to
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{article_a.id}/links")

      body = json_response(conn, 200)
      assert body["data"] == []
    end
  end
end
