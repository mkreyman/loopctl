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
  alias Loopctl.Audit.ChangesCursor
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
        required: false,
        description:
          "ISO8601 timestamp. Required UNLESS a `cursor` is supplied. Used for the " <>
            "FIRST page (`inserted_at > since`); follow `next_cursor` thereafter."
      ],
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Opaque KEYSET cursor (US-27.9b) — the drift-free continuation token. " <>
            "Follow `meta.next_cursor`/`next_cursor` verbatim. Unlike `since` (a " <>
            "timestamp, which can skip or duplicate rows that share a microsecond " <>
            "under bulk writes), the cursor seeks the stable `(inserted_at, id)` tuple " <>
            "and never drifts across ties. Takes precedence over `since` when both are " <>
            "given. Integrity-protected and tenant-bound; a tampered/forged cursor is " <>
            "rejected with 400."
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
             next_since: %OpenApiSpex.Schema{
               type: :string,
               format: :"date-time",
               nullable: true,
               description:
                 "Back-compat timestamp token (NOT tie-safe under bulk writes). New " <>
                   "callers should follow `next_cursor`."
             },
             next_cursor: %OpenApiSpex.Schema{
               type: :string,
               nullable: true,
               description:
                 "Drift-free keyset continuation token (US-27.9b); null when exhausted."
             }
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
    with {:ok, tenant_id} <- require_tenant(conn),
         {:ok, since, cursor_opt} <- resolve_seek(tenant_id, params) do
      limit = parse_limit(params["limit"])

      opts =
        []
        |> maybe_put(:cursor, cursor_opt)
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
        next_since: format_datetime(result.next_since),
        next_cursor: encode_cursor(tenant_id, result.next_cursor)
      })
    end
  end

  # Resolves the seek position into a `{since_datetime, cursor_position_or_nil}`.
  #
  # US-27.9b: the `cursor` query param (when present) is the drift-free keyset token
  # and takes PRECEDENCE over `since`. Tenant scope is ALWAYS the principal's
  # `tenant_id`; the cursor is decoded+verified with the caller's tenant key, so a
  # forged/tampered/cross-tenant cursor is rejected with 400 (AC-27.9b.4), never a
  # silent reset to the beginning.
  #
  #   - cursor ABSENT      → require `since` (back-compat: the timestamp first page)
  #   - cursor EMPTY ""    → no cursor seek; require `since` (treats `cursor=` like
  #                          "start", deferring to `since` for the first position)
  #   - cursor a token     → decode → keyset seek (since is ignored / defaults to epoch)
  #   - cursor non-string  → 400
  defp resolve_seek(tenant_id, params) do
    case Map.fetch(params, "cursor") do
      :error -> with {:ok, since} <- parse_since(params["since"]), do: {:ok, since, nil}
      {:ok, ""} -> with {:ok, since} <- parse_since(params["since"]), do: {:ok, since, nil}
      {:ok, raw} when is_binary(raw) -> decode_cursor(tenant_id, raw)
      {:ok, _non_string} -> {:error, :bad_request, "cursor parameter must be a string"}
    end
  end

  defp decode_cursor(tenant_id, raw) do
    case ChangesCursor.decode(tenant_id, raw) do
      {:ok, position} ->
        # `since` is unused on the keyset path; the cursor carries the full position.
        # Pass the unix epoch so the (cursor-present) seek branch is taken with a
        # harmless `since` value.
        {:ok, DateTime.from_unix!(0), position}

      {:error, :invalid} ->
        {:error, :bad_request,
         "Invalid or tampered cursor. Send `since` to start from a timestamp, then " <>
           "follow `next_cursor` verbatim to paginate."}
    end
  end

  defp encode_cursor(_tenant_id, nil), do: nil

  defp encode_cursor(tenant_id, {%DateTime{}, _id} = position),
    do: ChangesCursor.encode(tenant_id, position)

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
