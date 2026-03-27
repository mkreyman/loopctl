defmodule Loopctl.ArtifactsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Artifacts

  defp setup_story do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        agent_status: :reported_done
      })

    %{tenant: tenant, project: project, epic: epic, agent: agent, story: story}
  end

  # --- Artifact Reports ---

  describe "create_artifact_report/4" do
    test "creates an artifact report with valid attrs" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      attrs = %{
        "artifact_type" => "migration",
        "path" => "priv/repo/migrations/20240101_create_users.exs",
        "exists" => true,
        "details" => %{"lines" => 42}
      }

      assert {:ok, report} =
               Artifacts.create_artifact_report(tenant.id, story.id, attrs,
                 agent_id: agent.id,
                 reported_by: :agent,
                 actor_id: agent.id,
                 actor_label: "agent:test"
               )

      assert report.tenant_id == tenant.id
      assert report.story_id == story.id
      assert report.artifact_type == "migration"
      assert report.path == "priv/repo/migrations/20240101_create_users.exs"
      assert report.exists == true
      assert report.details == %{"lines" => 42}
      assert report.reported_by == :agent
      assert report.reporter_agent_id == agent.id
    end

    test "creates artifact report with orchestrator role" do
      %{tenant: tenant, story: story} = setup_story()
      orch = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      attrs = %{"artifact_type" => "test", "path" => "test/my_test.exs"}

      assert {:ok, report} =
               Artifacts.create_artifact_report(tenant.id, story.id, attrs,
                 agent_id: orch.id,
                 reported_by: :orchestrator
               )

      assert report.reported_by == :orchestrator
      assert report.reporter_agent_id == orch.id
    end

    test "requires artifact_type" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:error, changeset} =
               Artifacts.create_artifact_report(tenant.id, story.id, %{},
                 agent_id: agent.id,
                 reported_by: :agent
               )

      assert errors_on(changeset)[:artifact_type] != nil
    end

    test "defaults exists to true" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:ok, report} =
               Artifacts.create_artifact_report(
                 tenant.id,
                 story.id,
                 %{"artifact_type" => "schema"},
                 agent_id: agent.id,
                 reported_by: :agent
               )

      assert report.exists == true
    end

    test "creates audit log entry" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      {:ok, _report} =
        Artifacts.create_artifact_report(
          tenant.id,
          story.id,
          %{"artifact_type" => "schema", "path" => "lib/test.ex"},
          agent_id: agent.id,
          reported_by: :agent,
          actor_id: agent.id,
          actor_label: "agent:test"
        )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "artifact_report",
          action: "created"
        )

      assert result.data != []
      audit = hd(result.data)
      assert audit.new_state["artifact_type"] == "schema"
      assert audit.new_state["story_id"] == story.id
    end
  end

  describe "list_artifact_reports/3" do
    test "lists all reports for a story ordered by inserted_at" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      {:ok, r1} =
        Artifacts.create_artifact_report(
          tenant.id,
          story.id,
          %{"artifact_type" => "schema"},
          agent_id: agent.id,
          reported_by: :agent
        )

      {:ok, r2} =
        Artifacts.create_artifact_report(
          tenant.id,
          story.id,
          %{"artifact_type" => "migration"},
          agent_id: agent.id,
          reported_by: :agent
        )

      {:ok, result} = Artifacts.list_artifact_reports(tenant.id, story.id)

      assert length(result.data) == 2
      assert Enum.map(result.data, & &1.id) == [r1.id, r2.id]
      assert result.total == 2
      assert result.page == 1
      assert result.page_size == 20
    end

    test "returns empty list for story with no reports" do
      %{tenant: tenant, story: story} = setup_story()

      {:ok, result} = Artifacts.list_artifact_reports(tenant.id, story.id)

      assert result.data == []
      assert result.total == 0
    end

    test "supports pagination" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      for type <- ~w(schema migration test route context) do
        Artifacts.create_artifact_report(
          tenant.id,
          story.id,
          %{"artifact_type" => type},
          agent_id: agent.id,
          reported_by: :agent
        )
      end

      {:ok, page1} = Artifacts.list_artifact_reports(tenant.id, story.id, page: 1, page_size: 2)
      assert length(page1.data) == 2
      assert page1.total == 5
      assert page1.page == 1

      {:ok, page2} = Artifacts.list_artifact_reports(tenant.id, story.id, page: 2, page_size: 2)
      assert length(page2.data) == 2
      assert page2.page == 2

      {:ok, page3} = Artifacts.list_artifact_reports(tenant.id, story.id, page: 3, page_size: 2)
      assert length(page3.data) == 1
    end
  end

  describe "tenant isolation (artifact reports)" do
    test "tenant A cannot see tenant B artifact reports" do
      %{tenant: tenant_a, story: story_a, agent: agent_a} = setup_story()
      tenant_b = fixture(:tenant)

      {:ok, _} =
        Artifacts.create_artifact_report(
          tenant_a.id,
          story_a.id,
          %{"artifact_type" => "schema"},
          agent_id: agent_a.id,
          reported_by: :agent
        )

      {:ok, result} = Artifacts.list_artifact_reports(tenant_b.id, story_a.id)
      assert result.data == []
      assert result.total == 0
    end
  end

  # --- Verification Results ---

  describe "list_verifications/3" do
    test "lists verification results ordered by iteration" do
      %{tenant: tenant, story: story} = setup_story()
      orch = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      v1 =
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          orchestrator_agent_id: orch.id,
          result: :fail,
          iteration: 1
        })

      v2 =
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          orchestrator_agent_id: orch.id,
          result: :pass,
          iteration: 2
        })

      {:ok, result} = Artifacts.list_verifications(tenant.id, story.id)

      assert length(result.data) == 2
      assert Enum.map(result.data, & &1.id) == [v1.id, v2.id]
      assert result.total == 2
    end

    test "supports pagination" do
      %{tenant: tenant, story: story} = setup_story()
      orch = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      for i <- 1..5 do
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          orchestrator_agent_id: orch.id,
          iteration: i
        })
      end

      {:ok, page1} = Artifacts.list_verifications(tenant.id, story.id, page: 1, page_size: 2)
      assert length(page1.data) == 2
      assert page1.total == 5

      {:ok, page3} = Artifacts.list_verifications(tenant.id, story.id, page: 3, page_size: 2)
      assert length(page3.data) == 1
    end
  end

  describe "get_verification/2" do
    test "returns verification result by ID" do
      %{tenant: tenant, story: story} = setup_story()
      orch = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      v =
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          orchestrator_agent_id: orch.id
        })

      assert {:ok, found} = Artifacts.get_verification(tenant.id, v.id)
      assert found.id == v.id
    end

    test "returns not_found for nonexistent ID" do
      %{tenant: tenant} = setup_story()

      assert {:error, :not_found} = Artifacts.get_verification(tenant.id, Ecto.UUID.generate())
    end

    test "returns not_found for wrong tenant" do
      %{tenant: tenant, story: story} = setup_story()
      orch = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      v =
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          orchestrator_agent_id: orch.id
        })

      tenant_b = fixture(:tenant)
      assert {:error, :not_found} = Artifacts.get_verification(tenant_b.id, v.id)
    end
  end

  describe "count_verifications/2" do
    test "returns count of verification results for a story" do
      %{tenant: tenant, story: story} = setup_story()
      orch = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      assert Artifacts.count_verifications(tenant.id, story.id) == 0

      fixture(:verification_result, %{
        tenant_id: tenant.id,
        story_id: story.id,
        orchestrator_agent_id: orch.id,
        iteration: 1
      })

      fixture(:verification_result, %{
        tenant_id: tenant.id,
        story_id: story.id,
        orchestrator_agent_id: orch.id,
        iteration: 2
      })

      assert Artifacts.count_verifications(tenant.id, story.id) == 2
    end
  end

  describe "tenant isolation (verification results)" do
    test "tenant A cannot see tenant B verification results" do
      %{tenant: tenant_a, story: story_a} = setup_story()
      tenant_b = fixture(:tenant)
      orch = fixture(:agent, %{tenant_id: tenant_a.id, agent_type: :orchestrator})

      fixture(:verification_result, %{
        tenant_id: tenant_a.id,
        story_id: story_a.id,
        orchestrator_agent_id: orch.id
      })

      {:ok, result} = Artifacts.list_verifications(tenant_b.id, story_a.id)
      assert result.data == []
      assert result.total == 0
    end
  end
end
