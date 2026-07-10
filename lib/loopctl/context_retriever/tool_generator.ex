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
      declared field `type`, plus `limit`/`offset` pagination params.
    * One `cr_search_<entity>` tool, emitted iff the entity has at least one
      field that is BOTH `searchable` AND a text-like `type` (currently
      `string` — see `@text_types`) AND that field is covered by the source's
      generated `search_vector` (`Entity.search_vector_columns/0`). A
      `searchable` field of a non-text type (e.g. an integer marked searchable)
      does not by itself trigger the search tool; the AC-30.2.1 restriction is
      "searchable TEXT field", not merely "searchable field", since a full-text
      search over a non-text column is meaningless to the US-30.3 executor. A
      searchable text field the vector does NOT index (e.g.
      `stories.agent_status`, `projects.slug`) ALSO suppresses the search tool
      (AC-30.3.4: "if a source's searchable columns can't be indexed in v1, that
      entity's search tool is not generated") — otherwise the executor's fixed
      `search_vector` query would silently search different columns than the
      entity declared. Its input schema takes a `query` string plus
      `limit`/`offset` pagination params, and searches across ALL of the
      entity's searchable TEXT fields collectively (the tool is per-entity, not
      per-field).

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

  # Field-type vocabulary lives authoritatively on `Entity.field_types/0`. Every
  # type declared there MUST be explicitly classified here as `:text` (eligible
  # to back the search tool, AC-30.2.1: "searchable TEXT field", not merely
  # "searchable field") or `:non_text` — see the compile-time guard below.
  # Classifying is a deliberate call per type (e.g. an integer marked
  # searchable never triggers a meaningless full-text search tool), so this map
  # is hand-maintained, NOT derived from the type's JSON Schema shape.
  @field_type_classification %{
    "string" => :text,
    "integer" => :non_text,
    "boolean" => :non_text,
    "float" => :non_text,
    "datetime" => :non_text
  }

  @text_types @field_type_classification
              |> Enum.filter(fn {_type, kind} -> kind == :text end)
              |> Enum.map(fn {type, _kind} -> type end)

  # Explicit JSON Schema mapping per `Entity.field_types/0` member. See the
  # compile-time guard below — this map, like `@field_type_classification`,
  # must cover every Entity-declared field type.
  @json_schema_types %{
    "string" => %{"type" => "string"},
    "integer" => %{"type" => "integer"},
    "boolean" => %{"type" => "boolean"},
    "float" => %{"type" => "number"},
    "datetime" => %{"type" => "string", "format" => "date-time"}
  }

  # Compile-time guard: if a future `Entity.@field_types` addition (e.g.
  # `"decimal"` or `"text"`) is left unclassified/unmapped here, compilation
  # fails loudly instead of the generator silently falling back to
  # `%{"type" => "string"}` (json_schema_type/1) or silently excluding the new
  # type from the search tool (@text_types) — the schema-drift bug this guard
  # closes.
  unmapped_field_types =
    Enum.uniq(
      (Entity.field_types() -- Map.keys(@field_type_classification)) ++
        (Entity.field_types() -- Map.keys(@json_schema_types))
    )

  if unmapped_field_types != [] do
    raise CompileError,
      description:
        "Loopctl.ContextRetriever.ToolGenerator is missing a @field_type_classification and/or " <>
          "@json_schema_types entry for Entity field type(s) #{inspect(unmapped_field_types)}. " <>
          "Add explicit entries for it before compiling."
  end

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
        [] ->
          []

        names ->
          if vector_indexed?(backing_source, names) do
            [search_spec(entity_name, backing_source, names)]
          else
            # AC-30.3.4: at least one declared searchable text field is not
            # covered by the source's generated `search_vector`, so it cannot be
            # indexed in v1 — suppress the search tool rather than emit one the
            # executor would answer over the WRONG (vector-covered) columns.
            []
          end
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
        # ever collided with a reserved key ("limit"/"offset") — not reachable
        # today since the US-30.1 column allowlist contains no such names, but
        # this keeps a future collision a correctly-typed field param rather
        # than a silently wrong-typed pagination param.
        #
        # Pagination is `offset`-based to match the US-30.3 `Executor`, which
        # reads `params["offset"]` and returns `meta: %{limit, offset}`
        # (AC-30.3.5). An earlier `cursor` param here was a dead contract — the
        # executor never read it and emits no cursor, so only page 1 was
        # reachable; `offset` reconciles the generated surface with the executor.
        "properties" =>
          %{"limit" => %{"type" => "integer"}, "offset" => %{"type" => "integer"}}
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
          # `offset`-based to match the US-30.3 executor (AC-30.3.5); see the
          # filter spec's pagination note.
          "offset" => %{"type" => "integer"}
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

  # Derived from `@json_schema_types`, guarded at compile time (above) to cover
  # every `Entity.field_types/0` member. The fallback only fires for a type
  # string that isn't one of `Entity.field_types/0` at all (e.g. malformed
  # data) — never for a real, unmapped Entity type, since that case is now a
  # compile error instead of a silent runtime fallback.
  defp json_schema_type(type), do: Map.get(@json_schema_types, type, %{"type" => "string"})

  # --- Predicates ---

  # AC-30.2.1: the search tool spans "searchable TEXT field"s, not merely
  # "searchable field"s — a `searchable` field of a non-text type (e.g. an
  # integer) does not qualify.
  defp searchable_text?(field), do: Entity.searchable?(field) and text_type?(field)

  defp text_type?(field), do: Entity.field_string_value(field, "type") in @text_types

  # AC-30.3.4: every declared searchable text field must be covered by the
  # source's generated `search_vector` (Entity.search_vector_columns/0) for the
  # search tool to be authorized. `field_names` are strings; vector columns are
  # atoms, so compare their string forms (no `String.to_atom/1` on field data).
  defp vector_indexed?(backing_source, field_names) do
    vector_col_strings =
      Entity.search_vector_columns()
      |> Map.get(backing_source, [])
      |> Enum.map(&Atom.to_string/1)

    Enum.all?(field_names, &(&1 in vector_col_strings))
  end

  # --- Field readers (delegate to Entity's public dual-key-shape contract) ---

  defp field_name(field), do: Entity.field_string_value(field, "name")
end
