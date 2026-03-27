defmodule LoopctlWeb.EpicController do
  @moduledoc """
  Controller for epic CRUD operations and progress summary.

  - `POST /api/v1/projects/:project_id/epics` -- user role, creates an epic
  - `GET /api/v1/projects/:project_id/epics` -- agent+, lists epics with pagination
  - `GET /api/v1/epics/:id` -- agent+, epic detail with stories
  - `PATCH /api/v1/epics/:id` -- user role, updates an epic
  - `DELETE /api/v1/epics/:id` -- user role, deletes an epic
  - `GET /api/v1/epics/:id/progress` -- agent+, epic progress summary
  """

  use LoopctlWeb, :controller

  alias Loopctl.Projects
  alias Loopctl.WorkBreakdown.Epics

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:create, :update, :delete]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:index, :show, :progress]

  @doc """
  POST /api/v1/projects/:project_id/epics

  Creates a new epic. Requires user+ role.
  """
  def create(conn, %{"project_id" => project_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _project} <- Projects.get_project(tenant_id, project_id) do
      attrs = %{
        project_id: project_id,
        number: params["number"],
        title: params["title"],
        description: params["description"],
        phase: params["phase"],
        position: params["position"] || 0,
        metadata: params["metadata"] || %{}
      }

      case Epics.create_epic(tenant_id, attrs,
             actor_id: api_key.id,
             actor_label: "user:#{api_key.name}"
           ) do
        {:ok, epic} ->
          conn
          |> put_status(:created)
          |> json(%{epic: epic_json(epic)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/v1/projects/:project_id/epics

  Lists epics for a project. Requires agent+ role.
  Supports pagination via ?page=N&page_size=M and filtering by ?phase=...
  """
  def index(conn, %{"project_id" => project_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, _project} <- Projects.get_project(tenant_id, project_id) do
      opts =
        []
        |> maybe_add_opt(:phase, params["phase"])
        |> maybe_add_opt(:page, parse_int(params["page"]))
        |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

      {:ok, result} = Epics.list_epics(tenant_id, project_id, opts)

      json(conn, %{
        data: Enum.map(result.data, &epic_list_json/1),
        meta: %{
          page: result.page,
          page_size: result.page_size,
          total_count: result.total,
          total_pages: ceil_div(result.total, result.page_size)
        }
      })
    end
  end

  @doc """
  GET /api/v1/epics/:id

  Returns epic detail with stories preloaded. Requires agent+ role.
  """
  def show(conn, %{"id" => epic_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Epics.get_epic_with_stories(tenant_id, epic_id) do
      {:ok, epic} ->
        json(conn, %{epic: epic_detail_json(epic)})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  PATCH /api/v1/epics/:id

  Updates an epic. Requires user+ role. Number cannot be changed.
  """
  def update(conn, %{"id" => epic_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, epic} <- Epics.get_epic(tenant_id, epic_id) do
      attrs = %{
        title: params["title"],
        description: params["description"],
        phase: params["phase"],
        position: params["position"],
        metadata: params["metadata"]
      }

      # Remove nil values so we only update provided fields
      attrs = Map.reject(attrs, fn {_k, v} -> is_nil(v) end)

      case Epics.update_epic(tenant_id, epic, attrs,
             actor_id: api_key.id,
             actor_label: "user:#{api_key.name}"
           ) do
        {:ok, updated} ->
          json(conn, %{epic: epic_json(updated)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  DELETE /api/v1/epics/:id

  Deletes an epic (cascades to stories). Requires user+ role.
  """
  def delete(conn, %{"id" => epic_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, epic} <- Epics.get_epic(tenant_id, epic_id) do
      case Epics.delete_epic(tenant_id, epic,
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
  GET /api/v1/epics/:id/progress

  Returns epic-level progress: story count by agent_status and verified_status.
  Requires agent+ role.
  """
  def progress(conn, %{"id" => epic_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Epics.get_epic_progress(tenant_id, epic_id) do
      {:ok, progress} ->
        json(conn, %{progress: progress})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp epic_json(epic) do
    %{
      id: epic.id,
      tenant_id: epic.tenant_id,
      project_id: epic.project_id,
      number: epic.number,
      title: epic.title,
      description: epic.description,
      phase: epic.phase,
      position: epic.position,
      metadata: epic.metadata,
      inserted_at: epic.inserted_at,
      updated_at: epic.updated_at
    }
  end

  defp epic_list_json(epic) when is_map(epic) do
    %{
      id: epic.id,
      tenant_id: epic.tenant_id,
      project_id: epic.project_id,
      number: epic.number,
      title: epic.title,
      description: epic.description,
      phase: epic.phase,
      position: epic.position,
      metadata: epic.metadata,
      story_count: Map.get(epic, :story_count, 0),
      completion_percentage: Map.get(epic, :completion_percentage, 0.0),
      inserted_at: epic.inserted_at,
      updated_at: epic.updated_at
    }
  end

  defp epic_detail_json(epic) do
    # NOTE(US-6.2): Stories preloading added when Story schema exists
    epic_json(epic)
    |> Map.put(:stories, [])
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
