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
  alias Loopctl.Knowledge
  alias LoopctlWeb.Helpers.Visibility

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

      # Visibility (#163): article change entries carry the memory's body + metadata
      # in their snapshot. For an agent caller, drop entries for any article it can't
      # currently see, so the change feed can't be used to read around the visibility
      # barrier. Higher roles (scope_opts == []) see everything.
      visible = filter_visible_changes(result.data, Visibility.scope_opts(conn), tenant_id)

      json(conn, %{
        data: Enum.map(visible, &change_json/1),
        has_more: result.has_more,
        next_since: format_datetime(result.next_since)
      })
    end
  end

  defp filter_visible_changes(entries, [], _tenant_id), do: entries

  defp filter_visible_changes(entries, [visibility_agent_id: vis], tenant_id) do
    # Collect every article id referenced by an article OR article_link entry, then
    # resolve visibility in one lookup. Article entries drop unless the article is
    # visible; article_link entries drop unless BOTH endpoints are visible (mirrors
    # list_links_for_article) — a link can't leak a private memory's id/edge.
    referenced_ids =
      entries
      |> Enum.flat_map(&change_article_ids/1)
      |> Enum.uniq()

    visible = Knowledge.visible_article_ids(tenant_id, referenced_ids, vis)

    Enum.reject(entries, fn entry ->
      case entry.entity_type do
        "article" ->
          not MapSet.member?(visible, entry.entity_id)

        "article_link" ->
          not Enum.all?(change_article_ids(entry), &MapSet.member?(visible, &1))

        _ ->
          false
      end
    end)
  end

  # Article ids referenced by a change entry: an article entry references itself; an
  # article_link entry references both endpoints (from new_state or old_state).
  defp change_article_ids(%{entity_type: "article", entity_id: id}), do: [id]

  defp change_article_ids(%{entity_type: "article_link"} = entry) do
    state = entry.new_state || entry.old_state || %{}

    [state["source_article_id"], state["target_article_id"]]
    |> Enum.filter(&is_binary/1)
  end

  defp change_article_ids(_entry), do: []

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
