defmodule LoopctlWeb.DependencyGraphController do
  @moduledoc """
  Controller for dependency graph query endpoints.

  - `GET /api/v1/stories/ready` -- agent+, stories ready to be assigned
  - `GET /api/v1/stories/blocked` -- agent+, stories blocked by deps
  - `GET /api/v1/projects/:id/dependency_graph` -- agent+, full dependency graph
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.WorkBreakdown.Queries

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:ready, :blocked, :graph]

  tags(["Dependencies"])

  operation(:ready,
    summary: "List ready stories",
    description: "Returns stories ready to be assigned (pending, all deps verified).",
    parameters: [
      project_id: [in: :query, type: :string, description: "Filter by project"],
      epic_id: [in: :query, type: :string, description: "Filter by epic"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Ready stories", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.StoryResponse},
             meta: Schemas.PaginationMeta
           }
         }}
    }
  )

  operation(:blocked,
    summary: "List blocked stories",
    description: "Returns stories blocked by unverified dependencies.",
    parameters: [
      project_id: [in: :query, type: :string, description: "Filter by project"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Blocked stories", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}}
    }
  )

  operation(:graph,
    summary: "Get dependency graph",
    description: "Returns the full dependency graph for a project.",
    parameters: [id: [in: :path, type: :string, description: "Project UUID"]],
    responses: %{
      200 =>
        {"Dependency graph", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  GET /api/v1/stories/ready

  Returns stories ready to be assigned (pending, all deps verified).
  """
  def ready(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:project_id, params["project_id"])
      |> maybe_add_opt(:epic_id, params["epic_id"])
      |> maybe_add_opt(:page, parse_int(params["page"]))
      |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

    {:ok, result} = Queries.list_ready_stories(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &story_json/1),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc """
  GET /api/v1/stories/blocked

  Returns stories blocked by unverified dependencies.
  """
  def blocked(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:project_id, params["project_id"])
      |> maybe_add_opt(:page, parse_int(params["page"]))
      |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

    {:ok, result} = Queries.list_blocked_stories(tenant_id, opts)

    json(conn, %{
      data:
        Enum.map(result.data, fn item ->
          %{
            story: story_json(item.story),
            blocking_dependencies: item.blocking_dependencies
          }
        end),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc """
  GET /api/v1/projects/:id/dependency_graph

  Returns the full dependency graph for a project.
  """
  def graph(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Queries.get_dependency_graph(tenant_id, project_id) do
      {:ok, graph} ->
        json(conn, %{graph: graph})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp story_json(story) do
    %{
      id: story.id,
      tenant_id: story.tenant_id,
      project_id: story.project_id,
      epic_id: story.epic_id,
      number: story.number,
      title: story.title,
      agent_status: story.agent_status,
      verified_status: story.verified_status,
      sort_key: story.sort_key,
      inserted_at: story.inserted_at,
      updated_at: story.updated_at
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
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
