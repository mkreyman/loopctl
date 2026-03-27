defmodule Loopctl.Tenants do
  @moduledoc """
  Context module for tenant management.

  Tenants are the root organizational unit. They are NOT tenant-scoped
  (no RLS) because the tenants table is queried by the auth pipeline
  before tenant context is set.

  All queries use `AdminRepo` since tenants have no `tenant_id`
  and are not subject to RLS policies.
  """

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.Tenant

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
  """
  @spec update_tenant(Tenant.t(), map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant(%Tenant{} = tenant, attrs) do
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
