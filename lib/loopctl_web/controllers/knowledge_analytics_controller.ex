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
  - `GET /api/v1/knowledge/analytics/search-coverage` -- declared `search_events` coverage
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.KbCuration
  alias Loopctl.Knowledge.RetrievalMetrics
  alias Loopctl.Knowledge.SearchEventCoverage

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

  # What a CALLER may ask for, which is the stored types PLUS `"all"`. Kept separate from
  # `@valid_access_types` on purpose: that list validates the type of a RECORDED event, and
  # `"all"` is a query selector rather than a storable type.
  @selectable_access_types Analytics.selectable_access_types()

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
          "Restrict to a single access type (#{Enum.join(@valid_access_types, ", ")}), or " <>
            "\"all\" for every event type. DEFAULTS TO READS " <>
            "(#{Enum.join(Analytics.read_access_types(), ", ")}) rather than to every event: " <>
            "`search` and `index` are IMPRESSIONS the ranker produced, they outnumber reads " <>
            "roughly 50:1, and counting them made this endpoint rank ranker output under a " <>
            "name that promises usage. Pass \"all\" for the pre-#713 behaviour. " <>
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
        "is an upper bound. `precision` ALONE also rises when a search simply returns " <>
        "FEWER results, with no better retrieval — its denominator counts surfaced " <>
        "RESULTS; the two call-level rates divide CALL counts, which a narrower page " <>
        "does not shrink. Never optimise them alone — read them with the absolute " <>
        "`followed_through` and the volume fields. BOTH follow-through " <>
        "rates carry two further biases pointing OPPOSITE ways: the recording cap hides " <>
        "opens of results ranked beyond it (biases them DOWN on large pages), while one " <>
        "open credits EVERY search in the window that surfaced that article, not just " <>
        "the preceding one (biases them UP when an agent refines and re-searches, which " <>
        "bites hardest on `scored_follow_through`).\n\n" <>
        "THE THIRD STAGE (unit: DISTINCT (recall, article) REFERENCES) — `referenced` " <>
        "counts the articles a client asserted it USED, via " <>
        "`POST /recall/{recall_id}/referenced`, and `reference_rate` divides it by " <>
        "`searched` — the SAME denominator as `precision`, so it carries every one of " <>
        "that field's caveats. It is `null`, never 0.0, on a day that surfaced nothing. " <>
        "This is the ONLY figure here derived from a client ASSERTION rather than a " <>
        "delivery the server observed: the assertion is bounded (only an article that " <>
        "recall actually surfaced under that id, in the caller's own tenant, is " <>
        "accepted) but the bound is on WHICH articles, not on whether the claim is " <>
        "true. Read it as self-reported usage. Repeats cannot inflate it — the counter " <>
        "dedupes on (recall, article) — and no ranking consumes it: `referenced` rows " <>
        "are in no read set, are excluded from the heat index, and never enter " <>
        "`followed_through`, `precision` or the per-article read counts.\n\n" <>
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
        "as zero.\n\n" <>
        "WHICH FOLLOW-THROUGH RATE TO QUOTE. Two are published over DIFFERENT " <>
        "populations, and picking the wrong one misstates agent behaviour by roughly " <>
        "3.4x. `search_follow_through` is over every query-bearing call that SURVIVES the " <>
        "infrastructure exclusion — `smoke`/`skill-eval` sit in NO denominator here, but " <>
        "the recall hook and the session-start auto-query DO, and neither can follow " <>
        "through by construction. Use it to describe total traffic through the retrieval " <>
        "path, and read it as BLENDED. `scored_follow_through` is over `searches_scored` " <>
        "(a session identity AND a channel that can react to a result), and IT is the " <>
        "rate to quote when the question is whether AGENTS are consuming the KB; it is " <>
        "`null` when nothing was scoreable, never `0.0`, because zero would assert that " <>
        "agents searched and opened nothing when the truth is that this instrument could " <>
        "not see. That nil-for-n/a is THIS field's alone: `search_follow_through` is " <>
        "non-null and reports `0.0` on a day with no qualifying searches, which is an " <>
        "n/a too — read it beside `searches`. Measured live for 2026-08-19..29: 10.8% " <>
        "blended (185/1,708) against 38.0% scored, because 72% of that blended " <>
        "denominator (1,234/1,708) was recall-hook traffic at 3.3%; the window's 486 " <>
        "smoke-test calls are in neither figure. This is spelled out because leaving " <>
        "the division to the caller already produced one wrong published conclusion, " <>
        "with both input columns documented at the time.\n\n" <>
        "COMPARE ROWS ONLY WITHIN A `metric_version`. Every row carries the version of the " <>
        "definition set that produced it. Three changes have already altered what a figure " <>
        "here MEANS — `searched` went from search calls to surfaced results, infrastructure " <>
        "traffic began being excluded, and the disposition trio was rescoped — each " <>
        "forward-looking and each previously leaving no mark on the row, so a series read " <>
        "across one of those boundaries compares definitions rather than days. `0` means " <>
        "the row predates the stamp and its definitions are unknown.",
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

  operation(:search_coverage,
    summary: "Declared telemetry coverage for search_events",
    description:
      "Which DECLARED columns of `search_events` are actually being filled, per search " <>
        "surface, over a bounded window. A coverage PROFILE per `tool` names the columns a " <>
        "correctly-instrumented caller is expected to supply; this reports how many rows " <>
        "are missing each one. Role: orchestrator+.\n\n" <>
        "WHY A DECLARATION AND NOT A QUERY — `search_events` shipped correct and nearly " <>
        "blind: 2 of its first 133 rows carried any `client_*` context, discoverable only " <>
        "by an audit nobody was scheduled to run. A declared profile reports a surface that " <>
        "emits NOTHING (`rows: 0`), which no audit over existing rows can do.\n\n" <>
        "WHAT IT CANNOT PROVE — that a PRESENT column is a CORRECT one. `client_kind` is " <>
        "the worked example: one MCP process serves a session and every agent it " <>
        "dispatches with an environment frozen at spawn, so it labels every search `main`. " <>
        "Such a row is 100% covered here and still wrong about the only thing that column " <>
        "exists to say. It also cannot see a search path that records NO row at all; the " <>
        "`unprofiled` bucket is the nearest guard, and it only catches a tool that DID " <>
        "write.\n\n" <>
        "POPULATIONS, NOT ONE DENOMINATOR — each column names the rows that COULD have " <>
        "carried it, reported as `scope`/`population` beside every count. `all` is every " <>
        "row; `ran` excludes `outcome=rejected` (a rejected call never ran, so it has no " <>
        "`mode_used` and no `duration_ms` by construction); `agent` is rows carrying a " <>
        "`client_kind` or `client_session_id`, i.e. rows that really came through the MCP " <>
        "client — the recall hook and smoke tests call the API directly and can never " <>
        "supply `client_*`, so scoring them would measure loopctl's own automation. " <>
        "`share_missing` is `null`, never `0.0`, on an empty population.\n\n" <>
        "CLIENT_CONTEXT — the `agent` denominator is built from two of the columns it " <>
        "scores, so a client that sends NOTHING empties it and leaves every `client_*` " <>
        "line reading a clean 0/0. Each profile therefore also carries `client_context`, " <>
        "scored over `all`, whose `missing` is the rows that carried NO client context at " <>
        "all — that is where a fleet gone blind reports itself. A high share on " <>
        "`memory_recall` is the recall hook and expected; a high share on " <>
        "`knowledge_search` is not.\n\n" <>
        "REQUIRED vs ENRICHABLE — `required` is what a client or the server can fill at " <>
        "record time, so a miss is a defect. `enrichable` (`client_model`, `client_effort`, " <>
        "`agent_id`) is what no client can send: the first two do not exist in the MCP " <>
        "server's spawn environment and are filled offline by " <>
        "`mix loopctl.enrich_search_events`, and `agent_id` is server-derived from a key " <>
        "that may own no agent. Enrichment runs on a schedule, so a window ending near now " <>
        "measures its LAG — read a recent enrichable share as a floor.\n\n" <>
        "UNPROFILED — every `tool` value with rows and no declared profile is listed with " <>
        "its row count, `null` included. `rows_total` counts the whole window, so " <>
        "`rows_total` minus the sum of profile `rows` is exactly the unprofiled traffic; a " <>
        "new surface cannot be silently dropped from the accounting.",
    parameters: [
      days: [
        in: :query,
        type: :integer,
        description:
          "Window length in days back from `to` (default 30, max #{SearchEventCoverage.max_window_days()}). " <>
            "Clamped, never rejected.",
        required: false
      ],
      to: [
        in: :query,
        type: :string,
        description:
          "ISO8601 date or datetime, exclusive upper bound (default now). A bare date is " <>
            "read at 00:00:00Z. The window is [from, to). REJECTED with 400 when it cannot " <>
            "be parsed — never silently replaced with now.",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Search event coverage", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      400 => {"Invalid to", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"Database unavailable — retryable; see Retry-After header", "application/json",
         Schemas.ErrorResponse},
      504 =>
        {"Database statement timeout (code db_statement_timeout) — the coverage scan " <>
           "exceeded its statement timeout; narrow `days`", "application/json",
         Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/search-coverage"
  def search_coverage(conn, params) do
    with :ok <- validate_to(params["to"]) do
      tenant_id = conn.assigns.current_api_key.tenant_id
      {from, to} = coverage_window(params)

      json(conn, SearchEventCoverage.report(tenant_id, from, to))
    end
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
      400 => {"Invalid since", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/curation-log"
  def curation_log(conn, params) do
    with :ok <- validate_since(params["since"]) do
      tenant_id = conn.assigns.current_api_key.tenant_id

      opts =
        []
        |> put_limit(params["limit"], 50, 500)
        |> put_offset(params["offset"])
        |> maybe_put(:kind, params["kind"])
        |> maybe_put(:since, parse_since(params["since"]))

      json(conn, KbCuration.list(tenant_id, opts))
    end
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

  # Plug parses `?since[]=x` into a LIST and `?since[a]=x` into a MAP, so without this the
  # clauses above raise FunctionClauseError on a well-formed request and `action_fallback`,
  # which only handles RETURNED errors, lets it out as a 500.
  defp parse_since(_), do: nil

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
  defp validate_access_type(value) when value in @selectable_access_types, do: :ok

  defp validate_access_type(value) when is_binary(value) do
    {:error, :bad_request,
     "Invalid access_type #{inspect(value)}. Valid values: #{Enum.join(@selectable_access_types, ", ")}"}
  end

  defp validate_access_type(_value),
    do: {:error, :bad_request, "Invalid access_type: expected a string"}

  # REJECT an unparseable `to` rather than substituting `now`, for the reason above: the
  # window silently became "the last N days ending now" while the operator believed they had
  # asked about a historical week, and `window` in the body was the only thing that said so.
  # Reject-don't-ignore, the rule this controller already applies to `access_type`: a
  # PRESENT-but-unparseable bound is a 400, never a silent fall back to the default window.
  # `since` runs the same clauses as `to` because the wrong answer is worse there —
  # `maybe_put/3` DROPS the key, so the caller gets the most recent page presented as the
  # window it asked for, rather than an error.
  defp validate_to(value), do: validate_bound("to", value)
  defp validate_since(value), do: validate_bound("since", value)

  defp validate_bound(_name, nil), do: :ok
  defp validate_bound(_name, ""), do: :ok

  defp validate_bound(name, value) when is_binary(value) do
    case parse_since(value) do
      nil ->
        {:error, :bad_request,
         "Invalid #{name} #{inspect(value)}. Expected an ISO8601 date or datetime."}

      _ ->
        :ok
    end
  end

  defp validate_bound(name, _value),
    do: {:error, :bad_request, "Invalid #{name}: expected a string"}

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

  # CLAMPED here, so `SearchEventCoverage.report/3`'s ArgumentError stays a programming
  # error rather than a 500 a caller can trigger with a query string. `from` is floored at
  # `history_starts/0`: a window opening before the table existed is not a smaller sample.
  defp coverage_window(params) do
    to =
      case parse_since(params["to"]) do
        %DateTime{} = dt -> dt
        # `parse_since/1` accepts a bare ISO8601 DATE, which is a reasonable thing to send
        # at an "exclusive upper bound". Read it at the start of that UTC day rather than
        # letting the catch-all below answer for `now` instead.
        %Date{} = d -> DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC")
        _ -> DateTime.utc_now()
      end

    days = parse_int(params["days"], 30) |> max(1) |> min(SearchEventCoverage.max_window_days())
    from = DateTime.add(to, -days * 86_400, :second)
    floor_at = SearchEventCoverage.history_starts()

    from = if DateTime.compare(from, floor_at) == :lt, do: floor_at, else: from

    # A `to` at or before the floor would leave an empty/inverted window. Report the first
    # instant instead of raising: an operator asking about pre-history gets an honest
    # all-zero window, not a 500.
    to = if DateTime.compare(to, from) != :gt, do: DateTime.add(from, 1, :second), else: to

    {from, to}
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
