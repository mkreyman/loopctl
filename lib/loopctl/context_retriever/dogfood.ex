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

  ## Idempotency, drift reconciliation, and the entity cap

  `seed_default_entities/2` is idempotent and self-healing:

    * **Unchanged definition** — an already-seeded entity whose persisted
      `backing_source` + `fields` still MATCH the canonical `@entity_definitions`
      is left untouched and returned as-is, so a repeated run (e.g. a mix task run
      twice) burns no entity-cap slots.
    * **Definition drift (reconciliation)** — because an entity definition is the
      executor's field allowlist (a security root), a stale persisted definition
      is a schema-drift hazard, not a harmless no-op. So if the persisted
      `backing_source`/`fields` differ from the canonical definition (e.g. an
      allowlisted column was added to or removed from the field set here, or an
      operator hand-edited the row via the PATCH API), the seed RE-VALIDATES the
      canonical shape through `Registry.update_entity/4` (same SERVER allowlist +
      safe-identifier checks as create) and reconciles the row in place —
      preserving its id and writing an `"updated"` audit entry. The canonical
      `@entity_definitions` are the source of truth for the dogfood surface.
    * **Concurrent re-seed (race-safe)** — the "already exists?" check and the
      create run in SEPARATE transactions, so two concurrent same-tenant seeds
      can both observe a missing entity and both attempt to create it. The loser
      trips the `unique_constraint([:tenant_id, :name])`; rather than surfacing
      that changeset error, the seed RE-READS the row and adopts the winner's,
      keeping a concurrent re-seed idempotent instead of an error.
    * **Cap-safe (no partial commit)** — each definition is created in its own
      transaction, so the multi-entity seed is not one atomic unit. To avoid
      committing a PARTIAL set when the tenant is near its entity cap, the seed
      does a pre-flight headroom check: if creating the still-missing definitions
      would exceed `Registry.max_entities/0`, it returns
      `{:error, {name, :entity_limit}}` and creates NOTHING. (The per-create
      advisory-locked cap in `Registry.create_entity/3` remains the true guard
      against a concurrent over-cap; the pre-flight check makes the serial run
      all-or-nothing.)
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
  RLS + audit). Idempotent and self-healing (see the moduledoc "Idempotency,
  drift reconciliation, and the entity cap"):

    * an already-seeded definition still matching its canonical shape is returned
      unchanged;
    * a DRIFTED definition (persisted `backing_source`/`fields` differ from the
      canonical `@entity_definitions`) is reconciled in place via
      `Registry.update_entity/4`, preserving its id;
    * a concurrent re-seed that loses the unique-name race adopts the winner's row
      rather than erroring;
    * a pre-flight cap check makes the run all-or-nothing so a near-cap tenant
      never gets a partial committed set.

  `opts` are forwarded to `Registry.create_entity/3` / `Registry.update_entity/4`
  for audit attribution (`:actor_id`, `:actor_label`, `:actor_type`, `:metadata`).

  Returns `{:ok, %{projects: Entity.t(), stories: Entity.t(), epics: Entity.t()}}`
  keyed by backing source, or `{:error, {entity_name, reason}}` on failure (e.g.
  `:entity_limit` if seeding the missing definitions would exceed the entity cap,
  in which case NOTHING is created).
  """
  @spec seed_default_entities(Ecto.UUID.t(), keyword()) ::
          {:ok, %{atom() => Entity.t()}} | {:error, {String.t(), term()}}
  def seed_default_entities(tenant_id, opts \\ []) when is_binary(tenant_id) and is_list(opts) do
    existing = Registry.for_tenant(tenant_id)
    existing_by_name = Map.new(existing, &{&1.name, &1})

    case check_cap_headroom(existing, existing_by_name) do
      :ok -> seed_each(tenant_id, existing_by_name, opts)
      {:error, _} = error -> error
    end
  end

  # Reconcile-or-create each canonical definition, short-circuiting on the first
  # failure. The pre-flight `check_cap_headroom/2` has already guaranteed there is
  # room for every missing definition, so the only remaining failure modes are a
  # genuine DB/infra error or a lost concurrent race (handled in `ensure_entity/4`).
  defp seed_each(tenant_id, existing_by_name, opts) do
    Enum.reduce_while(@entity_definitions, {:ok, %{}}, fn definition, {:ok, acc} ->
      existing = Map.get(existing_by_name, definition.name)

      case ensure_entity(tenant_id, definition, existing, opts) do
        {:ok, entity} -> {:cont, {:ok, Map.put(acc, definition.backing_source, entity)}}
        {:error, reason} -> {:halt, {:error, {definition.name, reason}}}
      end
    end)
  end

  # Pre-flight cap check so the multi-entity seed is all-or-nothing WRT the entity
  # cap. Each definition is created in its own transaction (see `ensure_entity/4`),
  # so without this a near-cap tenant could commit `project` + `story` and then
  # fail on `epic` with `:entity_limit`, leaving a partial set. If creating the
  # still-missing definitions would push the tenant over `Registry.max_entities/0`,
  # return `{:error, {name, :entity_limit}}` up front and create nothing. Re-runs
  # where every definition already exists have no missing rows to add, so they
  # always pass. The advisory-locked per-create cap in `Registry.create_entity/3`
  # is still the true guard against a concurrent over-cap.
  defp check_cap_headroom(existing, existing_by_name) do
    case Enum.reject(@entity_definitions, &Map.has_key?(existing_by_name, &1.name)) do
      [] ->
        :ok

      [first | _] = missing ->
        if length(existing) + length(missing) > Registry.max_entities() do
          {:error, {first.name, :entity_limit}}
        else
          :ok
        end
    end
  end

  # Reconcile a pre-fetched existing definition, or create a missing one.
  defp ensure_entity(tenant_id, definition, %Entity{} = existing, opts) do
    reconcile_entity(tenant_id, existing, definition, opts)
  end

  defp ensure_entity(tenant_id, %{name: name} = definition, nil, opts) do
    attrs = Map.take(definition, [:name, :backing_source, :fields])
    create_or_adopt(tenant_id, name, attrs, opts)
  end

  # Reconcile definition drift: if the persisted `backing_source`/`fields` still
  # match the canonical definition, return the row unchanged; otherwise re-validate
  # and update it in place (id preserved, `"updated"` audit entry) via the vetted
  # `Registry.update_entity/4` path. The canonical `@entity_definitions` are the
  # source of truth for the dogfood surface (a security-root allowlist), so a
  # drifted row must not be left stale.
  defp reconcile_entity(tenant_id, %Entity{} = existing, definition, opts) do
    if entity_matches?(existing, definition) do
      {:ok, existing}
    else
      attrs = Map.take(definition, [:name, :backing_source, :fields])
      Registry.update_entity(tenant_id, existing.id, attrs, opts)
    end
  end

  # Create the definition; if a concurrent seed won the unique-name race between
  # this tenant's pre-fetch and this insert, `create_entity` returns
  # `{:error, changeset}` from the `unique_constraint`. Re-read (fresh
  # transaction) and adopt the winner's row so a concurrent re-seed stays
  # idempotent instead of surfacing the constraint error. Any non-changeset error
  # (e.g. `:entity_limit` from a concurrent over-cap) is passed through.
  defp create_or_adopt(tenant_id, name, attrs, opts) do
    case Registry.create_entity(tenant_id, attrs, opts) do
      {:ok, entity} ->
        {:ok, entity}

      {:error, %Ecto.Changeset{} = changeset} ->
        case Registry.get_entity(tenant_id, name) do
          %Entity{} = existing -> {:ok, existing}
          nil -> {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Whether a persisted definition already matches the canonical one. Compares the
  # backing source and the normalized field set (order-insensitive, key-shape
  # agnostic) so a benign re-order never triggers a spurious update while a real
  # field/source change does.
  defp entity_matches?(%Entity{backing_source: source, fields: persisted}, %{
         backing_source: source,
         fields: desired
       }) do
    normalize_fields(persisted) == normalize_fields(desired)
  end

  defp entity_matches?(_existing, _definition), do: false

  # Normalize declared field elements to a canonical, comparable form. `fields`
  # elements may be atom-keyed (the canonical `@entity_definitions`) or
  # string-keyed (DB round-trip); `Entity`'s dual-key-shape readers bridge both.
  # Sorted by name so the comparison is order-insensitive.
  defp normalize_fields(fields) do
    fields
    |> Enum.map(fn field ->
      %{
        name: Entity.field_string_value(field, "name"),
        type: Entity.field_string_value(field, "type"),
        filterable: Entity.filterable?(field),
        searchable: Entity.searchable?(field)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end
end
