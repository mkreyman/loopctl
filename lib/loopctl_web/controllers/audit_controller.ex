defmodule LoopctlWeb.AuditController do
  @moduledoc """
  Controller for the audit log endpoint.

  GET /api/v1/audit — paginated, filtered audit log entries.
  Requires `user` role or higher.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.Audit

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  tags(["Audit"])

  operation(:index,
    summary: "List audit log entries",
    description: "Returns paginated audit log entries for the authenticated tenant.",
    parameters: [
      entity_type: [in: :query, type: :string, description: "Filter by entity type"],
      entity_id: [in: :query, type: :string, description: "Filter by entity ID"],
      action: [in: :query, type: :string, description: "Filter by action"],
      actor_type: [in: :query, type: :string, description: "Filter by actor type"],
      actor_id: [in: :query, type: :string, description: "Filter by actor ID"],
      project_id: [in: :query, type: :string, description: "Filter by project"],
      from: [in: :query, type: :string, description: "ISO8601 start time"],
      to: [in: :query, type: :string, description: "ISO8601 end time"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Audit log", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}}
    }
  )

  @doc """
  GET /api/v1/audit

  Returns paginated audit log entries for the authenticated tenant.
  Supports filters: entity_type, entity_id, action, actor_type, actor_id,
  project_id, from, to, page, page_size.
  """
  def index(conn, params) do
    with {:ok, tenant_id} <- require_tenant(conn) do
      opts =
        []
        |> maybe_put(:entity_type, params["entity_type"])
        |> maybe_put(:entity_id, params["entity_id"])
        |> maybe_put(:action, params["action"])
        |> maybe_put(:actor_type, params["actor_type"])
        |> maybe_put(:actor_id, params["actor_id"])
        |> maybe_put(:project_id, params["project_id"])
        |> maybe_put_datetime(:from, params["from"])
        |> maybe_put_datetime(:to, params["to"])
        |> maybe_put_integer(:page, params["page"])
        |> maybe_put_integer(:page_size, params["page_size"])

      {:ok, result} = Audit.list_entries(tenant_id, opts)

      json(conn, %{
        data: Enum.map(result.data, &entry_json/1),
        pagination: %{
          total: result.total,
          page: result.page,
          page_size: result.page_size
        }
      })
    end
  end

  defp entry_json(entry) do
    %{
      id: entry.id,
      entity_type: entry.entity_type,
      entity_id: entry.entity_id,
      action: entry.action,
      actor_type: entry.actor_type,
      actor_id: entry.actor_id,
      actor_label: entry.actor_label,
      old_state: entry.old_state,
      new_state: entry.new_state,
      project_id: entry.project_id,
      metadata: entry.metadata,
      inserted_at: entry.inserted_at
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_integer(opts, _key, nil), do: opts

  defp maybe_put_integer(opts, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> Keyword.put(opts, key, n)
      :error -> opts
    end
  end

  defp maybe_put_integer(opts, key, value) when is_integer(value) do
    Keyword.put(opts, key, value)
  end

  defp maybe_put_datetime(opts, _key, nil), do: opts

  defp maybe_put_datetime(opts, key, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> Keyword.put(opts, key, dt)
      _ -> opts
    end
  end

  defp require_tenant(conn) do
    case conn.assigns[:current_tenant] do
      %{id: id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :bad_request, "Superadmin must use X-Impersonate-Tenant header"}
    end
  end
end
