defmodule LoopctlWeb.CapRecoveryControllerTest do
  @moduledoc """
  Tests for POST /api/v1/stories/:id/recover-cap.

  custody-04: the endpoint must NEVER trust client-supplied cryptographic
  claims. `cap_type` is always `start_cap`; `lineage` is always re-derived
  server-side from the story's implementer dispatch.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Builds a story claimed by `agent` via a real implementer dispatch, with
  # the tenant's ed25519 audit key wired up so Capabilities.mint/4 works.
  # The server-authoritative lineage is `dispatch.lineage_path`.
  defp setup_recovery_context do
    tenant = fixture(:tenant, %{audit_signing_public_key: :crypto.strong_rand_bytes(32)})
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {raw_key, _api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    # Wire the tenant's signing keypair: pub on the tenant row, priv via Secrets mock.
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: pub)
      |> AdminRepo.update!()

    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    dispatch = insert_dispatch(tenant.id, agent.id)
    story = claimed_story(tenant.id, epic.id, agent.id, dispatch.id)

    %{
      tenant: tenant,
      agent: agent,
      raw_key: raw_key,
      story: story,
      dispatch: dispatch,
      server_lineage: dispatch.lineage_path
    }
  end

  defp insert_dispatch(tenant_id, agent_id) do
    dispatch_id = Ecto.UUID.generate()
    lineage = [Ecto.UUID.generate(), dispatch_id]

    %Dispatch{id: dispatch_id, tenant_id: tenant_id}
    |> Dispatch.changeset(%{
      agent_id: agent_id,
      role: :agent,
      lineage_path: lineage,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      created_at: DateTime.utc_now()
    })
    |> AdminRepo.insert!()
  end

  defp claimed_story(tenant_id, epic_id, agent_id, dispatch_id) do
    story =
      fixture(:story, %{
        tenant_id: tenant_id,
        epic_id: epic_id,
        agent_status: :implementing,
        assigned_agent_id: agent_id
      })

    # implementer_dispatch_id is not handled by the story fixture — set it directly.
    story
    |> Ecto.Changeset.change(implementer_dispatch_id: dispatch_id)
    |> AdminRepo.update!()
  end

  describe "POST /api/v1/stories/:id/recover-cap — custody-04 hardening" do
    test "ignores client-supplied cap_type + lineage and re-derives both server-side",
         %{conn: conn} do
      %{story: story, raw_key: raw_key, tenant: tenant, server_lineage: server_lineage} =
        setup_recovery_context()

      bogus_lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/recover-cap", %{
          "cap_type" => "verify_cap",
          "lineage" => bogus_lineage
        })

      body = json_response(conn, 201)
      cap = body["data"]

      # The response is a start_cap bound to the SERVER-derived lineage,
      # NOT the verify_cap / bogus lineage the client asked for.
      assert cap["typ"] == "start_cap"
      assert cap["story_id"] == story.id
      assert cap["issued_to_lineage"] == server_lineage
      refute cap["issued_to_lineage"] == bogus_lineage

      # The signature must bind to the server-derived values: it verifies as
      # a start_cap on the real lineage, and fails as verify_cap / bogus lineage.
      assert {:ok, _} =
               Capabilities.verify(tenant.id, %{
                 "cap_id" => cap["cap_id"],
                 "typ" => "start_cap",
                 "story_id" => story.id,
                 "lineage" => server_lineage
               })

      assert {:error, :wrong_type} =
               Capabilities.verify(tenant.id, %{
                 "cap_id" => cap["cap_id"],
                 "typ" => "verify_cap",
                 "story_id" => story.id,
                 "lineage" => server_lineage
               })

      assert {:error, :wrong_lineage} =
               Capabilities.verify(tenant.id, %{
                 "cap_id" => cap["cap_id"],
                 "typ" => "start_cap",
                 "story_id" => story.id,
                 "lineage" => bogus_lineage
               })
    end

    test "recovers a start_cap with no params (happy path)", %{conn: conn} do
      %{story: story, raw_key: raw_key, server_lineage: server_lineage} =
        setup_recovery_context()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/recover-cap", %{})

      cap = json_response(conn, 201)["data"]
      assert cap["typ"] == "start_cap"
      assert cap["issued_to_lineage"] == server_lineage
    end

    test "legacy story without an implementer dispatch yields an empty lineage",
         %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_recovery_context()

      # Simulate a pre-dispatch story: no implementer_dispatch_id recorded.
      story
      |> Ecto.Changeset.change(implementer_dispatch_id: nil)
      |> AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/recover-cap", %{"cap_type" => "verify_cap"})

      cap = json_response(conn, 201)["data"]
      assert cap["typ"] == "start_cap"
      assert cap["issued_to_lineage"] == []
    end

    test "returns 404 when caller is not the assigned agent", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_recovery_context()

      # A different agent in the same tenant must not be able to recover.
      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {other_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_key)
        |> post(~p"/api/v1/stories/#{story.id}/recover-cap", %{})

      assert json_response(conn, 404)["error"]["status"] == 404
    end

    test "tenant isolation: an agent from another tenant cannot recover the story",
         %{conn: conn} do
      %{story: story} = setup_recovery_context()

      other_tenant = fixture(:tenant)
      other_agent = fixture(:agent, %{tenant_id: other_tenant.id, agent_type: :implementer})

      {other_key, _} =
        fixture(:api_key, %{tenant_id: other_tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_key)
        |> post(~p"/api/v1/stories/#{story.id}/recover-cap", %{})

      assert json_response(conn, 404)["error"]["status"] == 404
    end
  end
end
