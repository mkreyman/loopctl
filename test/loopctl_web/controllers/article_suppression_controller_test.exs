defmodule LoopctlWeb.ArticleSuppressionControllerTest do
  @moduledoc """
  The HTTP half of the reversible retrieval tombstone.

  Role and visibility are the two things a transport test has to pin here: suppression is
  agent-role KB curation under the #331 carve-out, and it earns that role on being
  non-destructive AND audited AND reversible — the third property archive lacks. An agent may
  only suppress an article it can see, exactly as with archive.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp setup_tenant(role) do
    tenant = fixture(:tenant)
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: role})
    article = fixture(:article, %{tenant_id: tenant.id, status: :published})
    {tenant, raw_key, article}
  end

  defp audit_for(article_id, action) do
    from(a in AuditLog,
      where: a.entity_type == "article" and a.entity_id == ^article_id and a.action == ^action
    )
    |> AdminRepo.all()
  end

  describe "POST /api/v1/articles/:id/suppress" do
    test "an AGENT key suppresses and the response renders the tombstone", %{conn: conn} do
      {tenant, raw_key, article} = setup_tenant(:agent)

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/suppress", %{"reason" => "wrong figure"})
        |> json_response(200)

      assert body["data"]["id"] == article.id
      # Status is untouched: this is a claim about retrieval, not about editorial state.
      assert body["data"]["status"] == "published"
      assert body["data"]["suppression_reason"] == "wrong figure"
      assert is_binary(body["data"]["suppressed_at"])
      assert body["data"]["suppressed_by"] =~ "agent"

      assert AdminRepo.get!(Article, article.id).suppressed_at != nil
      assert [audit] = audit_for(article.id, "article.suppressed")
      assert audit.tenant_id == tenant.id
    end

    test "returns 422 with no reason", %{conn: conn} do
      {_tenant, raw_key, article} = setup_tenant(:agent)

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/suppress", %{})
        |> json_response(422)

      assert body["error"] || body["errors"]
      assert AdminRepo.get!(Article, article.id).suppressed_at == nil
    end

    test "returns 422 with a blank reason", %{conn: conn} do
      {_tenant, raw_key, article} = setup_tenant(:agent)

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/articles/#{article.id}/suppress", %{"reason" => "  "})
      |> json_response(422)

      assert AdminRepo.get!(Article, article.id).suppressed_at == nil
    end

    test "a multibyte reason over the COLUMN bound is a 422, not a 500", %{conn: conn} do
      # 400 decomposed graphemes = 800 codepoints. varchar(500) counts codepoints, so a
      # grapheme-based length check clears every Elixir bound and lets Postgres raise 22001
      # out of the transaction — a 500 on a caller mistake the contract answers with a 422.
      {_tenant, raw_key, article} = setup_tenant(:agent)
      reason = String.duplicate("e" <> <<0x0301::utf8>>, 400)

      assert String.length(reason) < 500

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/articles/#{article.id}/suppress", %{"reason" => reason})
      |> json_response(422)

      assert AdminRepo.get!(Article, article.id).suppressed_at == nil
    end

    test "a multibyte actor label is truncated in CODEPOINTS, not graphemes", %{conn: _conn} do
      # The controller's label is short ASCII, so driving this through HTTP asserts nothing:
      # a grapheme slice passes it unchanged and the test stays green on the bug. Call the
      # context with a label that is UNDER the bound in graphemes and OVER it in codepoints
      # — the one shape varchar(200) rejects.
      {tenant, _raw_key, article} = setup_tenant(:agent)
      label = String.duplicate("e" <> <<0x0301::utf8>>, 110)

      assert String.length(label) < 200
      assert length(String.to_charlist(label)) > 200

      {:ok, _} =
        Knowledge.suppress_article(tenant.id, article.id, reason: "held", actor_label: label)

      by = AdminRepo.get!(Article, article.id).suppressed_by
      assert length(String.to_charlist(by)) <= 200
    end

    test "returns 404 for another tenant's article", %{conn: conn} do
      {_tenant, raw_key, _article} = setup_tenant(:agent)
      other = fixture(:tenant)
      foreign = fixture(:article, %{tenant_id: other.id, status: :published})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/articles/#{foreign.id}/suppress", %{"reason" => "not mine"})
      |> json_response(404)

      assert AdminRepo.get!(Article, foreign.id).suppressed_at == nil
    end

    test "an agent gets 404 on another agent's private memory", %{conn: conn} do
      tenant = fixture(:tenant)

      {raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: nil})

      private =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          metadata: %{"visibility" => "private", "agent_id" => "someone-else"}
        })

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/articles/#{private.id}/suppress", %{"reason" => "peeking"})
      |> json_response(404)

      assert AdminRepo.get!(Article, private.id).suppressed_at == nil
    end

    test "an ORCHESTRATOR key also passes the role gate", %{conn: conn} do
      {_tenant, raw_key, article} = setup_tenant(:orchestrator)

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/articles/#{article.id}/suppress", %{"reason" => "hierarchy applies"})
      |> json_response(200)
    end

    test "an unauthenticated request is rejected", %{conn: conn} do
      {_tenant, _raw_key, article} = setup_tenant(:agent)

      conn
      |> post(~p"/api/v1/articles/#{article.id}/suppress", %{"reason" => "no key"})
      |> json_response(401)

      assert AdminRepo.get!(Article, article.id).suppressed_at == nil
    end
  end

  describe "POST /api/v1/articles/:id/unsuppress" do
    test "restores the article and clears all three fields", %{conn: conn} do
      {tenant, raw_key, article} = setup_tenant(:agent)
      {:ok, _} = Knowledge.suppress_article(tenant.id, article.id, reason: "temporary")

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles/#{article.id}/unsuppress")
        |> json_response(200)

      assert body["data"]["suppressed_at"] == nil
      assert body["data"]["suppressed_by"] == nil
      assert body["data"]["suppression_reason"] == nil

      assert [_audit] = audit_for(article.id, "article.unsuppressed")
    end

    test "is a harmless no-op on an article that is not suppressed", %{conn: conn} do
      {_tenant, raw_key, article} = setup_tenant(:agent)

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/articles/#{article.id}/unsuppress")
      |> json_response(200)

      assert audit_for(article.id, "article.unsuppressed") == []
    end

    test "returns 404 for another tenant's article", %{conn: conn} do
      {_tenant, raw_key, _article} = setup_tenant(:agent)
      other = fixture(:tenant)
      foreign = fixture(:article, %{tenant_id: other.id, status: :published})
      {:ok, _} = Knowledge.suppress_article(other.id, foreign.id, reason: "theirs")

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/articles/#{foreign.id}/unsuppress")
      |> json_response(404)

      assert AdminRepo.get!(Article, foreign.id).suppressed_at != nil
    end
  end

  describe "GET /api/v1/knowledge/index?suppressed=... — finding what to undo" do
    setup %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: nil})
      kept = fixture(:article, %{tenant_id: tenant.id, status: :published})
      gone = fixture(:article, %{tenant_id: tenant.id, status: :published})
      {:ok, _} = Knowledge.suppress_article(tenant.id, gone.id, reason: "listed for undo")

      %{conn: auth_conn(conn, raw_key), kept: kept, gone: gone}
    end

    defp index_ids(conn, query) do
      conn
      |> get(~p"/api/v1/knowledge/index?#{query}")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1["id"])
      |> MapSet.new()
    end

    test "the default listing excludes it", %{conn: conn, kept: kept, gone: gone} do
      listed = index_ids(conn, %{})

      assert MapSet.member?(listed, kept.id)
      refute MapSet.member?(listed, gone.id)
    end

    test "suppressed=only lists exactly the undo set", %{conn: conn, kept: kept, gone: gone} do
      listed = index_ids(conn, %{"suppressed" => "only"})

      assert MapSet.member?(listed, gone.id)
      refute MapSet.member?(listed, kept.id)
    end

    test "suppressed=include lists both", %{conn: conn, kept: kept, gone: gone} do
      listed = index_ids(conn, %{"suppressed" => "include"})

      assert MapSet.member?(listed, gone.id)
      assert MapSet.member?(listed, kept.id)
    end

    test "an unrecognised value fails CLOSED to exclude", %{conn: conn, gone: gone} do
      # A typo in a query param must never put a suppressed article back on a listing.
      refute MapSet.member?(index_ids(conn, %{"suppressed" => "onlyy"}), gone.id)
    end
  end

  describe "the suppressed article is still readable by id over HTTP" do
    test "GET /api/v1/articles/:id returns it with the tombstone rendered", %{conn: conn} do
      {tenant, raw_key, article} = setup_tenant(:agent)
      {:ok, _} = Knowledge.suppress_article(tenant.id, article.id, reason: "under review")

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{article.id}")
        |> json_response(200)

      # This is the endpoint that makes the act reversible in practice: an operator has to be
      # able to read what was suppressed and why before deciding to undo it.
      assert body["data"]["id"] == article.id
      assert body["data"]["suppression_reason"] == "under review"
    end
  end
end
