defmodule LoopctlWeb.DispatchLineageCeilingTest do
  @moduledoc """
  The lineage ceiling on `POST /api/v1/dispatches`: a caller may only mint inside its
  OWN subtree.

  A parentless dispatch starts a new lineage tree that shares no root with anything
  else, which is exactly the shape the L4 custody gates read as "an unrelated
  principal". A caller able to mint one on demand can hand itself separation from its
  own work, so only the tenant's OPERATOR key — a `user`-role key that no dispatch
  minted, rooted in the human anchor — may start a tree. Naming someone else's dispatch
  as parent is the same escape one step out, since every dispatch id is enumerable.

  "Operator" is a POSITIVE test, not the absence of a lineage: `lineage_for_api_key/2`
  also returns [] for a legacy long-lived `:orchestrator` key, and treating that as the
  operator left it able to hand itself an independently-rooted dispatch.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # `:create` is orchestrator-role+ and human-anchored. The operator key is the
  # `role: :user` key the signup ceremony mints — no dispatch minted it, so its
  # lineage is [].
  defp operator_ctx do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {operator_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})
    %{tenant: tenant, operator_key: operator_key, agent: agent}
  end

  defp mint_root(%{operator_key: operator_key, agent: agent}) do
    build_conn()
    |> auth(operator_key)
    |> post(~p"/api/v1/dispatches", %{"role" => "orchestrator", "agent_id" => agent.id})
    |> json_response(201)
    |> Map.fetch!("data")
  end

  describe "root minting" do
    test "an operator key (no lineage of its own) may start a tree" do
      ctx = operator_ctx()

      data = mint_root(ctx)

      assert [root_id] = data["dispatch"]["lineage_path"]
      assert root_id == data["dispatch"]["id"]
      assert is_nil(data["dispatch"]["parent_dispatch_id"])
    end

    test "a dispatch-minted key may NOT start a second, independent tree" do
      ctx = operator_ctx()
      %{"dispatch" => root, "api_key" => %{"raw_key" => dispatched_key}} = mint_root(ctx)

      conn =
        build_conn()
        |> auth(dispatched_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "orchestrator",
          "agent_id" => ctx.agent.id
        })

      error = json_response(conn, 403)["error"]
      assert error["code"] == "root_dispatch_forbidden"

      # The refusal tells the caller to mint under its OWN dispatch, so it has to be
      # able to name it. Nothing else on this API identifies which row is the caller's.
      assert error["remediation"]["your_dispatch_id"] == root["id"]
    end

    test "a LEGACY orchestrator key is not the operator and may NOT start a tree" do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {legacy_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      conn =
        build_conn()
        |> auth(legacy_key)
        |> post(~p"/api/v1/dispatches", %{"role" => "orchestrator", "agent_id" => agent.id})

      assert json_response(conn, 403)["error"]["code"] == "root_dispatch_forbidden"
    end
  end

  describe "parent minting" do
    test "a dispatch-minted key may mint beneath its own dispatch" do
      ctx = operator_ctx()
      %{"dispatch" => root, "api_key" => %{"raw_key" => dispatched_key}} = mint_root(ctx)

      conn =
        build_conn()
        |> auth(dispatched_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => ctx.agent.id,
          "parent_dispatch_id" => root["id"]
        })

      data = json_response(conn, 201)["data"]
      root_id = root["id"]
      child_id = data["dispatch"]["id"]

      assert data["dispatch"]["lineage_path"] == [root_id, child_id]
      assert data["dispatch"]["parent_dispatch_id"] == root_id
    end

    test "a dispatch-minted key may NOT parent under a different root" do
      ctx = operator_ctx()
      %{"api_key" => %{"raw_key" => dispatched_key}} = mint_root(ctx)

      # A second, unrelated tree the operator started (a distinct agent: one agent may
      # hold only one active key per role). Its id is readable by any agent key in the
      # tenant, which is why naming it as parent has to be refused here.
      second_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})
      %{"dispatch" => other_root} = mint_root(%{ctx | agent: second_agent})

      conn =
        build_conn()
        |> auth(dispatched_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => ctx.agent.id,
          "parent_dispatch_id" => other_root["id"]
        })

      assert json_response(conn, 403)["error"]["code"] == "parent_outside_caller_lineage"
    end

    test "an operator key may still parent anywhere in its own tenant" do
      ctx = operator_ctx()
      %{"dispatch" => root} = mint_root(ctx)

      conn =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => ctx.agent.id,
          "parent_dispatch_id" => root["id"]
        })

      assert json_response(conn, 201)["data"]["dispatch"]["parent_dispatch_id"] == root["id"]
    end

    test "tenant isolation: another tenant's dispatch is not a usable parent" do
      ctx = operator_ctx()
      other = operator_ctx()
      %{"dispatch" => foreign_root} = mint_root(other)

      conn =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/dispatches", %{
          "role" => "agent",
          "agent_id" => ctx.agent.id,
          "parent_dispatch_id" => foreign_root["id"]
        })

      assert json_response(conn, 404)
    end
  end
end
