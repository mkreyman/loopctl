defmodule LoopctlWeb.KnowledgeExportController do
  @moduledoc """
  Controller for exporting knowledge articles as Obsidian-compatible ZIP files.

  - `GET /api/v1/knowledge/export` -- ZIP of all tenant articles, role: user+
  - `GET /api/v1/projects/:project_id/knowledge/export` -- ZIP of project articles, role: user+

  Only published articles are included. The ZIP contains Markdown files with
  YAML frontmatter, [[wikilinks]] for related articles, and a `_index.md` root file.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  tags(["Knowledge Wiki"])

  operation(:export,
    summary: "Export knowledge as Obsidian ZIP",
    description:
      "Exports published articles as an Obsidian-compatible ZIP archive. " <>
        "Files are organized as `{category}/{slug}.md` with YAML frontmatter, " <>
        "[[wikilinks]], and a root `_index.md`. Only published articles are included. " <>
        "When called via GET /projects/:project_id/knowledge/export, includes both " <>
        "tenant-wide and project-specific articles. Role: user+.",
    parameters: [
      project_id: [
        in: :path,
        type: :string,
        description: "Project UUID (optional, for project-scoped export)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Obsidian ZIP archive", "application/zip",
         %OpenApiSpex.Schema{type: :string, format: :binary}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/export or GET /api/v1/projects/:project_id/knowledge/export"
  def export(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      case params["project_id"] do
        nil -> []
        project_id -> [project_id: project_id]
      end

    case Knowledge.export_obsidian(tenant_id, opts) do
      {:ok, zip_binary} ->
        date = Date.utc_today() |> Date.to_iso8601()

        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"knowledge-export-#{date}.zip\""
        )
        |> send_resp(200, zip_binary)

      {:error, :payload_too_large} ->
        conn
        |> put_status(413)
        |> json(%{
          error: %{
            status: 413,
            message:
              "Export exceeds 5,000 articles. Use project-scoped export " <>
                "(GET /projects/:id/knowledge/export) to reduce scope."
          }
        })
    end
  end
end
