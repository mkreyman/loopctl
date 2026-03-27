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

  @doc """
  Registers a new agent within a tenant.

  Creates the agent record and logs an audit entry atomically via
  `Ecto.Multi`. The `tenant_id` is set on the struct, not via cast.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `:name`, `:agent_type`, and optional `:metadata`
  - `opts` -- keyword list with:
    - `:actor_id` -- UUID of the API key performing the action
    - `:actor_label` -- human-readable label (e.g., "agent:worker-1")

  ## Returns

  - `{:ok, %Agent{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec register_agent(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def register_agent(tenant_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset =
      %Agent{tenant_id: tenant_id}
      |> Agent.register_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:agent, changeset)
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

    case AdminRepo.transaction(multi) do
      {:ok, %{agent: agent}} ->
        {:ok, agent}

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
  Updates the `last_seen_at` timestamp for an agent.

  This is a best-effort operation -- failures are logged but do not
  propagate to the caller. Used by the UpdateLastSeen plug.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `agent_id` -- the agent UUID
  - `now` -- the current timestamp
  """
  @spec touch_last_seen(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Agent.t()} | {:error, term()}
  def touch_last_seen(tenant_id, agent_id, now) do
    case AdminRepo.get_by(Agent, id: agent_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      agent ->
        agent
        |> Agent.touch_changeset(now)
        |> AdminRepo.update()
    end
  end

  @doc """
  Lists agents for a tenant with optional filters and page-based pagination.

  ## Options (keyword list)

  - `:agent_type` -- filter by agent type (`:orchestrator` or `:implementer`)
  - `:status` -- filter by status (`:active`, `:idle`, `:deactivated`)
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
    offset = (page - 1) * page_size

    base_query =
      Agent
      |> where([a], a.tenant_id == ^tenant_id)
      |> apply_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    agents =
      base_query
      |> order_by([a], asc: a.name)
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
end
