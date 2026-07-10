defmodule Loopctl.ContextRetriever.ToolGenerator do
  @moduledoc """
  Pure generator turning an `%Loopctl.ContextRetriever.Entity{}` definition into
  the list of agent tool specs it authorizes (Epic 30, Context Retriever).

  This is the bridge between a persisted entity definition (US-30.1) and the
  agent tool surface later consumed by the executor (US-30.3), the API
  (US-30.4), and MCP dynamic listing (US-30.5). `specs_for/1` defines the spec
  SHAPE those all agree on — no DB access, no side effects, no process: same
  entity in, same list of tool spec maps out, every time.

  ## Generated tools

    * One `cr_filter_<entity>_by_<field>` tool per declared field whose
      `filterable` is `true`. Its input schema types the field param from the
      declared field `type`, plus `limit`/`cursor` pagination params.
    * One `cr_search_<entity>` tool, emitted iff the entity has at least one
      field that is BOTH `searchable` AND a text-like `type` (currently
      `string` — see `@text_types`). A `searchable` field of a non-text type
      (e.g. an integer marked searchable) does not by itself trigger the
      search tool; the AC-30.2.1 restriction is "searchable TEXT field", not
      merely "searchable field", since a full-text search over a non-text
      column is meaningless to the US-30.3 executor. Its input schema takes a
      `query` string plus `limit`/`cursor` pagination params, and searches
      across ALL of the entity's searchable TEXT fields collectively (the tool
      is per-entity, not per-field).

  A field that is neither `filterable` nor (searchable AND text-typed)
  produces no tool at all — the generated surface is exactly the allowlist,
  nothing more (AC-30.2.4).

  ## The `cr_` prefix

  Tool names are prefixed `cr_` (context-retriever) so they can never collide
  with loopctl's static MCP tools, none of which start with `cr_`/`filter_`/
  `search_` (AC-30.2.3).

  ## Metadata is the executor's dispatch contract

  Every spec carries a `metadata` map (`entity`, `backing_source`, `field`,
  `operation`, and — for filter tools — `field_type`; for the search tool —
  `searchable_fields`, the exact list of searchable-text column names it
  spans) so US-30.3's executor dispatches on STRUCTURED data, never by
  re-parsing the tool name string or re-deriving the searchable-field set.

  ## Key-shape robustness

  `entity.fields` elements may be atom-keyed (build path, e.g. tests
  constructing an `%Entity{}` literal) or string-keyed (DB round-trip, since
  `fields` is `{:array, :map}`). This module reads both forms via
  `Loopctl.ContextRetriever.Entity`'s public `field_value/2`,
  `field_string_value/2`, `filterable?/1`, and `searchable?/1` accessors — the
  canonical, single source of truth for that dual-key-shape contract — rather
  than re-implementing its own copy. `String.to_atom/1` is never called on
  field content.
  """

  alias Loopctl.ContextRetriever.Entity

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          metadata: map()
        }

  @tool_prefix "cr_"

  # Text-like field types eligible to back the search tool (AC-30.2.1: "searchable
  # TEXT field", not merely "searchable field"). Kept as a fixed set, compared
  # against the declared `type` string, so a non-text column (e.g. an integer
  # marked searchable) never triggers a meaningless full-text search tool.
  @text_types ~w(string)

  @doc """
  Returns the deterministic list of tool specs authorized by `entity`.

  Filter specs (one per `filterable` field, in field-declaration order) come
  first, followed by the single `cr_search_<entity>` spec when the entity has
  at least one field that is both `searchable` and text-typed. Calling this
  repeatedly on an unchanged entity returns an identical list (AC-30.2.2/
  AC-30.2.3 determinism).
  """
  @spec specs_for(Entity.t()) :: [spec()]
  def specs_for(%Entity{name: entity_name, backing_source: backing_source, fields: fields}) do
    filter_specs =
      fields
      |> Enum.filter(&Entity.filterable?/1)
      |> Enum.map(&filter_spec(entity_name, backing_source, &1))

    searchable_field_names =
      fields
      |> Enum.filter(&searchable_text?/1)
      |> Enum.map(&field_name/1)

    search_specs =
      case searchable_field_names do
        [] -> []
        names -> [search_spec(entity_name, backing_source, names)]
      end

    filter_specs ++ search_specs
  end

  # --- Filter tool ---

  defp filter_spec(entity_name, backing_source, field) do
    field_name = field_name(field)
    field_type = Entity.field_string_value(field, "type")
    tool_name = "#{@tool_prefix}filter_#{entity_name}_by_#{field_name}"

    %{
      name: tool_name,
      description:
        "Filter #{entity_name} records where #{field_name} matches the given value. " <>
          "Returns a page of matching records.",
      input_schema: %{
        "type" => "object",
        # Static pagination params are the base; the declared field's own type
        # is applied LAST via `Map.put/3` so it always wins if `field_name`
        # ever collided with a reserved key ("limit"/"cursor") — not reachable
        # today since the US-30.1 column allowlist contains no such names, but
        # this keeps a future collision a correctly-typed field param rather
        # than a silently wrong-typed pagination param.
        "properties" =>
          %{"limit" => %{"type" => "integer"}, "cursor" => %{"type" => "string"}}
          |> Map.put(field_name, json_schema_type(field_type)),
        "required" => [field_name]
      },
      metadata: %{
        entity: entity_name,
        backing_source: backing_source,
        field: field_name,
        operation: :filter,
        field_type: field_type
      }
    }
  end

  # --- Search tool ---

  defp search_spec(entity_name, backing_source, searchable_field_names) do
    %{
      name: "#{@tool_prefix}search_#{entity_name}",
      description:
        "Full-text search across #{entity_name}'s searchable fields. " <>
          "Returns a page of matching records.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"},
          "limit" => %{"type" => "integer"},
          "cursor" => %{"type" => "string"}
        },
        "required" => ["query"]
      },
      metadata: %{
        entity: entity_name,
        backing_source: backing_source,
        field: nil,
        operation: :search,
        searchable_fields: searchable_field_names
      }
    }
  end

  # --- Field-type -> JSON Schema mapping ---

  defp json_schema_type("string"), do: %{"type" => "string"}
  defp json_schema_type("integer"), do: %{"type" => "integer"}
  defp json_schema_type("boolean"), do: %{"type" => "boolean"}
  defp json_schema_type("float"), do: %{"type" => "number"}
  defp json_schema_type("datetime"), do: %{"type" => "string", "format" => "date-time"}
  defp json_schema_type(_other), do: %{"type" => "string"}

  # --- Predicates ---

  # AC-30.2.1: the search tool spans "searchable TEXT field"s, not merely
  # "searchable field"s — a `searchable` field of a non-text type (e.g. an
  # integer) does not qualify.
  defp searchable_text?(field), do: Entity.searchable?(field) and text_type?(field)

  defp text_type?(field), do: Entity.field_string_value(field, "type") in @text_types

  # --- Field readers (delegate to Entity's public dual-key-shape contract) ---

  defp field_name(field), do: Entity.field_string_value(field, "name")
end
