defmodule LoopctlWeb.AgentMemoryTrustTest do
  @moduledoc """
  #163 — agent-memory write-path identity binding + read-path visibility enforcement.

  Write: an agent may only write a memory under its OWN verified key identity
  (`metadata.agent_id` is stamped from the key, overriding any spoofed value).
  Read: `private`/`owner` memories are visible only to the owning agent; higher
  roles (user/orchestrator) see everything.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  setup :verify_on_exit!

  # 1536-dim vector from a sparse prefix (rest zero-filled), for embedding fixtures.
  defp e(prefix), do: prefix ++ List.duplicate(0.0, 1536 - length(prefix))

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # api_keys.agent_id is a FK to agents, so mint a real agent per key.
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key}
  end

  # Create a memory article via the API and return the parsed response body.
  defp post_memory(conn, raw_key, attrs) do
    conn
    |> auth(raw_key)
    |> post(~p"/api/v1/articles", attrs)
  end

  defp memory_attrs(title, metadata) do
    %{
      "title" => title,
      "body" => "#{title} body text",
      "category" => "finding",
      "metadata" => metadata
    }
  end

  describe "write-path: agent_id binding (#163)" do
    test "stamps metadata.agent_id from the key, overriding a spoofed value", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_a, key_a} = agent_key(tenant.id)
      foreign = Ecto.UUID.generate()

      conn =
        post_memory(
          conn,
          raw_a,
          memory_attrs("SpoofAttempt", %{"agent_id" => foreign, "memory_type" => "finding"})
        )

      body = json_response(conn, 201)
      article = AdminRepo.get!(Article, body["data"]["id"])
      # The spoofed foreign agent_id was overwritten with the caller's verified identity.
      assert article.metadata["agent_id"] == to_string(key_a.agent_id)
      refute article.metadata["agent_id"] == foreign
    end

    test "stamps agent_id when omitted but agent-memory metadata is present", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_a, key_a} = agent_key(tenant.id)

      conn = post_memory(conn, raw_a, memory_attrs("OmittedId", %{"memory_type" => "decision"}))

      body = json_response(conn, 201)
      article = AdminRepo.get!(Article, body["data"]["id"])
      assert article.metadata["agent_id"] == to_string(key_a.agent_id)
    end

    test "an agent key with no identity cannot write a memory (403)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: nil})

      conn = post_memory(conn, raw, memory_attrs("NoIdentity", %{"memory_type" => "finding"}))

      assert json_response(conn, 403)["error"]["code"] == "agent_identity_required"
    end

    test "a higher role may attribute a memory to any agent (not stamped)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_user, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      target_agent = Ecto.UUID.generate()

      conn =
        post_memory(
          conn,
          raw_user,
          memory_attrs("OnBehalf", %{"agent_id" => target_agent, "memory_type" => "summary"})
        )

      body = json_response(conn, 201)
      article = AdminRepo.get!(Article, body["data"]["id"])
      assert article.metadata["agent_id"] == target_agent
    end

    test "a plain (non-memory) article is not stamped with an agent_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_a, _key_a} = agent_key(tenant.id)

      conn =
        conn
        |> auth(raw_a)
        |> post(~p"/api/v1/articles", %{
          "title" => "PlainNote",
          "body" => "no agent-memory markers here",
          "category" => "reference"
        })

      body = json_response(conn, 201)
      article = AdminRepo.get!(Article, body["data"]["id"])
      refute Map.has_key?(article.metadata, "agent_id")
    end

    test "a higher role cannot store a blank agent_id (would be readable by identity-less agents)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_user, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        post_memory(
          conn,
          raw_user,
          memory_attrs("Blank", %{"agent_id" => "", "visibility" => "private"})
        )

      # The changeset rejects a blank agent_id (422), so "" can never be a usable owner.
      assert json_response(conn, 422)
    end
  end

  describe "read-path: visibility enforcement (#163)" do
    setup %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_a, key_a} = agent_key(tenant.id)
      {raw_b, _key_b} = agent_key(tenant.id)
      {raw_user, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Agent A writes a PRIVATE memory and a SHARED memory (both published).
      priv =
        post_memory(conn, raw_a, memory_attrs("ZorptPrivate", %{"visibility" => "private"}))
        |> json_response(201)

      shared =
        post_memory(conn, raw_a, memory_attrs("ZorptShared", %{"visibility" => "shared"}))
        |> json_response(201)

      %{
        tenant: tenant,
        raw_a: raw_a,
        key_a: key_a,
        raw_b: raw_b,
        raw_user: raw_user,
        priv_id: priv["data"]["id"],
        shared_id: shared["data"]["id"]
      }
    end

    defp get_ids(conn, raw_key, path) do
      conn
      |> auth(raw_key)
      |> get(path)
      |> json_response(200)
      |> Map.get("data")
      |> Enum.map(& &1["id"])
    end

    test "private memory is hidden from another agent on get", ctx do
      conn = ctx.conn |> auth(ctx.raw_b) |> get(~p"/api/v1/articles/#{ctx.priv_id}")
      assert json_response(conn, 404)
    end

    test "private memory is excluded from another agent's list / index / search", ctx do
      refute ctx.priv_id in get_ids(ctx.conn, ctx.raw_b, ~p"/api/v1/articles")

      # The index groups `data` by category — flatten it.
      index_ids =
        ctx.conn
        |> auth(ctx.raw_b)
        |> get(~p"/api/v1/knowledge/index?fields=id")
        |> json_response(200)
        |> Map.get("data")
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1["id"])

      refute ctx.priv_id in index_ids

      search_ids =
        ctx.conn
        |> auth(ctx.raw_b)
        |> get(~p"/api/v1/knowledge/search?q=Zorpt")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.map(& &1["id"])

      refute ctx.priv_id in search_ids
      # The shared sibling IS visible to agent B.
      assert ctx.shared_id in search_ids
    end

    test "private memory is excluded from another agent's context", ctx do
      ids =
        ctx.conn
        |> auth(ctx.raw_b)
        |> get(~p"/api/v1/knowledge/context?query=Zorpt")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.map(& &1["id"])

      refute ctx.priv_id in ids
    end

    test "the owning agent still sees its own private memory", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.raw_a) |> get(~p"/api/v1/articles/#{ctx.priv_id}"),
               200
             )

      assert ctx.priv_id in get_ids(ctx.conn, ctx.raw_a, ~p"/api/v1/articles")
    end

    test "the owning agent sees its own private memory in context", ctx do
      ids =
        ctx.conn
        |> auth(ctx.raw_a)
        |> get(~p"/api/v1/knowledge/context?query=Zorpt")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.map(& &1["id"])

      assert ctx.priv_id in ids
    end

    test "shared memory is visible to another agent", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.raw_b) |> get(~p"/api/v1/articles/#{ctx.shared_id}"),
               200
             )

      assert ctx.shared_id in get_ids(ctx.conn, ctx.raw_b, ~p"/api/v1/articles")
    end

    test "a higher role (user) sees another agent's private memory", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.raw_user) |> get(~p"/api/v1/articles/#{ctx.priv_id}"),
               200
             )

      assert ctx.priv_id in get_ids(ctx.conn, ctx.raw_user, ~p"/api/v1/articles")
    end

    test "the owning agent reads its own OWNER-visibility memory; another agent can't", ctx do
      owner_id =
        post_memory(ctx.conn, ctx.raw_a, memory_attrs("ZorptOwner", %{"visibility" => "owner"}))
        |> json_response(201)
        |> get_in(["data", "id"])

      assert json_response(
               ctx.conn |> auth(ctx.raw_a) |> get(~p"/api/v1/articles/#{owner_id}"),
               200
             )

      assert json_response(
               ctx.conn |> auth(ctx.raw_b) |> get(~p"/api/v1/articles/#{owner_id}"),
               404
             )
    end

    test "an identity-less agent sees only shared memories", ctx do
      {raw_noid, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :agent, agent_id: nil})
      ids = get_ids(ctx.conn, raw_noid, ~p"/api/v1/articles")
      assert ctx.shared_id in ids
      refute ctx.priv_id in ids
    end
  end

  # The trust barrier is only as strong as its weakest read path — assert agent A's
  # PRIVATE memory never leaks to agent B through ANY agent-reachable knowledge read.
  describe "cross-endpoint visibility isolation (#163)" do
    setup %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_a, _key_a} = agent_key(tenant.id)
      {raw_b, _key_b} = agent_key(tenant.id)
      %{conn: conn, tenant: tenant, raw_a: raw_a, raw_b: raw_b}
    end

    # tags is a TOP-LEVEL article field (not metadata); visibility lives in metadata.
    defp private_embedded(conn, raw_key, tenant_id, title, vector, tags \\ []) do
      attrs = %{
        "title" => title,
        "body" => "#{title} body text",
        "category" => "finding",
        "tags" => tags,
        "metadata" => %{"visibility" => "private"}
      }

      id = post_memory(conn, raw_key, attrs) |> json_response(201) |> get_in(["data", "id"])

      {:ok, _} = Knowledge.update_embedding(tenant_id, id, e(vector))
      id
    end

    test "count / stats / facets never include another agent's private memory", ctx do
      # Tenant has exactly one article: agent A's private memory tagged `zsecret`.
      _id =
        post_memory(ctx.conn, ctx.raw_a, %{
          "title" => "Secret",
          "body" => "secret body",
          "category" => "finding",
          "tags" => ["zsecret"],
          "metadata" => %{"visibility" => "private"}
        })
        |> json_response(201)

      # count
      assert ctx.conn
             |> auth(ctx.raw_b)
             |> get(~p"/api/v1/knowledge/count")
             |> json_response(200)
             |> Map.get("count") == 0

      assert ctx.conn
             |> auth(ctx.raw_a)
             |> get(~p"/api/v1/knowledge/count")
             |> json_response(200)
             |> Map.get("count") == 1

      # stats (tenant-wide totals)
      assert ctx.conn
             |> auth(ctx.raw_b)
             |> get(~p"/api/v1/knowledge/stats")
             |> json_response(200)
             |> Map.get("total") == 0

      assert ctx.conn
             |> auth(ctx.raw_a)
             |> get(~p"/api/v1/knowledge/stats")
             |> json_response(200)
             |> Map.get("total") == 1

      # facets
      b_facets =
        ctx.conn
        |> auth(ctx.raw_b)
        |> get(~p"/api/v1/knowledge/facets")
        |> json_response(200)
        |> Map.get("data")

      a_facets =
        ctx.conn
        |> auth(ctx.raw_a)
        |> get(~p"/api/v1/knowledge/facets")
        |> json_response(200)
        |> Map.get("data")

      refute Map.has_key?(b_facets, "zsecret")
      assert Map.get(a_facets, "zsecret") == 1
    end

    test "distant_pairs never pairs another agent's private memory", ctx do
      # Two of agent A's private memories, in the default 0.3–0.7 band (distance 0.5).
      private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "P1", [1.0, 0.0])
      private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "P2", [0.5, 0.866])

      assert ctx.conn
             |> auth(ctx.raw_b)
             |> get(~p"/api/v1/knowledge/pairs")
             |> json_response(200)
             |> Map.get("data") == []

      assert length(
               ctx.conn
               |> auth(ctx.raw_a)
               |> get(~p"/api/v1/knowledge/pairs")
               |> json_response(200)
               |> Map.get("data")
             ) == 1
    end

    test "suggest_links never suggests another agent's private memory", ctx do
      # A SHARED, embedded target both agents can query; a PRIVATE candidate owned by A.
      target_id =
        post_memory(ctx.conn, ctx.raw_a, memory_attrs("Target", %{"visibility" => "shared"}))
        |> json_response(201)
        |> get_in(["data", "id"])

      {:ok, _} = Knowledge.update_embedding(ctx.tenant.id, target_id, e([1.0, 0.0]))
      priv_cand = private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "Cand", [1.0, 0.0])

      b_ids =
        ctx.conn
        |> auth(ctx.raw_b)
        |> get(~p"/api/v1/knowledge/articles/#{target_id}/suggested_links")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.map(& &1["id"])

      a_ids =
        ctx.conn
        |> auth(ctx.raw_a)
        |> get(~p"/api/v1/knowledge/articles/#{target_id}/suggested_links")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.map(& &1["id"])

      refute priv_cand in b_ids
      assert priv_cand in a_ids
    end

    test "graph / walk never traverse to another agent's private memory", ctx do
      # Shared start S linked to agent A's private memory P.
      s_id =
        post_memory(ctx.conn, ctx.raw_a, memory_attrs("Start", %{"visibility" => "shared"}))
        |> json_response(201)
        |> get_in(["data", "id"])

      p_id = private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "Hidden", [1.0, 0.0])

      fixture(:article_link, %{
        tenant_id: ctx.tenant.id,
        source_article_id: s_id,
        target_article_id: p_id,
        relationship_type: :relates_to
      })

      graph_b =
        ctx.conn
        |> auth(ctx.raw_b)
        |> get(~p"/api/v1/knowledge/graph?article_id=#{s_id}&depth=2")
        |> json_response(200)

      refute p_id in Enum.map(graph_b["nodes"], & &1["id"])

      walk_b =
        ctx.conn
        |> auth(ctx.raw_b)
        |> get(~p"/api/v1/knowledge/walk?start_id=#{s_id}&length=4")
        |> json_response(200)

      refute p_id in Enum.map(walk_b["data"], & &1["id"])

      # Agent A (owner) reaches it via both walk and graph.
      walk_a =
        ctx.conn
        |> auth(ctx.raw_a)
        |> get(~p"/api/v1/knowledge/walk?start_id=#{s_id}&length=4")
        |> json_response(200)

      assert p_id in Enum.map(walk_a["data"], & &1["id"])

      graph_a =
        ctx.conn
        |> auth(ctx.raw_a)
        |> get(~p"/api/v1/knowledge/graph?article_id=#{s_id}&depth=2")
        |> json_response(200)

      assert p_id in Enum.map(graph_a["nodes"], & &1["id"])
    end

    test "the /links endpoint never leaks a private memory's title to another agent", ctx do
      # Shared S links to agent A's private P; agent B lists S's links.
      s_id =
        post_memory(ctx.conn, ctx.raw_a, memory_attrs("LinkStart", %{"visibility" => "shared"}))
        |> json_response(201)
        |> get_in(["data", "id"])

      p_id = private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "LinkHidden", [1.0, 0.0])

      fixture(:article_link, %{
        tenant_id: ctx.tenant.id,
        source_article_id: s_id,
        target_article_id: p_id,
        relationship_type: :relates_to
      })

      far_ids = fn raw ->
        ctx.conn
        |> auth(raw)
        |> get(~p"/api/v1/articles/#{s_id}/links")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.flat_map(fn l -> [l["source_article"]["id"], l["target_article"]["id"]] end)
      end

      refute p_id in far_ids.(ctx.raw_b)
      assert p_id in far_ids.(ctx.raw_a)
    end

    test "an agent cannot create a link to an article it can't see", ctx do
      # Agent A's private memory; agent B (with its own article) tries to link to it.
      p_id = private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "Unseen", [1.0, 0.0])

      b_article =
        post_memory(ctx.conn, ctx.raw_b, memory_attrs("BOwn", %{"visibility" => "shared"}))
        |> json_response(201)
        |> get_in(["data", "id"])

      # 404 (no existence leak), not a successful link.
      ctx.conn
      |> auth(ctx.raw_b)
      |> post(~p"/api/v1/article_links", %{
        "source_article_id" => b_article,
        "target_article_id" => p_id,
        "relationship_type" => "relates_to"
      })
      |> json_response(404)
    end

    test "the change feed never leaks another agent's private memory body", ctx do
      priv =
        post_memory(ctx.conn, ctx.raw_a, %{
          "title" => "ZorptChangeSecret",
          "body" => "private body in the change feed",
          "category" => "finding",
          "metadata" => %{"visibility" => "private"}
        })
        |> json_response(201)
        |> get_in(["data", "id"])

      changed_ids = fn raw ->
        ctx.conn
        |> auth(raw)
        |> get(~p"/api/v1/changes?since=2020-01-01T00:00:00Z&entity_type=article")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.map(& &1["entity_id"])
      end

      refute priv in changed_ids.(ctx.raw_b)
      assert priv in changed_ids.(ctx.raw_a)
    end

    test "the change feed doesn't leak a private memory's id via an article_link entry", ctx do
      # A link between two of agent A's private memories — agent B must not see the
      # article_link change entry (it carries both private UUIDs).
      p1 = private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "LP1", [1.0, 0.0])
      p2 = private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "LP2", [1.0, 0.0])

      fixture(:article_link, %{
        tenant_id: ctx.tenant.id,
        source_article_id: p1,
        target_article_id: p2,
        relationship_type: :relates_to
      })

      link_state_ids = fn raw ->
        ctx.conn
        |> auth(raw)
        |> get(~p"/api/v1/changes?since=2020-01-01T00:00:00Z&entity_type=article_link")
        |> json_response(200)
        |> Map.get("data")
        |> Enum.flat_map(fn e ->
          [e["new_state"]["source_article_id"], e["new_state"]["target_article_id"]]
        end)
      end

      b_ids = link_state_ids.(ctx.raw_b)
      refute p1 in b_ids
      refute p2 in b_ids
    end

    test "idempotency dedup doesn't reveal another agent's private memory id", ctx do
      # Agent A creates a private memory with a known idempotency_key.
      key = "shared-key-zorpt"

      a_resp =
        post_memory(ctx.conn, ctx.raw_a, %{
          "title" => "IdemPriv",
          "body" => "idem private body",
          "category" => "finding",
          "idempotency_key" => key,
          "metadata" => %{"visibility" => "private"}
        })
        |> json_response(201)

      a_id = a_resp["data"]["id"]

      # Agent B replays the same key — must NOT get back A's private article id;
      # the unique index rejects the write without echoing the private reference.
      b_conn =
        ctx.conn
        |> auth(ctx.raw_b)
        |> post(~p"/api/v1/articles", %{
          "title" => "BProbe",
          "body" => "b body",
          "category" => "finding",
          "idempotency_key" => key
        })

      # B doesn't dedup against A's invisible memory → the unique index rejects the
      # write (422), and A's private id never appears in the response.
      b_body = json_response(b_conn, 422)
      refute inspect(b_body) =~ a_id
    end

    test "novelty priors exclude another agent's private proposals", ctx do
      # Agent A's private proposal; agent B scoring an idea sees no comparable prior.
      private_embedded(ctx.conn, ctx.raw_a, ctx.tenant.id, "Proposal", [1.0, 0.0], ["proposal"])

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _ -> {:ok, e([1.0, 0.0])} end)

      b_meta =
        ctx.conn
        |> auth(ctx.raw_b)
        |> post(~p"/api/v1/knowledge/novelty", %{ideas: [%{text: "x"}]})
        |> json_response(200)
        |> Map.get("meta")

      a_meta =
        ctx.conn
        |> auth(ctx.raw_a)
        |> post(~p"/api/v1/knowledge/novelty", %{ideas: [%{text: "x"}]})
        |> json_response(200)
        |> Map.get("meta")

      assert b_meta["prior_count"] == 0
      assert a_meta["prior_count"] == 1
    end
  end
end
