defmodule LoopctlWeb.AgentController do
  @moduledoc """
  Controller for agent registration, listing, and detail.

  - `POST /api/v1/agents/register` -- agent role, self-registers
  - `GET /api/v1/agents` -- orchestrator+, lists agents with filters
  - `GET /api/v1/agents/:id` -- orchestrator+, agent detail
  """

  use LoopctlWeb, :controller

  alias Loopctl.Agents
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :agent] when action in [:register]
  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:index, :show]

  @doc """
  POST /api/v1/agents/register

  Self-registers a new agent. Requires an API key with `agent` role.
  Returns the created agent record.
  """
  def register(conn, params) do
    api_key = conn.assigns.current_api_key

    if api_key.agent_id do
      {:error, :conflict}
    else
      tenant_id = api_key.tenant_id

      attrs = %{
        name: params["name"],
        agent_type: safe_to_agent_type(params["agent_type"]),
        metadata: params["metadata"] || %{}
      }

      audit_opts = AuditContext.from_conn(conn)

      case Agents.register_agent(
             tenant_id,
             attrs,
             Keyword.merge(audit_opts, api_key_id: api_key.id)
           ) do
        {:ok, agent} ->
          conn
          |> put_status(:created)
          |> json(%{agent: agent_json(agent)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/v1/agents

  Lists agents for the current tenant with optional filters.
  Requires orchestrator+ role.
  """
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add_filter(:agent_type, safe_to_agent_type(params["agent_type"]))
      |> maybe_add_filter(:status, safe_to_status(params["status"]))
      |> maybe_add_filter(:sort_by, params["sort_by"])
      |> maybe_add_filter(:page, parse_int(params["page"]))
      |> maybe_add_filter(:page_size, parse_int(params["page_size"]))

    {:ok, result} = Agents.list_agents(tenant_id, opts)

    json(conn, %{
      agents: Enum.map(result.data, &agent_json/1),
      total: result.total,
      page: result.page,
      page_size: result.page_size
    })
  end

  @doc """
  GET /api/v1/agents/:id

  Returns agent detail for the current tenant.
  Requires orchestrator+ role.
  """
  def show(conn, %{"id" => agent_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Agents.get_agent(tenant_id, agent_id) do
      {:ok, agent} ->
        json(conn, %{agent: agent_json(agent)})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp agent_json(agent) do
    %{
      id: agent.id,
      tenant_id: agent.tenant_id,
      name: agent.name,
      agent_type: agent.agent_type,
      status: agent.status,
      last_seen_at: agent.last_seen_at,
      metadata: agent.metadata,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end

  defp safe_to_agent_type(nil), do: nil

  defp safe_to_agent_type(type) when is_binary(type) do
    case type do
      "orchestrator" -> :orchestrator
      "implementer" -> :implementer
      _ -> nil
    end
  end

  defp safe_to_status(nil), do: nil

  defp safe_to_status(status) when is_binary(status) do
    case status do
      "active" -> :active
      "idle" -> :idle
      "deactivated" -> :deactivated
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)
end
