defmodule LoopctlWeb.ApiKeyLineageCeilingTest do
  @moduledoc """
  The lineage ceiling has to hold across EVERY way of obtaining a credential, not just
  `POST /api/v1/dispatches`.

  A plain API key was minted by no dispatch, so `Dispatches.lineage_for_api_key/2`
  resolves it to `[]` — the same shape `DispatchController` admits as "may start a new
  root". A dispatch-minted `:user`-role key could therefore mint (or rotate itself) a
  plain key and, holding it, start the independent tree the ceiling had just refused it.

  So the two raw-key-minting actions — `create` and `rotate` — are refused to a caller
  that carries a lineage of its own. The operator key, which has none, is unaffected.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # The tenant's operator key: `role: :user`, minted by the signup ceremony rather than
  # by a dispatch, so its lineage is [].
  defp operator_ctx do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {operator_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})
    %{tenant: tenant, operator_key: operator_key, agent: agent}
  end

  # A dispatch minted at `:user` role — the highest a dispatch may carry, and the only
  # role that clears `RequireRole, role: :user` on this controller. Without the ceiling
  # plug this key is the whole exploit.
  defp dispatched_user_key(ctx) do
    build_conn()
    |> auth(ctx.operator_key)
    |> post(~p"/api/v1/dispatches", %{"role" => "user", "agent_id" => ctx.agent.id})
    |> json_response(201)
    |> Map.fetch!("data")
  end

  describe "create" do
    test "the operator key may still mint a plain API key" do
      ctx = operator_ctx()

      conn =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "ci", "role" => "agent"})

      assert json_response(conn, 201)["api_key"]["raw_key"]
    end

    test "a dispatch-minted key may NOT mint one" do
      ctx = operator_ctx()
      %{"dispatch" => dispatch, "api_key" => %{"raw_key" => raw_key}} = dispatched_user_key(ctx)

      conn =
        build_conn()
        |> auth(raw_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "escape-hatch", "role" => "orchestrator"})

      error = json_response(conn, 403)["error"]
      assert error["code"] == "api_key_mint_forbidden"

      # The remedy has to be one the refused caller can perform, and it can only mint
      # beneath a dispatch it can name.
      assert error["remediation"]["your_dispatch_id"] == dispatch["id"]
      assert error["message"] =~ "parent_dispatch_id"
    end

    test "the escape is closed end to end: no plain key, so no independent root" do
      ctx = operator_ctx()
      %{"api_key" => %{"raw_key" => raw_key}} = dispatched_user_key(ctx)

      # Step 1 of the exploit — mint a lineage-free key — is refused...
      assert build_conn()
             |> auth(raw_key)
             |> post(~p"/api/v1/api_keys", %{"name" => "escape-hatch", "role" => "user"})
             |> json_response(403)

      # ...and step 2, which that key would have made possible, is still refused on the
      # credential the caller actually holds.
      assert build_conn()
             |> auth(raw_key)
             |> post(~p"/api/v1/dispatches", %{"role" => "agent", "agent_id" => ctx.agent.id})
             |> json_response(403)
             |> get_in(["error", "code"]) == "root_dispatch_forbidden"
    end
  end

  describe "rotate" do
    test "the operator key may still rotate a key" do
      ctx = operator_ctx()
      {_raw, target} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :agent})

      conn =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/api_keys/#{target.id}/rotate", %{})

      assert json_response(conn, 201)["new_key"]["raw_key"]
    end

    test "a dispatch-minted key may NOT rotate its way to a lineage-free credential" do
      ctx = operator_ctx()
      %{"api_key" => %{"raw_key" => raw_key}} = dispatched_user_key(ctx)
      {_raw, target} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator})

      conn =
        build_conn()
        |> auth(raw_key)
        |> post(~p"/api/v1/api_keys/#{target.id}/rotate", %{})

      assert json_response(conn, 403)["error"]["code"] == "api_key_mint_forbidden"
    end
  end

  describe "reads" do
    test "listing keys is not a mint and stays available to a lineaged caller" do
      ctx = operator_ctx()
      %{"api_key" => %{"raw_key" => raw_key}} = dispatched_user_key(ctx)

      conn =
        build_conn()
        |> auth(raw_key)
        |> get(~p"/api/v1/api_keys")

      assert is_list(json_response(conn, 200)["api_keys"])
    end
  end

  describe "tenant isolation" do
    test "another tenant's dispatch does not lineage-bind this tenant's operator key" do
      ctx = operator_ctx()
      other = operator_ctx()
      _ = dispatched_user_key(other)

      conn =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "ci", "role" => "agent"})

      assert json_response(conn, 201)["api_key"]["raw_key"]
    end
  end
end
