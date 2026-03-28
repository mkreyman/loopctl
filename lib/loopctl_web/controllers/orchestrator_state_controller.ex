defmodule LoopctlWeb.OrchestratorStateController do
  @moduledoc """
  Controller for orchestrator state management.

  - `PUT /api/v1/orchestrator/state/:project_id` -- save state (upsert)
  - `GET /api/v1/orchestrator/state/:project_id` -- retrieve state
  - `GET /api/v1/orchestrator/state/:project_id/history` -- version history
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Orchestrator
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: [:orchestrator, :superadmin]

  tags(["Orchestrator"])

  operation(:save,
    summary: "Save orchestrator state",
    description: "Saves (upserts) orchestrator state with optimistic locking.",
    parameters: [project_id: [in: :path, type: :string, description: "Project UUID"]],
    request_body: {"State params", "application/json", Schemas.OrchestratorStateRequest},
    responses: %{
      200 =>
        {"State saved", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Project not found", "application/json", Schemas.ErrorResponse},
      409 => {"Version conflict", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:show,
    summary: "Get orchestrator state",
    description: "Retrieves orchestrator state. Defaults to state_key='main'.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID"],
      state_key: [in: :query, type: :string, description: "State key (default: main)"]
    ],
    responses: %{
      200 =>
        {"State", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:history,
    summary: "Get orchestrator state history",
    description: "Returns version history derived from audit log entries.",
    parameters: [
      project_id: [in: :path, type: :string, description: "Project UUID"],
      state_key: [in: :query, type: :string, description: "State key filter"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"State history", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
             },
             meta: Schemas.PaginationMeta
           }
         }},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

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

    audit_opts = AuditContext.from_conn(conn)

    case Orchestrator.save_state(tenant_id, project_id, attrs, audit_opts) do
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

  @doc """
  GET /api/v1/orchestrator/state/:project_id/history

  Returns version history derived from audit log entries.
  Supports pagination and state_key filtering.
  """
  def history(conn, %{"project_id" => project_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:state_key, params["state_key"] || "main")
      |> maybe_add_opt(:page, parse_int(params["page"]))
      |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

    case Orchestrator.get_state_history(tenant_id, project_id, opts) do
      {:ok, result} ->
        json(conn, %{
          data: result.data,
          meta: %{
            page: result.page,
            page_size: result.page_size,
            total_count: result.total,
            total_pages: ceil_div(result.total, result.page_size)
          }
        })

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

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
