defmodule LoopctlWeb.KnowledgeSuggestLinksControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleLink

  import Ecto.Query

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp setup_tenant_key do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, raw_key}
  end

  # 1536-dim vector from a sparse prefix (rest zero-filled). Cosine is magnitude-
  # independent: e([1.0]) vs e([1.0]) = 1; vs e([1.0, 1.0]) = 1/√2 ≈ 0.707; vs
  # e([0.0, 1.0]) = 0.
  defp e(prefix), do: prefix ++ List.duplicate(0.0, 1536 - length(prefix))

  defp embedded(tenant_id, title, vector, status \\ :published) do
    a = fixture(:article, %{tenant_id: tenant_id, title: title, status: status})
    {:ok, _} = Knowledge.update_embedding(tenant_id, a.id, e(vector))
    a
  end

  defp suggest(conn, key, id, query \\ %{}) do
    conn
    |> auth_conn(key)
    |> get(~p"/api/v1/knowledge/articles/#{id}/suggested_links?#{query}")
    |> json_response(200)
  end

  defp ids(body), do: Enum.map(body["data"], & &1["id"])

  describe "GET /api/v1/knowledge/articles/:id/suggested_links (#150)" do
    # #168 regression: the endpoint 500'd in production because the target's stored
    # vector was round-tripped back in as a `^param::vector`. The query now does the
    # cosine column-to-column via a self-join. This guards the end-to-end HTTP path
    # (controller → query → JSON) returns 200 with the documented candidate shape.
    test "returns 200 with ranked candidate shape (no 500) — #168", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target168", [1.0, 0.0])
      c1 = embedded(tenant.id, "Cand1", [1.0, 0.0])
      c2 = embedded(tenant.id, "Cand2", [0.9, 0.1])

      conn =
        conn |> auth_conn(key) |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")

      # The key assertion: a clean 200, never a 500.
      body = json_response(conn, 200)
      returned = ids(body)
      assert c1.id in returned
      assert c2.id in returned
      refute target.id in returned

      for cand <- body["data"] do
        assert is_binary(cand["id"])
        assert is_binary(cand["title"])
        assert cand["category"]
        assert is_number(cand["similarity_score"])
        assert cand["similarity_score"] >= 0.5
      end
    end

    test "returns candidates ranked by similarity, highest first, excluding below-threshold",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      identical = embedded(tenant.id, "Identical", [1.0])
      medium = embedded(tenant.id, "Medium", [1.0, 1.0])
      _orthogonal = embedded(tenant.id, "Orthogonal", [0.0, 1.0])

      body = suggest(conn, key, target.id)

      # orthogonal (cosine 0) is below the 0.5 default threshold → excluded.
      assert ids(body) == [identical.id, medium.id]
      # similarity_score present and descending; carries id/title/category.
      [first, second] = body["data"]
      assert first["similarity_score"] >= second["similarity_score"]
      assert first["title"] == "Identical"
      assert first["category"]
    end

    test "excludes the article itself and any already-linked article (either direction)",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      linked = embedded(tenant.id, "Linked", [1.0])
      free = embedded(tenant.id, "Free", [1.0])

      # Existing link target→linked (any type) must exclude `linked`.
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: target.id,
        target_article_id: linked.id,
        relationship_type: :derived_from
      })

      body = suggest(conn, key, target.id)

      assert target.id not in ids(body)
      assert linked.id not in ids(body)
      assert free.id in ids(body)
    end

    test "is read-only — creates no links", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      _candidate = embedded(tenant.id, "Candidate", [1.0])

      before =
        AdminRepo.aggregate(from(l in ArticleLink, where: l.tenant_id == ^tenant.id), :count, :id)

      _ = suggest(conn, key, target.id)

      after_count =
        AdminRepo.aggregate(from(l in ArticleLink, where: l.tenant_id == ^tenant.id), :count, :id)

      assert before == 0
      assert after_count == 0
    end

    test "honors limit and threshold", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      embedded(tenant.id, "C1", [1.0])
      embedded(tenant.id, "C2", [1.0])
      embedded(tenant.id, "C3", [1.0])

      assert length(ids(suggest(conn, key, target.id, %{limit: 1}))) == 1

      # threshold 0.99 still keeps the identical (cosine 1) candidates.
      assert length(ids(suggest(conn, key, target.id, %{threshold: "0.99"}))) == 3
    end

    test "excludes draft candidates (published-only)", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      _draft = embedded(tenant.id, "Draft Candidate", [1.0], :draft)

      assert ids(suggest(conn, key, target.id)) == []
    end

    test "a published article with no embedding returns an empty list", %{conn: conn} do
      {tenant, key} = setup_tenant_key()

      target =
        fixture(:article, %{tenant_id: tenant.id, title: "No Embedding", status: :published})

      assert ids(suggest(conn, key, target.id)) == []
    end

    test "nonexistent or draft target returns 404", %{conn: conn} do
      {tenant, key} = setup_tenant_key()

      conn
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/articles/#{Ecto.UUID.generate()}/suggested_links")
      |> json_response(404)

      draft = fixture(:article, %{tenant_id: tenant.id, title: "Draft", status: :draft})

      build_conn()
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/articles/#{draft.id}/suggested_links")
      |> json_response(404)
    end

    test "invalid threshold returns 400", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])

      resp =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links?threshold=2")
        |> json_response(400)

      assert resp["error"]["message"] =~ "threshold"
    end

    test "tenant isolation: another tenant's article is not found", %{conn: conn} do
      {_tenant_a, key_a} = setup_tenant_key()
      tenant_b = fixture(:tenant)
      b = embedded(tenant_b.id, "B", [1.0])

      conn
      |> auth_conn(key_a)
      |> get(~p"/api/v1/knowledge/articles/#{b.id}/suggested_links")
      |> json_response(404)
    end
  end
end
