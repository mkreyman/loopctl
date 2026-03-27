defmodule LoopctlWeb.AuditController do
  @moduledoc """
  Controller for the audit log endpoint.

  GET /api/v1/audit — paginated, filtered audit log entries.
  Requires `user` role or higher.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Audit

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  @doc """
  GET /api/v1/audit

  Returns paginated audit log entries for the authenticated tenant.
  Supports filters: entity_type, entity_id, action, actor_type, actor_id,
  project_id, from, to, page, page_size.
  """
  def index(conn, params) do
    tenant_id = conn.assigns.current_tenant.id

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
end
