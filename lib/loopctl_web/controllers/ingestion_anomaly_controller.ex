defmodule LoopctlWeb.IngestionAnomalyController do
  @moduledoc """
  Controller for ingestion capture-silence anomaly management.

  - `GET /api/v1/ingestion-anomalies` -- list unresolved anomalies (orchestrator+)
  - `PATCH /api/v1/ingestion-anomalies/:id` -- mark anomaly as resolved;
    `?archived=true` archives a retired source_type, `?archived=false` un-archives
    it (restoring monitoring) (user+)

  Role gating mirrors `LoopctlWeb.CostAnomalyController` exactly: listing at the
  same read role cost anomalies use, and resolution at `:user` (a custody-adjacent
  action, additionally human-anchor gated).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionHealth

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:index]
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:update]

  # Work-breakdown / custody-adjacent surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:update]

  tags(["Knowledge Wiki"])

  operation(:index,
    summary: "List ingestion anomalies (capture-silence + high-reject-rate)",
    description:
      "Returns unresolved ingestion anomalies for the tenant — both capture_silence " <>
        "(a source_type that stopped producing articles) and high_reject_rate (writes " <>
        "attempted but rejected at high rate, which persist no article row). " <>
        "Filterable by source_type and anomaly_type. Archived anomalies are excluded by " <>
        "default; use ?include_archived=true to include them. A malformed ?resolved value " <>
        "or an unknown ?anomaly_type is rejected with 422. The response `meta.filters` " <>
        "echoes the effective filters, " <>
        "and `meta.warnings` flags a source_type filter that names a never-seen source " <>
        "(so an empty list is not mistaken for healthy).",
    parameters: [
      source_type: [
        in: :query,
        type: :string,
        description: "Filter by monitored article source_type (e.g. session_log)"
      ],
      anomaly_type: [
        in: :query,
        type: :string,
        description: "Filter by anomaly type: capture_silence or high_reject_rate"
      ],
      include_archived: [
        in: :query,
        type: :boolean,
        description: "Include archived anomalies (default: false)"
      ],
      resolved: [
        in: :query,
        type: :string,
        description:
          "Filter by resolved status: true = resolved only, false = unresolved only " <>
            "(default: false), all = both resolved and unresolved (complete timeline)"
      ],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Anomaly list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}},
             meta: Schemas.PaginationMeta
           }
         }},
      422 =>
        {"Invalid 'resolved' or 'anomaly_type' filter value", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Resolve, archive, or un-archive ingestion anomaly",
    description:
      "Marks an ingestion capture-silence anomaly as resolved. Pass ?archived=true to " <>
        "instead ARCHIVE it — the escape hatch for a retired source_type, which hides it " <>
        "from the default list and suppresses re-detection. Pass ?archived=false to " <>
        "UN-ARCHIVE it, restoring monitoring for a mistakenly-archived source_type. A " <>
        "malformed ?archived value is rejected with 422.",
    parameters: [
      id: [in: :path, type: :string, description: "Anomaly UUID"],
      archived: [
        in: :query,
        type: :boolean,
        description:
          "true = archive (suppress re-detection); false = un-archive (restore monitoring); " <>
            "omit = resolve"
      ]
    ],
    responses: %{
      200 =>
        {"Anomaly resolved or archived", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           description: "Confirmation of resolution or archival",
           properties: %{
             ingestion_anomaly: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 id: %OpenApiSpex.Schema{type: :string, format: :uuid},
                 resolved: %OpenApiSpex.Schema{type: :boolean, example: true},
                 archived: %OpenApiSpex.Schema{type: :boolean, example: false},
                 updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
               }
             }
           }
         }},
      404 => {"Anomaly not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/ingestion-anomalies

  Lists unresolved ingestion capture-silence anomalies for the tenant.
  """
  def index(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    # A malformed ?resolved OR an unknown ?anomaly_type is rejected with 422 (not
    # silently coerced / turned into a `where false` empty list) — so an operator who
    # mistypes a filter sees the error, not a zero-result that reads as "healthy".
    # Mirrors the update action's malformed-?archived guard.
    with {:ok, resolved} <- parse_resolved(params["resolved"]),
         {:ok, anomaly_type} <- parse_anomaly_type(params["anomaly_type"]) do
      source_type = string_filter(params["source_type"])
      include_archived = parse_bool(params["include_archived"]) || false

      opts =
        []
        |> maybe_add_opt(:source_type, source_type)
        |> maybe_add_opt(:anomaly_type, anomaly_type)
        |> maybe_add_opt(:include_archived, include_archived)
        |> maybe_add_opt(:resolved, resolved)
        |> maybe_add_opt(:page, parse_int(params["page"]))
        |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

      {:ok, result} = IngestionHealth.list_anomalies(tenant_id, opts)

      json(conn, %{
        data: result.data,
        meta: %{
          page: result.page,
          page_size: result.page_size,
          total_count: result.total,
          total_pages: ceil_div(result.total, result.page_size),
          # Echo the EFFECTIVE filters (post-default) so a caller can confirm what was
          # actually applied — an omitted `resolved` reports the unresolved-only default.
          filters: %{
            source_type: source_type,
            anomaly_type: anomaly_type,
            resolved: if(is_nil(resolved), do: false, else: resolved),
            include_archived: include_archived
          },
          # Warn when a source_type filter names a never-seen source, so an empty list
          # is never mistaken for "healthy ingestion".
          warnings: source_type_warnings(tenant_id, source_type)
        }
      })
    end
  end

  # When a source_type filter names a source with NO recorded write activity for this
  # tenant, an empty anomaly list does not imply healthy ingestion — surface that.
  defp source_type_warnings(tenant_id, source_type) when is_binary(source_type) do
    if IngestionHealth.source_type_seen?(tenant_id, source_type) do
      []
    else
      [
        "source_type #{inspect(source_type)} has no recorded write activity for this " <>
          "tenant; an empty result does not imply healthy ingestion for it."
      ]
    end
  end

  defp source_type_warnings(_tenant_id, _source_type), do: []

  @doc """
  PATCH /api/v1/ingestion-anomalies/:id

  Resolves the anomaly, or (with `?archived=true`) archives it, or (with
  `?archived=false`) un-archives it. A malformed `?archived` value yields 422 so a
  state-changing intent is never silently downgraded to a resolve.
  """
  def update(conn, %{"id" => id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    audit_opts = [
      actor_id: api_key.id,
      actor_label: api_key.name,
      actor_type: "api_key"
    ]

    with {:ok, action} <- archived_action(params),
         {:ok, anomaly} <- apply_action(action, tenant_id, id, audit_opts) do
      json(conn, %{
        ingestion_anomaly: %{
          id: anomaly.id,
          resolved: anomaly.resolved,
          archived: anomaly.archived,
          updated_at: anomaly.updated_at
        }
      })
    end
  end

  # Determine intent from ?archived. Absent -> resolve. Explicit true/false ->
  # archive/unarchive. Any other (malformed) value is rejected — never silently
  # downgraded to resolve, which would be a wrong state change for the operator.
  defp archived_action(params) do
    case Map.fetch(params, "archived") do
      :error ->
        {:ok, :resolve}

      {:ok, raw} ->
        case parse_bool(raw) do
          true ->
            {:ok, :archive}

          false ->
            {:ok, :unarchive}

          nil ->
            {:error, :unprocessable_entity,
             "Invalid 'archived' value #{inspect(raw)}; expected true or false."}
        end
    end
  end

  defp apply_action(:archive, tenant_id, id, opts),
    do: IngestionHealth.archive_anomaly(tenant_id, id, opts)

  defp apply_action(:unarchive, tenant_id, id, opts),
    do: IngestionHealth.unarchive_anomaly(tenant_id, id, opts)

  defp apply_action(:resolve, tenant_id, id, opts),
    do: IngestionHealth.resolve_anomaly(tenant_id, id, opts)

  # --- Private helpers ---

  defp parse_bool(nil), do: nil
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool(_), do: nil

  # `resolved=all` is a sentinel meaning "both resolved and unresolved"; true/false
  # narrow to that status; absent/empty -> {:ok, nil} (context default of
  # unresolved-only). A malformed value is rejected with 422 rather than silently
  # coerced, so an empty result is never mistaken for a deliberate filter.
  defp parse_resolved(nil), do: {:ok, nil}
  defp parse_resolved(""), do: {:ok, nil}
  defp parse_resolved("all"), do: {:ok, :all}
  defp parse_resolved("true"), do: {:ok, true}
  defp parse_resolved("false"), do: {:ok, false}
  defp parse_resolved(true), do: {:ok, true}
  defp parse_resolved(false), do: {:ok, false}

  defp parse_resolved(other) do
    {:error, :unprocessable_entity,
     "Invalid 'resolved' value #{inspect(other)}; expected true, false, or all."}
  end

  # Absent/empty -> {:ok, nil} (no filter). A known anomaly_type -> {:ok, value}. An
  # UNKNOWN value (e.g. the natural typo "high-reject-rate") is rejected with 422 rather
  # than flowing into the context's `where(false)` and returning an empty list that an
  # operator would misread as healthy ingestion.
  defp parse_anomaly_type(nil), do: {:ok, nil}
  defp parse_anomaly_type(""), do: {:ok, nil}

  defp parse_anomaly_type(value) when is_binary(value) do
    if value in known_anomaly_types() do
      {:ok, value}
    else
      {:error, :unprocessable_entity,
       "Invalid 'anomaly_type' value #{inspect(value)}; expected one of " <>
         "#{Enum.join(known_anomaly_types(), ", ")}."}
    end
  end

  defp parse_anomaly_type(_), do: {:ok, nil}

  defp known_anomaly_types, do: Enum.map(IngestionAnomaly.anomaly_types(), &Atom.to_string/1)

  # A query filter must be a non-empty string to apply; empty/absent/malformed -> nil.
  defp string_filter(value) when is_binary(value) and value != "", do: value
  defp string_filter(_), do: nil

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
