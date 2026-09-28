defmodule LoopctlWeb.ImportExportController do
  @moduledoc """
  Controller for project import and export operations.

  - `POST /api/v1/projects/:id/import` -- import work breakdown (orchestrator, user, or superadmin role)
  - `POST /api/v1/projects/:id/import?merge=true` -- merge import (orchestrator, user, or superadmin role)
  - `GET /api/v1/projects/:id/export` -- export project (agent+ role)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.ImportExport
  alias Loopctl.Projects
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:orchestrator, :user, :superadmin]] when action in [:import_project]

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:export_project]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  # NOT applied to :export_project — export is a read-only KB-tier-safe op.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:import_project]

  # A :kb scope can never receive an imported work breakdown. Import uses the :id path param.
  plug LoopctlWeb.Plugs.RequireWorkProject, [param: "id"] when action in [:import_project]

  tags(["Import/Export"])

  operation(:import_project,
    summary: "Import work breakdown",
    description: "Imports a work breakdown into a project. Use merge=true for merge import.",
    parameters: [
      id: [in: :path, type: :string, description: "Project UUID"],
      merge: [
        in: :query,
        type: :boolean,
        description:
          "Merge mode (update existing). Also accepted as a JSON boolean in the body; any " <>
            "value but true or false is 422."
      ],
      report_orphans: [
        in: :query,
        type: :boolean,
        description:
          "Merge mode only (#880): include `stories_orphaned`, the project's stories the " <>
            "payload does not mention (nothing is detached). Meaningful for a FULL round-trip " <>
            "of an export; on a partial merge every unmentioned story is listed. Absent or " <>
            "false, the key is omitted. 422 without merge=true, and for any value but true or " <>
            "false. Both flags may instead be JSON booleans in the body (`ImportRequest`)."
      ]
    ],
    request_body: {"Import data", "application/json", Schemas.ImportRequest},
    responses: %{
      201 =>
        {"Import summary", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      200 =>
        {"Merge summary (merge=true): `epics_created`, `epics_updated`, `stories_created`, " <>
           "`stories_updated`, `dependencies_created`, `dependencies_existing`, and " <>
           "`stories_orphaned` ([{number, title}]) only when `report_orphans` is true",
         "application/json", %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Project not found", "application/json", Schemas.ErrorResponse},
      409 => {"Conflict", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:export_project,
    summary: "Export project",
    description: "Exports a complete project as JSON.",
    parameters: [id: [in: :path, type: :string, description: "Project UUID"]],
    responses: %{
      200 => {"Export data", "application/json", Schemas.ExportResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/projects/:id/import

  Imports a work breakdown into a project. When `merge=true` query param
  is present, performs a merge import that updates existing entities.
  """
  def import_project(conn, %{"id" => project_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn) |> Keyword.put(:caller_role, api_key.role)

    with {:ok, merge?} <- flag(params, "merge"),
         {:ok, report_orphans?} <- flag(params, "report_orphans"),
         :ok <- orphans_need_merge(merge?, report_orphans?),
         {:ok, _project} <- Projects.get_project(tenant_id, project_id) do
      if merge? do
        merge_import(conn, tenant_id, project_id, params, [
          {:report_orphans, report_orphans?} | audit_opts
        ])
      else
        do_fresh_import(conn, tenant_id, project_id, params, audit_opts)
      end
    end
  end

  # ONE reading of both flags (#880): the query string's "true"/"false" or a JSON boolean in the
  # body — Phoenix merges the body over the query, so the body wins where both are given.
  # Anything else is refused, never read as false: a flag misread as off silently runs a fresh
  # import, or drops the orphan list the caller asked for.
  defp flag(params, name) do
    case Map.get(params, name) do
      value when value in [nil, false, "false"] -> {:ok, false}
      value when value in [true, "true"] -> {:ok, true}
      _other -> {:error, :unprocessable_entity, "#{name} must be true or false"}
    end
  end

  # Orphans are a MERGE's report; on a fresh import the flag would be silently meaningless.
  defp orphans_need_merge(false, true),
    do: {:error, :unprocessable_entity, "report_orphans needs merge=true"}

  defp orphans_need_merge(_merge?, _report_orphans?), do: :ok

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

  defp merge_import(conn, tenant_id, project_id, params, opts) do
    case ImportExport.merge_import_project(tenant_id, project_id, params, opts) do
      {:ok, summary} ->
        json(conn, %{import: summary})

      {:error, :validation, message} ->
        {:error, :unprocessable_entity, message}

      {:error, :cycle_detected, message} ->
        {:error, :unprocessable_entity, message}
    end
  end
end
