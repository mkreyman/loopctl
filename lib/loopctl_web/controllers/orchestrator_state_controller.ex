defmodule LoopctlWeb.OrchestratorStateController do
  @moduledoc """
  Controller for orchestrator state management.

  - `PUT /api/v1/orchestrator/state/:project_id` -- save state (upsert)
  - `GET /api/v1/orchestrator/state/:project_id` -- retrieve state
  """

  use LoopctlWeb, :controller

  alias Loopctl.Orchestrator

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: [:orchestrator, :superadmin]

  @doc """
  PUT /api/v1/orchestrator/state/:project_id

  Saves (upserts) orchestrator state with optimistic locking.
  Requires orchestrator role.
  """
  def save(conn, %{"project_id" => project_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    attrs = %{
      state_key: params["state_key"],
      state_data: params["state_data"],
      version: params["version"]
    }

    case Orchestrator.save_state(tenant_id, project_id, attrs,
           actor_id: api_key.id,
           actor_label: "orchestrator:#{api_key.name}"
         ) do
      {:ok, state} ->
        json(conn, %{state: state_json(state)})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :version_conflict} ->
        {:error, :conflict}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  GET /api/v1/orchestrator/state/:project_id

  Retrieves orchestrator state. Supports optional state_key query parameter.
  Defaults to "main" if not provided.
  """
  def show(conn, %{"project_id" => project_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    state_key = params["state_key"] || "main"

    case Orchestrator.get_state(tenant_id, project_id, state_key) do
      {:ok, state} ->
        json(conn, %{state: state_json(state)})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp state_json(state) do
    %{
      id: state.id,
      tenant_id: state.tenant_id,
      project_id: state.project_id,
      state_key: state.state_key,
      state_data: state.state_data,
      version: state.version,
      inserted_at: state.inserted_at,
      updated_at: state.updated_at
    }
  end
end
