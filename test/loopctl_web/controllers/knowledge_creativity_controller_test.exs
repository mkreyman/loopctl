defmodule LoopctlWeb.KnowledgeCreativityControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Knowledge

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp setup_tenant_key do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, raw_key}
  end

  # 1536-dim vector from a sparse prefix (rest zero-filled). pgvector `<=>` is
  # cosine *distance* (1 - cosine similarity), range [0, 2]:
  #   e([1,0]) vs e([1,0])         → 0.0   (identical)
  #   e([1,0]) vs e([0.5, 0.866])  → 0.5   (60° apart — inside default 0.3–0.7 band)
  #   e([1,0]) vs e([0,1])         → 1.0   (orthogonal)
  defp e(prefix), do: prefix ++ List.duplicate(0.0, 1536 - length(prefix))

  defp embedded(tenant_id, title, vector, attrs \\ %{}) do
    a =
      fixture(
        :article,
        Map.merge(%{tenant_id: tenant_id, title: title, status: :published}, attrs)
      )

    {:ok, _} = Knowledge.update_embedding(tenant_id, a.id, e(vector))
    a
  end

  defp link(tenant_id, src, dst) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: src.id,
      target_article_id: dst.id,
      relationship_type: :relates_to
    })
  end

  describe "GET /api/v1/knowledge/pairs (#152 A1)" do
    # P–Q and P–U both sit at cosine distance 0.5 (inside the default band);
    # P–T (1.0) and the Q/U cross pairs fall outside it.
    defp band_fixture(tenant_id) do
      p = embedded(tenant_id, "P", [1.0, 0.0])
      q = embedded(tenant_id, "Q", [0.5, 0.866])
      u = embedded(tenant_id, "U", [0.5, -0.866])
      t = embedded(tenant_id, "T", [0.0, 1.0])
      %{p: p, q: q, u: u, t: t}
    end

    defp pair_ids(pair), do: MapSet.new([pair["a"]["id"], pair["b"]["id"]])

    test "returns only pairs whose cosine distance is inside the band", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      %{p: p, q: q, u: u} = band_fixture(tenant.id)

      body =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/pairs")
        |> json_response(200)

      pairs = body["data"]
      assert body["meta"]["count"] == length(pairs)
      # P–Q and P–U
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["has_more"] == false
      # Exactly the two in-band pairs P–Q and P–U; nothing involving T.
      assert MapSet.new(Enum.map(pairs, &pair_ids/1)) ==
               MapSet.new([MapSet.new([p.id, q.id]), MapSet.new([p.id, u.id])])

      assert Enum.all?(pairs, fn pr -> pr["distance"] >= 0.3 and pr["distance"] <= 0.7 end)
      # Each side carries id/title/category.
      [first | _] = pairs
      assert first["a"]["title"]
      assert first["a"]["category"]
    end

    test "honors a custom band", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      band_fixture(tenant.id)

      # A narrow band around 1.0 keeps only the orthogonal P–T pair.
      body =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/pairs?min_distance=0.9&max_distance=1.1")
        |> json_response(200)

      assert Enum.all?(body["data"], fn pr -> pr["distance"] >= 0.9 and pr["distance"] <= 1.1 end)
      assert length(body["data"]) == 1
    end

    test "bridge_path=true keeps only graph-connected pairs", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      %{p: p, q: q} = band_fixture(tenant.id)
      link(tenant.id, p, q)

      body =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/pairs?bridge_path=true")
        |> json_response(200)

      # P–U is in-band but unlinked → excluded; only the linked P–Q survives.
      assert Enum.map(body["data"], &pair_ids/1) == [MapSet.new([p.id, q.id])]
    end

    test "paginates deterministically with limit/offset", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      band_fixture(tenant.id)

      page1 =
        conn |> auth_conn(key) |> get(~p"/api/v1/knowledge/pairs?limit=1") |> json_response(200)

      page2 =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/pairs?limit=1&offset=1")
        |> json_response(200)

      assert length(page1["data"]) == 1
      assert page1["meta"]["has_more"] == true
      assert length(page2["data"]) == 1
      assert page2["meta"]["has_more"] == false
      assert pair_ids(hd(page1["data"])) != pair_ids(hd(page2["data"]))
    end

    test "invalid band → 400", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()

      resp =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/pairs?min_distance=0.8&max_distance=0.2")
        |> json_response(400)

      assert resp["error"]["message"] =~ "distance"
    end

    test "non-numeric distance → 400", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()

      resp =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/pairs?min_distance=abc")
        |> json_response(400)

      assert resp["error"]["message"] =~ "numbers"
    end

    test "tenant isolation: another tenant's articles never pair", %{conn: conn} do
      {tenant_a, key_a} = setup_tenant_key()
      embedded(tenant_a.id, "A-only", [1.0, 0.0])

      tenant_b = fixture(:tenant)
      band_fixture(tenant_b.id)

      body =
        conn |> auth_conn(key_a) |> get(~p"/api/v1/knowledge/pairs") |> json_response(200)

      # Tenant A has a single embedded article → no pairs; B's pairs are invisible.
      assert body["data"] == []
    end
  end

  describe "POST /api/v1/knowledge/novelty (#152 A2)" do
    # Map idea text → a controllable embedding so novelty is deterministic.
    defp stub_idea_embeddings(mapping) do
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn text ->
        {:ok, e(Map.get(mapping, text, [0.0, 0.0]))}
      end)
    end

    test "scores each idea by distance to the nearest prior proposal", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      # A single prior proposal at e([1,0]).
      embedded(tenant.id, "Prior", [1.0, 0.0], %{tags: ["proposal"]})

      stub_idea_embeddings(%{
        "identical" => [1.0, 0.0],
        "orthogonal" => [0.0, 1.0]
      })

      body =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/knowledge/novelty", %{
          ideas: [%{text: "identical"}, %{text: "orthogonal"}]
        })
        |> json_response(200)

      [a, b] = body["data"]
      assert_in_delta a["novelty_score"], 0.0, 1.0e-4
      assert_in_delta b["novelty_score"], 1.0, 1.0e-4
    end

    test "no priors → nil novelty score (distinguishable from high score)", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()
      stub_idea_embeddings(%{"anything" => [1.0, 0.0]})

      body =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/knowledge/novelty", %{ideas: [%{text: "anything"}]})
        |> json_response(200)

      assert [%{"novelty_score" => nil}] = body["data"]
    end

    test "blank idea text skips embedding and returns nil (no API waste)", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      embedded(tenant.id, "Prior", [1.0, 0.0], %{tags: ["proposal"]})

      # Expect NO embedding calls for blank ideas (would be called for non-blank)
      Mox.expect(Loopctl.MockEmbeddingClient, :generate_embedding, 0, fn _ ->
        {:ok, e([1.0, 0.0])}
      end)

      body =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/knowledge/novelty", %{
          ideas: [
            %{text: ""},
            %{title: "", spark: "", thesis: ""}
          ]
        })
        |> json_response(200)

      # Both ideas are blank → no embeddings called, both score nil
      assert [%{"novelty_score" => nil}, %{"novelty_score" => nil}] = body["data"]
    end

    test "prior_tag selects a different prior family", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      # Prior tagged `proposal` is ignored when prior_tag=hypothesis is requested.
      embedded(tenant.id, "Proposal", [1.0, 0.0], %{tags: ["proposal"]})
      stub_idea_embeddings(%{"idea" => [1.0, 0.0]})

      body =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/knowledge/novelty", %{
          ideas: [%{text: "idea"}],
          prior_tag: "hypothesis"
        })
        |> json_response(200)

      # No `hypothesis`-tagged priors → nil novelty score.
      assert [%{"novelty_score" => nil}] = body["data"]
    end

    test "empty / non-array ideas → 400" do
      {_tenant, key} = setup_tenant_key()

      for payload <- [%{ideas: []}, %{ideas: "nope"}, %{}] do
        resp =
          build_conn()
          |> auth_conn(key)
          |> post(~p"/api/v1/knowledge/novelty", payload)
          |> json_response(400)

        assert resp["error"]["message"] =~ "ideas"
      end
    end

    test "more than 50 ideas → 400", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()
      ideas = for i <- 1..51, do: %{text: "idea #{i}"}

      resp =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/knowledge/novelty", %{ideas: ideas})
        |> json_response(400)

      assert resp["error"]["message"] =~ "50"
    end

    test "response includes prior_count in meta", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      # Create 3 prior proposals.
      for i <- 1..3 do
        embedded(tenant.id, "Prior #{i}", [1.0, 0.0], %{tags: ["proposal"]})
      end

      stub_idea_embeddings(%{"idea" => [1.0, 0.0]})

      body =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/knowledge/novelty", %{ideas: [%{text: "idea"}]})
        |> json_response(200)

      assert body["meta"]["prior_count"] == 3
    end
  end

  describe "GET /api/v1/knowledge/walk (#152 A3)" do
    test "walks the link graph without revisiting nodes", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      a = embedded(tenant.id, "A", [1.0])
      b = embedded(tenant.id, "B", [1.0])
      c = embedded(tenant.id, "C", [1.0])
      link(tenant.id, a, b)
      link(tenant.id, b, c)

      body =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/walk?start_id=#{a.id}&length=4")
        |> json_response(200)

      # Linear chain A→B→C: deterministic, dead-ends at C, no revisit of A.
      assert Enum.map(body["data"], & &1["id"]) == [a.id, b.id, c.id]
      assert body["meta"]["count"] == 3
    end

    test "stops at a dead end / start with no neighbors returns just the start", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      a = embedded(tenant.id, "Lonely", [1.0])

      body =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/walk?start_id=#{a.id}")
        |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [a.id]
    end

    test "never revisits across a bidirectional link", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      a = embedded(tenant.id, "A", [1.0])
      b = embedded(tenant.id, "B", [1.0])
      link(tenant.id, a, b)
      link(tenant.id, b, a)

      body =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/walk?start_id=#{a.id}&length=10")
        |> json_response(200)

      # A↔B both directions, but A is already visited → walk is [A, B], not a loop.
      assert Enum.map(body["data"], & &1["id"]) == [a.id, b.id]
    end

    test "nonexistent or draft start → 404", %{conn: conn} do
      {tenant, key} = setup_tenant_key()

      conn
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/walk?start_id=#{Ecto.UUID.generate()}")
      |> json_response(404)

      draft = fixture(:article, %{tenant_id: tenant.id, title: "Draft", status: :draft})

      build_conn()
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/walk?start_id=#{draft.id}")
      |> json_response(404)
    end

    test "missing or invalid start_id → 400", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()

      assert conn
             |> auth_conn(key)
             |> get(~p"/api/v1/knowledge/walk")
             |> json_response(400)
             |> get_in(["error", "message"]) =~ "start_id"

      assert build_conn()
             |> auth_conn(key)
             |> get(~p"/api/v1/knowledge/walk?start_id=not-a-uuid")
             |> json_response(400)
             |> get_in(["error", "message"]) =~ "UUID"
    end

    test "tenant isolation: another tenant's article is not found", %{conn: conn} do
      {_tenant_a, key_a} = setup_tenant_key()
      tenant_b = fixture(:tenant)
      b = embedded(tenant_b.id, "B", [1.0])

      conn
      |> auth_conn(key_a)
      |> get(~p"/api/v1/knowledge/walk?start_id=#{b.id}")
      |> json_response(404)
    end
  end
end
