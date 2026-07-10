defmodule Loopctl.ContextRetriever.Registry do
  @moduledoc """
  Per-tenant registry of entity definitions (Epic 30, Context Retriever).

  Reads and writes go through `Loopctl.Repo.with_tenant/2`, which sets the RLS
  context (`SET LOCAL app.current_tenant_id` + `SET LOCAL ROLE`) for the
  transaction. Tenant isolation therefore rides RLS on `entity_definitions`
  (ENABLE, not FORCE — see `Loopctl.Repo.RlsHelpers`): a definition authored by
  tenant A is invisible to tenant B. The `tenant_id` is still passed explicitly
  as the first argument to every function (multi-tenant rule).

  ## Per-tenant cap

  `create_entity/2` enforces a configurable per-tenant cap
  (`:max_entity_definitions_per_tenant`) BEFORE inserting, so a tenant cannot
  inflate the dynamic ListTools payload/latency of the generated agent query
  surface without bound. The count and the insert share ONE `with_tenant`
  transaction, so the check is consistent with the write. An over-cap create
  returns `{:error, :entity_limit}` and inserts nothing.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.Repo

  @default_max_entities 50

  @doc """
  Returns all of `tenant_id`'s entity definitions, ordered by `name`.

  Scope-enforced: only the caller tenant's rows are visible (RLS). A tenant with
  no definitions gets `[]`.
  """
  @spec for_tenant(Ecto.UUID.t()) :: [Entity.t()]
  def for_tenant(tenant_id) when is_binary(tenant_id) do
    {:ok, entities} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(from(e in Entity, order_by: [asc: e.name]))
      end)

    entities
  end

  @doc """
  Returns `tenant_id`'s entity definition named `name`, or `nil` if none.

  Scope-enforced via RLS: a name that exists only under a different tenant
  returns `nil` (no cross-tenant existence leak).
  """
  @spec get_entity(Ecto.UUID.t(), String.t()) :: Entity.t() | nil
  def get_entity(tenant_id, name) when is_binary(tenant_id) and is_binary(name) do
    {:ok, entity} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.get_by(Entity, name: name)
      end)

    entity
  end

  @doc """
  Creates an entity definition for `tenant_id` from `attrs`.

  `tenant_id` is set programmatically on the struct (never cast). Enforces the
  per-tenant cap: if the tenant is already at `max_entities/0`, returns
  `{:error, :entity_limit}` WITHOUT inserting. Otherwise validates via
  `Entity.create_changeset/2` and inserts.

  Runs as an `Ecto.Multi` so the RLS context, the cap check, and the insert all
  execute in ONE transaction and the write's `unique_constraint` is caught as an
  `{:error, changeset}` (a bare `Repo.insert` inside `Repo.with_tenant` would
  poison the transaction on a constraint violation — Ecto only savepoints per-op
  under `Multi`). The `:rls` step sets `SET LOCAL app.current_tenant_id` +
  `SET LOCAL ROLE`, so the cap count and insert are RLS-scoped to this tenant.

  Returns `{:ok, entity}`, `{:error, :entity_limit}`, or `{:error, changeset}`.
  """
  @spec create_entity(Ecto.UUID.t(), map()) ::
          {:ok, Entity.t()} | {:error, :entity_limit | Ecto.Changeset.t()}
  def create_entity(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    Multi.new()
    |> Multi.run(:rls, fn _repo, _changes ->
      Repo.set_rls_context(tenant_id)
      {:ok, :ok}
    end)
    |> Multi.run(:cap, fn repo, _changes ->
      # The cap check shares this transaction with the insert. RLS scopes the
      # count to this tenant.
      if repo.aggregate(Entity, :count, :id) >= max_entities() do
        {:error, :entity_limit}
      else
        {:ok, :ok}
      end
    end)
    |> Multi.insert(:entity, Entity.create_changeset(%Entity{tenant_id: tenant_id}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{entity: entity}} -> {:ok, entity}
      {:error, :cap, :entity_limit, _changes} -> {:error, :entity_limit}
      {:error, :entity, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  @doc "Configurable per-tenant cap on entity definitions."
  @spec max_entities() :: pos_integer()
  def max_entities do
    Application.get_env(:loopctl, :max_entity_definitions_per_tenant, @default_max_entities)
  end
end
