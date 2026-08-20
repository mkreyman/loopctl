defmodule LoopctlWeb.KnowledgeAnalyticsController do
  @moduledoc """
  Controller for knowledge analytics endpoints.

  All endpoints require `orchestrator+` role and surface aggregated
  article usage data captured by `Loopctl.Knowledge.Analytics`.

  - `GET /api/v1/knowledge/analytics/top-articles` -- top accessed articles
  - `GET /api/v1/knowledge/articles/:id/stats` -- per-article usage stats
  - `GET /api/v1/knowledge/analytics/agents/:agent_id` -- per-agent usage
  - `GET /api/v1/knowledge/analytics/projects/:id/usage` -- per-project rollup
  - `GET /api/v1/knowledge/analytics/unused-articles` -- unused published articles
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.KbCuration
  alias Loopctl.Knowledge.RetrievalMetrics

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  tags(["Knowledge Analytics"])

  @max_limit 100
  @max_unused_limit 200
  # DERIVED, never re-listed (#569). This was the THIRD hand-maintained copy of the
  # `article_access_events.access_type` enum, and it went stale the moment `"drill"` was added
  # to the other two — silently, because `put_access_type/2`'s catch-all DROPPED an unrecognised
  # value instead of rejecting it, so `?access_type=drill` returned the UNFILTERED top articles
  # under a heading that said otherwise. Wrong numbers presented as the right ones is the worst
  # shape an analytics bug can take. `Analytics.valid_access_types/0` is the one list; the
  # OpenAPI description below is interpolated from it so the published contract cannot drift
  # from the enforced one either.
  @valid_access_types Analytics.valid_access_types()

  # Same discipline as the line above: the published cap is READ from the module that
  # enforces it (`Knowledge.maybe_record_search_access/5` takes exactly this many), so
  # raising the cap cannot leave the API description stating the old number.
  @max_recorded_search_results Analytics.max_recorded_search_results()
  @valid_group_by ~w(article project agent)

  operation(:top_articles,
    summary: "Top accessed knowledge articles",
    description:
      "Returns the top accessed articles for the tenant in a time window. " <>
        "Supports `project_id` filtering and `group_by` (article|project|agent). " <>
        "Role: orchestrator+.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        description: "Max rows per page (default 20, max 100). Clamped, never rejected.",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Rows to skip — page the ranking to completeness (default 0)",
        required: false
      ],
      since_days: [
        in: :query,
        type: :integer,
        description: "Look back this many days (default 7, min 1, max 365)",
        required: false
      ],
      access_type: [
        in: :query,
        type: :string,
        description:
          "Restrict to a single access type (#{Enum.join(@valid_access_types, ", ")}). " <>
            "An unrecognised value is a 400, never a silently unfiltered result.",
        required: false
      ],
      project_id: [
        in: :query,
        type: :string,
        description:
          "Filter events to a single project_id (events without attribution are excluded)",
        required: false
      ],
      group_by: [
        in: :query,
        type: :string,
        description: "Grouping dimension: article (default), project, or agent",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Top articles", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/top-articles"
  def top_articles(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    group_by = parse_group_by(params["group_by"])

    with :ok <- validate_access_type(params["access_type"]) do
      opts =
        []
        |> put_limit(params["limit"], 20, @max_limit)
        |> put_offset(params["offset"])
        |> put_since(params["since_days"], 7)
        |> put_access_type(params["access_type"])
        |> put_project_id(params["project_id"])
        |> Keyword.put(:group_by, group_by)

      rows = Knowledge.list_top_articles(tenant_id, opts)
      json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.top_articles(rows, opts))
    end
  end

  operation(:article_stats,
    summary: "Per-article usage statistics",
    description: "Returns aggregated access counts for a single article. Role: orchestrator+.",
    parameters: [
      id: [in: :path, type: :string, description: "Article UUID", required: true]
    ],
    responses: %{
      200 =>
        {"Article stats", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/articles/:id/stats"
  def article_stats(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    # Deliberately NO `:api_key_id`: this resolves the id to shape a STATS response and
    # delivers no body, and `Analytics.record_access/6` no-ops on a nil api_key_id
    # (`analytics.ex:119`), so nothing is recorded. Do NOT add one for attribution — opening
    # an article's analytics would then register as a read of it, inflating the very number
    # this endpoint reports and feeding `heat_index/2` a read it caused.
    case Knowledge.get_article(tenant_id, article_id) do
      {:ok, article} ->
        stats = Knowledge.get_article_stats(tenant_id, article.id)
        json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.article_stats(article, stats))

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  operation(:agent_usage,
    summary: "Per-agent knowledge usage",
    description:
      ~s(Returns the reads, top articles, and access type breakdown for a single ) <>
        ~s(api_key OR logical agent. The path parameter is resolved against ) <>
        ~s(`api_keys.id` first, then `agents.id`. The response envelope includes ) <>
        ~s(`resolved_as: "api_key" | "agent"` so callers can tell which branch ) <>
        ~s(ran. Cross-tenant or missing ids return 404. Role: orchestrator+.),
    parameters: [
      agent_id: [
        in: :path,
        type: :string,
        description: "API key UUID or agent UUID",
        required: true
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max top articles to return (default 20, max 100)",
        required: false
      ],
      since_days: [
        in: :query,
        type: :integer,
        description: "Look back this many days (default 7, min 1, max 365)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Agent usage", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/agents/:agent_id"
  def agent_usage(conn, %{"agent_id" => id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> put_limit(params["limit"], 20, @max_limit)
      |> put_since(params["since_days"], 7)

    with {:ok, usage} <- Knowledge.get_agent_usage(tenant_id, id, opts) do
      json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.agent_usage(usage, opts))
    end
  end

  operation(:project_usage,
    summary: "Per-project wiki usage rollup",
    description:
      "Returns total reads, unique articles, unique callers, access type " <>
        "breakdown, top articles, and a zero-filled daily read-count series " <>
        "for a single project. Cross-tenant or missing projects return 404. " <>
        "Role: orchestrator+.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Project UUID",
        required: true
      ],
      since_days: [
        in: :query,
        type: :integer,
        description: "Look back this many days (default 7, min 1, max 365)",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max top articles to return (default 20, max 100)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Project usage", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/projects/:id/usage"
  def project_usage(conn, %{"id" => project_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    since_days = parse_int(params["since_days"], 7) |> max(1) |> min(365)

    opts =
      []
      |> put_limit(params["limit"], 20, @max_limit)
      |> Keyword.put(:since_days, since_days)

    with {:ok, usage} <- Knowledge.get_project_usage(tenant_id, project_id, opts) do
      json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.project_usage(usage, since_days))
    end
  end

  operation(:unused_articles,
    summary: "Unused published articles",
    description:
      "Returns published articles with zero access events in the configured window. " <>
        "Role: orchestrator+.",
    parameters: [
      days_unused: [
        in: :query,
        type: :integer,
        description: "Window length in days (default 30)",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max rows per page (default 50, max 200). Clamped, never rejected.",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Rows to skip — page the full unused set to completeness (default 0)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Unused articles", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/unused-articles"
  def unused_articles(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> put_int(:days_unused, params["days_unused"], 30, 1, 365)
      |> put_limit(params["limit"], 50, @max_unused_limit)
      |> put_offset(params["offset"])

    rows = Knowledge.list_unused_articles(tenant_id, opts)
    json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.unused_articles(rows, opts))
  end

  operation(:retrieval_metrics,
    summary: "Retrieval precision time series",
    description:
      "Daily retrieval PRECISION (agents' KB #3): the share of a day's RECORDED search " <>
        "RESULTS the agent then opened (search → get/context within a window). A proxy " <>
        "for retrieval quality that trends up as the corpus is de-duplicated and better " <>
        "navigated. Most recent day first. Role: orchestrator+.\n\n" <>
        "DENOMINATORS (#582) — `precision` = `followed_through` / `searched`, and " <>
        "`searched` counts RECORDED SURFACED RESULTS (one row per result a search put in " <>
        "front of an agent, capped at the first #{@max_recorded_search_results} per " <>
        "call), NOT search calls; `results_recorded` is the same number named for its " <>
        "unit. Because of that cap `precision` is precision@#{@max_recorded_search_results}: " <>
        "a call returning more results contributes only #{@max_recorded_search_results} to " <>
        "`searched`, and an open of a result ranked beyond the cap appears in neither " <>
        "term. The per-CALL rate is reported separately as `search_follow_through` = " <>
        "`searches_with_follow_through` / `searches` (distinct QUERY-BEARING search " <>
        "calls) — that is the 'share of searches that led to an open'. " <>
        "`results_returned` is the true un-truncated result count for those same calls, " <>
        "so it exceeds the rows those calls wrote whenever a page hit that cap.\n\n" <>
        "CALL-LEVEL POPULATION — the four call-level fields are computed per ROW, not " <>
        "per day: a row counts only if it carries a search identity (nothing recorded " <>
        "before #582 does) and is not a query-less enumeration page (`list` / " <>
        "`list_keyset`, written by the browse endpoints — browsing is not searching). A " <>
        "day that MIXES qualifying and non-qualifying rows therefore reports a PARTIAL " <>
        "`searches` / `results_returned`, not 0; only a day with no qualifying row reads " <>
        "0. Do NOT compare `results_returned` against `searched` — they aggregate " <>
        "different row populations, so `results_returned` < `searched` is the normal " <>
        "shape of a legacy-heavy or browse-heavy day.\n\n" <>
        "CAVEATS — searches returning ZERO results and searches made without an api key " <>
        "are structurally unrecordable and appear in NO denominator, so every ratio here " <>
        "is an upper bound. Both ratios also rise when a search simply returns FEWER " <>
        "results, with no better retrieval: never optimise them alone — read them with " <>
        "the absolute `followed_through` and the volume fields. `search_follow_through` " <>
        "carries two further biases pointing OPPOSITE ways: the recording cap hides opens " <>
        "of results ranked beyond it (biases it DOWN on large pages), while one open " <>
        "credits EVERY search in the window that surfaced that article, not just the " <>
        "preceding one (biases it UP when an agent refines and re-searches).\n\n" <>
        "EXACT ATTRIBUTION (unit: READS, not surfaced results and not calls) — " <>
        "`attributed_opens` / `cross_key_opens` / `direct_opens` count READ rows by how " <>
        "their originating search was established server-side at write time. These are " <>
        "NOT comparable with `followed_through`, which counts SURFACED RESULTS later " <>
        "opened. `cross_key_opens` is the population `followed_through` cannot see at " <>
        "all: it correlates on `api_key_id`, and the injected recall hook searches under " <>
        "a different key from the session that reads, so that channel scores a structural " <>
        "ZERO there — meaning UNMEASURABLE, not unread. Cross-key attribution is " <>
        "circumstantial by construction (two agents in one tenant can reach one article " <>
        "independently), which is why it is labelled rather than folded in silently. " <>
        "`direct_opens` is the agent going straight to an article by link or cited id — " <>
        "previously indistinguishable from 'surfaced and ignored', close to its " <>
        "opposite. A read with no attribution is in none of the three (pre-migration " <>
        "rows, a surfacing row predating #582 that carries no search identity, and a " <>
        "`drill` with no surfacing row — the progressive index records none, so calling " <>
        "it a direct open would be false).\n\n" <>
        "TWO WINDOWS, NOT ONE KNOB — attribution is baked in at WRITE time and cannot be " <>
        "re-asked of history; the correlated metrics take `window_seconds` at QUERY time. " <>
        "They share a default, so a divergence after passing a different `window_seconds` " <>
        "is that mismatch, not a bug.\n\n" <>
        "DISPOSITION (unit: SEARCH CALLS) — `searches_scored_with_follow_through`, " <>
        "`searches_reformulated` and `searches_quiet` PARTITION `searches_scored`, NOT " <>
        "`searches`. Treating every not-opened search as a failure is wrong: an agent " <>
        "whose question is answered by the result snippet correctly opens nothing, and " <>
        "that is a success. A REFORMULATION (the SAME SESSION issuing a later search " <>
        "call with a DIFFERENT QUERY inside the window, having opened nothing) is the " <>
        "closest thing to an unambiguous failure in that bucket, so it is reported " <>
        "separately. What remains is `quiet` and is STILL a mixture of 'the snippet " <>
        "sufficed' and 'the rows were ignored' — this surface does NOT separate them. " <>
        "Do not read `quiet` as either; follow-through is a floor, never a satisfaction " <>
        "rate.\n\n" <>
        "`searches_scored` IS SMALLER THAN `searches`, AND THE GAP IS NOT QUIET " <>
        "TRAFFIC. A search is scoreable only if it carries a session identity (stamped " <>
        "forward-looking, so every row predating it is unscoreable and a pre-migration " <>
        "row reports `searches_scored: 0`) and comes from a channel that can react to a " <>
        "result at all — the recall hook and the session-start auto-query emit one " <>
        "distilled query per prompt and never see what came back, so they cannot " <>
        "reformulate by construction. They remain in every other denominator on this " <>
        "surface, including precision. Read `searches - searches_scored` as n/a, never " <>
        "as zero.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        description: "Days per page (default 30, max 365). Clamped, never rejected.",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Days to skip (default 0)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Retrieval metrics", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/retrieval-metrics"
  def retrieval_metrics(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> put_limit(params["limit"], 30, 365)
      |> put_offset(params["offset"])

    json(conn, RetrievalMetrics.list_snapshots(tenant_id, opts))
  end

  operation(:curation_log,
    summary: "KB curation adjustment log",
    description:
      "The concise, human-readable log of KB CURATION adjustments (novelty-gate decisions, " <>
        "conflict supersede/merge/dismiss) — the 'what did the KB change' feed for rollout " <>
        "analysis. Recorded only while the tenant has `settings.kb_curation_log` on (toggle " <>
        "via PATCH /api/v1/admin/tenants/:id). Most recent first. Role: orchestrator+.",
    parameters: [
      kind: [
        in: :query,
        type: :string,
        description:
          "Filter by kind (gate_duplicate|gate_draft|gate_skip|supersede|merge|dismiss). " <>
            "`gate_skip` is the novelty gate DISCARDING a high-overlap proposal under " <>
            "on_low_novelty=skip — the audit trail for captures that were dropped, not stored.",
        required: false
      ],
      since: [
        in: :query,
        type: :string,
        description: "ISO8601 date/datetime lower bound (inclusive)",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Events per page (default 50, max 500). Clamped, never rejected.",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Events to skip (default 0)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Curation log", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/curation-log"
  def curation_log(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> put_limit(params["limit"], 50, 500)
      |> put_offset(params["offset"])
      |> maybe_put(:kind, params["kind"])
      |> maybe_put(:since, parse_since(params["since"]))

    json(conn, KbCuration.list(tenant_id, opts))
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp put_limit(opts, value, default, max_value) do
    Keyword.put(opts, :limit, parse_int(value, default) |> max(1) |> min(max_value))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Accept an ISO8601 datetime OR date for the curation-log `since` lower bound.
  defp parse_since(nil), do: nil
  defp parse_since(""), do: nil

  defp parse_since(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(value) do
          {:ok, d} -> d
          _ -> nil
        end
    end
  end

  # Offset enables paging the ranking past the first page — never rejected, so a
  # caller can enumerate to completeness (the rankings are access-count aggregates,
  # not vector scans, so deep offset is cheap).
  defp put_offset(opts, value) do
    Keyword.put(opts, :offset, parse_int(value, 0) |> max(0))
  end

  defp put_since(opts, value, default_days) do
    days = parse_int(value, default_days) |> max(1) |> min(365)
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Keyword.put(opts, :since, since)
  end

  defp put_access_type(opts, nil), do: opts
  defp put_access_type(opts, ""), do: opts

  defp put_access_type(opts, value) when value in @valid_access_types do
    Keyword.put(opts, :access_type, value)
  end

  defp put_access_type(opts, _), do: opts

  # REJECT an unrecognised value rather than ignoring it. `put_access_type/2`'s catch-all
  # exists so the opts pipeline stays total, but on its own it turned a typo — or a type this
  # deployment does not know yet — into a 200 carrying the unfiltered set, labelled as if the
  # filter had applied. A caller cannot tell that from a real answer.
  defp validate_access_type(nil), do: :ok
  defp validate_access_type(""), do: :ok
  defp validate_access_type(value) when value in @valid_access_types, do: :ok

  defp validate_access_type(value) when is_binary(value) do
    {:error, :bad_request,
     "Invalid access_type #{inspect(value)}. Valid values: #{Enum.join(@valid_access_types, ", ")}"}
  end

  defp validate_access_type(_value),
    do: {:error, :bad_request, "Invalid access_type: expected a string"}

  defp put_project_id(opts, nil), do: opts
  defp put_project_id(opts, ""), do: opts

  # Require the canonical 36-char dashed form. `Ecto.UUID.cast/1` also accepts a
  # raw 16-byte binary, so a 16-char junk value would otherwise coerce into a
  # bogus-but-valid UUID and silently narrow results instead of being ignored.
  defp put_project_id(opts, value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, cast_id} -> Keyword.put(opts, :project_id, cast_id)
      :error -> opts
    end
  end

  defp put_project_id(opts, _), do: opts

  defp parse_group_by(nil), do: :article
  defp parse_group_by(""), do: :article

  defp parse_group_by(value) when value in @valid_group_by do
    String.to_existing_atom(value)
  end

  defp parse_group_by(_), do: :article

  defp put_int(opts, key, value, default, min_value, max_value) do
    Keyword.put(opts, key, parse_int(value, default) |> max(min_value) |> min(max_value))
  end

  defp parse_int(nil, default), do: default
  defp parse_int(int, _default) when is_integer(int), do: int

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
