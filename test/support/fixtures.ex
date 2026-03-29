defmodule Loopctl.Fixtures do
  @moduledoc """
  Test fixture helpers for building and inserting test data.

  - `build/2` — returns a map or struct without touching the database.
  - `fixture/2` — inserts into the database, auto-creating dependencies.

  All fixtures use binary UUIDs. Tenant isolation tests should create
  separate tenants via `fixture(:tenant)`.
  """

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.Artifacts.ArtifactReport
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Auth
  alias Loopctl.Orchestrator.OrchestratorState
  alias Loopctl.Projects.Project
  alias Loopctl.QualityAssurance.UiTestRun
  alias Loopctl.Skills.Skill
  alias Loopctl.Skills.SkillResult
  alias Loopctl.Skills.SkillVersion
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.EpicDependency
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkBreakdown.StoryDependency

  @doc """
  Builds a data map for the given type without database insertion.
  Useful for changeset tests and unit tests that don't need persistence.
  """
  def build(type, attrs \\ %{})

  def build(:tenant, attrs) do
    Map.merge(
      %{
        name: "Test Tenant #{System.unique_integer([:positive])}",
        slug: "test-tenant-#{System.unique_integer([:positive])}",
        email: "test-#{System.unique_integer([:positive])}@example.com",
        settings: %{},
        status: :active
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:audit_log, attrs) do
    Map.merge(
      %{
        entity_type: "project",
        entity_id: Ecto.UUID.generate(),
        action: "created",
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "user:test",
        old_state: nil,
        new_state: %{"name" => "Test"},
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:agent, attrs) do
    Map.merge(
      %{
        name: "agent-#{System.unique_integer([:positive])}",
        agent_type: :implementer,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:project, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "Test Project #{seq}",
        slug: "test-project-#{seq}",
        repo_url: "https://github.com/example/project-#{seq}",
        description: "A test project",
        tech_stack: "elixir/phoenix",
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:epic, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        number: seq,
        title: "Epic #{seq}",
        description: "Test epic description",
        phase: "p0_foundation",
        position: 0,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:story, attrs) do
    seq = System.unique_integer([:positive])
    # Keep minor part under 10000 to satisfy sort_key validation
    minor = rem(seq, 9999) + 1

    Map.merge(
      %{
        number: "1.#{minor}",
        title: "Story #{seq}",
        description: "Test story description",
        acceptance_criteria: [],
        estimated_hours: nil,
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:epic_dependency, attrs) do
    Enum.into(attrs, %{})
  end

  def build(:story_dependency, attrs) do
    Enum.into(attrs, %{})
  end

  def build(:orchestrator_state, attrs) do
    Map.merge(
      %{
        state_key: "main",
        state_data: %{"current_epic" => 1, "completed_stories" => []},
        version: 1
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:artifact_report, attrs) do
    Map.merge(
      %{
        artifact_type: "schema",
        path: "lib/loopctl/test.ex",
        exists: true,
        details: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:verification_result, attrs) do
    Map.merge(
      %{
        result: :pass,
        summary: "All checks passed",
        findings: %{},
        review_type: "enhanced_review",
        iteration: 1
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:webhook, attrs) do
    Map.merge(
      %{
        url: "https://example.com/hooks/#{System.unique_integer([:positive])}",
        events: ["story.status_changed"],
        active: true
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:webhook_event, attrs) do
    Map.merge(
      %{
        event_type: "story.status_changed",
        payload: %{"event" => "story.status_changed", "data" => %{}},
        status: :pending,
        attempts: 0
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:api_key, attrs) do
    Map.merge(
      %{
        name: "test-key-#{System.unique_integer([:positive])}",
        role: :user
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:skill, attrs) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "test-skill-#{seq}",
        description: "A test skill",
        metadata: %{}
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:skill_version, attrs) do
    Map.merge(
      %{
        prompt_text: "Test prompt text for skill version",
        changelog: "Initial version",
        created_by: "test"
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:skill_result, attrs) do
    Map.merge(
      %{
        metrics: %{
          "findings_count" => 5,
          "false_positive_count" => 1,
          "true_positive_count" => 4
        }
      },
      Enum.into(attrs, %{})
    )
  end

  def build(:ui_test_run, attrs) do
    Map.merge(
      %{
        guide_reference: "docs/user_guides/test_guide_#{System.unique_integer([:positive])}.md",
        started_at: DateTime.utc_now()
      },
      Enum.into(attrs, %{})
    )
  end

  @doc """
  Inserts a record into the database, auto-creating any required dependencies.
  Returns the inserted struct.

  For `:api_key`, returns `{raw_key, %ApiKey{}}` since the raw key
  is needed for authentication in tests.
  """
  def fixture(type, attrs \\ %{})

  def fixture(:tenant, attrs) do
    data = build(:tenant, attrs)
    status = Map.get(data, :status, :active)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(data)
      |> AdminRepo.insert!()

    # Apply non-active status after creation (create always defaults to :active)
    if status != :active do
      tenant
      |> Tenant.status_changeset(status)
      |> AdminRepo.update!()
    else
      tenant
    end
  end

  def fixture(:agent, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:agent, attrs)

    changeset =
      %Agent{tenant_id: tenant_id}
      |> Agent.register_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:project, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:project, attrs)

    changeset =
      %Project{tenant_id: tenant_id}
      |> Project.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:epic, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create project if not provided
    {project_id, attrs} =
      case Map.get(attrs, :project_id) do
        nil ->
          project = fixture(:project, %{tenant_id: tenant_id})
          {project.id, Map.put(attrs, :project_id, project.id)}

        pid ->
          {pid, attrs}
      end

    data = build(:epic, attrs)

    changeset =
      %Epic{tenant_id: tenant_id, project_id: project_id}
      |> Epic.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:story, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    # Auto-create epic if not provided
    {epic, attrs} =
      case Map.get(attrs, :epic_id) do
        nil ->
          project_id = Map.get(attrs, :project_id)

          epic =
            if project_id do
              fixture(:epic, %{tenant_id: tenant_id, project_id: project_id})
            else
              fixture(:epic, %{tenant_id: tenant_id})
            end

          attrs = Map.put(attrs, :epic_id, epic.id)
          attrs = Map.put(attrs, :project_id, epic.project_id)
          {epic, attrs}

        eid ->
          epic = AdminRepo.get!(Epic, eid)
          attrs = Map.put(attrs, :project_id, epic.project_id)
          {epic, attrs}
      end

    project_id = Map.get(attrs, :project_id, epic.project_id)

    # Handle optional status overrides
    agent_status = Map.get(attrs, :agent_status, :pending)
    verified_status = Map.get(attrs, :verified_status, :unverified)

    data = build(:story, attrs)

    changeset =
      %Story{tenant_id: tenant_id, project_id: project_id, epic_id: epic.id}
      |> Story.create_changeset(data)

    story = AdminRepo.insert!(changeset)

    # Apply status overrides if non-default
    if agent_status != :pending or verified_status != :unverified do
      story
      |> Ecto.Changeset.change(%{agent_status: agent_status, verified_status: verified_status})
      |> AdminRepo.update!()
    else
      story
    end
  end

  def fixture(:epic_dependency, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    epic_id = Map.fetch!(attrs, :epic_id)
    depends_on_epic_id = Map.fetch!(attrs, :depends_on_epic_id)

    changeset =
      %EpicDependency{
        tenant_id: tenant_id,
        epic_id: epic_id,
        depends_on_epic_id: depends_on_epic_id
      }
      |> EpicDependency.create_changeset()

    AdminRepo.insert!(changeset)
  end

  def fixture(:story_dependency, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    story_id = Map.fetch!(attrs, :story_id)
    depends_on_story_id = Map.fetch!(attrs, :depends_on_story_id)

    changeset =
      %StoryDependency{
        tenant_id: tenant_id,
        story_id: story_id,
        depends_on_story_id: depends_on_story_id
      }
      |> StoryDependency.create_changeset()

    AdminRepo.insert!(changeset)
  end

  def fixture(:artifact_report, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {story_id, attrs} =
      case Map.get(attrs, :story_id) do
        nil ->
          story = fixture(:story, %{tenant_id: tenant_id})
          {story.id, Map.put(attrs, :story_id, story.id)}

        sid ->
          {sid, attrs}
      end

    agent_id = Map.get(attrs, :reporter_agent_id)
    reported_by = Map.get(attrs, :reported_by, :agent)

    data = build(:artifact_report, attrs)

    changeset =
      %ArtifactReport{
        tenant_id: tenant_id,
        story_id: story_id,
        reported_by: reported_by,
        reporter_agent_id: agent_id
      }
      |> ArtifactReport.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:verification_result, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {story_id, attrs} =
      case Map.get(attrs, :story_id) do
        nil ->
          story = fixture(:story, %{tenant_id: tenant_id})
          {story.id, Map.put(attrs, :story_id, story.id)}

        sid ->
          {sid, attrs}
      end

    orchestrator_agent_id = Map.get(attrs, :orchestrator_agent_id)

    data = build(:verification_result, attrs)

    changeset =
      %VerificationResult{
        tenant_id: tenant_id,
        story_id: story_id,
        orchestrator_agent_id: orchestrator_agent_id
      }
      |> VerificationResult.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:webhook, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:webhook, attrs)
    raw_secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    changeset =
      %Webhook{
        tenant_id: tenant_id,
        signing_secret_encrypted: raw_secret
      }
      |> Webhook.create_changeset(data)

    webhook = AdminRepo.insert!(changeset)

    # Apply overrides for active and consecutive_failures
    active = Map.get(attrs, :active, true)
    consecutive_failures = Map.get(attrs, :consecutive_failures, 0)

    if active != true or consecutive_failures != 0 do
      webhook
      |> Ecto.Changeset.change(%{active: active, consecutive_failures: consecutive_failures})
      |> AdminRepo.update!()
    else
      webhook
    end
  end

  def fixture(:webhook_event, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {webhook_id, attrs} =
      case Map.get(attrs, :webhook_id) do
        nil ->
          webhook = fixture(:webhook, %{tenant_id: tenant_id})
          {webhook.id, Map.put(attrs, :webhook_id, webhook.id)}

        wid ->
          {wid, attrs}
      end

    data = build(:webhook_event, attrs)
    status = Map.get(data, :status, :pending)
    attempts = Map.get(data, :attempts, 0)

    changeset =
      %WebhookEvent{
        tenant_id: tenant_id,
        webhook_id: webhook_id
      }
      |> WebhookEvent.create_changeset(data)

    event = AdminRepo.insert!(changeset)

    # Apply status/attempts overrides
    if status != :pending or attempts != 0 do
      event
      |> Ecto.Changeset.change(%{status: status, attempts: attempts})
      |> AdminRepo.update!()
    else
      event
    end
  end

  def fixture(:api_key, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided (unless superadmin)
    {tenant_id, attrs} =
      case {Map.get(attrs, :tenant_id), Map.get(attrs, :role, :user)} do
        {nil, :superadmin} ->
          {nil, attrs}

        {nil, _role} ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        {tid, _role} ->
          {tid, attrs}
      end

    data = build(:api_key, attrs)
    data = Map.put(data, :tenant_id, tenant_id)

    {:ok, {raw_key, api_key}} = Auth.generate_api_key(data)
    {raw_key, api_key}
  end

  def fixture(:audit_log, attrs) do
    attrs = Enum.into(attrs, %{})

    # Auto-create a tenant if not provided
    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    data = build(:audit_log, attrs)

    changeset =
      data
      |> AuditLog.create_changeset()
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)

    AdminRepo.insert!(changeset)
  end

  def fixture(:orchestrator_state, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {project_id, attrs} =
      case Map.get(attrs, :project_id) do
        nil ->
          project = fixture(:project, %{tenant_id: tenant_id})
          {project.id, Map.put(attrs, :project_id, project.id)}

        pid ->
          {pid, attrs}
      end

    data = build(:orchestrator_state, attrs)

    changeset =
      %{
        state_key: data.state_key,
        state_data: data.state_data
      }
      |> OrchestratorState.create_changeset()
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
      |> Ecto.Changeset.put_change(:project_id, project_id)

    version = Map.get(data, :version, 1)

    state = AdminRepo.insert!(changeset)

    if version != 1 do
      state
      |> Ecto.Changeset.change(%{version: version})
      |> AdminRepo.update!()
    else
      state
    end
  end

  def fixture(:skill, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    project_id = Map.get(attrs, :project_id)
    prompt_text = Map.get(attrs, :prompt_text, "Default skill prompt text")
    data = build(:skill, attrs)

    changeset =
      %Skill{tenant_id: tenant_id, project_id: project_id}
      |> Skill.create_changeset(data)

    skill = AdminRepo.insert!(changeset)

    # Create v1 version
    version_changeset =
      %SkillVersion{
        tenant_id: tenant_id,
        skill_id: skill.id,
        version: 1
      }
      |> SkillVersion.create_changeset(%{
        prompt_text: prompt_text,
        created_by: "fixture",
        changelog: "Initial version"
      })

    AdminRepo.insert!(version_changeset)

    skill
  end

  def fixture(:skill_version, attrs) do
    attrs = Enum.into(attrs, %{})
    skill_id = Map.fetch!(attrs, :skill_id)
    tenant_id = Map.fetch!(attrs, :tenant_id)
    version = Map.fetch!(attrs, :version)

    data = build(:skill_version, attrs)

    changeset =
      %SkillVersion{
        tenant_id: tenant_id,
        skill_id: skill_id,
        version: version
      }
      |> SkillVersion.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:skill_result, attrs) do
    attrs = Enum.into(attrs, %{})
    tenant_id = Map.fetch!(attrs, :tenant_id)
    skill_version_id = Map.fetch!(attrs, :skill_version_id)
    verification_result_id = Map.fetch!(attrs, :verification_result_id)
    story_id = Map.fetch!(attrs, :story_id)

    data = build(:skill_result, attrs)

    changeset =
      %SkillResult{
        tenant_id: tenant_id,
        skill_version_id: skill_version_id,
        verification_result_id: verification_result_id,
        story_id: story_id
      }
      |> SkillResult.create_changeset(data)

    AdminRepo.insert!(changeset)
  end

  def fixture(:ui_test_run, attrs) do
    attrs = Enum.into(attrs, %{})

    {tenant_id, attrs} =
      case Map.get(attrs, :tenant_id) do
        nil ->
          tenant = fixture(:tenant)
          {tenant.id, Map.put(attrs, :tenant_id, tenant.id)}

        tid ->
          {tid, attrs}
      end

    {project_id, attrs} =
      case Map.get(attrs, :project_id) do
        nil ->
          project = fixture(:project, %{tenant_id: tenant_id})
          {project.id, Map.put(attrs, :project_id, project.id)}

        pid ->
          {pid, attrs}
      end

    agent_id = Map.get(attrs, :started_by_agent_id)
    status = Map.get(attrs, :status, :in_progress)

    data = build(:ui_test_run, attrs)

    changeset =
      %UiTestRun{
        tenant_id: tenant_id,
        project_id: project_id,
        started_by_agent_id: agent_id
      }
      |> UiTestRun.create_changeset(data)

    run = AdminRepo.insert!(changeset)

    # Apply non-default status overrides after creation
    if status != :in_progress do
      run
      |> Ecto.Changeset.change(%{status: status, completed_at: DateTime.utc_now()})
      |> AdminRepo.update!()
    else
      run
    end
  end

  @doc """
  Generates a fresh binary UUID for use in tests.
  """
  def uuid, do: Ecto.UUID.generate()
end
