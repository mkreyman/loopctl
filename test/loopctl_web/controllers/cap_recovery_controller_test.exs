defmodule LoopctlWeb.CapRecoveryControllerTest do
  @moduledoc """
  Chain-of-custody v2 (L1): capability recovery must only ever re-mint a
  `start_cap`, bound to the lineage recorded on the story's implementer
  dispatch — never a client-chosen cap type or lineage.

  Refs advisory GHSA-w3j2-2w3r-hjcf.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Capabilities.CapabilityToken
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp caps_for(story_id) do
    AdminRepo.all(from(c in CapabilityToken, where: c.story_id == ^story_id))
  end

  # capture_log/1 captures the GLOBAL, process-wide Logger — including lines from
  # OTHER async tests running concurrently. Keep only the captured line(s) carrying
  # this test's unique story.id so marker assertions can't be satisfied by a sibling.
  defp forgery_line(log, story_id) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, story_id))
    |> Enum.join("\n")
  end

  defp audit_entries(story_id, action) do
    AdminRepo.all(
      from(a in AuditLog,
        where: a.entity_id == ^story_id and a.action == ^action
      )
    )
  end

  defp insert_dispatch(tenant_id, agent_id, story_id, lineage, extra) do
    attrs =
      Map.merge(
        %{
          role: :agent,
          agent_id: agent_id,
          story_id: story_id,
          lineage_path: lineage,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        extra
      )

    %Dispatch{tenant_id: tenant_id}
    |> Dispatch.changeset(attrs)
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

    role = Map.get(opts, :role, :agent)

    {raw_key, _api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: role, agent_id: agent.id})

    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
    lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    {story, recorded_lineage} =
      if Map.get(opts, :with_dispatch, true) do
        dispatch =
          insert_dispatch(
            tenant.id,
            agent.id,
            story.id,
            lineage,
            Map.get(opts, :dispatch_attrs, %{})
          )

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

  describe "POST /api/v1/stories/:id/recover-cap — exact_role gate" do
    test "rejects an orchestrator key linked to the same agent_id with 403", %{conn: conn} do
      # An orchestrator identity can be linked to the same agent_id as an
      # implementer. The exact_role: :agent gate (matching claim/start) must
      # not let it walk this custody endpoint via role hierarchy.
      %{raw_key: orch_key, story: story} = setup_ctx(%{role: :orchestrator})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 403}} = json_response(conn, 403)
      assert caps_for(story.id) == []
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — forgery-attempt observability" do
    test "logs a warning and writes an audit entry on a forged cap_type", %{conn: conn} do
      %{raw_key: raw_key, story: story, agent: agent} = setup_ctx()

      log =
        capture_log(fn ->
          conn =
            conn
            |> auth_conn(raw_key)
            |> post("/api/v1/stories/#{story.id}/recover-cap", %{"cap_type" => "verify_cap"})

          assert %{"error" => %{"status" => 422}} = json_response(conn, 422)
        end)

      # Scope marker assertions to THIS story's log line: capture_log sees the
      # global process-wide Logger, so bare "cap_recovery_forgery_attempt" /
      # "rejected_cap_type=..." substrings could match a SIBLING async test's
      # warning captured concurrently. `forgery_line/2` keeps only the line
      # carrying this story.id (the message emits both on one line).
      forgery_line = forgery_line(log, story.id)
      assert forgery_line =~ "cap_recovery_forgery_attempt"
      assert forgery_line =~ "rejected_cap_type=\"verify_cap\""
      assert log =~ story.id

      # Surfaces in GET /stories/:id/history (Audit.entity_history reads this table)
      assert [entry] = audit_entries(story.id, "cap_recovery_forgery_attempt")
      assert entry.entity_type == "story"
      assert entry.metadata["rejected_cap_type"] == "verify_cap"
      assert entry.metadata["caller_agent_id"] == agent.id
      assert caps_for(story.id) == []
    end
  end

  describe "POST /api/v1/stories/:id/recover-cap — dispatch activeness" do
    test "rejects recovery when the implementer dispatch is revoked", %{conn: conn} do
      %{raw_key: raw_key, story: story} =
        setup_ctx(%{dispatch_attrs: %{revoked_at: DateTime.utc_now()}})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 422, "message" => message}} = json_response(conn, 422)
      assert message =~ "revoked"
      assert caps_for(story.id) == []
    end

    test "rejects recovery when the implementer dispatch is expired", %{conn: conn} do
      %{raw_key: raw_key, story: story} =
        setup_ctx(%{
          dispatch_attrs: %{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"error" => %{"status" => 422}} = json_response(conn, 422)
      assert caps_for(story.id) == []
    end

    test "mints as usual when the implementer dispatch is active", %{conn: conn} do
      %{raw_key: raw_key, story: story, lineage: lineage} = setup_ctx()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/stories/#{story.id}/recover-cap", %{})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["typ"] == "start_cap"
      assert data["issued_to_lineage"] == lineage
    end
  end
end
