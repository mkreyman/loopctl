defmodule LoopctlWeb.ImportExportController do
  @moduledoc """
  Controller for project import and export operations.

  - `POST /api/v1/projects/:id/import` -- import work breakdown (user role)
  - `POST /api/v1/projects/:id/import?merge=true` -- merge import (user role)
  - `GET /api/v1/projects/:id/export` -- export project (agent+ role)
  """

  use LoopctlWeb, :controller

  alias Loopctl.ImportExport
  alias Loopctl.Projects
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:import_project]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:export_project]

  @doc """
  POST /api/v1/projects/:id/import

  Imports a work breakdown into a project. When `merge=true` query param
  is present, performs a merge import that updates existing entities.
  """
  def import_project(conn, %{"id" => project_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)
    merge? = params["merge"] == "true"

    with {:ok, _project} <- Projects.get_project(tenant_id, project_id) do
      if merge? do
        do_merge_import(conn, tenant_id, project_id, params, audit_opts)
      else
        do_fresh_import(conn, tenant_id, project_id, params, audit_opts)
      end
    end
  end

  @doc """
  GET /api/v1/projects/:id/export

  Exports a complete project as JSON.
  """
  def export_project(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case ImportExport.export_project(tenant_id, project_id) do
      {:ok, export} ->
        json(conn, export)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp do_fresh_import(conn, tenant_id, project_id, params, audit_opts) do
    case ImportExport.import_project(tenant_id, project_id, params, audit_opts) do
      {:ok, summary} ->
        conn
        |> put_status(:created)
        |> json(%{import: summary})

      {:error, :conflict, details} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            status: 409,
            message: "Import conflicts with existing data. Use merge=true to update.",
            details: details
          }
        })

      {:error, :validation, message} ->
        {:error, :unprocessable_entity, message}

      {:error, :cycle_detected, message} ->
        {:error, :unprocessable_entity, message}
    end
  end

  defp do_merge_import(conn, tenant_id, project_id, params, audit_opts) do
    case ImportExport.merge_import_project(tenant_id, project_id, params, audit_opts) do
      {:ok, summary} ->
        json(conn, %{import: summary})

      {:error, :validation, message} ->
        {:error, :unprocessable_entity, message}

      {:error, :cycle_detected, message} ->
        {:error, :unprocessable_entity, message}
    end
  end
end
