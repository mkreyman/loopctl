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
          "Merge mode (update existing). Also accepted as a JSON boolean in the body, which " <>
            "must then agree with this; any value but true or false is 422."
      ],
      report_orphans: [
        in: :query,
        type: :boolean,
        description:
          "Merge mode only (#880): include `stories_orphaned`, the project's stories the " <>
            "payload does not mention (nothing is detached). Meaningful for a FULL round-trip " <>
            "of an export; on a partial merge every unmentioned story is listed. Absent or " <>
            "false, the key is omitted. 422 without merge=true, and for any value but true or " <>
            "false. Either flag may instead be a JSON boolean in the body (`ImportRequest`); " <>
            "given in both, the two must agree or it is 422."
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

  Imports a work breakdown into a project. `merge` performs a merge import that updates
  existing entities; `report_orphans` (merge only, #880) adds `stories_orphaned`. Each flag is
  the query string's "true"/"false" or a JSON boolean in the body; given in both it must
  agree. Anything else is 422, as is `report_orphans` without `merge`.
  """
  def import_project(conn, %{"id" => project_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn) |> Keyword.put(:caller_role, api_key.role)

    with {:ok, merge?} <- flag(conn, "merge"),
         {:ok, report_orphans?} <- flag(conn, "report_orphans"),
         :ok <- orphans_need_merge(merge?, report_orphans?),
         {:ok, _project} <- Projects.get_project(tenant_id, project_id) do
      if merge? do
        do_merge_import(conn, tenant_id, project_id, params, [
          {:report_orphans, report_orphans?} | audit_opts
        ])
      else
        do_fresh_import(conn, tenant_id, project_id, params, audit_opts)
      end
    end
  end

  # ONE reading of both flags (#880), from each source SEPARATELY: `params` merges the body over
  # the query, which would let one silently override the other. The query takes "true"/"false",
  # the body a JSON boolean (`Schemas.ImportRequest`); given in both, they must agree. Anything
  # else is refused, never read as false: a flag misread as off silently runs a fresh import, or
  # drops the orphan list the caller asked for.
  defp flag(conn, name) do
    with {:ok, query} <- flag_value(Map.get(conn.query_params, name), ["true", "false"], name),
         {:ok, body} <- flag_value(Map.get(conn.body_params, name), [true, false], name) do
      agree(query, body, name)
    end
  end

  defp flag_value(nil, _accepted, _name), do: {:ok, nil}

  defp flag_value(value, accepted, name) do
    if value in accepted,
      do: {:ok, value in ["true", true]},
      else: {:error, :unprocessable_entity, "#{name} must be true or false"}
  end

  defp agree(nil, nil, _name), do: {:ok, false}
  defp agree(value, nil, _name), do: {:ok, value}
  defp agree(nil, value, _name), do: {:ok, value}
  defp agree(value, value, _name), do: {:ok, value}

  defp agree(_query, _body, name),
    do:
      {:error, :unprocessable_entity,
       "#{name} is given in both the query string and the body, with different values"}

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

  defp do_merge_import(conn, tenant_id, project_id, params, opts) do
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
