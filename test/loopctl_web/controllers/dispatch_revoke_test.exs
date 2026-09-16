defmodule LoopctlWeb.DispatchRevokeTest do
  @moduledoc """
  `POST /api/v1/dispatches/:id/revoke` — the reachable half of `Dispatches.revoke/2`.

  Until this route existed the function had no caller outside the app: no route, no MCP
  tool. So a session dispatch whose session died left an ephemeral key that was still
  `revoked_at IS NULL`, OCCUPYING its agent's slot in
  `api_keys_one_role_per_agent_idx` until its TTL — and the index cannot test expiry (a
  partial-index predicate must be IMMUTABLE and `now()` is STABLE), so nothing but a
  revoke frees it. Every later mint for that agent is refused 422 `agent already has an
  active key with this role`, which is the delivery loop stopping.

  The gate is `role: :orchestrator` + `RequireHumanAnchor` + THE LINEAGE CEILING. The
  ceiling is not decoration: `Dispatches.revoke/2` cascades to descendants, so an
  unrestricted revoke lets any orchestrator dispatch take down another principal's whole
  tree — and lets an implementer prune the pool `select_verifier/3` draws from (which
  admits only `is_nil(revoked_at) and expires_at > now`) until the verifier it wants is
  the one left.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp anchored_tenant_ctx(trust_tier \\ :human_anchored) do
    tenant = fixture(:tenant, %{trust_tier: trust_tier})
    {operator_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})
    %{tenant: tenant, operator_key: operator_key, agent: agent}
  end

  # Mint through the API so the lineage is the one the ceiling actually reads.
  defp mint(raw_key, params) do
    build_conn()
    |> auth(raw_key)
    |> post(~p"/api/v1/dispatches", params)
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp mint_root(%{operator_key: operator_key, agent: agent}) do
    mint(operator_key, %{"role" => "orchestrator", "agent_id" => agent.id})
  end

  defp revoke(raw_key, dispatch_id) do
    build_conn()
    |> auth(raw_key)
    |> post(~p"/api/v1/dispatches/#{dispatch_id}/revoke")
  end

  defp reload(id), do: AdminRepo.get!(Dispatch, id)

  defp key_revoked?(dispatch_id) do
    dispatch = reload(dispatch_id)
    not is_nil(AdminRepo.get!(ApiKey, dispatch.api_key_id).revoked_at)
  end

  describe "the operator key revoking its own tenant's tree" do
    test "revokes the dispatch AND the ephemeral key it minted" do
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root} = mint_root(ctx)

      body = revoke(ctx.operator_key, root["id"]) |> json_response(200) |> Map.fetch!("data")

      assert body["revoked_count"] >= 1
      assert body["dispatch"]["revoked_at"]

      assert key_revoked?(root["id"]),
             "the KEY is what holds the one-key-per-role slot; revoking only the " <>
               "dispatch row would leave the slot occupied"
    end

    test "the cascade reaches descendants" do
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root, "api_key" => %{"raw_key" => root_key}} = mint_root(ctx)
      child_agent = fixture(:agent, %{tenant_id: ctx.tenant.id})

      %{"dispatch" => child} =
        mint(root_key, %{
          "role" => "agent",
          "agent_id" => child_agent.id,
          "parent_dispatch_id" => root["id"]
        })

      body = revoke(ctx.operator_key, root["id"]) |> json_response(200) |> Map.fetch!("data")

      assert body["revoked_count"] == 2
      assert reload(child["id"]).revoked_at, "a descendant must be revoked with its ancestor"
      assert key_revoked?(child["id"])
    end

    test "it frees the slot: the agent can be dispatched again" do
      # The behaviour the whole endpoint exists for, asserted end to end rather than as
      # a column value — a `revoked_at` assertion stays green if the index predicate
      # ever stops matching what the revoke writes.
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root} = mint_root(ctx)

      conn =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/dispatches", %{"role" => "orchestrator", "agent_id" => ctx.agent.id})

      assert json_response(conn, 422)

      assert revoke(ctx.operator_key, root["id"]) |> json_response(200)

      assert build_conn()
             |> auth(ctx.operator_key)
             |> post(~p"/api/v1/dispatches", %{
               "role" => "orchestrator",
               "agent_id" => ctx.agent.id
             })
             |> json_response(201)
    end

    test "idempotent: a second revoke answers 200/0 and keeps the original revoked_at" do
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root} = mint_root(ctx)

      first = revoke(ctx.operator_key, root["id"]) |> json_response(200) |> Map.fetch!("data")
      second = revoke(ctx.operator_key, root["id"]) |> json_response(200) |> Map.fetch!("data")

      assert second["revoked_count"] == 0
      assert second["dispatch"]["revoked_at"] == first["dispatch"]["revoked_at"]
    end
  end

  describe "the lineage ceiling" do
    test "a dispatch-minted key may revoke inside its own subtree" do
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root, "api_key" => %{"raw_key" => root_key}} = mint_root(ctx)
      child_agent = fixture(:agent, %{tenant_id: ctx.tenant.id})

      %{"dispatch" => child} =
        mint(root_key, %{
          "role" => "agent",
          "agent_id" => child_agent.id,
          "parent_dispatch_id" => root["id"]
        })

      assert revoke(root_key, child["id"]) |> json_response(200)
      assert reload(child["id"]).revoked_at
    end

    test "it may NOT revoke a dispatch outside its lineage" do
      ctx = anchored_tenant_ctx()

      # Two independent trees under the same tenant, both rooted by the operator key.
      %{"dispatch" => tree_a, "api_key" => %{"raw_key" => a_key}} = mint_root(ctx)
      other_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      %{"dispatch" => tree_b} =
        mint(ctx.operator_key, %{"role" => "orchestrator", "agent_id" => other_agent.id})

      error = revoke(a_key, tree_b["id"]) |> json_response(403) |> Map.fetch!("error")

      assert error["code"] == "dispatch_outside_caller_lineage"
      # The refusal must name a dispatch the refused caller can actually act on.
      assert error["remediation"]["your_dispatch_id"] == tree_a["id"]

      refute reload(tree_b["id"]).revoked_at, "nothing may be revoked on a refused call"
    end
  end

  describe "refusals" do
    test "an agent-role key is 403 insufficient_role" do
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root} = mint_root(ctx)
      agent = fixture(:agent, %{tenant_id: ctx.tenant.id})

      {agent_key, _} =
        fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :agent, agent_id: agent.id})

      error = revoke(agent_key, root["id"]) |> json_response(403) |> Map.fetch!("error")

      assert error["code"] == "insufficient_role"
      refute reload(root["id"]).revoked_at
    end

    test "an agent_rooted tenant is 403 custody_tier_required" do
      ctx = anchored_tenant_ctx(:agent_rooted)

      error =
        revoke(ctx.operator_key, Ecto.UUID.generate())
        |> json_response(403)
        |> Map.fetch!("error")

      assert error["code"] == "custody_tier_required"
    end

    test "an unknown dispatch id is 404" do
      ctx = anchored_tenant_ctx()
      assert revoke(ctx.operator_key, Ecto.UUID.generate()) |> json_response(404)
    end

    test "tenant isolation: another tenant's dispatch is 404, not revoked" do
      ctx_a = anchored_tenant_ctx()
      ctx_b = anchored_tenant_ctx()
      %{"dispatch" => b_root} = mint_root(ctx_b)

      assert revoke(ctx_a.operator_key, b_root["id"]) |> json_response(404)
      refute reload(b_root["id"]).revoked_at
    end
  end

  describe "custody halt" do
    test "the route is classified as custody surface, so a halt suspends it" do
      # `LoopctlWeb.CustodySurface` decides from METHOD + PATH, before any controller
      # runs. A route it does not classify escapes the halt silently — and revocation
      # changes the ACTIVE dispatch set that verifier selection draws from, which is
      # exactly what a halted tenant's actor would want to reshape.
      conn = %Plug.Conn{
        method: "POST",
        path_info: ["api", "v1", "dispatches", Ecto.UUID.generate(), "revoke"]
      }

      assert LoopctlWeb.CustodySurface.custody_operation?(conn)
    end

    test "a halted tenant is refused" do
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root} = mint_root(ctx)
      {:ok, _} = Loopctl.Tenants.halt_custody(ctx.tenant.id)

      error =
        revoke(ctx.operator_key, root["id"]) |> json_response(503) |> Map.fetch!("error")

      assert error["code"] == "tenant_halted"
      refute reload(root["id"]).revoked_at
    end
  end

  describe "custody provenance is untouched" do
    test "a revoked dispatch still resolves, so every L4 lineage comparison is unchanged" do
      ctx = anchored_tenant_ctx()
      %{"dispatch" => root} = mint_root(ctx)

      assert revoke(ctx.operator_key, root["id"]) |> json_response(200)

      assert {:ok, revoked} = Dispatches.get_dispatch(ctx.tenant.id, root["id"])
      assert revoked.lineage_path == root["lineage_path"]
      assert revoked.revoked_at
    end
  end
end
