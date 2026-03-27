defmodule LoopctlWeb.StoryDependencyController do
  @moduledoc """
  Controller for story dependency CRUD operations.

  - `POST /api/v1/story_dependencies` -- user role, creates a story dependency
  - `DELETE /api/v1/story_dependencies/:id` -- user role, deletes a story dependency
  - `GET /api/v1/epics/:id/story_dependencies` -- agent+, lists story deps for epic
  """

  use LoopctlWeb, :controller

  alias Loopctl.WorkBreakdown.Dependencies
  alias Loopctl.WorkBreakdown.Epics

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:create, :delete]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:index]

  @doc """
  POST /api/v1/story_dependencies

  Creates a dependency: story_id depends on depends_on_story_id.
  """
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    attrs = %{
      story_id: params["story_id"],
      depends_on_story_id: params["depends_on_story_id"]
    }

    case Dependencies.create_story_dependency(tenant_id, attrs,
           actor_id: api_key.id,
           actor_label: "user:#{api_key.name}"
         ) do
      {:ok, dep} ->
        conn
        |> put_status(:created)
        |> json(%{story_dependency: dep_json(dep)})

      {:error, :self_dependency} ->
        {:error, :unprocessable_entity, "A story cannot depend on itself"}

      {:error, :cross_project} ->
        {:error, :unprocessable_entity, "Stories must belong to the same project"}

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
  DELETE /api/v1/story_dependencies/:id

  Removes a dependency edge.
  """
  def delete(conn, %{"id" => dep_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, dep} <- Dependencies.get_story_dependency(tenant_id, dep_id) do
      case Dependencies.delete_story_dependency(tenant_id, dep,
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
  GET /api/v1/epics/:id/story_dependencies

  Lists story dependency edges for stories in an epic (including cross-epic deps).
  """
  def index(conn, %{"id" => epic_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _epic} <- Epics.get_epic(tenant_id, epic_id) do
      {:ok, deps} = Dependencies.list_story_dependencies_for_epic(tenant_id, epic_id)

      json(conn, %{
        data: Enum.map(deps, &dep_json/1)
      })
    end
  end

  defp dep_json(dep) do
    %{
      id: dep.id,
      tenant_id: dep.tenant_id,
      story_id: dep.story_id,
      depends_on_story_id: dep.depends_on_story_id,
      inserted_at: dep.inserted_at
    }
  end
end
