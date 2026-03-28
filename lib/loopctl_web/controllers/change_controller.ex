defmodule LoopctlWeb.ChangeController do
  @moduledoc """
  Controller for the change feed polling endpoint.

  GET /api/v1/changes?since=ISO8601 — cursor-based change feed for orchestrators.
  Returns audit log entries since a given timestamp, ordered ascending.

  Accessible to agent role and above. The `since` parameter is required.
  Results are capped at a configurable maximum (default 1000) with
  `has_more` and `next_since` for pagination.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Audit

  action_fallback LoopctlWeb.FallbackController

  tags(["Audit"])

  operation(:index,
    summary: "Poll change feed",
    description:
      "Cursor-based change feed for orchestrators. Returns audit log entries since a given timestamp.",
    parameters: [
      since: [
        in: :query,
        type: :string,
        required: true,
        description: "ISO8601 timestamp (required)"
      ],
      project_id: [in: :query, type: :string, description: "Filter by project"],
      entity_type: [in: :query, type: :string, description: "Filter by entity type"],
      action: [in: :query, type: :string, description: "Filter by action"],
      limit: [in: :query, type: :integer, description: "Max results"]
    ],
    responses: %{
      200 =>
        {"Change feed", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
             },
             has_more: %OpenApiSpex.Schema{type: :boolean},
             next_since: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true}
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # No RequireRole needed: within :authenticated pipeline, accessible to all
  # roles including agent. Agents and orchestrators need the change feed for
  # polling state changes (US-9.1).

  @doc """
  GET /api/v1/changes?since=ISO8601

  Required: `since` (ISO8601 timestamp)
  Optional: `project_id`, `entity_type`, `action`
  """
  def index(conn, params) do
    with {:ok, since} <- parse_since(params["since"]),
         {:ok, tenant_id} <- require_tenant(conn) do
      limit = parse_limit(params["limit"])

      opts =
        []
        |> maybe_put(:project_id, params["project_id"])
        |> maybe_put(:entity_type, params["entity_type"])
        |> maybe_put(:action, params["action"])
        |> maybe_put(:limit, limit)

      {:ok, result} = Audit.list_changes(tenant_id, since, opts)

      json(conn, %{
        data: Enum.map(result.data, &change_json/1),
        has_more: result.has_more,
        next_since: format_datetime(result.next_since)
      })
    end
  end

  defp parse_since(nil) do
    {:error, :bad_request, "The 'since' parameter is required"}
  end

  defp parse_since(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _reason} ->
        {:error, :bad_request,
         "Invalid timestamp format for 'since'. Expected ISO8601 (e.g., 2026-01-01T00:00:00Z)"}
    end
  end

  defp change_json(entry) do
    %{
      id: entry.id,
      entity_type: entry.entity_type,
      entity_id: entry.entity_id,
      action: entry.action,
      actor_type: entry.actor_type,
      actor_label: entry.actor_label,
      new_state: entry.new_state,
      project_id: entry.project_id,
      metadata: entry.metadata,
      inserted_at: entry.inserted_at
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_limit(nil), do: nil

  defp parse_limit(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_limit(val) when is_integer(val) and val > 0, do: val
  defp parse_limit(_), do: nil

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp require_tenant(conn) do
    case conn.assigns[:current_tenant] do
      %{id: id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :bad_request, "Superadmin must use X-Impersonate-Tenant header"}
    end
  end
end
