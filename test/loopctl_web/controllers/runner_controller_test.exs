defmodule LoopctlWeb.RunnerControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Runners

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp operator_ctx do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {operator_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    %{tenant: tenant, operator_key: operator_key}
  end

  describe "POST /api/v1/runners" do
    test "enrolls a runner and returns its token once", %{conn: conn} do
      ctx = operator_ctx()

      body =
        conn
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/runners", %{"name" => "minis"})
        |> json_response(201)

      assert body["runner"]["name"] == "minis"
      assert is_nil(body["runner"]["revoked_at"])
      refute Map.has_key?(body["runner"], "api_key_id")

      assert {:ok, %{runner: runner}} = Runners.authenticate(body["token"])
      assert runner.id == body["runner"]["id"]
    end

    test "422 on a malformed or duplicate name", %{conn: conn} do
      ctx = operator_ctx()
      authed = auth(conn, ctx.operator_key)

      assert json_response(post(authed, ~p"/api/v1/runners", %{"name" => "Bad Name"}), 422)
      assert json_response(post(authed, ~p"/api/v1/runners", %{"name" => "minis"}), 201)
      assert json_response(post(authed, ~p"/api/v1/runners", %{"name" => "minis"}), 422)
    end

    test "403 for orchestrator and agent keys", %{conn: conn} do
      ctx = operator_ctx()

      for role <- [:orchestrator, :agent] do
        {raw, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: role})

        assert conn
               |> auth(raw)
               |> post(~p"/api/v1/runners", %{"name" => "minis-#{role}"})
               |> json_response(403)
      end
    end

    test "403 custody_tier_required for an agent-rooted tenant, on enroll and revoke",
         %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      {_token, runner} = fixture(:runner, %{tenant_id: tenant.id})
      authed = auth(conn, raw)

      for resp <- [
            post(authed, ~p"/api/v1/runners", %{"name" => "minis"}),
            delete(authed, ~p"/api/v1/runners/#{runner.id}")
          ] do
        assert json_response(resp, 403)["error"]["code"] == "custody_tier_required"
      end

      assert [_still_active] = Runners.list_runners(tenant.id)
      assert json_response(get(authed, ~p"/api/v1/runners"), 200)
    end

    test "403 api_key_mint_forbidden for a dispatch-minted key", %{conn: conn} do
      ctx = operator_ctx()
      agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      %{"api_key" => %{"raw_key" => dispatched_key}} =
        build_conn()
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/dispatches", %{"role" => "user", "agent_id" => agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      body =
        conn
        |> auth(dispatched_key)
        |> post(~p"/api/v1/runners", %{"name" => "escape"})
        |> json_response(403)

      assert body["error"]["code"] == "api_key_mint_forbidden"
      assert Runners.list_runners(ctx.tenant.id) == []
    end
  end

  describe "POST /api/v1/api_keys/:id/rotate on a runner's key" do
    test "422, and the runner keeps its one working key", %{conn: conn} do
      ctx = operator_ctx()
      {raw, runner} = fixture(:runner, %{tenant_id: ctx.tenant.id})

      body =
        conn
        |> auth(ctx.operator_key)
        |> post(~p"/api/v1/api_keys/#{runner.api_key_id}/rotate", %{})
        |> json_response(422)

      assert body["error"]["message"] =~ "belongs to a runner"
      assert {:ok, _} = Runners.authenticate(raw)
    end
  end

  describe "GET /api/v1/runners" do
    test "lists active runners, and revoked ones on request", %{conn: conn} do
      ctx = operator_ctx()
      {_raw, active} = fixture(:runner, %{tenant_id: ctx.tenant.id, name: "minis"})
      {_raw, gone} = fixture(:runner, %{tenant_id: ctx.tenant.id, name: "blockit"})
      {:ok, _} = Runners.revoke_runner(ctx.tenant.id, gone.id)

      authed = auth(conn, ctx.operator_key)

      assert [%{"id" => id}] = json_response(get(authed, ~p"/api/v1/runners"), 200)["runners"]
      assert id == active.id

      all = json_response(get(authed, ~p"/api/v1/runners?include_revoked=true"), 200)["runners"]
      assert length(all) == 2
    end
  end

  describe "DELETE /api/v1/runners/:id" do
    test "revokes the runner so its token no longer authenticates", %{conn: conn} do
      ctx = operator_ctx()
      {raw, runner} = fixture(:runner, %{tenant_id: ctx.tenant.id})

      body =
        conn
        |> auth(ctx.operator_key)
        |> delete(~p"/api/v1/runners/#{runner.id}")
        |> json_response(200)

      assert body["runner"]["revoked_at"]
      assert {:error, _} = Runners.authenticate(raw)
    end

    test "404 for another tenant's runner, which stays active", %{conn: conn} do
      ctx = operator_ctx()
      {raw_other, other} = fixture(:runner, %{})

      assert conn
             |> auth(ctx.operator_key)
             |> delete(~p"/api/v1/runners/#{other.id}")
             |> json_response(404)

      assert {:ok, _} = Runners.authenticate(raw_other)
    end
  end
end
