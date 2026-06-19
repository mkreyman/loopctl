defmodule LoopctlWeb.KnowledgeIndexController do
  @moduledoc """
  Controller for the lightweight knowledge catalog endpoint.

  - `GET /api/v1/knowledge/index` -- tenant-wide catalog of published articles (agent+)
  - `GET /api/v1/projects/:project_id/knowledge/index` -- project-scoped catalog (agent+)

  Returns article metadata (no body) grouped by category. Honors `category`,
  `tags`, `offset`, and `limit` query params with deterministic pagination over
  the full filtered set (up to 1000 articles per page).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  @valid_categories Ecto.Enum.values(Article, :category)

  operation(:index,
    summary: "Knowledge index",
    description:
      "Returns a lightweight catalog of published articles grouped by category. " <>
        "Each article includes only id, title, category, tags, status, and updated_at. " <>
        "When called via GET /projects/:project_id/knowledge/index, includes both " <>
        "tenant-wide and project-specific articles. Honors category/tags filters and " <>
        "offset/limit pagination (default limit 1000, max 1000) with deterministic " <>
        "ordering, so every article is reachable. `meta.categories` reports per-category " <>
        "counts over the entire filtered set. Role: agent+.",
    parameters: [
      project_id: [
        in: :path,
        type: :string,
        description: "Project UUID (optional, for project-scoped index)",
        required: false
      ],
      category: [
        in: :query,
        type: :string,
        description:
          "Filter by category (pattern, convention, decision, finding, reference). " <>
            "Returns 400 for an unknown category.",
        required: false
      ],
      tags: [
        in: :query,
        type: :string,
        description: "Comma-separated tags; matches articles carrying ANY of them",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max articles to return (default 1000, max 1000)",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Articles to skip for pagination (default 0)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Knowledge index", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               description: "Articles grouped by category"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 total_count: %OpenApiSpex.Schema{type: :integer},
                 categories: %OpenApiSpex.Schema{type: :object},
                 offset: %OpenApiSpex.Schema{type: :integer},
                 limit: %OpenApiSpex.Schema{type: :integer},
                 truncated: %OpenApiSpex.Schema{type: :boolean}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/index or GET /api/v1/projects/:project_id/knowledge/index"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, opts} <- build_opts(params) do
      {:ok, result} = Knowledge.list_index(tenant_id, opts)
      json(conn, LoopctlWeb.KnowledgeIndexJSON.index(result))
    end
  end

  defp build_opts(params) do
    with {:ok, category} <- validate_category(params["category"]) do
      opts =
        []
        |> maybe_put(:project_id, params["project_id"])
        |> maybe_put(:category, category)
        |> maybe_put(:tags, parse_tags(params["tags"]))
        |> maybe_put(:limit, parse_int(params["limit"]))
        |> maybe_put(:offset, parse_int(params["offset"]))

      {:ok, opts}
    end
  end

  defp validate_category(nil), do: {:ok, nil}
  defp validate_category(""), do: {:ok, nil}

  defp validate_category(category) when is_binary(category) do
    atom = String.to_existing_atom(category)

    if atom in @valid_categories do
      {:ok, atom}
    else
      invalid_category()
    end
  rescue
    ArgumentError -> invalid_category()
  end

  defp invalid_category do
    valid = @valid_categories |> Enum.map_join(", ", &to_string/1)
    {:error, :bad_request, "Invalid category. Valid categories: #{valid}"}
  end

  defp parse_tags(nil), do: nil
  defp parse_tags(""), do: nil

  defp parse_tags(tags_str) when is_binary(tags_str) do
    tags =
      tags_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if tags == [], do: nil, else: tags
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]
end
