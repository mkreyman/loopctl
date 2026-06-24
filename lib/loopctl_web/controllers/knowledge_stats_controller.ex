defmodule LoopctlWeb.KnowledgeStatsController do
  @moduledoc """
  Controller for the lightweight knowledge stats endpoint.

  - `GET /api/v1/knowledge/stats` -- tenant-wide article counts (agent+)
  - `GET /api/v1/projects/:project_id/knowledge/stats` -- project-scoped counts (agent+)

  Returns aggregate `COUNT(*)` totals (no article rows or metadata), so a caller
  can answer "how many articles are here?" without paging the index. Counts
  span all statuses; `by_status` makes the published/draft/etc. split explicit.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  operation(:stats,
    summary: "Knowledge stats",
    description:
      "Returns aggregate article counts for the tenant — `total`, `by_category`, " <>
        "and `by_status` — computed with cheap COUNT(*) GROUP BY queries (no " <>
        "article metadata is loaded). Counts span all statuses (draft, published, " <>
        "archived, superseded); use `by_status` to see the split. When called via " <>
        "GET /projects/:project_id/knowledge/stats, counts both tenant-wide and " <>
        "project-specific articles (same visibility as the index). Role: agent+.",
    parameters: [
      project_id: [
        in: :path,
        type: :string,
        description: "Project UUID (optional, for project-scoped counts)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Knowledge stats", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             total: %OpenApiSpex.Schema{type: :integer},
             by_category: %OpenApiSpex.Schema{
               type: :object,
               description: "Count per category"
             },
             by_status: %OpenApiSpex.Schema{
               type: :object,
               description: "Count per status"
             }
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/stats or GET /api/v1/projects/:project_id/knowledge/stats"
  def stats(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    result =
      Knowledge.stats(
        tenant_id,
        project_opts(params["project_id"]) ++ Visibility.scope_opts(conn)
      )

    json(conn, LoopctlWeb.KnowledgeStatsJSON.stats(result))
  end

  # Best-effort project filter (mirrors KnowledgeAnalyticsController.put_project_id):
  # a missing or malformed project_id yields tenant-wide counts rather than
  # crashing on an Ecto.Query.CastError (a non-UUID path segment would otherwise
  # 500). A valid-but-nonexistent project already yields tenant-wide counts, so
  # this keeps malformed and nonexistent consistent.
  defp project_opts(value) when value in [nil, ""], do: []

  # Require the canonical 36-char dashed form. `Ecto.UUID.cast/1` also accepts a
  # raw 16-byte binary, so a 16-char junk segment would otherwise coerce into a
  # bogus-but-valid UUID and silently narrow the counts instead of falling back
  # to tenant-wide.
  defp project_opts(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, project_id} -> [project_id: project_id]
      :error -> []
    end
  end

  defp project_opts(_), do: []
end
