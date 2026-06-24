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
  alias Loopctl.Knowledge.Article

  setup :verify_on_exit!

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
  end
end
