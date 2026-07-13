defmodule Loopctl.Agents do
  @moduledoc """
  Context module for agent registration and management.

  Agents are tenant-scoped AI entities that register to perform work.
  All operations require a `tenant_id` as the first argument.

  Writes use `AdminRepo` (matching the Auth and Audit patterns) while
  reads use `AdminRepo` with explicit tenant_id WHERE clauses. The RLS
  policy on the `agents` table provides defence-in-depth in production,
  where `Repo` connects as a non-superuser.

  Agent registration is an atomic operation that creates the agent
  record and writes an audit log entry in a single transaction.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.Audit
  alias Loopctl.Auth
  alias Loopctl.Webhooks.EventGenerator

  @doc """
  Registers a new agent within a tenant.

  Creates the agent record, links the API key to the agent, and logs
  an audit entry atomically via `Ecto.Multi`. The `tenant_id` is set
  on the struct, not via cast.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `:name`, `:agent_type`, and optional `:metadata`
  - `opts` -- keyword list with:
    - `:api_key_id` -- UUID of the API key to link to the new agent
    - `:actor_id` -- UUID of the API key performing the action
    - `:actor_label` -- human-readable label (e.g., "agent:worker-1")

  ## Returns

  - `{:ok, %Agent{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec register_agent(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def register_agent(tenant_id, attrs, opts \\ []) do
    api_key_id = Keyword.get(opts, :api_key_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset =
      %Agent{tenant_id: tenant_id}
      |> Agent.register_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:agent, changeset)
      |> maybe_link_api_key(api_key_id)
      |> Audit.log_in_multi(:audit, fn %{agent: agent} ->
        %{
          tenant_id: tenant_id,
          entity_type: "agent",
          entity_id: agent.id,
          action: "registered",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          new_state: %{
            "name" => agent.name,
            "agent_type" => to_string(agent.agent_type),
            "status" => to_string(agent.status)
          }
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{agent: agent} ->
        %{
          tenant_id: tenant_id,
          event_type: "agent.registered",
          payload: %{
            "event" => "agent.registered",
            "agent_id" => agent.id,
            "agent_name" => agent.name,
            "agent_type" => to_string(agent.agent_type),
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, changes} ->
        # US-33.3: binding an agent MUTATES the api_key (sets agent_id — a
        # scope-relevant change, AC-33.3.3). Bust the cached entry so the next
        # request sees the bound key (e.g. the "already has an agent" 409 guard),
        # not the stale pre-bind snapshot. The `:link_api_key` Multi step already
        # loaded+updated the api_key struct, so invalidate by its key_hash in hand
        # — no second AdminRepo round-trip on the cache's own pool (US-33.3,
        # finding-4 remediation). When no key was linked the step is absent.
        changes |> linked_key_hashes() |> Auth.invalidate_key_cache_by_hashes()
        {:ok, changes.agent}

      {:error, :agent, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets an agent by ID, scoped to a tenant.

  ## Returns

  - `{:ok, %Agent{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_agent(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Agent.t()} | {:error, :not_found}
  def get_agent(tenant_id, agent_id) do
    case AdminRepo.get_by(Agent, id: agent_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Updates an agent within a tenant.

  ## Parameters

  - `tenant_id` -- the tenant UUID (for scoping)
  - `agent` -- the `%Agent{}` struct to update
  - `attrs` -- map of fields to update

  ## Returns

  - `{:ok, %Agent{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec update_agent(Ecto.UUID.t(), Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def update_agent(_tenant_id, %Agent{} = agent, attrs) do
    agent
    |> Agent.update_changeset(attrs)
    |> AdminRepo.update()
  end

  @doc """
  Records a debounced `last_seen_at` touch for an agent (US-33.4).

  This no longer performs a synchronous DB write on the request path. It records
  `now` into `Loopctl.TouchBuffer` (an in-memory ETS buffer, no `AdminRepo`
  SELECT and no UPDATE); a supervised periodic flusher writes the buffered maxima
  in one batched, monotonic `UPDATE`. `last_seen_at` is a liveness heuristic, so
  bounded staleness (at most one flush interval) is acceptable. Best-effort — it
  never raises and never blocks the request. Used by the `UpdateLastSeen` plug.

  `tenant_id` is accepted for the caller's convenience but is not needed for
  scoping: `agent_id` is a globally-unique UUID, so the flush's `WHERE id = ...`
  is self-scoping (no cross-tenant write is possible).

  ## Parameters

  - `tenant_id` -- the tenant UUID (unused; agent_id is globally unique)
  - `agent_id` -- the agent UUID
  - `now` -- the current timestamp
  """
  @spec touch_last_seen(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: :ok
  def touch_last_seen(_tenant_id, agent_id, %DateTime{} = now) do
    Loopctl.TouchBuffer.record_agent(agent_id, now)
  end

  @allowed_sort_fields ~w(name agent_type status last_seen_at inserted_at)

  @doc """
  Lists agents for a tenant with optional filters and page-based pagination.

  ## Options (keyword list)

  - `:agent_type` -- filter by agent type (`:orchestrator` or `:implementer`)
  - `:status` -- filter by status (`:active`, `:idle`, `:deactivated`)
  - `:sort_by` -- sort field, one of #{inspect(@allowed_sort_fields)} (default "name")
  - `:page` -- page number (default 1)
  - `:page_size` -- agents per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%Agent{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_agents(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Agent.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_agents(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    sort_field = resolve_sort_field(Keyword.get(opts, :sort_by, "name"))
    offset = (page - 1) * page_size

    base_query =
      Agent
      |> where([a], a.tenant_id == ^tenant_id)
      |> apply_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    agents =
      base_query
      |> order_by([a], asc: field(a, ^sort_field))
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: agents, total: total, page: page, page_size: page_size}}
  end

  # --- Private filter helpers ---

  defp apply_filters(query, opts) do
    query
    |> filter_by_type(Keyword.get(opts, :agent_type))
    |> filter_by_status(Keyword.get(opts, :status))
  end

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: where(query, [a], a.agent_type == ^type)

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [a], a.status == ^status)

  defp resolve_sort_field(field) when field in @allowed_sort_fields do
    String.to_existing_atom(field)
  end

  defp resolve_sort_field(_), do: :name

  defp maybe_link_api_key(multi, nil), do: multi

  defp maybe_link_api_key(multi, api_key_id) do
    Multi.update(multi, :link_api_key, fn %{agent: agent} ->
      api_key = AdminRepo.get!(Loopctl.Auth.ApiKey, api_key_id)
      Ecto.Changeset.change(api_key, %{agent_id: agent.id})
    end)
  end

  # The `:link_api_key` step is only present when an api_key_id was passed; its
  # value is the updated ApiKey struct, so its key_hash is already in memory.
  defp linked_key_hashes(%{link_api_key: %{key_hash: key_hash}}), do: [key_hash]
  defp linked_key_hashes(_changes), do: []
end
