defmodule LoopctlWeb.EpicDependencyController do
  @moduledoc """
  Controller for epic dependency CRUD operations.

  - `POST /api/v1/epic_dependencies` -- user role, creates an epic dependency
  - `DELETE /api/v1/epic_dependencies/:id` -- user role, deletes an epic dependency
  - `GET /api/v1/projects/:id/epic_dependencies` -- agent+, lists epic deps for project
  """

  use LoopctlWeb, :controller

  alias Loopctl.Projects
  alias Loopctl.WorkBreakdown.Dependencies

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:create, :delete]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:index]

  @doc """
  POST /api/v1/epic_dependencies

  Creates a dependency: epic_id depends on depends_on_epic_id.
  """
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    attrs = %{
      epic_id: params["epic_id"],
      depends_on_epic_id: params["depends_on_epic_id"]
    }

    case Dependencies.create_epic_dependency(tenant_id, attrs,
           actor_id: api_key.id,
           actor_label: "user:#{api_key.name}"
         ) do
      {:ok, dep} ->
        conn
        |> put_status(:created)
        |> json(%{epic_dependency: dep_json(dep)})

      {:error, :self_dependency} ->
        {:error, :unprocessable_entity, "An epic cannot depend on itself"}

      {:error, :cross_project} ->
        {:error, :unprocessable_entity, "Epics must belong to the same project"}

      {:error, :cycle_detected} ->
        {:error, :unprocessable_entity, "Cycle detected in dependency graph"}

      {:error, {:cross_level_deadlock, msg}} ->
        {:error, :unprocessable_entity, msg}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :conflict} ->
        {:error, :conflict}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  DELETE /api/v1/epic_dependencies/:id

  Removes a dependency edge.
  """
  def delete(conn, %{"id" => dep_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, dep} <- Dependencies.get_epic_dependency(tenant_id, dep_id) do
      case Dependencies.delete_epic_dependency(tenant_id, dep,
             actor_id: api_key.id,
             actor_label: "user:#{api_key.name}"
           ) do
        {:ok, _deleted} ->
          send_resp(conn, :no_content, "")

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/v1/projects/:id/epic_dependencies

  Lists all epic dependency edges for a project.
  """
  def index(conn, %{"id" => project_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _project} <- Projects.get_project(tenant_id, project_id) do
      {:ok, deps} = Dependencies.list_epic_dependencies(tenant_id, project_id)

      json(conn, %{
        data: Enum.map(deps, &dep_json/1)
      })
    end
  end

  defp dep_json(dep) do
    %{
      id: dep.id,
      tenant_id: dep.tenant_id,
      epic_id: dep.epic_id,
      depends_on_epic_id: dep.depends_on_epic_id,
      inserted_at: dep.inserted_at
    }
  end
end
