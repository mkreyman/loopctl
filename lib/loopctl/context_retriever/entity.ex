defmodule Loopctl.ContextRetriever.Entity do
  @moduledoc """
  Schema for the `entity_definitions` table (Epic 30, Context Retriever).

  An **entity definition** is a tenant-admin-authored declaration of a queryable
  "entity" — a name, a set of typed fields, and a backing loopctl-internal source
  (`projects` / `stories` / `epics`). Later stories (US-30.2 generator, US-30.3
  executor) turn each definition into an auto-generated, governed agent query
  surface over loopctl's STRUCTURED records.

  ## Security root — the definition IS the executor's field allowlist

  The entity definition is **attacker-authored**: a tenant admin (role >= user)
  writes it, and the executor later shapes rows to the "declared fields only". If
  an admin could declare arbitrary columns (`tenant_id`, audit/custody columns,
  raw jsonb blobs), the "declared-fields-only" shaping would faithfully
  exfiltrate them. To prevent that, a **SERVER-defined per-backing-source column
  allowlist** (`@column_allowlist`, a code constant) bounds which columns any
  entity may declare. `create_changeset/2` REJECTS any declared field whose name
  is not in the allowlist for the row's `backing_source`, in addition to
  validating a safe-identifier regex, the field `type` against a fixed set, and
  the `filterable`/`searchable` booleans. This is the whole point of the story —
  do not weaken it.

  ## Fields

  - `tenant_id` — set programmatically, NEVER cast (multi-tenant/RLS rule).
  - `name` — the admin-chosen entity name, unique per tenant. Independent of
    `backing_source` (an entity named `"story"` may back onto `:stories`).
  - `backing_source` — `Ecto.Enum`, phase-1 loopctl-internal sources only
    (`:projects`, `:stories`, `:epics`).
  - `fields` — `{:array, :map}`; each element is
    `%{"name" => ..., "type" => ..., "filterable" => bool, "searchable" => bool}`
    with per-element validation.

  ## Reading a field element

  Field elements may be atom-keyed (build path) or string-keyed (DB
  round-trip). `field_value/2`, `field_string_value/2`, `filterable?/1`, and
  `searchable?/1` are the canonical, public readers for that dual-key-shape
  contract — other modules that need to inspect a declared field element
  (e.g. `Loopctl.ContextRetriever.ToolGenerator`) MUST use these instead of
  re-implementing their own key-shape handling.

  ## Relationships are OUT of scope for v1 (AC-30.1.6)

  Relationships / joins between entities are explicitly NOT persisted in v1 — no
  unvalidated relationship JSON is stored anywhere on this schema. Any future
  relationship or join-traversal feature MUST, before it ships, add:

    1. **per-join tenant scoping** — every joined source is filtered by the same
       `tenant_id` (RLS + explicit predicate), so a join can never cross tenants;
       and
    2. **target-entity-must-be-allowlisted validation** — the join target must
       itself be an allowlisted entity/source (never a raw table name), so the
       column allowlist above is not bypassed by traversing into an unsanctioned
       source.

  Shipping join traversal without BOTH of these re-opens exactly the
  exfiltration hole `@column_allowlist` closes.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # Phase-1 backing sources: loopctl-internal STRUCTURED records only.
  @backing_sources [:projects, :stories, :epics]

  # Allowed field types a tenant admin may declare. Kept as a fixed set so a
  # tenant-supplied `type` string is compared, never `String.to_atom/1`'d.
  @field_types ~w(string integer boolean float datetime)

  # Hard cap on how many fields one entity may declare. The per-tenant Registry
  # cap bounds entity COUNT, not fields-per-entity, so without this a single
  # definition could declare an unbounded number of fields and inflate the
  # generated ListTools payload/latency (US-30.2). Every valid field must also be
  # an allowlisted, non-duplicate column, so the largest real source (stories, 9
  # columns) sits well under this; the cap is a payload/DoS guard, not a
  # functional limit.
  @max_fields 50

  # The ONLY keys a declared field map may carry. `field :fields, {:array, :map}`
  # casts each element verbatim, so extra keys (e.g. a multi-megabyte `blob`)
  # would otherwise round-trip into the stored jsonb of this security-root record.
  # Each field map is normalized with `Map.take/2` to these keys (in both string
  # and atom form, since params arrive atom-keyed and the DB round-trips
  # string-keyed) before validation and storage.
  @sanctioned_field_keys ~w(name type filterable searchable)a
  @sanctioned_field_key_strings ~w(name type filterable searchable)

  # Safe-identifier regex for a declared field `name`. Bounds names to
  # lowercase snake_case identifiers, defeating `status; DROP TABLE` style input.
  @identifier_regex ~r/^[a-z_][a-z0-9_]*$/

  # SERVER-defined per-backing-source exposed-column allowlist (AC-30.1.2).
  #
  # This is the SECURITY GATE of Epic 30: it is the exhaustive set of columns a
  # tenant admin may expose per source. It DELIBERATELY excludes `tenant_id`, the
  # `metadata` jsonb blob, and every custody/dispatch/audit column
  # (`implementer_dispatch_id`, `verifier_dispatch_id`, `assigned_agent_id`,
  # timestamps of custody transitions, etc.). Adding a column here exposes it to
  # every tenant admin's declared query surface — treat additions as a security
  # review, not a convenience.
  @column_allowlist %{
    projects: [
      :name,
      :slug,
      :repo_url,
      :description,
      :tech_stack,
      :status,
      :mission
    ],
    stories: [
      :number,
      :title,
      :description,
      :agent_status,
      :verified_status,
      :epic_id,
      :project_id,
      :sort_key,
      :estimated_hours
    ],
    epics: [
      :number,
      :title,
      :description,
      :phase,
      :position,
      :project_id
    ]
  }

  # Precompute the allowlist as a set of STRING column names per source, so a
  # tenant-supplied field `name` (a string) is membership-tested WITHOUT ever
  # calling `String.to_atom/1` on user input.
  @column_allowlist_strings Map.new(@column_allowlist, fn {source, cols} ->
                              {source, MapSet.new(Enum.map(cols, &Atom.to_string/1))}
                            end)

  schema "entity_definitions" do
    tenant_field()
    field :name, :string
    field :backing_source, Ecto.Enum, values: @backing_sources
    field :fields, {:array, :map}, default: []

    timestamps()
  end

  @doc """
  Changeset for creating a new entity definition.

  `tenant_id` is set programmatically on the struct and is NEVER cast. Validates:

    * `name`, `backing_source`, `fields` all present;
    * `fields` declares at least one field — an empty list is rejected (a
      zero-field entity would generate a useless, empty tool surface) — and at
      most `#{@max_fields}` (payload/DoS guard on the generated tool surface);
    * each declared field map is normalized to the four sanctioned keys
      (`name`/`type`/`filterable`/`searchable`) so no extra key (e.g. an
      arbitrary `blob`) round-trips into this security-root record's jsonb;
    * `backing_source` is one of the phase-1 sources (`Ecto.Enum` rejects
      unknowns automatically);
    * each element of `fields` is a well-formed
      `%{name, type, filterable, searchable}` map whose `name` matches the
      safe-identifier regex, whose `type` is in the allowed set, whose
      `filterable`/`searchable` are booleans, AND whose `name` is in the SERVER
      column allowlist for the row's `backing_source`;
    * no field `name` is declared more than once (a duplicate would emit
      duplicate tool-parameter/select entries downstream).
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(entity \\ %__MODULE__{}, attrs) do
    entity
    |> cast(attrs, [:name, :backing_source, :fields])
    |> validate_required([:name, :backing_source, :fields])
    |> validate_format(:name, @identifier_regex,
      message: "must be a lowercase snake_case identifier"
    )
    |> validate_length(:name, max: 100)
    |> normalize_field_keys()
    |> validate_length(:fields, max: @max_fields)
    |> validate_non_empty_fields()
    |> validate_fields()
    |> unique_constraint([:tenant_id, :name],
      message: "has already been taken for this tenant",
      error_key: :name
    )
  end

  @doc "Returns the list of valid backing sources."
  @spec backing_sources() :: [atom()]
  def backing_sources, do: @backing_sources

  @doc "Returns the list of allowed field-type strings."
  @spec field_types() :: [String.t()]
  def field_types, do: @field_types

  @doc """
  Returns the SERVER column allowlist (source atom => list of column atoms).

  Later stories (US-30.2 generator, US-30.3 executor) read this to bound the
  generated/executed query surface to sanctioned columns only.
  """
  @spec column_allowlist() :: %{atom() => [atom()]}
  def column_allowlist, do: @column_allowlist

  @doc """
  Reads a declared field element's raw value under `key`.

  `entity.fields` elements may be atom-keyed (build path, e.g. `%Entity{}`
  literals in tests) or string-keyed (DB round-trip, since `fields` is
  `{:array, :map}`). This is THE canonical reader for that dual-key-shape
  contract — `Loopctl.ContextRetriever.ToolGenerator` (US-30.2) consumes it
  rather than re-implementing its own copy, so both interpretations of this
  security-root field-map shape stay in lockstep.
  """
  @spec field_value(map(), String.t()) :: term()
  def field_value(map, key), do: value(map, key)

  @doc """
  Reads a declared field element's value under `key`, coerced to a string.

  Returns `nil` if the value is absent or not string/atom.
  """
  @spec field_string_value(map(), String.t()) :: String.t() | nil
  def field_string_value(map, key), do: string_value(map, key)

  @doc "Whether a declared field element has `filterable: true`."
  @spec filterable?(map()) :: boolean()
  def filterable?(field), do: field_value(field, "filterable") == true

  @doc "Whether a declared field element has `searchable: true`."
  @spec searchable?(map()) :: boolean()
  def searchable?(field), do: field_value(field, "searchable") == true

  # --- Private helpers ---

  # Strip every declared field map down to the sanctioned keys BEFORE validation
  # and storage, so an unknown key (e.g. `%{name: ..., blob: <megabytes>}`) cannot
  # round-trip into the `{:array, :map}` jsonb of this security-root record. Runs
  # only when `:fields` was cast to a list; non-list values are left for
  # `validate_fields/1` to reject. `Map.take/2` keeps whichever key form (string
  # or atom) each element actually carries.
  defp normalize_field_keys(changeset) do
    case get_change(changeset, :fields) do
      fields when is_list(fields) ->
        put_change(changeset, :fields, Enum.map(fields, &take_sanctioned_keys/1))

      _ ->
        changeset
    end
  end

  defp take_sanctioned_keys(field) when is_map(field) and not is_struct(field) do
    Map.take(field, @sanctioned_field_keys ++ @sanctioned_field_key_strings)
  end

  defp take_sanctioned_keys(field), do: field

  # Per-element validation of the `fields` array. Runs against the row's
  # `backing_source` so the column allowlist is source-specific. A missing/unknown
  # `backing_source` short-circuits with no field errors — `Ecto.Enum` +
  # `validate_required` already flag that, and there is no allowlist to check
  # against.
  # Reject a definition that declares zero fields. `validate_length(:fields, min: 1)`
  # canNOT be used here: the schema default for `fields` is `[]`, so casting an
  # empty list (or omitting `fields`) produces NO change and `validate_length`
  # skips it. Read the resolved value via `get_field/2` instead. A zero-field
  # entity would generate a useless, empty tool surface downstream (US-30.2).
  defp validate_non_empty_fields(changeset) do
    case get_field(changeset, :fields) do
      [] -> add_error(changeset, :fields, "must declare at least one field")
      _ -> changeset
    end
  end

  defp validate_fields(changeset) do
    source = get_field(changeset, :backing_source)

    validate_change(changeset, :fields, fn :fields, fields ->
      field_list_errors(fields, source)
    end)
  end

  defp field_list_errors(fields, _source) when not is_list(fields) do
    [fields: "must be a list of field definitions"]
  end

  # No source to validate columns against; the enum/required checks already erred.
  defp field_list_errors(_fields, nil), do: []

  defp field_list_errors(fields, source) do
    per_element =
      fields
      |> Enum.with_index()
      |> Enum.flat_map(fn {field, index} -> field_errors(field, index, source) end)

    per_element ++ duplicate_name_errors(fields)
  end

  # Reject an entity that declares the same field `name` twice. Duplicates would
  # otherwise round-trip into the stored `fields` array and let the US-30.2
  # generator emit duplicate tool-parameter/select entries. Names are compared as
  # strings so `"title"` and `:title` collide; unnamed/malformed elements are
  # skipped here (their own per-element error already fired).
  defp duplicate_name_errors(fields) do
    fields
    |> Enum.map(&declared_name/1)
    |> Enum.reject(&is_nil/1)
    |> duplicated_values()
    |> Enum.map(fn name ->
      {:fields, "field name #{inspect(name)} is declared more than once"}
    end)
  end

  defp declared_name(field) when is_map(field) and not is_struct(field) do
    string_value(field, "name")
  end

  defp declared_name(_field), do: nil

  # Distinct values that appear more than once, each reported once.
  defp duplicated_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end

  defp field_errors(field, index, source) when is_map(field) and not is_struct(field) do
    name = string_value(field, "name")
    type = type_string(value(field, "type"))
    filterable = value(field, "filterable")
    searchable = value(field, "searchable")

    []
    |> validate_field_name(name, index, source)
    |> validate_field_type(type, index)
    |> validate_field_boolean(filterable, "filterable", index)
    |> validate_field_boolean(searchable, "searchable", index)
  end

  defp field_errors(_field, index, _source) do
    [fields: "field ##{index} must be a map with name, type, filterable, searchable"]
  end

  defp validate_field_name(errors, name, index, source) do
    allowed = Map.get(@column_allowlist_strings, source, MapSet.new())

    cond do
      not is_binary(name) ->
        [{:fields, "field ##{index} name is required"} | errors]

      not Regex.match?(@identifier_regex, name) ->
        [{:fields, "field ##{index} name #{inspect(name)} is not a safe identifier"} | errors]

      not MapSet.member?(allowed, name) ->
        [
          {:fields,
           "field ##{index} name #{inspect(name)} is not an allowed column for source #{source}"}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_field_type(errors, type, index) do
    if is_binary(type) and type in @field_types do
      errors
    else
      [
        {:fields, "field ##{index} type #{inspect(type)} is not one of #{inspect(@field_types)}"}
        | errors
      ]
    end
  end

  defp validate_field_boolean(errors, value, key, index) do
    if is_boolean(value) do
      errors
    else
      [{:fields, "field ##{index} #{key} must be a boolean"} | errors]
    end
  end

  # Read a value under the string key OR its atom equivalent. Admin params may
  # arrive with atom keys (`%{name: ...}`) on the create path, while the DB
  # round-trips `{:array, :map}` as string-keyed maps. The atom keys checked here
  # (`name`/`type`/`filterable`/`searchable`) are compile-time literals, so no
  # atom is ever created from user input.
  defp value(map, "name"), do: map["name"] || map[:name]
  defp value(map, "type"), do: map["type"] || map[:type]
  defp value(map, "filterable"), do: fetch_bool_key(map, "filterable", :filterable)
  defp value(map, "searchable"), do: fetch_bool_key(map, "searchable", :searchable)

  # For boolean keys, `||` would swallow a legitimate `false`, so fetch explicitly.
  defp fetch_bool_key(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, v} -> v
      :error -> Map.get(map, atom_key)
    end
  end

  # Normalize a declared `type` to a string for comparison against `@field_types`.
  # Accepts a string (`"string"`) or an atom (`:string`) — `to_string/1` on an
  # existing atom is safe (creates no new atom), unlike `String.to_atom/1` on the
  # user-supplied value. Any other shape becomes `nil` (→ validation error).
  defp type_string(v) when is_binary(v), do: v
  defp type_string(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp type_string(_), do: nil

  defp string_value(map, key) do
    case value(map, key) do
      v when is_binary(v) -> v
      v when is_atom(v) and not is_nil(v) -> Atom.to_string(v)
      _ -> nil
    end
  end
end
