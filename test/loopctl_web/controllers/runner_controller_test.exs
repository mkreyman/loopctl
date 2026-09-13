defmodule LoopctlWeb.RunnerControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Runners
  alias Loopctl.Runners.Presence

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
      assert body["runner"]["max_sessions"] == 2
      assert body["runner"]["in_flight"] == 0
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

    test "takes max_sessions, and 422 when it is out of range", %{conn: conn} do
      ctx = operator_ctx()
      authed = auth(conn, ctx.operator_key)

      assert json_response(
               post(authed, ~p"/api/v1/runners", %{"name" => "big", "max_sessions" => 65}),
               422
             )

      body =
        json_response(
          post(authed, ~p"/api/v1/runners", %{"name" => "small", "max_sessions" => 1}),
          201
        )

      assert body["runner"]["max_sessions"] == 1
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

  describe "GET /api/v1/runners/pool" do
    # Tracks a runner in its tenant's pool the way RunnerChannel does, against a stand-in
    # process: the entry lives exactly as long as that process.
    defp track_runner(runner, overrides \\ %{}) do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      meta =
        Map.merge(
          %{
            contract_version: "1.0",
            machine: runner.name,
            cores: 16,
            memory_mb: 28_000,
            repos: ["mkreyman/loopctl"],
            max_sessions: 2,
            in_flight: 1,
            draining: false,
            joined_at: DateTime.utc_now(),
            runner_id: runner.id
          },
          overrides
        )

      {:ok, _ref} = Presence.track(pid, Runners.pool_topic(runner.tenant_id), runner.name, meta)
      pid
    end

    test "returns a connected runner with its meta and latest sample", %{conn: conn} do
      ctx = operator_ctx()

      {_raw, runner} =
        fixture(:runner, %{tenant_id: ctx.tenant.id, name: "minis", max_sessions: 3})

      sample = %{
        sampled_at: "2026-09-12T10:00:00Z",
        loadavg_1m: 0.5,
        free_ram_mb: 12_000,
        free_disk_mb: 400_000
      }

      track_runner(runner, %{sample: sample, node: "loopctl@10.0.0.7", machine_id: "d8d9e2a1"})

      assert %{"runners" => [entry]} =
               conn
               |> auth(ctx.operator_key)
               |> get(~p"/api/v1/runners/pool")
               |> json_response(200)

      assert entry["machine"] == "minis"
      assert entry["runner_id"] == runner.id
      # Capacity is Postgres's; what the runner reported is kept apart as a hint.
      assert entry["in_flight"] == 0
      assert entry["max_sessions"] == 3
      assert entry["reported_in_flight"] == 1
      assert entry["reported_max_sessions"] == 2
      assert entry["draining"] == false
      assert entry["live_sockets"] == 1
      assert {:ok, _, _} = DateTime.from_iso8601(entry["joined_at"])
      assert entry["sample"]["free_ram_mb"] == 12_000
      assert entry["node"] == "loopctl@10.0.0.7"
      assert entry["machine_id"] == "d8d9e2a1"
    end

    test "is empty when no runner is connected, and a sample is null until reported",
         %{conn: conn} do
      ctx = operator_ctx()
      authed = auth(conn, ctx.operator_key)
      {_raw, runner} = fixture(:runner, %{tenant_id: ctx.tenant.id, name: "blockit"})

      assert json_response(get(authed, ~p"/api/v1/runners/pool"), 200) == %{"runners" => []}

      track_runner(runner)

      assert %{"runners" => [%{"machine" => "blockit", "sample" => nil}]} =
               json_response(get(authed, ~p"/api/v1/runners/pool"), 200)
    end

    test "surfaces two live sockets on one credential and shows the newest", %{conn: conn} do
      ctx = operator_ctx()
      {_raw, runner} = fixture(:runner, %{tenant_id: ctx.tenant.id, name: "mac-mini"})

      track_runner(runner, %{joined_at: ~U[2026-09-12 09:00:00Z], in_flight: 0})
      track_runner(runner, %{joined_at: ~U[2026-09-12 10:00:00Z], in_flight: 2})

      assert %{"runners" => [entry]} =
               conn
               |> auth(ctx.operator_key)
               |> get(~p"/api/v1/runners/pool")
               |> json_response(200)

      assert entry["live_sockets"] == 2
      assert entry["reported_in_flight"] == 2
      assert entry["joined_at"] == "2026-09-12T10:00:00Z"
    end

    test "is tenant-scoped: another tenant's key sees none of this tenant's runners" do
      ctx_a = operator_ctx()
      ctx_b = operator_ctx()
      {_raw, runner_a} = fixture(:runner, %{tenant_id: ctx_a.tenant.id, name: "minis"})
      {_raw, runner_b} = fixture(:runner, %{tenant_id: ctx_b.tenant.id, name: "nuc"})
      track_runner(runner_a)
      track_runner(runner_b)

      machines = fn raw_key ->
        build_conn()
        |> auth(raw_key)
        |> get(~p"/api/v1/runners/pool")
        |> json_response(200)
        |> Map.fetch!("runners")
        |> Enum.map(& &1["machine"])
      end

      assert machines.(ctx_a.operator_key) == ["minis"]
      assert machines.(ctx_b.operator_key) == ["nuc"]
    end

    test "403 for orchestrator and agent keys", %{conn: conn} do
      ctx = operator_ctx()
      {_raw, runner} = fixture(:runner, %{tenant_id: ctx.tenant.id, name: "minis"})
      track_runner(runner)

      for role <- [:orchestrator, :agent] do
        {raw, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: role})

        body =
          conn
          |> auth(raw)
          |> get(~p"/api/v1/runners/pool")
          |> json_response(403)

        refute Map.has_key?(body, "runners")
      end
    end

    test "is a read, so an agent-rooted tenant's user key may call it", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      assert json_response(get(auth(conn, raw), ~p"/api/v1/runners/pool"), 200) ==
               %{"runners" => []}
    end

    test "resolves to the pool action, not a runner id" do
      assert %{plug: LoopctlWeb.RunnerController, plug_opts: :pool} =
               Phoenix.Router.route_info(LoopctlWeb.Router, "GET", "/api/v1/runners/pool", "")
    end
  end
end
