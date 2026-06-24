defmodule LoopctlWeb.KnowledgeFacetsController do
  @moduledoc """
  Server-side counting and faceting over the article set.

  - `GET /api/v1/knowledge/count` -- count articles matching filters, no rows (agent+)
  - `GET /api/v1/knowledge/facets` -- count articles grouped by distinct tag (agent+)

  These remove large client-side enumerations: a caller can answer "how many
  *published* articles tagged both X and Y" (`count` with `status`+`tags`+`match=all`)
  or "how many distinct `book-*` books exist" (`facets?group_by=tag&tag_prefix=book-`)
  without paging any article rows.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias LoopctlWeb.Helpers.Pagination
  alias LoopctlWeb.Helpers.TagMatch
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  @valid_statuses Article |> Ecto.Enum.values(:status) |> Enum.map(&to_string/1)
  @valid_categories Article |> Ecto.Enum.values(:category) |> Enum.map(&to_string/1)

  operation(:count,
    summary: "Count articles (no rows)",
    description:
      "Returns the count of articles matching the filters, without returning any " <>
        "rows. Accepts the same filters as the article list (`category`, `status`, " <>
        "`tags`, `match`, `source_type`, `source_id`, `idempotency_key`, `project_id`). " <>
        "With `tags=a,b&match=all` it counts articles carrying BOTH tags; combine with " <>
        "`status=published` for \"how many published articles tagged both\". Role: agent+.",
    parameters: [
      category: [in: :query, type: :string, description: "Filter by category"],
      status: [in: :query, type: :string, description: "Filter by status"],
      tags: [in: :query, type: :string, description: "Filter by tags (comma-separated)"],
      match: [
        in: :query,
        type: :string,
        description: "Tag match mode: any (default, OR) or all (AND)"
      ],
      source_type: [in: :query, type: :string, description: "Filter by source_type"],
      source_id: [in: :query, type: :string, description: "Filter by source_id"],
      idempotency_key: [in: :query, type: :string, description: "Filter by idempotency_key"],
      project_id: [in: :query, type: :string, description: "Filter by project UUID"]
    ],
    responses: %{
      200 =>
        {"Count", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{count: %OpenApiSpex.Schema{type: :integer}}
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/count"
  def count(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with :ok <- validate_enum(params["status"], @valid_statuses, "status"),
         :ok <- validate_enum(params["category"], @valid_categories, "category"),
         :ok <- validate_project_id(params),
         {:ok, match} <- TagMatch.parse(params) do
      count =
        Knowledge.count_articles(
          tenant_id,
          build_opts(params, match) ++ Visibility.scope_opts(conn)
        )

      json(conn, %{count: count})
    end
  end

  operation(:facets,
    summary: "Tag facets (count by distinct tag)",
    description:
      "Counts articles grouped by each distinct tag over the filtered set, so a " <>
        "caller gets a distinct-tag count and per-tag totals without paging rows. " <>
        "`tag_prefix` restricts to a tag family (e.g. `book-`) to count distinct " <>
        "members of that family. `meta.distinct_count` is the TRUE number of distinct " <>
        "tags (independent of `limit`); `meta.truncated` flags when `limit` returned " <>
        "fewer rows. Per-tag `count` is the number of distinct articles carrying the " <>
        "tag. Honors the same filters as `count` (including `status` and `tags`/`match`). " <>
        "Cost: unnests tags over the whole filtered set (the GIN index doesn't help the " <>
        "unnest/group); on large tenants narrow with `tag_prefix`/`category`/`status`/" <>
        "`project_id`. `group_by=tag` is the only mode today. Role: agent+.",
    parameters: [
      group_by: [in: :query, type: :string, description: "Facet dimension (only `tag`)"],
      tag_prefix: [in: :query, type: :string, description: "Only tags starting with this prefix"],
      category: [in: :query, type: :string, description: "Filter by category"],
      status: [in: :query, type: :string, description: "Filter by status"],
      tags: [in: :query, type: :string, description: "Filter by tags (comma-separated)"],
      match: [in: :query, type: :string, description: "Tag match mode: any (default) or all"],
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max distinct tags in the facet result (default all, max 1000; values above 1000 rejected with 400)"
      ]
    ],
    responses: %{
      200 =>
        {"Tag facets", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :object, description: "tag => count"},
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 group_by: %OpenApiSpex.Schema{type: :string},
                 distinct_count: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "True distinct-tag count, independent of limit"
                 },
                 truncated: %OpenApiSpex.Schema{
                   type: :boolean,
                   description: "True when limit returned fewer facet rows than distinct_count"
                 },
                 tag_prefix: %OpenApiSpex.Schema{type: :string, nullable: true}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/facets"
  def facets(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with :ok <- validate_group_by(params["group_by"]),
         :ok <- validate_enum(params["status"], @valid_statuses, "status"),
         :ok <- validate_enum(params["category"], @valid_categories, "category"),
         :ok <- validate_project_id(params),
         :ok <- Pagination.validate_limit(params),
         {:ok, match} <- TagMatch.parse(params) do
      opts =
        params
        |> build_opts(match)
        |> maybe_put(:tag_prefix, string_param(params["tag_prefix"]))
        |> maybe_put(:limit, parse_int(params["limit"]))
        |> Keyword.merge(Visibility.scope_opts(conn))

      %{facets: facets, distinct_count: distinct_count, truncated: truncated} =
        Knowledge.tag_facets(tenant_id, opts)

      data = Map.new(facets, fn %{tag: tag, count: count} -> {tag, count} end)

      json(conn, %{
        data: data,
        meta: %{
          group_by: "tag",
          distinct_count: distinct_count,
          truncated: truncated,
          tag_prefix: string_param(params["tag_prefix"])
        }
      })
    end
  end

  # --- Helpers ---

  defp build_opts(params, match) do
    []
    |> maybe_put(:project_id, string_param(params["project_id"]))
    |> maybe_put(:category, params["category"])
    |> maybe_put(:status, params["status"])
    |> maybe_put(:tags, parse_tags(params["tags"]))
    |> maybe_put(:match, match)
    |> maybe_put(:source_type, string_param(params["source_type"]))
    |> maybe_put(:source_id, string_param(params["source_id"]))
    |> maybe_put(:idempotency_key, string_param(params["idempotency_key"]))
  end

  # Reject a malformed project_id with 400 rather than letting a non-UUID reach
  # the binary_id query and raise Ecto.Query.CastError (a 500). Requires the
  # canonical 36-char dashed form so a 16-char junk segment can't coerce into a
  # bogus-but-valid UUID (mirrors KnowledgeStatsController.project_opts/1).
  defp validate_project_id(params) do
    case params["project_id"] do
      value when value in [nil, ""] ->
        :ok

      value when is_binary(value) and byte_size(value) == 36 ->
        case Ecto.UUID.cast(value) do
          {:ok, _} -> :ok
          :error -> {:error, :bad_request, "Invalid project_id. Must be a UUID."}
        end

      _ ->
        {:error, :bad_request, "Invalid project_id. Must be a UUID."}
    end
  end

  defp validate_group_by(nil), do: :ok
  defp validate_group_by(""), do: :ok
  defp validate_group_by("tag"), do: :ok
  defp validate_group_by(_), do: {:error, :bad_request, "Invalid group_by. Allowed values: tag."}

  defp validate_enum(nil, _allowed, _field), do: :ok
  defp validate_enum("", _allowed, _field), do: :ok

  defp validate_enum(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else:
        {:error, :bad_request, "Invalid #{field}. Allowed values: #{Enum.join(allowed, ", ")}."}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp string_param(value) when is_binary(value), do: value
  defp string_param(_), do: nil

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      parsed -> parsed
    end
  end

  defp parse_tags(_), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
