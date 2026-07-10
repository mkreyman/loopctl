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

  `create_entity/3` enforces a configurable per-tenant cap
  (`:max_entity_definitions_per_tenant`) BEFORE inserting, so a tenant cannot
  inflate the dynamic ListTools payload/latency of the generated agent query
  surface without bound. A transaction-scoped `pg_advisory_xact_lock` keyed on
  `tenant_id` serializes concurrent same-tenant creates, so the count-then-insert
  cap is race-free (mirrors `Loopctl.Memory.remember/2`). The count and the
  insert share ONE transaction, so the check is consistent with the write. An
  over-cap create returns `{:error, :entity_limit}` and inserts nothing.

  ## Audit

  Because an entity definition is the executor's field allowlist (a security
  root), `create_entity/3` writes an `audit_log` entry (`entity_definition` /
  `created`) inside the same transaction via `Loopctl.Audit.log_in_multi/3`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.Audit
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.Repo

  @default_max_entities 50

  # Namespace for the per-tenant entity-cap advisory lock. `pg_advisory_xact_lock`
  # takes two int4s (namespace, key); the namespace isolates this lock CLASS from
  # every other advisory lock in the app (e.g. the memory-quota lock), so hashing
  # a tenant_id here can never collide with an unrelated lock keyed on the same int.
  @entity_cap_lock_ns :erlang.phash2(:loopctl_context_retriever_entity_cap)

  @doc """
  Returns all of `tenant_id`'s entity definitions, ordered by `name`.

  Scope-enforced: only the caller tenant's rows are visible (RLS). A tenant with
  no definitions gets `[]`.
  """
  @spec for_tenant(Ecto.UUID.t()) :: [Entity.t()]
  def for_tenant(tenant_id) when is_binary(tenant_id) do
    {:ok, entities} =
      Repo.with_tenant(tenant_id, fn ->
        # RLS already scopes this read to the caller tenant; the explicit
        # `tenant_id` predicate is defense-in-depth on this security-root read
        # (mirrors the `:cap` step below) so a future reorder/removal of the RLS
        # context can't silently make these definitions cross-tenant.
        Repo.all(from(e in Entity, where: e.tenant_id == ^tenant_id, order_by: [asc: e.name]))
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
        # Explicit `tenant_id` predicate as defense-in-depth alongside RLS (see
        # `for_tenant/1`), so this security-root read stays single-tenant even if
        # the RLS context were ever broken by a future refactor.
        Repo.get_by(Entity, tenant_id: tenant_id, name: name)
      end)

    entity
  end

  @doc """
  Creates an entity definition for `tenant_id` from `attrs`.

  `tenant_id` is set programmatically on the struct (never cast). Enforces the
  per-tenant cap: if the tenant is already at `max_entities/0`, returns
  `{:error, :entity_limit}` WITHOUT inserting. Otherwise validates via
  `Entity.create_changeset/2` and inserts.

  Runs as an `Ecto.Multi` so the RLS context, the advisory lock, the cap check,
  the insert, and the audit entry all execute in ONE transaction and the write's
  `unique_constraint` is caught as an `{:error, changeset}` (a bare `Repo.insert`
  inside `Repo.with_tenant` would poison the transaction on a constraint
  violation — Ecto only savepoints per-op under `Multi`). The `:rls` step sets
  `SET LOCAL app.current_tenant_id` + `SET LOCAL ROLE`, so the cap count, insert,
  and audit write are RLS-scoped to this tenant.

  ## Race-free cap (advisory lock)

  The `:lock` step takes a transaction-scoped `pg_advisory_xact_lock` keyed on
  `tenant_id` BEFORE the count, serializing concurrent same-tenant creates.
  Without it, two creates under READ COMMITTED could each observe
  `count = cap - 1` (neither sees the other's uncommitted insert) and both
  commit, landing at `cap + N`. This mirrors `Loopctl.Memory.remember/2`'s
  quota lock. The lock auto-releases at COMMIT/ROLLBACK.

  ## Audit trail

  The entity definition is a SECURITY ROOT (the executor's field allowlist), so
  its creation is recorded via `Audit.log_in_multi/3` inside the same
  transaction. `opts` supplies the actor for that entry:

    * `:actor_id` — the acting API key id (optional).
    * `:actor_label` — human-readable actor label (optional).
    * `:actor_type` — defaults to `"api_key"`.
    * `:metadata` — extra JSONB context (defaults to `%{}`).

  Returns `{:ok, entity}`, `{:error, :entity_limit}`, or `{:error, changeset}`.
  """
  @spec create_entity(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Entity.t()} | {:error, :entity_limit | Ecto.Changeset.t() | term()}
  def create_entity(tenant_id, attrs, opts \\ [])
      when is_binary(tenant_id) and is_map(attrs) and is_list(opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")
    metadata = Keyword.get(opts, :metadata, %{})

    Multi.new()
    |> Multi.run(:rls, fn _repo, _changes ->
      Repo.set_rls_context(tenant_id)
      {:ok, :ok}
    end)
    |> Multi.run(:lock, fn repo, _changes ->
      # Serialize concurrent same-tenant creates so the count-then-insert cap is
      # race-free. Two-int form isolates this lock class by namespace.
      key = :erlang.phash2(tenant_id)
      repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@entity_cap_lock_ns, key])
      {:ok, :ok}
    end)
    |> Multi.run(:cap, fn repo, _changes ->
      # The cap check shares this transaction with the insert (under the advisory
      # lock). RLS already scopes the count to this tenant; the explicit
      # `tenant_id` predicate is defense-in-depth on the security-root count so a
      # future reorder/removal of `:rls` can't silently make it cross-tenant.
      count = repo.aggregate(from(e in Entity, where: e.tenant_id == ^tenant_id), :count, :id)

      if count >= max_entities() do
        {:error, :entity_limit}
      else
        {:ok, :ok}
      end
    end)
    |> Multi.insert(:entity, Entity.create_changeset(%Entity{tenant_id: tenant_id}, attrs))
    |> Audit.log_in_multi(:audit, fn %{entity: entity} ->
      %{
        tenant_id: tenant_id,
        entity_type: "entity_definition",
        entity_id: entity.id,
        action: "created",
        actor_type: actor_type,
        actor_id: actor_id,
        actor_label: actor_label,
        metadata: metadata,
        new_state: %{
          "name" => entity.name,
          "backing_source" => to_string(entity.backing_source),
          "field_count" => length(entity.fields)
        }
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{entity: entity}} -> {:ok, entity}
      {:error, :cap, :entity_limit, _changes} -> {:error, :entity_limit}
      {:error, :entity, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      # Catch-all so any other failing step (notably `:audit` — e.g. a
      # caller-supplied non-map `:metadata` invalidating the audit changeset, or a
      # future required/validated audit field or added step) returns `{:error, _}`
      # per the documented contract instead of raising `CaseClauseError`. The
      # transaction still rolls back, so nothing is persisted. Mirrors
      # `Loopctl.Memory.remember/2`'s trailing per-step error handling.
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "Configurable per-tenant cap on entity definitions."
  @spec max_entities() :: pos_integer()
  def max_entities do
    Application.get_env(:loopctl, :max_entity_definitions_per_tenant, @default_max_entities)
  end
end
