defmodule LoopctlWeb.AdminAuditController do
  @moduledoc """
  Controller for cross-tenant audit log queries.

  GET /api/v1/admin/audit — query audit log across all tenants.
  Requires superadmin API key. Includes tenant name/slug in response.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :superadmin

  tags(["Admin"])

  operation(:index,
    summary: "Cross-tenant audit log (admin)",
    description: "Returns paginated audit log entries across all tenants. Requires superadmin.",
    parameters: [
      tenant_id: [in: :query, type: :string, description: "Filter by tenant"],
      entity_type: [in: :query, type: :string, description: "Filter by entity type"],
      entity_id: [in: :query, type: :string, description: "Filter by entity ID"],
      action: [in: :query, type: :string, description: "Filter by action"],
      actor_type: [in: :query, type: :string, description: "Filter by actor type"],
      actor_id: [in: :query, type: :string, description: "Filter by actor ID"],
      from: [in: :query, type: :string, description: "ISO8601 start time"],
      to: [in: :query, type: :string, description: "ISO8601 end time"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Audit log", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/admin/audit

  Returns paginated audit log entries across all tenants.
  Supports filters: tenant_id, entity_type, entity_id, action,
  actor_type, actor_id, from, to, page, page_size.
  """
  def index(conn, params) do
    opts =
      []
      |> maybe_put(:tenant_id, params["tenant_id"])
      |> maybe_put(:entity_type, params["entity_type"])
      |> maybe_put(:entity_id, params["entity_id"])
      |> maybe_put(:action, params["action"])
      |> maybe_put(:actor_type, params["actor_type"])
      |> maybe_put(:actor_id, params["actor_id"])
      |> maybe_put_datetime(:from, params["from"])
      |> maybe_put_datetime(:to, params["to"])
      |> maybe_put_integer(:page, params["page"])
      |> maybe_put_integer(:page_size, params["page_size"])

    {:ok, result} = Tenants.list_audit_admin(opts)

    json(conn, %{
      data: Enum.map(result.data, &entry_json/1),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  defp entry_json(entry) do
    %{
      id: entry.id,
      tenant_id: entry.tenant_id,
      tenant_name: entry.tenant_name,
      tenant_slug: entry.tenant_slug,
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

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
