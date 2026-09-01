defmodule LoopctlWeb.AdminKnowledgeStatsController do
  @moduledoc """
  Cross-tenant KB retrieval BREAKDOWN for superadmins.

  `GET /api/v1/admin/knowledge/retrieval-metrics` — one row per tenant for a single day.

  This is deliberately a breakdown and never a roll-up. Each tenant's KB is a different
  corpus with a different size, subject mix and traffic profile, so a figure summed or
  averaged across them describes no corpus that exists — and the blend hides the very
  account an operator is looking for. `Tenants.system_stats/0` is the place for
  platform-wide numbers; it counts inventory, which IS summable, rather than retrieval
  quality, which is not.

  The tenant-scoped equivalent for a normal key is
  `GET /api/v1/knowledge/analytics/retrieval-metrics`, which never crosses a tenant
  boundary. Nothing here relaxes that: this endpoint reads snapshots, which are already
  one row per tenant per day, and it reports them separately.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge.RetrievalMetrics

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :superadmin

  tags(["Admin"])

  operation(:index,
    summary: "Per-tenant KB retrieval breakdown (admin)",
    description:
      "One row PER TENANT for a single day. Requires superadmin.\n\n" <>
        "THIS IS A BREAKDOWN, NOT A ROLL-UP, AND THE ROWS ARE NOT SUMMABLE. Each tenant's " <>
        "KB is a different corpus with a different size and traffic profile, so a mean or " <>
        "total across them describes no corpus that exists — a 2% read rate over 79,000 " <>
        "articles blended with a 40% rate over 30 is not a fact about either. The payload " <>
        "reports `meta.aggregation: \"none\"` for that reason and carries no totals row. " <>
        "For platform-wide numbers use GET /api/v1/admin/stats, which counts inventory " <>
        "(summable) rather than retrieval quality (not).\n\n" <>
        "Tenants with no snapshot for the day are INCLUDED with `snapshot: null` rather " <>
        "than omitted — a KB nobody queried, or a broken ingest, is a finding, and dropping " <>
        "the row makes the most interesting one invisible.\n\n" <>
        "Rows carry their own `metric_version` and these CAN DIFFER within one response: a " <>
        "tenant not re-snapshotted since a definition change still carries the older one. " <>
        "Compare a column across tenants only where the versions match.\n\n" <>
        "WHICH FOLLOW-THROUGH RATE TO QUOTE — this surface publishes BOTH per tenant, and " <>
        "it is the one where the wrong choice does the most damage, because comparing " <>
        "tenants is exactly what it is for. `search_follow_through` is over every " <>
        "query-bearing call that survives the infrastructure exclusion, which still " <>
        "INCLUDES the recall hook and the session-start auto-query — channels that emit " <>
        "one distilled query per prompt, never see what came back, and so cannot follow " <>
        "through by construction. It is BLENDED: use it for total traffic, and NEVER quote " <>
        "it as agent behaviour. `scored_follow_through` is over `searches_scored` (a " <>
        "session identity AND a channel that can react to a result) and IS the " <>
        "agent-behaviour rate. It is `null`, never `0.0`, when nothing was scoreable — " <>
        "zero would assert that agents searched and opened nothing when the truth is that " <>
        "the instrument could not see, so a null row is n/a and must be excluded from a " <>
        "comparison rather than read as a floor. Measured live for 2026-08-19..29 on one " <>
        "tenant: 10.8% blended against 38.0% scored, a 3.4x gap, because the recall hook " <>
        "alone was 1,234 of that window's 1,708 calls. A tenant whose automation searches " <>
        "on a schedule will look far worse than one whose does not, on the blended rate " <>
        "alone, with no difference in how its agents behave.",
    parameters: [
      day: [
        in: :query,
        type: :string,
        description:
          "ISO date (YYYY-MM-DD). Defaults to yesterday, which is the day the " <>
            "nightly snapshot worker writes.",
        required: false
      ],
      window_seconds: [
        in: :query,
        type: :integer,
        description:
          "Follow-through window the snapshot was computed with (default 1800). " <>
            "A snapshot exists per (tenant, day, window), so a non-default value returns " <>
            "rows only where one was computed at that window.",
        required: false
      ],
      active_only: [
        in: :query,
        type: :boolean,
        description:
          "Restrict to active tenants (default true). Pass false to include " <>
            "suspended and deactivated ones.",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Per-tenant breakdown", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      400 => {"Invalid parameter", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/admin/knowledge/retrieval-metrics"
  def index(conn, params) do
    with {:ok, day} <- parse_day(params["day"]),
         {:ok, window} <- parse_window(params["window_seconds"]) do
      opts = build_opts(day, window, params["active_only"] != "false")

      %{rows: rows, meta: meta} = RetrievalMetrics.tenant_breakdown(opts)

      json(conn, %{data: rows, meta: meta})
    end
  end

  # Only the params the caller actually supplied are passed through, so the defaults live in
  # ONE place (`RetrievalMetrics.tenant_breakdown/1`) rather than being restated here where
  # they could drift out of agreement with it.
  defp build_opts(day, window, active_only) do
    [active_only: active_only]
    |> put_unless_nil(:day, day)
    |> put_unless_nil(:window_seconds, window)
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_day(nil), do: {:ok, nil}
  defp parse_day(""), do: {:ok, nil}

  defp parse_day(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, day} -> {:ok, day}
      {:error, _} -> {:error, :bad_request, "Invalid day #{inspect(value)}: expected YYYY-MM-DD"}
    end
  end

  defp parse_day(_), do: {:error, :bad_request, "Invalid day: expected a string"}

  defp parse_window(nil), do: {:ok, nil}
  defp parse_window(""), do: {:ok, nil}

  # A silently-ignored bad window would return the DEFAULT window's rows under a caller's
  # explicit non-default request — the same shape of analytics bug the access_type validation
  # already exists to prevent, so it is a 400 rather than a fallback.
  defp parse_window(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 ->
        {:ok, n}

      _ ->
        {:error, :bad_request,
         "Invalid window_seconds #{inspect(value)}: expected a positive integer"}
    end
  end

  defp parse_window(_),
    do: {:error, :bad_request, "Invalid window_seconds: expected a positive integer"}
end
