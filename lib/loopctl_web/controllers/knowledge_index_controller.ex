defmodule LoopctlWeb.KnowledgeIndexController do
  @moduledoc """
  Controller for the lightweight knowledge catalog endpoint.

  - `GET /api/v1/knowledge/index` -- tenant-wide catalog of published articles (agent+)
  - `GET /api/v1/projects/:project_id/knowledge/index` -- project-scoped catalog (agent+)

  Returns article metadata (no body) grouped by category. Honors `category`,
  `tags`, `offset`, and `limit` query params with deterministic pagination over
  the full filtered set (up to 1000 articles per page). A `fields` projection
  (default `id,title,category`) keeps the payload small — request `tags`,
  `status`, or `updated_at` explicitly when needed.
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
  # The projectable field set is duplicated in three other places that must stay
  # in sync when a field is added/removed:
  #   1. the SELECT in `Knowledge.list_index/2` — must remain a SUPERSET of this
  #      list (it is fixed and projection-independent; the JSON view trims it),
  #   2. `LoopctlWeb.KnowledgeIndexJSON.field_value/2` — one clause per field,
  #   3. the MCP `knowledge_index` tool's `fields` enum in mcp-server/index.js —
  #      a SEPARATELY-RELEASED npm package with no compile-time coupling here, so
  #      an added field must be shipped to both.
  @valid_fields ~w(id title category tags status updated_at)
  @default_fields ~w(id title category)

  operation(:index,
    summary: "Knowledge index",
    description:
      "Returns a lightweight catalog of published articles grouped by category. " <>
        "Each article object includes only the projected fields (default " <>
        "id, title, category — see `fields`). " <>
        "When called via GET /projects/:project_id/knowledge/index, includes both " <>
        "tenant-wide and project-specific articles. Honors category/tags filters and " <>
        "offset/limit pagination (default limit 1000, max 1000) with deterministic " <>
        "ordering, so every article is reachable. `meta.categories` reports per-category " <>
        "counts over the entire filtered set. Use `fields` to control the projection " <>
        "(default id,title,category; request tags/status/updated_at explicitly) to keep " <>
        "the payload small. Role: agent+.",
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
      ],
      fields: [
        in: :query,
        type: :string,
        description:
          "Comma-separated projection (id, title, category, tags, status, updated_at). " <>
            "Default id,title,category. `id` and `category` are always included " <>
            "(category is the grouping key). Returns 400 for unknown fields.",
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
                 truncated: %OpenApiSpex.Schema{type: :boolean},
                 has_more: %OpenApiSpex.Schema{type: :boolean},
                 fields: %OpenApiSpex.Schema{
                   type: :array,
                   items: %OpenApiSpex.Schema{type: :string}
                 }
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

    with {:ok, fields} <- parse_fields(params["fields"]),
         {:ok, opts} <- build_opts(params) do
      {:ok, result} = Knowledge.list_index(tenant_id, opts)
      json(conn, LoopctlWeb.KnowledgeIndexJSON.index(result, fields))
    end
  end

  defp parse_fields(nil), do: {:ok, @default_fields}
  defp parse_fields(""), do: {:ok, @default_fields}

  defp parse_fields(str) when is_binary(str) do
    requested =
      str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    invalid = Enum.reject(requested, &(&1 in @valid_fields))

    cond do
      requested == [] ->
        {:ok, @default_fields}

      invalid != [] ->
        {:error, :bad_request,
         "Invalid fields: #{Enum.join(invalid, ", ")}. Valid fields: #{Enum.join(@valid_fields, ", ")}"}

      true ->
        # Always include id (identity) and category (the grouping key, so each
        # article object stays self-describing when `data` is flattened).
        {:ok, Enum.uniq(["id", "category" | requested])}
    end
  end

  # Non-string fields param (e.g. ?fields[]=x or ?fields[k]=v) → 400, not a 500.
  defp parse_fields(_), do: {:error, :bad_request, "fields must be a comma-separated string"}

  defp build_opts(params) do
    with {:ok, category} <- validate_category(params["category"]) do
      opts =
        []
        |> maybe_put(:project_id, parse_project_id(params["project_id"]))
        |> maybe_put(:category, category)
        |> maybe_put(:tags, parse_tags(params["tags"]))
        |> maybe_put(:limit, parse_int(params["limit"]))
        |> maybe_put(:offset, parse_int(params["offset"]))

      {:ok, opts}
    end
  end

  # Best-effort project filter: a malformed (non-UUID) project_id yields
  # tenant-wide results rather than crashing on an Ecto.Query.CastError (a
  # non-UUID path segment would otherwise 500). Consistent with a valid-but-
  # nonexistent project, which already returns tenant-wide articles.
  defp parse_project_id(value) when value in [nil, ""], do: nil

  defp parse_project_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, project_id} -> project_id
      :error -> nil
    end
  end

  defp parse_project_id(_), do: nil

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

  # Non-string category param (e.g. ?category[]=x) → 400, not a 500.
  defp validate_category(_), do: invalid_category()

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

  # Non-string tags param (e.g. ?tags[]=x) → treated as no tag filter, not a 500.
  defp parse_tags(_), do: nil

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  # Non-scalar limit/offset param (e.g. ?limit[]=x) → ignored, not a 500.
  defp parse_int(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]
end
