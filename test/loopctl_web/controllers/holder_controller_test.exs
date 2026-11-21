defmodule LoopctlWeb.HolderControllerTest do
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.Audit.AuditLog

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  @body %{"kind" => "interactive", "session_id" => "s1", "host" => "minis", "worktree" => "/w"}

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {agent_key, _api_key, agent} = fixture(:agent_key, %{tenant_id: tenant.id})
    %{tenant: tenant, agent_key: agent_key, agent: agent}
  end

  defp register(raw_key, body \\ @body) do
    build_conn() |> auth(raw_key) |> post(~p"/api/v1/holders", body)
  end

  describe "POST /api/v1/holders" do
    test "a plain agent key registers and gets a credential once", ctx do
      body = json_response(register(ctx.agent_key), 201)

      assert body["holder"]["kind"] == "interactive"
      assert body["holder"]["agent_id"] == ctx.agent.id
      assert is_binary(body["credential"]["raw_key"])
      assert body["heartbeat_seconds"] == Loopctl.Holders.heartbeat_seconds()
    end

    test "a retried register answers 200 with the same holder and a new credential", ctx do
      first = json_response(register(ctx.agent_key), 201)
      second = json_response(register(ctx.agent_key), 200)

      assert second["holder"]["id"] == first["holder"]["id"]
      refute second["credential"]["raw_key"] == first["credential"]["raw_key"]
    end

    test "a runner session's id is 409 session_id_held, and its holder is untouched", ctx do
      {:ok, runner} =
        Loopctl.Holders.register(
          ctx.tenant.id,
          ctx.agent.id,
          Map.merge(@body, %{"kind" => "runner_session", "session_id" => "dispatch:d1"}),
          kinds: [:runner_session]
        )

      body =
        json_response(register(ctx.agent_key, %{@body | "session_id" => "dispatch:d1"}), 409)

      assert body["error"]["code"] == "session_id_held"
      assert {:ok, _} = Loopctl.Auth.verify_api_key(runner.raw_key)
    end

    test "a holder credential gets its own holder and no new credential", ctx do
      first = json_response(register(ctx.agent_key), 201)
      again = json_response(register(first["credential"]["raw_key"]), 200)

      assert again["holder"]["id"] == first["holder"]["id"]
      assert again["credential"] == nil
    end

    test "a dispatch-minted key is refused holder_mint_forbidden", ctx do
      {operator_key, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :user})
      orch = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      %{"api_key" => %{"raw_key" => raw_key}} =
        build_conn()
        |> auth(operator_key)
        |> post(~p"/api/v1/dispatches", %{"role" => "orchestrator", "agent_id" => orch.id})
        |> json_response(201)
        |> Map.fetch!("data")

      error = json_response(register(raw_key), 403)["error"]
      assert error["code"] == "holder_mint_forbidden"
      assert error["remediation"]["remedy"] =~ "runner sessions are holders already"
    end

    test "a key with no agent is refused agent_required", ctx do
      {user_key, _} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :user})
      assert json_response(register(user_key), 422)["error"]["code"] == "agent_required"
    end

    test "an agent-rooted tenant is refused custody_tier_required" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {agent_key, _, _} = fixture(:agent_key, %{tenant_id: tenant.id})

      assert json_response(register(agent_key), 403)["error"]["code"] == "custody_tier_required"
    end

    test "invalid fields are 422", ctx do
      conn = register(ctx.agent_key, %{"kind" => "runner_session", "session_id" => "s1"})
      assert json_response(conn, 422)
    end
  end

  describe "a late heartbeat (US-52.19)" do
    test "TC-52.19.4: 409 holder_lease_expired, then 401 because the credential is revoked",
         ctx do
      registered = json_response(register(ctx.agent_key), 201)
      id = registered["holder"]["id"]
      own = registered["credential"]["raw_key"]

      Loopctl.Holders.Holder
      |> Loopctl.AdminRepo.get!(id)
      |> Ecto.Changeset.change(lease_until: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Loopctl.AdminRepo.update!()

      late = build_conn() |> auth(own) |> post(~p"/api/v1/holders/#{id}/heartbeat")
      assert json_response(late, 409)["error"]["code"] == "holder_lease_expired"

      assert Loopctl.AdminRepo.get!(Loopctl.Holders.Holder, id).ended_reason == :lapsed

      again = build_conn() |> auth(own) |> post(~p"/api/v1/holders/#{id}/heartbeat")
      assert json_response(again, 401)
    end
  end

  describe "heartbeat and end" do
    setup ctx do
      h1 = json_response(register(ctx.agent_key), 201)
      h2 = json_response(register(ctx.agent_key, Map.put(@body, "session_id", "s2")), 201)
      %{h1: h1, h2: h2}
    end

    test "the owner heartbeats, a stranger gets 404", ctx do
      id = ctx.h1["holder"]["id"]
      own = ctx.h1["credential"]["raw_key"]

      body =
        build_conn()
        |> auth(own)
        |> post(~p"/api/v1/holders/#{id}/heartbeat")
        |> json_response(200)

      assert body["heartbeat_seconds"] == Loopctl.Holders.heartbeat_seconds()
      {:ok, lease, _} = DateTime.from_iso8601(body["lease_until"])
      {:ok, registered, _} = DateTime.from_iso8601(ctx.h1["holder"]["lease_until"])
      assert DateTime.compare(lease, registered) in [:gt, :eq]

      stranger = ctx.h2["credential"]["raw_key"]

      assert build_conn()
             |> auth(stranger)
             |> post(~p"/api/v1/holders/#{id}/heartbeat")
             |> json_response(404)
    end

    test "end twice writes one audit row, then the credential is refused", ctx do
      id = ctx.h1["holder"]["id"]
      own = ctx.h1["credential"]["raw_key"]

      ended =
        build_conn() |> auth(own) |> post(~p"/api/v1/holders/#{id}/end") |> json_response(200)

      assert ended["holder"]["ended_reason"] == "ended"

      assert build_conn() |> auth(own) |> post(~p"/api/v1/holders/#{id}/end") |> response(401)

      assert build_conn()
             |> auth(own)
             |> post(~p"/api/v1/holders/#{id}/heartbeat")
             |> response(401)

      assert Loopctl.AdminRepo.aggregate(
               from(a in AuditLog, where: a.entity_id == ^id and a.action == "ended"),
               :count
             ) == 1
    end

    test "a stranger cannot end another holder", ctx do
      id = ctx.h1["holder"]["id"]
      stranger = ctx.h2["credential"]["raw_key"]

      assert build_conn()
             |> auth(stranger)
             |> post(~p"/api/v1/holders/#{id}/end")
             |> json_response(404)
    end
  end
end
