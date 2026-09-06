defmodule LoopctlWeb.KnowledgeIndexController do
  @moduledoc """
  Controller for the lightweight knowledge catalog endpoint.

  - `GET /api/v1/knowledge/index` -- catalog of published articles (agent+)
  - `GET /api/v1/projects/:project_id/knowledge/index` -- project-scoped catalog (agent+)

  Returns article metadata (no body) grouped by category. Agent callers see only articles
  they own, or marked as `shared`. Higher roles see all articles. Honors `category`,
  `tags`, `offset`, and `limit` query params with deterministic pagination over
  the filtered set (up to 1000 articles per page). A `fields` projection
  (default `id,title,category`) keeps the payload small — request `tags`,
  `status`, or `updated_at` explicitly when needed. `suppressed=only` lists the
  retrieval-suppressed set, which is how an operator finds what there is to undo.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleCursor
  alias Loopctl.Knowledge.Suppression
  alias LoopctlWeb.Helpers.Pagination
  alias LoopctlWeb.Helpers.TagMatch
  alias LoopctlWeb.Helpers.Visibility

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
  @valid_fields ~w(id title category tags status updated_at suppressed_at suppressed_by suppression_reason)
  @default_fields ~w(id title category)

  operation(:index,
    summary: "Knowledge index",
    description:
      "Returns a lightweight catalog of published articles grouped by category. " <>
        "Each article object includes only the projected fields (default " <>
        "id, title, category — see `fields`). " <>
        "Agent callers see only articles they own (when `visibility` is `private` or `owner`) " <>
        "or marked `shared`; higher roles see all articles. " <>
        "When called via GET /projects/:project_id/knowledge/index, includes both " <>
        "tenant-wide and project-specific articles. Honors category/tags filters and " <>
        "offset/limit pagination (default limit 1000, max 1000) with deterministic " <>
        "ordering over the filtered set. `meta.categories` reports per-category " <>
        "counts within the caller's visible articles. Use `fields` to control the projection " <>
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
        description: "Comma-separated tags (match mode set by `match`, default ANY)",
        required: false
      ],
      match: [
        in: :query,
        type: :string,
        description: "Tag match mode: any (default, OR) or all (AND — carries every listed tag)",
        required: false
      ],
      source_type: [
        in: :query,
        type: :string,
        description: "Filter to articles with this source_type (by-source enumeration)",
        required: false
      ],
      source_id: [
        in: :query,
        type: :string,
        description:
          "Filter to articles with this source_id UUID (by-source enumeration). " <>
            "A malformed id matches nothing.",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max articles to return (default 1000, max 1000). A limit above the max is " <>
            "clamped to the maximum — never rejected — so pagination stays complete.",
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
      ],
      suppressed: [
        in: :query,
        type: :string,
        description:
          "How to treat RETRIEVAL-SUPPRESSED articles: `exclude` (default), `include`, or " <>
            "`only`. `only` is the discovery path — it lists exactly what there is to undo " <>
            "with POST /api/v1/articles/:id/unsuppress, which is what makes the suppression " <>
            "reversible in practice rather than only in principle. An unrecognised value " <>
            "resolves to `exclude`: a typo must never put a suppressed article back on a " <>
            "listing. Honored on BOTH the offset and the keyset path.",
        required: false
      ],
      cursor: [
        in: :query,
        type: :string,
        description:
          "Opaque KEYSET cursor for drift-free enumeration of the index (US-27.9b). " <>
            "To use cursor pagination, pass an empty string (`cursor=`) on the FIRST " <>
            "request to opt into the keyset path (which orders by `inserted_at ASC, " <>
            "id ASC`); then follow `meta.next_cursor` verbatim on subsequent requests. " <>
            "Omitting the `cursor` parameter entirely uses the legacy offset path " <>
            "(orders by `category, updated_at DESC, id`), which does not emit " <>
            "`next_cursor`. Do not mix the two paths mid-enumeration, as the sort order " <>
            "differs. The keyset path honors the same category/tags/source filters and " <>
            "is the drift-free way to walk a tag or a source to exhaustion under " <>
            "concurrent writes. The cursor is integrity-protected and tenant-bound — a " <>
            "tampered/forged cursor is rejected with 400.",
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

    with {:ok, _effective_limit} <- Pagination.validate_limit(params),
         {:ok, fields} <- parse_fields(params["fields"]),
         {:ok, base_opts} <- build_opts(params) do
      opts = Keyword.merge(base_opts, Visibility.scope_opts(conn))

      # US-27.9b: the presence of a `cursor` query param (even empty) opts the index
      # into drift-free keyset pagination — the same dual path the search list uses.
      # Tenant scope is ALWAYS the principal's (`tenant_id`), never the cursor; the
      # cursor is decoded+verified with the caller's tenant key (AC-27.9b.4).
      #
      #   - param ABSENT    → legacy offset path (back-compat, grouped + total_count)
      #   - param EMPTY     → keyset walk FROM THE START (first page, no seek)
      #   - param a token   → keyset seek AFTER the decoded position
      #   - param malformed → 400 (not a string)
      run_index(conn, tenant_id, opts, fields, keyset_cursor(params))
    end
  end

  # Dispatches the offset vs keyset path (extracted so the cursor-decode branch stays
  # within the credo nesting limit). `:none` → legacy offset; the rest → keyset.
  defp run_index(conn, tenant_id, opts, fields, :none) do
    {:ok, result} = Knowledge.list_index(tenant_id, opts)
    json(conn, LoopctlWeb.KnowledgeIndexJSON.index(result, fields))
  end

  defp run_index(_conn, _tenant_id, _opts, _fields, :invalid) do
    {:error, :bad_request, "cursor parameter must be a string"}
  end

  defp run_index(conn, tenant_id, opts, fields, :start) do
    render_keyset(conn, tenant_id, opts, fields, nil)
  end

  defp run_index(conn, tenant_id, opts, fields, {:cursor, raw}) do
    case ArticleCursor.decode(tenant_id, raw) do
      {:ok, position} ->
        render_keyset(conn, tenant_id, opts, fields, position)

      {:error, :invalid} ->
        {:error, :bad_request,
         "Invalid or tampered cursor. Send an empty 'cursor' to start from the " <>
           "beginning, then follow 'meta.next_cursor' verbatim to paginate."}
    end
  end

  defp render_keyset(conn, tenant_id, opts, fields, position) do
    {:ok, result} = Knowledge.list_index_keyset(tenant_id, Keyword.put(opts, :cursor, position))

    encoded =
      case result.next_cursor do
        nil -> nil
        cursor -> ArticleCursor.encode(tenant_id, cursor)
      end

    json(conn, LoopctlWeb.KnowledgeIndexJSON.keyset(%{result | next_cursor: encoded}, fields))
  end

  # Classifies the `cursor` query param: ABSENT → `:none` (legacy offset path);
  # PRESENT-but-empty → `:start` (keyset from the beginning); a non-empty string →
  # `{:cursor, raw}` (keyset seek); a non-string `cursor[]=` form → `:invalid` (400,
  # not a 500 and not a silent page-1 reset). Mirrors the search controller verbatim.
  defp keyset_cursor(params) when is_map(params) do
    case Map.fetch(params, "cursor") do
      :error -> :none
      {:ok, ""} -> :start
      {:ok, raw} when is_binary(raw) -> {:cursor, raw}
      {:ok, _non_string} -> :invalid
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
    with {:ok, category} <- validate_category(params["category"]),
         {:ok, match} <- TagMatch.parse(params) do
      opts =
        []
        |> maybe_put(:project_id, parse_project_id(params["project_id"]))
        |> maybe_put(:category, category)
        |> maybe_put(:tags, parse_tags(params["tags"]))
        |> Keyword.put(:match, match)
        |> maybe_put(:source_type, parse_source_type(params["source_type"]))
        |> maybe_put(:source_id, parse_source_id(params["source_id"]))
        |> maybe_put(:limit, parse_int(params["limit"]))
        |> maybe_put(:offset, parse_int(params["offset"]))
        # Always set, never `maybe_put`: `Suppression.parse_mode/1` resolves every
        # unrecognised value — including a missing param and a `?suppressed[]=` array form —
        # to `:exclude`, so passing it explicitly is how the default becomes visible in the
        # opts rather than implicit in a Keyword.get default two modules away.
        |> Keyword.put(:suppressed, Suppression.parse_mode(params["suppressed"]))

      {:ok, opts}
    end
  end

  defp parse_source_type(value) when is_binary(value) and value != "", do: value
  defp parse_source_type(_), do: nil

  # `source_id` is matched as a binary_id by the context filter, which maps a
  # malformed (non-UUID) value to "matches nothing" rather than raising. We pass a
  # non-empty string straight through; the context guards the cast.
  defp parse_source_id(value) when is_binary(value) and value != "", do: value
  defp parse_source_id(_), do: nil

  # Best-effort project filter: a malformed (non-UUID) project_id yields
  # tenant-wide results rather than crashing on an Ecto.Query.CastError (a
  # non-UUID path segment would otherwise 500). Consistent with a valid-but-
  # nonexistent project, which already returns tenant-wide articles.
  defp parse_project_id(value) when value in [nil, ""], do: nil

  # Require the canonical 36-char dashed form. `Ecto.UUID.cast/1` also accepts a
  # raw 16-byte binary, so a 16-char junk segment would otherwise coerce into a
  # bogus-but-valid UUID and silently narrow results instead of falling back to
  # tenant-wide.
  defp parse_project_id(value) when is_binary(value) and byte_size(value) == 36 do
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
