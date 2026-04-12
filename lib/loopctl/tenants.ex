defmodule Loopctl.Tenants do
  @moduledoc """
  Context module for tenant management.

  Tenants are the root organizational unit. They are NOT tenant-scoped
  (no RLS) because the tenants table is queried by the auth pipeline
  before tenant context is set.

  All queries use `AdminRepo` since tenants have no `tenant_id`
  and are not subject to RLS policies.
  """

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.Tenant

  @max_authenticators_per_signup 5
  @pending_enrollment_ttl_seconds 15 * 60

  @doc """
  Creates a new tenant with the given attributes.

  ## Examples

      iex> create_tenant(%{name: "Acme", slug: "acme", email: "a@acme.com"})
      {:ok, %Tenant{}}

      iex> create_tenant(%{name: "Acme"})
      {:error, %Ecto.Changeset{}}
  """
  @spec create_tenant(map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs)
    |> AdminRepo.insert()
  end

  @doc """
  US-26.0.1 — atomic tenant signup ceremony with WebAuthn enrollment.

  The flow is wrapped in a single `Ecto.Multi` so a single failing
  attestation rolls back every side effect (tenant, authenticators,
  audit entries).

  ## Params

  Takes a single map with:
  - `:name` — tenant display name (required)
  - `:slug` — unique slug (required, validated)
  - `:email` — contact email (required, validated)
  - `:authenticators` — list of maps in the form
    `%{attestation_result: %{credential_id, public_key, attestation_format, sign_count}, friendly_name: "..."}`
    (required, length 1..5)

  The caller is responsible for running WebAuthn verification on each
  browser response and passing the normalized `attestation_result`
  alongside the operator-supplied `friendly_name`.

  ## Returns

  - `{:ok, %{tenant: %Tenant{}, root_authenticators: [%RootAuthenticator{}]}}`
  - `{:error, :no_authenticators}` — empty list
  - `{:error, :too_many_authenticators}` — more than 5
  - `{:error, :slug_taken}` | `{:error, :email_taken}`
  - `{:error, %Ecto.Changeset{}}` — validation failure
  """
  @spec signup(map()) ::
          {:ok, %{tenant: Tenant.t(), root_authenticators: [RootAuthenticator.t()]}}
          | {:error, :no_authenticators}
          | {:error, :too_many_authenticators}
          | {:error, :slug_taken}
          | {:error, :email_taken}
          | {:error, Ecto.Changeset.t()}
  def signup(attrs) when is_map(attrs) do
    authenticators = Map.get(attrs, :authenticators) || Map.get(attrs, "authenticators") || []

    cond do
      authenticators == [] ->
        {:error, :no_authenticators}

      length(authenticators) > @max_authenticators_per_signup ->
        {:error, :too_many_authenticators}

      true ->
        do_signup(attrs, authenticators)
    end
  end

  defp do_signup(attrs, authenticators) do
    # Drop the `authenticators` key from the changeset input so cast/3
    # does not stumble over the mixed-key map.
    tenant_attrs = Map.drop(attrs, [:authenticators, "authenticators"])

    multi =
      Multi.new()
      |> Multi.insert(:tenant, Tenant.signup_changeset(tenant_attrs))
      |> insert_authenticators(authenticators)
      |> Multi.update(:activate, fn %{tenant: tenant} ->
        Tenant.activate_after_enrollment_changeset(tenant)
      end)
      |> Audit.log_in_multi(:audit_genesis, fn %{activate: tenant, authenticators: auths} ->
        %{
          tenant_id: tenant.id,
          entity_type: "tenant",
          entity_id: tenant.id,
          action: "signed_up",
          actor_type: "human",
          actor_id: nil,
          actor_label: "human:webauthn",
          new_state: %{
            "name" => tenant.name,
            "slug" => tenant.slug,
            "email" => tenant.email,
            "authenticator_count" => length(auths),
            "authenticator_fingerprints" => Enum.map(auths, &fingerprint(&1.credential_id))
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{activate: tenant, authenticators: authenticators}} ->
        {:ok, %{tenant: tenant, root_authenticators: authenticators}}

      {:error, :tenant, %Ecto.Changeset{} = changeset, _changes} ->
        signup_changeset_error(changeset)

      {:error, {:authenticator, _index}, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp insert_authenticators(multi, authenticators) do
    authenticators
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {entry, index}, acc ->
      Multi.run(acc, {:authenticator, index}, fn _repo, %{tenant: tenant} ->
        attestation = Map.fetch!(entry, :attestation_result)
        friendly_name = Map.get(entry, :friendly_name) || default_friendly_name(index)

        attrs =
          attestation
          |> Map.put(:friendly_name, friendly_name)
          |> Map.put_new(:sign_count, 0)

        %RootAuthenticator{tenant_id: tenant.id}
        |> RootAuthenticator.create_changeset(attrs)
        |> AdminRepo.insert()
      end)
    end)
    |> Multi.run(:authenticators, fn _repo, changes ->
      result =
        changes
        |> Enum.filter(fn
          {{:authenticator, _}, _} -> true
          _ -> false
        end)
        |> Enum.sort_by(fn {{:authenticator, i}, _} -> i end)
        |> Enum.map(fn {_, auth} -> auth end)

      {:ok, result}
    end)
  end

  defp default_friendly_name(0), do: "Primary authenticator"
  defp default_friendly_name(n), do: "Backup authenticator #{n}"

  defp signup_changeset_error(changeset) do
    cond do
      has_unique_constraint_error?(changeset, :slug) ->
        {:error, :slug_taken}

      has_unique_constraint_error?(changeset, :email) ->
        {:error, :email_taken}

      true ->
        {:error, changeset}
    end
  end

  defp has_unique_constraint_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # Short, non-reversible label for the audit entry so we can tell
  # authenticators apart in human-readable logs.
  defp fingerprint(credential_id) when is_binary(credential_id) do
    :crypto.hash(:sha256, credential_id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc """
  Returns the TTL (in seconds) that the pending-enrollment cleanup
  worker uses to expire half-finished signup attempts.
  """
  @spec pending_enrollment_ttl_seconds() :: pos_integer()
  def pending_enrollment_ttl_seconds, do: @pending_enrollment_ttl_seconds

  @doc """
  Maximum number of authenticators that can be enrolled in the initial
  signup ceremony.
  """
  @spec max_authenticators_per_signup() :: pos_integer()
  def max_authenticators_per_signup, do: @max_authenticators_per_signup

  @doc """
  Gets a tenant by ID.

  Returns `{:ok, tenant}` or `{:error, :not_found}`.
  """
  @spec get_tenant(Ecto.UUID.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant(id) do
    case AdminRepo.get(Tenant, id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc """
  Gets a tenant by slug.

  Returns `{:ok, tenant}` or `{:error, :not_found}`.
  """
  @spec get_tenant_by_slug(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_slug(slug) do
    case AdminRepo.get_by(Tenant, slug: slug) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc """
  Updates a tenant with the given attributes.

  When `settings` is provided in attrs, it is merged into the existing
  settings map (provided keys override, unspecified keys preserved).
  """
  @spec update_tenant(Tenant.t(), map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant(%Tenant{} = tenant, attrs) do
    attrs = merge_settings(tenant, attrs)

    tenant
    |> Tenant.update_changeset(attrs)
    |> AdminRepo.update()
  end

  @doc """
  Lists all tenants. Intended for superadmin use.

  Accepts optional filters:
  - `:status` — filter by tenant status
  """
  @spec list_tenants(keyword()) :: {:ok, [Tenant.t()]}
  def list_tenants(opts \\ []) do
    import Ecto.Query

    query =
      Tenant
      |> apply_status_filter(opts[:status])
      |> order_by([t], asc: t.name)

    {:ok, AdminRepo.all(query)}
  end

  @doc """
  Suspends a tenant by setting its status to `:suspended`.
  """
  @spec suspend_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def suspend_tenant(%Tenant{} = tenant) do
    tenant
    |> Tenant.status_changeset(:suspended)
    |> AdminRepo.update()
  end

  @doc """
  Activates a tenant by setting its status to `:active`.
  """
  @spec activate_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def activate_tenant(%Tenant{} = tenant) do
    tenant
    |> Tenant.status_changeset(:active)
    |> AdminRepo.update()
  end

  @doc """
  Gets a specific setting value from a tenant's settings map.

  Falls back to `default` if the key is not present.

  ## Examples

      iex> get_tenant_settings(tenant, "max_projects", 50)
      10  # if tenant.settings has "max_projects" => 10

      iex> get_tenant_settings(tenant, "nonexistent", 42)
      42  # fallback default
  """
  @spec get_tenant_settings(Tenant.t(), String.t(), term()) :: term()
  def get_tenant_settings(%Tenant{settings: settings}, key, default \\ nil) do
    Map.get(settings || %{}, key, default)
  end

  # --- Superadmin functions ---

  @doc """
  Lists all tenants with summary stats for superadmin use.

  Returns paginated results with project_count, story_count, agent_count,
  and api_key_count computed via subqueries.

  ## Options

  - `:status` — filter by tenant status atom
  - `:search` — case-insensitive partial match on name or slug
  - `:page` — page number (default 1)
  - `:page_size` — items per page (default 20, max 100)
  """
  @spec list_tenants_admin(keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_tenants_admin(opts \\ []) do
    import Ecto.Query

    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Tenant
      |> apply_status_filter(opts[:status])
      |> apply_search_filter(opts[:search])

    total = AdminRepo.aggregate(base_query, :count, :id)

    tenants =
      base_query
      |> order_by([t], asc: t.name)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    data = Enum.map(tenants, &tenant_with_stats/1)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Gets a single tenant with full detail stats for superadmin use.

  Returns tenant with project_count, story_count, epic_count, agent_count,
  and api_key_count.
  """
  @spec get_tenant_admin(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_tenant_admin(id) do
    case AdminRepo.get(Tenant, id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant_with_stats(tenant)}
    end
  end

  @doc """
  Updates a tenant with partial settings merge for superadmin use.

  When `settings` is provided in attrs, it is merged into the existing
  settings map (provided keys override, unspecified keys preserved).
  """
  @spec update_tenant_admin(Tenant.t(), map()) ::
          {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant_admin(%Tenant{} = tenant, attrs) do
    attrs = merge_settings(tenant, attrs)

    tenant
    |> Tenant.update_changeset(attrs)
    |> AdminRepo.update()
  end

  @doc """
  Returns system-wide aggregate statistics across all tenants.

  Used by the GET /api/v1/admin/stats endpoint.

  ## Returns

  A map with total counts, tenant status breakdown, story status
  aggregates, and active agent/story counts.
  """
  @spec system_stats() :: {:ok, map()}
  def system_stats do
    import Ecto.Query

    # Tenant counts by status
    tenant_stats =
      from(t in Tenant,
        select: %{
          total: count(t.id),
          active: count(fragment("CASE WHEN ? = 'active' THEN 1 END", t.status)),
          pending_enrollment:
            count(fragment("CASE WHEN ? = 'pending_enrollment' THEN 1 END", t.status)),
          suspended: count(fragment("CASE WHEN ? = 'suspended' THEN 1 END", t.status)),
          deactivated: count(fragment("CASE WHEN ? = 'deactivated' THEN 1 END", t.status))
        }
      )
      |> AdminRepo.one()

    alias Loopctl.Agents.Agent
    alias Loopctl.Auth.ApiKey
    alias Loopctl.Projects.Project
    alias Loopctl.WorkBreakdown.Epic
    alias Loopctl.WorkBreakdown.Story

    # Simple counts
    total_projects = AdminRepo.aggregate(Project, :count, :id)
    total_epics = AdminRepo.aggregate(Epic, :count, :id)
    total_stories = AdminRepo.aggregate(Story, :count, :id)
    total_agents = AdminRepo.aggregate(Agent, :count, :id)
    total_api_keys = count_active_api_keys()

    # Story status breakdowns
    stories_by_agent_status = count_stories_by_field(:agent_status)
    stories_by_verified_status = count_stories_by_field(:verified_status)

    # Active stories = implementing
    active_stories = Map.get(stories_by_agent_status, "implementing", 0)

    # Active agents = active status + last_seen_at within 24 hours
    active_agents = count_active_agents()

    {:ok,
     %{
       total_tenants: tenant_stats.total,
       tenants_active: tenant_stats.active,
       tenants_suspended: tenant_stats.suspended,
       tenants_deactivated: tenant_stats.deactivated,
       total_projects: total_projects,
       total_epics: total_epics,
       total_stories: total_stories,
       total_agents: total_agents,
       total_api_keys: total_api_keys,
       stories_by_agent_status: stories_by_agent_status,
       stories_by_verified_status: stories_by_verified_status,
       active_stories: active_stories,
       active_agents: active_agents
     }}
  end

  @doc """
  Lists audit log entries across all tenants for superadmin use.

  Joins with tenants to include tenant name/slug in each entry.
  Supports all standard audit filters plus tenant_id filter.

  ## Options

  - `:tenant_id` — filter by specific tenant
  - `:entity_type` — filter by entity type
  - `:entity_id` — filter by entity ID
  - `:action` — filter by action
  - `:actor_type` — filter by actor type
  - `:actor_id` — filter by actor ID
  - `:from` — filter entries after this DateTime
  - `:to` — filter entries before this DateTime
  - `:page` — page number (default 1)
  - `:page_size` — entries per page (default 20, max 100)
  """
  @spec list_audit_admin(keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_audit_admin(opts \\ []) do
    import Ecto.Query

    alias Loopctl.Audit.AuditLog

    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      from(a in AuditLog,
        as: :audit,
        left_join: t in Tenant,
        as: :tenant,
        on: a.tenant_id == t.id
      )
      |> apply_audit_filters(opts)

    total = AdminRepo.aggregate(base_query, :count)

    entries =
      base_query
      |> order_by([audit: a], desc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> select([audit: a, tenant: t], %{
        id: a.id,
        tenant_id: a.tenant_id,
        tenant_name: t.name,
        tenant_slug: t.slug,
        entity_type: a.entity_type,
        entity_id: a.entity_id,
        action: a.action,
        actor_type: a.actor_type,
        actor_id: a.actor_id,
        actor_label: a.actor_label,
        old_state: a.old_state,
        new_state: a.new_state,
        project_id: a.project_id,
        metadata: a.metadata,
        inserted_at: a.inserted_at
      })
      |> AdminRepo.all()

    {:ok, %{data: entries, total: total, page: page, page_size: page_size}}
  end

  # --- Private helpers ---

  defp apply_status_filter(query, nil), do: query

  defp apply_status_filter(query, status) do
    import Ecto.Query
    where(query, [t], t.status == ^status)
  end

  defp apply_search_filter(query, nil), do: query
  defp apply_search_filter(query, ""), do: query

  defp apply_search_filter(query, search) do
    import Ecto.Query
    pattern = "%#{escape_like(search)}%"

    where(
      query,
      [t],
      ilike(t.name, ^pattern) or ilike(t.slug, ^pattern)
    )
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp tenant_with_stats(%Tenant{} = tenant) do
    import Ecto.Query

    alias Loopctl.Agents.Agent
    alias Loopctl.Auth.ApiKey
    alias Loopctl.Projects.Project
    alias Loopctl.WorkBreakdown.Epic
    alias Loopctl.WorkBreakdown.Story

    tid = tenant.id

    # Single query with subqueries instead of 5 individual queries
    stats =
      from(t in Tenant,
        where: t.id == ^tid,
        select: %{
          project_count:
            subquery(from(p in Project, where: p.tenant_id == ^tid, select: count(p.id))),
          story_count:
            subquery(from(s in Story, where: s.tenant_id == ^tid, select: count(s.id))),
          epic_count: subquery(from(e in Epic, where: e.tenant_id == ^tid, select: count(e.id))),
          agent_count:
            subquery(from(a in Agent, where: a.tenant_id == ^tid, select: count(a.id))),
          api_key_count:
            subquery(
              from(ak in ApiKey,
                where: ak.tenant_id == ^tid and is_nil(ak.revoked_at),
                select: count(ak.id)
              )
            )
        }
      )
      |> AdminRepo.one!()

    Map.put(stats, :tenant, tenant)
  end

  defp merge_settings(tenant, attrs) do
    case Map.get(attrs, "settings") || Map.get(attrs, :settings) do
      nil ->
        attrs

      new_settings when is_map(new_settings) ->
        merged = Map.merge(tenant.settings || %{}, new_settings)
        attrs |> Map.put("settings", merged) |> Map.delete(:settings)

      _ ->
        attrs
    end
  end

  defp count_active_api_keys do
    import Ecto.Query

    alias Loopctl.Auth.ApiKey

    from(ak in ApiKey, where: is_nil(ak.revoked_at), select: count(ak.id))
    |> AdminRepo.one()
  end

  defp count_stories_by_field(field) do
    import Ecto.Query

    alias Loopctl.WorkBreakdown.Story

    field_atom = field

    from(s in Story,
      group_by: field(s, ^field_atom),
      select: {field(s, ^field_atom), count(s.id)}
    )
    |> AdminRepo.all()
    |> Map.new(fn {status, count} -> {to_string(status), count} end)
  end

  defp count_active_agents do
    import Ecto.Query

    alias Loopctl.Agents.Agent

    cutoff = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    from(a in Agent,
      where: a.status == :active and a.last_seen_at > ^cutoff,
      select: count(a.id)
    )
    |> AdminRepo.one()
  end

  defp apply_audit_filters(query, opts) do
    import Ecto.Query

    query
    |> audit_filter(:tenant_id, Keyword.get(opts, :tenant_id))
    |> audit_filter(:entity_type, Keyword.get(opts, :entity_type))
    |> audit_filter(:entity_id, Keyword.get(opts, :entity_id))
    |> audit_filter(:action, Keyword.get(opts, :action))
    |> audit_filter(:actor_type, Keyword.get(opts, :actor_type))
    |> audit_filter(:actor_id, Keyword.get(opts, :actor_id))
    |> audit_filter_from(Keyword.get(opts, :from))
    |> audit_filter_to(Keyword.get(opts, :to))
  end

  defp audit_filter(query, _field, nil), do: query
  defp audit_filter(query, _field, ""), do: query

  defp audit_filter(query, :tenant_id, val) do
    import Ecto.Query
    where(query, [audit: a], a.tenant_id == ^val)
  end

  defp audit_filter(query, :entity_type, val) do
    import Ecto.Query
    where(query, [audit: a], a.entity_type == ^val)
  end

  defp audit_filter(query, :entity_id, val) do
    import Ecto.Query
    where(query, [audit: a], a.entity_id == ^val)
  end

  defp audit_filter(query, :action, val) do
    import Ecto.Query
    where(query, [audit: a], a.action == ^val)
  end

  defp audit_filter(query, :actor_type, val) do
    import Ecto.Query
    where(query, [audit: a], a.actor_type == ^val)
  end

  defp audit_filter(query, :actor_id, val) do
    import Ecto.Query
    where(query, [audit: a], a.actor_id == ^val)
  end

  defp audit_filter_from(query, nil), do: query

  defp audit_filter_from(query, from) do
    import Ecto.Query
    where(query, [audit: a], a.inserted_at >= ^from)
  end

  defp audit_filter_to(query, nil), do: query

  defp audit_filter_to(query, to) do
    import Ecto.Query
    where(query, [audit: a], a.inserted_at <= ^to)
  end
end
