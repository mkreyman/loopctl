defmodule Loopctl.ContextRetriever.Dogfood do
  @moduledoc """
  US-30.6 — seeds Context-Retriever entity definitions for loopctl's OWN backing
  tables (`projects`, `stories`, `epics`), per tenant. This is loopctl
  "dogfooding" Epic 30: the generic entity/tool/executor machinery (US-30.1..5)
  pointed at loopctl's own structured records, so an agent can query
  projects/stories/epics through the SAME governed Context-Retriever surface any
  tenant gets.

  ## What this builds vs. reuses

  This module builds NO new query/generator/executor machinery — that is all
  finished. It only declares three entity definitions and persists them through
  the vetted `Loopctl.ContextRetriever.Registry.create_entity/3` path, so the
  seeded definitions are held to EXACTLY the same guarantees as any
  tenant-authored one:

    * the SERVER per-source column allowlist (`Entity.@column_allowlist`,
      US-30.1 AC-30.1.2) — every declared field below is allowlisted, so no
      custody/audit/internal column can be exposed;
    * the per-tenant entity cap + advisory lock (race-free);
    * an `audit_log` entry per created definition (security-root creation);
    * RLS scoping (`Repo.with_tenant`) — the seed is tenant-scoped.

  ## Parity contract (AC-30.6.2)

  The generated `cr_filter_story_by_agent_status` tool is the dogfood analogue of
  the hand-written `Loopctl.WorkBreakdown.Stories.list_stories/3` oracle. Note the
  AC's `cr_filter_story_by_status` is reconciled to **`agent_status`**: a
  `Story` has no single `status` column (it carries `agent_status` +
  `verified_status`), so the filterable status field seeded here is
  `agent_status` (and `verified_status`). The parity/subset proof lives in
  `test/loopctl/context_retriever/dogfood_test.exs`.

  ## Field declarations

  Per source, filterable status/scope fields plus searchable text fields — ALL
  constrained to `Entity.column_allowlist/0` and, for searchable text, to
  `Entity.search_vector_columns/0` (so the search tool is actually generated):

    * `project` → filter: `status`; search: `name`, `description`, `mission`.
    * `story`   → filter: `agent_status`, `verified_status`, `epic_id`;
      search: `title`, `description` (`title` is also filterable).
    * `epic`    → filter: `phase`; search: `title`, `description` (`title` is
      also filterable).

  ## Idempotency

  `seed_default_entities/2` is idempotent: an entity whose `name` already exists
  for the tenant is left untouched and returned as-is (so re-running the seed —
  e.g. a mix task run twice — neither errors on the unique-name constraint nor
  burns entity-cap slots).
  """

  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.ContextRetriever.Registry

  # The three dogfood entity definitions. Each `fields` element is constrained to
  # `Entity.@column_allowlist` for its `backing_source` — the create path rejects
  # anything else, and a compile-time guard (below) keeps this list honest.
  @entity_definitions [
    %{
      name: "project",
      backing_source: :projects,
      fields: [
        %{name: "status", type: "string", filterable: true, searchable: false},
        %{name: "name", type: "string", filterable: true, searchable: true},
        %{name: "description", type: "string", filterable: false, searchable: true},
        %{name: "mission", type: "string", filterable: false, searchable: true}
      ]
    },
    %{
      name: "story",
      backing_source: :stories,
      fields: [
        %{name: "agent_status", type: "string", filterable: true, searchable: false},
        %{name: "verified_status", type: "string", filterable: true, searchable: false},
        %{name: "epic_id", type: "string", filterable: true, searchable: false},
        %{name: "title", type: "string", filterable: true, searchable: true},
        %{name: "description", type: "string", filterable: false, searchable: true}
      ]
    },
    %{
      name: "epic",
      backing_source: :epics,
      fields: [
        %{name: "phase", type: "string", filterable: true, searchable: false},
        %{name: "title", type: "string", filterable: true, searchable: true},
        %{name: "description", type: "string", filterable: false, searchable: true}
      ]
    }
  ]

  # Compile-time guard: every declared field must be in the SERVER column
  # allowlist for its source, so this dogfood seed can never drift ahead of the
  # US-30.1 security constant (a `create_entity` at runtime would reject it, but
  # failing at compile time is louder and keeps the seed trustworthy).
  for %{name: entity_name, backing_source: source, fields: fields} <- @entity_definitions do
    allowed = Entity.column_allowlist() |> Map.fetch!(source) |> Enum.map(&Atom.to_string/1)

    for %{name: field_name} <- fields do
      unless field_name in allowed do
        raise CompileError,
          description:
            "Loopctl.ContextRetriever.Dogfood entity #{inspect(entity_name)} declares " <>
              "field #{inspect(field_name)} not in the column allowlist for source " <>
              "#{inspect(source)}"
      end
    end
  end

  # Compile-time guard: every field declared `searchable: true` must be covered by
  # the source's generated `search_vector` (`Entity.search_vector_columns/0`).
  # This ENFORCES the moduledoc promise that searchable text is "constrained to
  # Entity.search_vector_columns/0 so the search tool is actually generated": a
  # searchable-but-unindexed column would make the generated `cr_search_*` tool
  # reject at runtime with `:search_not_indexed` (US-30.3 AC-30.3.4) — an unusable
  # search surface that this seed must never declare. Failing at compile time is
  # louder than a runtime rejection and keeps this dogfood seed honest against the
  # US-30.3 vector-coverage constant.
  for %{name: entity_name, backing_source: source, fields: fields} <- @entity_definitions do
    vector_cols =
      Entity.search_vector_columns() |> Map.get(source, []) |> Enum.map(&Atom.to_string/1)

    for %{name: field_name, searchable: true} <- fields do
      unless field_name in vector_cols do
        raise CompileError,
          description:
            "Loopctl.ContextRetriever.Dogfood entity #{inspect(entity_name)} declares " <>
              "searchable field #{inspect(field_name)} not covered by the search_vector for " <>
              "source #{inspect(source)} (Entity.search_vector_columns/0)"
      end
    end
  end

  @doc """
  Returns the static dogfood entity definitions (name / backing_source / fields).

  Pure data — no DB access. Handy for tests that want to assert the seeded shape
  without hitting the registry.
  """
  @spec entity_definitions() :: [map()]
  def entity_definitions, do: @entity_definitions

  @doc """
  Seeds the three dogfood entity definitions for `tenant_id`.

  Each definition is created via `Registry.create_entity/3` (allowlist + cap +
  RLS + audit). Idempotent: a definition whose `name` already exists for the
  tenant is returned unchanged rather than re-created.

  `opts` are forwarded to `Registry.create_entity/3` for audit attribution
  (`:actor_id`, `:actor_label`, `:actor_type`, `:metadata`).

  Returns `{:ok, %{projects: Entity.t(), stories: Entity.t(), epics: Entity.t()}}`
  keyed by backing source, or `{:error, {entity_name, reason}}` on the first
  failure (e.g. `:entity_limit` if the tenant is already at its entity cap).
  """
  @spec seed_default_entities(Ecto.UUID.t(), keyword()) ::
          {:ok, %{atom() => Entity.t()}} | {:error, {String.t(), term()}}
  def seed_default_entities(tenant_id, opts \\ []) when is_binary(tenant_id) and is_list(opts) do
    Enum.reduce_while(@entity_definitions, {:ok, %{}}, fn definition, {:ok, acc} ->
      case ensure_entity(tenant_id, definition, opts) do
        {:ok, entity} ->
          {:cont, {:ok, Map.put(acc, definition.backing_source, entity)}}

        {:error, reason} ->
          {:halt, {:error, {definition.name, reason}}}
      end
    end)
  end

  # Create the definition unless one with the same name already exists for the
  # tenant (idempotent re-seed).
  defp ensure_entity(tenant_id, %{name: name} = definition, opts) do
    case Registry.get_entity(tenant_id, name) do
      %Entity{} = existing ->
        {:ok, existing}

      nil ->
        attrs = Map.take(definition, [:name, :backing_source, :fields])
        Registry.create_entity(tenant_id, attrs, opts)
    end
  end
end
