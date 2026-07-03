defmodule LoopctlWeb.CapRecoveryControllerTest do
  @moduledoc """
  Chain-of-custody v2 (L1): capability recovery must only ever re-mint a
  `start_cap`, bound to the lineage recorded on the story's implementer
  dispatch — never a client-chosen cap type or lineage.

  Refs advisory GHSA-w3j2-2w3r-hjcf.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Capabilities.CapabilityToken
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp caps_for(story_id) do
    AdminRepo.all(from(c in CapabilityToken, where: c.story_id == ^story_id))
  end

  defp insert_dispatch(tenant_id, agent_id, story_id, lineage) do
    %Dispatch{tenant_id: tenant_id}
    |> Dispatch.changeset(%{
      role: :agent,
      agent_id: agent_id,
      story_id: story_id,
      lineage_path: lineage,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> AdminRepo.insert!()
  end

  # Builds a tenant whose audit signing key is available, an agent + agent-role
  # API key, and a story assigned to that agent. When `with_dispatch: true`
  # (default) the story also carries a recorded implementer dispatch whose
  # lineage_path is the canonical, server-side lineage.
  defp setup_ctx(opts \\ %{}) do
    tenant = fixture(:tenant)

    # Make the tenant's audit signing key available so mint/4 can succeed.
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: pub)
      |> AdminRepo.update!()

    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw_key, _api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
    lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    {story, recorded_lineage} =
      if Map.get(opts, :with_dispatch, true) do
        dispatch = insert_dispatch(tenant.id, agent.id, story.id, lineage)

        story =
          story
          |> Ecto.Changeset.change(
            assigned_agent_id: agent.id,
            implementer_dispatch_id: dispatch.id
          )
          |> AdminRepo.update!()

        {story, lineage}
      else
        story =
          story
          |> Ecto.Changeset.change(assigned_agent_id: agent.id)
          |> AdminRepo.update!()

        {story, nil}
      end

    %{
      tenant: tenant,
      agent: agent,
      raw_key: raw_key,
      story: story,
      lineage: recorded_lineage
    }
  end

  describe "POST /api/v1/stories/:id/recover-cap — cap_type restriction" do
    for forged <- ["verify_cap", "report_cap", "review_complete_cap"] do
      test "rejects client-supplied cap_type #{forged} with 422 and mints nothing", %{conn: conn} do
        %{raw_key: raw_key, story: story} = setup_ctx()

        conn =
          conn
          |> auth_conn(raw_key)
          |> post("/api/v1/stories/#{story.id}/recover-cap", %{"cap_type" => unquote(forged)})

        assert %{"error" => %{"status" => 422, "message" => message}} = json_response(conn, 422)
        assert message =~ "start_cap"
        assert caps_for(story.id) == []
      end
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — start_cap recovery" do
    test "with no cap_type mints a start_cap bound to the server-derived lineage", %{conn: conn} do
      %{raw_key: raw_key, story: story, lineage: lineage} = setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["story_id"] == story.id
      assert data["issued_to_lineage"] == lineage
    end

    test "with explicit cap_type start_cap mints a start_cap", %{conn: conn} do
      %{raw_key: raw_key, story: story, lineage: lineage} = setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{"cap_type" => "start_cap"})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["issued_to_lineage"] == lineage
    end

    test "ignores a client-supplied lineage and uses the recorded dispatch lineage", %{conn: conn} do
      %{raw_key: raw_key, story: story, lineage: lineage} = setup_ctx()
      attacker_lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{"lineage" => attacker_lineage})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["issued_to_lineage"] == lineage
      refute data["issued_to_lineage"] == attacker_lineage
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — guards" do
    test "rejects a caller with no recorded dispatch lineage for the story", %{conn: conn} do
      %{raw_key: raw_key, story: story} = setup_ctx(%{with_dispatch: false})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 422}} = json_response(conn, 422)
      assert caps_for(story.id) == []
    end

    test "returns 404 for a same-tenant story assigned to another agent", %{conn: conn} do
      %{raw_key: raw_key, tenant: tenant} = setup_ctx()

      other_agent = fixture(:agent, %{tenant_id: tenant.id})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      other_story =
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
        |> Ecto.Changeset.change(assigned_agent_id: other_agent.id)
        |> AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{other_story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
      assert caps_for(other_story.id) == []
    end

    test "tenant isolation: cannot recover a cap for another tenant's story", %{conn: conn} do
      %{raw_key: raw_key} = setup_ctx()
      # A completely separate tenant with its own agent-owned story.
      %{story: foreign_story} = setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{foreign_story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
      assert caps_for(foreign_story.id) == []
    end
  end
end
