defmodule LoopctlWeb.KnowledgeExportController do
  @moduledoc """
  Controller for exporting knowledge articles as an Obsidian-compatible
  `.tar.gz` archive (US-27.16).

  - `GET /api/v1/knowledge/export` -- tenant articles, role: user+
  - `GET /api/v1/projects/:project_id/knowledge/export` -- project articles, role: user+

  Only published articles are included. The archive contains one
  `{category}/{slug}.md` per article with YAML frontmatter, `[[wikilinks]]` for
  related articles, and a root `_index.md`.

  The export is STREAMED as a chunked `.tar.gz` with bounded server memory and NO
  article-count cap (the former 5,000-article 413 is gone): articles are read in
  short keyset pages that release the BYPASSRLS connection between pages, and the
  archive is built incrementally so peak memory holds at most one page. A mid-stream
  error fails CLOSED — the chunked response ends WITHOUT a valid tar end-of-archive,
  so a restore pipeline detects truncation. Concurrent exports are capped
  (per-tenant + global) and refused with `429` over the cap, never starving the
  admin pool. See `Loopctl.Knowledge.StreamingExport`.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge.StreamingExport.ObsidianFormat
  alias LoopctlWeb.Helpers.ProjectId

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  tags(["Knowledge Wiki"])

  operation(:export,
    summary: "Export knowledge as a streamed Obsidian .tar.gz",
    description:
      "Streams published articles as an Obsidian-compatible gzipped tar archive. " <>
        "Files are organized as `{category}/{slug}-{short_id}.md` (the id suffix " <>
        "guarantees collision-free paths) with YAML frontmatter, [[wikilinks]], and " <>
        "a root `_index.md`. Only published articles are included. When called via " <>
        "GET /projects/:project_id/knowledge/export, includes both tenant-wide and " <>
        "project-specific articles. Bounded memory, no article-count cap, fail-closed " <>
        "on mid-stream error. Each article's related-link list is capped at " <>
        "export_max_links_per_article (default 100) per direction; a capped article " <>
        "carries `links_truncated: true` in its frontmatter. Role: user+.",
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
        {"Obsidian .tar.gz archive (chunked)", "application/gzip",
         %OpenApiSpex.Schema{type: :string, format: :binary}},
      429 => {"Too many concurrent exports", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/export or GET /api/v1/projects/:project_id/knowledge/export"
  def export(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    # Validate project_id BEFORE streaming: `send_chunked/2` commits a 200 with
    # no way back to an error status, so a malformed project_id reaching the
    # query would raise mid-stream and truncate the archive. Reject it here so
    # the FallbackController can return a clean 422 before any body is sent.
    with :ok <- ProjectId.validate(params["project_id"]) do
      opts =
        case params["project_id"] do
          value when value in [nil, ""] -> []
          project_id -> [project_id: project_id]
        end

      LoopctlWeb.StreamingExport.stream(
        conn,
        tenant_id,
        ObsidianFormat,
        "knowledge-export",
        opts
      )
    end
  end
end
