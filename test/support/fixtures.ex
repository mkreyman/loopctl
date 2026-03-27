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
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Auth
  alias Loopctl.Orchestrator.OrchestratorState
  alias Loopctl.Projects.Project
  alias Loopctl.Tenants.Tenant
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

  def build(:api_key, attrs) do
    Map.merge(
      %{
        name: "test-key-#{System.unique_integer([:positive])}",
        role: :user
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

  @doc """
  Generates a fresh binary UUID for use in tests.
  """
  def uuid, do: Ecto.UUID.generate()
end
