defmodule LoopctlWeb.KnowledgeSearchController do
  @moduledoc """
  Controller for the unified knowledge search endpoint.

  - `GET /api/v1/knowledge/search` -- search articles by keyword, semantic, or combined mode (agent+)

  Supports three search modes:

  - `keyword` -- full-text search using PostgreSQL ts_rank_cd
  - `semantic` -- vector similarity search via pgvector (embedding generated on-the-fly)
  - `combined` (default) -- weighted merge of keyword + semantic scores with graceful fallback

  Returns article metadata with a score and snippet (max 300 chars). Never returns the full body.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Egress
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleCursor
  alias LoopctlWeb.Helpers.ClientContext
  alias LoopctlWeb.Helpers.ProjectId
  alias LoopctlWeb.Helpers.SearchTelemetry
  alias LoopctlWeb.Helpers.TagMatch
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  @valid_modes ~w(keyword semantic combined)
  @valid_categories Ecto.Enum.values(Article, :category)

  operation(:search,
    summary: "Search knowledge articles",
    description:
      "Unified search endpoint supporting keyword, semantic, and combined modes. " <>
        "Returns article metadata with scores and snippets (max 300 chars). EVERY result " <>
        "now carries a `snippet` plus a `snippet_source`: `highlight` when the KEYWORD " <>
        "lane matched (a `ts_headline` fragment, marking matched terms with **term** and " <>
        "able to open mid-sentence), or `lead` when it did not (an extract of the " <>
        "article's own opening prose, skipping banners/headings/bullets). Previously the " <>
        "key was simply ABSENT on a semantic-only hit — so the results the query did not " <>
        "lexically match, which is exactly what the semantic lane exists to find, were " <>
        "the ones with nothing to explain them. Branch on `snippet_source` if you render " <>
        "the two differently; never treat its absence as an error (it is absent only " <>
        "when there is no snippet at all). " <>
        "No full body is returned. Combined mode is the default and falls back to " <>
        "keyword-only if embedding generation fails. " <>
        "`q` is optional when `tags` and/or `category` are supplied: in that " <>
        "**list mode** the endpoint returns the complete filtered set (no relevance " <>
        "ranking, score 0.0, no snippet) ordered by recency, fully reachable via " <>
        "`offset`/`limit` pagination over `meta.total_count`. " <>
        "**`meta.total_count` is mode-dependent** — `meta.total_count_scope` says " <>
        "exactly what it counts: `keyword_matches` (articles matching the " <>
        "stop-word-filtered Postgres tsquery — a pure stop-word query like 'the' " <>
        "matches almost nothing), `ranked_corpus` (semantic ranks all EMBEDDED " <>
        "published articles, so the count is the size of that embedded set — not a " <>
        "match count, and <= the total published count), `merged_candidates` " <>
        "(combined mode: the deduped UNION of a keyword and a semantic sub-search, " <>
        "each capped at 100, so up to ~200), or `filtered_set` " <>
        "(list mode: the complete filtered set). Do NOT use a relevance-mode " <>
        "`total_count` to size the corpus — use list mode or `GET /knowledge/stats`. " <>
        "Role: agent+.",
    parameters: [
      q: [
        in: :query,
        type: :string,
        description:
          "Search query (max 500 characters). Optional when tags/category are supplied.",
        required: false
      ],
      mode: [
        in: :query,
        type: :string,
        description: "Search mode: keyword, semantic, or combined (default: combined)",
        required: false
      ],
      format: [
        in: :query,
        type: :string,
        description:
          "Response shape: results (default, ranked results + snippets), stubs (capped " <>
            "stubs with hub enrichment, for surveying a topic without pulling bodies), or " <>
            "bodies (full bodies + linked references). stubs and bodies require a query " <>
            "and do not support cursor pagination. An unknown value is a 400.",
        required: false
      ],
      project_id: [
        in: :query,
        type: :string,
        description: "Filter by project: UUID, slug, or repo directory name",
        required: false
      ],
      category: [
        in: :query,
        type: :string,
        description: "Filter by category",
        required: false
      ],
      tags: [
        in: :query,
        type: :string,
        description: "Comma-separated tags to filter by (match mode set by `match`)",
        required: false
      ],
      match: [
        in: :query,
        type: :string,
        description: "Tag match mode: any (default, OR) or all (AND — carries every listed tag)",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max results to return (default 10). The cap is mode-dependent; a limit " <>
            "above it is clamped (never rejected) and the effective value is returned " <>
            "in `meta.limit`. **List mode** (no `q`, just `tags`/`category`) is " <>
            "exhaustive enumeration: max 1000, paginate the complete filtered set via " <>
            "`offset`. **Relevance modes** (keyword / semantic / combined) return a " <>
            "ranked top-N: max 100 (drop `q` for full enumeration).",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Results to skip for pagination (default 0)",
        required: false
      ],
      cursor: [
        in: :query,
        type: :string,
        description:
          "Opaque KEYSET cursor for drift-free list enumeration (list mode only). " <>
            "To use cursor pagination, pass an empty string (`cursor=`) on the FIRST request " <>
            "to opt into the keyset path (which orders by `inserted_at ASC, id ASC`); then " <>
            "follow `meta.next_cursor` verbatim on subsequent requests. Omitting the `cursor` " <>
            "parameter entirely uses the legacy offset path (orders by `updated_at DESC`), " <>
            "which does not emit `next_cursor`. Do not mix the two paths mid-enumeration, " <>
            "as the sort order differs. The cursor is integrity-protected and tenant-bound — " <>
            "a tampered/forged cursor is rejected with 400. Not valid with `q` (relevance " <>
            "modes return a ranked top-N, not a walk).",
        required: false
      ],
      include_body: [
        in: :query,
        type: :boolean,
        description:
          "Opt into article `body` on each keyset (`cursor`) list row (default false, " <>
            "**keyset-path-only** — not supported on offset paths). Body-less is the " <>
            "default to keep payloads small and avoid large chunked responses. When " <>
            "`include_body=true`, the response is trimmed by a 5MB serialized-body " <>
            "budget (same as offset full-content pages), so `count` may be less than " <>
            "`limit` if bodies are large. Honored ONLY for an effective `limit <= 25`; " <>
            "a request with `include_body=true` AND a requested `limit > 25` is rejected " <>
            "with 400 (never a silent oversized response). Only `true` enables it; any " <>
            "other value is false.",
        required: false
      ],
      "x-loopctl-client-context": [
        in: :header,
        type: :string,
        description:
          "OPTIONAL, analytics-only client context: base64 (unpadded) of a flat JSON " <>
            "object with any of `session_id`, `effort`, `model`, `host`, `repo`, " <>
            "`entrypoint`, `kind`, `version` — all strings, each truncated to 200 bytes. " <>
            "UNTRUSTED: it never authorizes anything (the api key remains the sole " <>
            "authority) and a malformed header is ignored, never an error.",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Search results", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Matching articles with scores and snippets"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               description:
                 "Offset/relevance modes return total_count/offset; the keyset list path " <>
                   "(`cursor`) instead returns the self-describing cursor contract: " <>
                   "next_cursor, has_more, limit, count, include_body.",
               properties: %{
                 outcome: LoopctlWeb.Outcome.schema(),
                 total_count: %OpenApiSpex.Schema{type: :integer},
                 total_count_scope: %OpenApiSpex.Schema{
                   type: :string,
                   enum: ["keyword_matches", "ranked_corpus", "merged_candidates", "filtered_set"],
                   description: "What total_count counts for this mode"
                 },
                 search_mode: %OpenApiSpex.Schema{
                   type: :string,
                   enum: [
                     "keyword",
                     "list",
                     "list_keyset",
                     "semantic_only",
                     "combined",
                     "keyword_only"
                   ],
                   description:
                     "The mode that actually ran (keyword_only = combined degraded to keyword; " <>
                       "list_keyset = the cursor enumeration path)"
                 },
                 limit: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "Effective per-page limit that actually ran"
                 },
                 offset: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "Offset path only; absent on the keyset (`cursor`) path"
                 },
                 pool_capped: %OpenApiSpex.Schema{
                   type: :boolean,
                   description:
                     "Relevance modes (semantic / combined): true when the ranked+filtered " <>
                       "results may be INCOMPLETE — either the corpus exceeds the relevance " <>
                       "pool cap, or a selective filter starved the pool below the cap. " <>
                       "`false` means this query's results are complete; `total_count` can " <>
                       "exceed what relevance pagination reaches, so on `pool_capped: true` " <>
                       "switch to list mode (`cursor`) for full enumeration."
                 },
                 ann_iterative_scan: %OpenApiSpex.Schema{
                   type: :string,
                   enum: ["off", "applied", "unavailable"],
                   description:
                     "Relevance modes (semantic / combined): whether the vector read ran " <>
                       "with pgvector's `hnsw.iterative_scan`. `off` = not enabled on this " <>
                       "instance (the default). `applied` = enabled and in force. " <>
                       "`unavailable` = enabled, but the read fell back to a single index " <>
                       "batch — the tenant filter is applied AFTER that batch, so results " <>
                       "may be INCOMPLETE. Treat `unavailable` like `pool_capped: true`: a " <>
                       "short result set is not evidence the corpus is empty. Read " <>
                       "`ann_iterative_scan_reason` for WHICH cause: an inconclusive " <>
                       "capability probe self-heals on the next conclusive one, while a " <>
                       "pgvector that does not support the setting stands until the " <>
                       "extension is upgraded."
                 },
                 ann_iterative_scan_reason: %OpenApiSpex.Schema{
                   type: :string,
                   description:
                     "Present ONLY alongside `ann_iterative_scan: \"unavailable\"`: a " <>
                       "non-sensitive explanation of the degraded vector read."
                 },
                 next_cursor: %OpenApiSpex.Schema{
                   type: :string,
                   nullable: true,
                   description:
                     "Keyset path: opaque cursor for the next page; null when the walk is " <>
                       "exhausted (the only exhaustion signal — there is no total_count)"
                 },
                 has_more: %OpenApiSpex.Schema{
                   type: :boolean,
                   description:
                     "Keyset path: whether another page exists (exactly next_cursor != null), " <>
                       "derived from the limit+1 peek, never a COUNT"
                 },
                 count: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "Keyset path: number of rows in THIS page (length of data)"
                 },
                 include_body: %OpenApiSpex.Schema{
                   type: :boolean,
                   description:
                     "Keyset path: whether each row carries the article body (honored only " <>
                       "for limit <= 25; see the include_body parameter)"
                 },
                 byte_truncated: %OpenApiSpex.Schema{
                   type: :boolean,
                   description:
                     "Keyset path (include_body only): true when the page was shortened by " <>
                       "the serialized-body byte budget. next_cursor is then recomputed from " <>
                       "the last kept row, so following it returns the dropped rows (no gap)."
                 },
                 fallback: %OpenApiSpex.Schema{
                   type: :boolean,
                   description:
                     "Relevance modes (combined / semantic): true when embedding generation " <>
                       "failed and the request silently degraded to keyword_only. Present only " <>
                       "when it degraded."
                 },
                 fallback_reason: %OpenApiSpex.Schema{
                   type: :string,
                   description:
                     "Present only alongside `fallback: true` (#297): a stable, non-sensitive " <>
                       "tag naming WHY semantic ranking was unavailable (never leaks an api key " <>
                       "or provider body). One of `no_embedding_key`, `embedding_circuit_open`, " <>
                       "`embedding_timeout`, `embedding_request_failed`, `embedding_crash`, " <>
                       "`embedding_error`, or `embedding_provider_error_<status>` (e.g. " <>
                       "`embedding_provider_error_401`, carrying only the HTTP status)."
                 },
                 semantic_result_count: %OpenApiSpex.Schema{
                   type: :integer,
                   description:
                     "Combined mode only (#297): rows the semantic half contributed. `0` with " <>
                       "no `fallback` means the embedding SUCCEEDED but ranking returned nothing " <>
                       "(a recall problem) — distinct from a keyword_only fallback."
                 },
                 remediation: %OpenApiSpex.Schema{
                   type: :object,
                   description:
                     "Present ONLY when `fallback_reason == \"no_embedding_key\"`: a " <>
                       "machine-readable, secret-free next-step so an agent can enable semantic " <>
                       "ranking WITHOUT a human. Names the `set_llm_config` MCP tool " <>
                       "(`mcp_tool`), the REST endpoint (`api`), the missing credential " <>
                       "(`missing: [\"embedding_api_key\"]`), a copy-paste `example`, and the " <>
                       "onboarding `docs`. Absent for transient/provider fallbacks (a key IS " <>
                       "configured there)."
                 }
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"Service unavailable", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             error: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 status: %OpenApiSpex.Schema{type: :integer},
                 message: %OpenApiSpex.Schema{type: :string}
               }
             }
           }
         }}
    }
  )

  @doc "GET /api/v1/knowledge/search"
  def search(conn, params) do
    # #658: RECORD THE REJECTION, wherever it was raised — a refused call never reaches
    # `maybe_record_search_access/5`, the only other writer. Wrapping the WHOLE action, not
    # a `with ... else`: an `else` sees only its own conditions, so the cursor rejections
    # and `:empty_query` (raised from the body) bypassed it. Every 4xx passes here.
    case do_search(conn, params) do
      {:error, _status, _msg} = error ->
        record_rejected_search(conn, params, error)
        error

      response ->
        response
    end
  end

  defp do_search(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    api_key = conn.assigns.current_api_key

    with {:ok, query_spec} <- resolve_query(params),
         {:ok, format} <- validate_format(params),
         {:ok, mode} <- validate_mode(params),
         :ok <- validate_search_limit(params, query_spec),
         :ok <- validate_include_body(params),
         {:ok, base_opts} <- build_opts(params) do
      opts =
        base_opts
        |> Keyword.put(:api_key_id, api_key.id)
        # WHO searched, on the SUCCESS path too. Recorded only for rejections, `agent_id`
        # made every named agent read as a 100% failure rate and filed all its successful
        # searches under NULL — a wrong answer, not a missing one.
        |> Keyword.put(:agent_id, Map.get(api_key, :agent_id))
        |> Keyword.put(:_started_at, System.monotonic_time(:millisecond))
        # The EFFECTIVE requested mode: `params["mode"]` is nil on the (very common)
        # no-mode request, and the recorder then fell back to the internal LANE label,
        # inventing `mode_requested` buckets no client can request.
        |> Keyword.put(:_mode_requested, params["mode"] || mode)
        # The RAW limit, before `maybe_add_limit/2` defaults and clamps it — `:limit` is
        # the effective value, and recording it as `limit_requested` reports a number the
        # client never sent.
        |> Keyword.put(:_limit_requested, raw_requested_limit(params))
        |> Keyword.put(:_client_context, ClientContext.attrs(conn))
        |> Keyword.merge(Visibility.scope_opts(conn))

      # US-27.9a: the presence of a `cursor` query param (even empty) opts the
      # LIST path into drift-free keyset pagination. Tenant scope is the
      # principal's (`tenant_id`), never the cursor; the cursor is
      # decoded+verified with the caller's tenant key.
      #
      #   - param ABSENT      → legacy offset list path (back-compat, unchanged)
      #   - param EMPTY       → keyset walk FROM THE START (first page, no seek)
      #   - param a token     → keyset seek AFTER the decoded position
      #   - param malformed   → 400 (not a string)
      case keyset_cursor(params) do
        :none ->
          run_in_format(conn, tenant_id, query_spec, mode, opts, format)

        :invalid ->
          {:error, :bad_request, "cursor parameter must be a string"}

        cursor_mode ->
          run_keyset(conn, tenant_id, query_spec, cursor_mode, opts)
      end
    end
  end

  # Best-effort attempt telemetry. Never raises and never alters the response.
  # Shared with the hybrid controller — see LoopctlWeb.Helpers.SearchTelemetry for why
  # this is not a private copy per endpoint.
  defp record_attempt(conn, attrs), do: SearchTelemetry.record_attempt(conn, attrs)

  defp record_rejected_search(conn, params, error) do
    record_attempt(conn, %{
      query: trim_query(params["q"]),
      # Derived from the request shape, as the SUCCESS path derives it: hardcoding
      # `knowledge_search` gave `knowledge_list` a 0% rejection rate and made this tool
      # absorb every enumeration failure.
      tool: request_tool(params),
      mode_requested: params["mode"],
      rejected?: true,
      rejection_reason: rejection_reason(error),
      result_count: 0
    })
  end

  # An embedding outage on the EXPLICIT semantic path returns a rendered 503 before any
  # search-path recorder runs, so the failure class this table exists to expose left no row
  # at all — while the same provider fault on combined is recorded as `degraded`.
  defp record_failed_search(conn, query_spec, mode, opts) do
    record_attempt(conn, %{
      query: search_text(query_spec),
      tool: "knowledge_search",
      mode_requested: Keyword.get(opts, :_mode_requested),
      mode_used: mode,
      degraded?: true,
      fallback_reason: "embedding_unavailable",
      result_count: 0
    })
  end

  defp search_text({:search, q}), do: q
  defp search_text(_list), do: nil

  defp request_tool(params) do
    if trim_query(params["q"]) == "" and filter_present?(params),
      do: "knowledge_list",
      else: "knowledge_search"
  end

  # A STABLE tag, not the prose message. Ordering is load-bearing: `invalid_cursor` means a
  # TAMPERED token, so every other 400 whose text merely MENTIONS a cursor — the
  # include_body misuse, the q+cursor conflict — is classified BEFORE it, or an operator
  # chases cursor tampering that is not happening. Both include_body 400s share one tag:
  # they are two halves of one client error.
  defp rejection_reason({:error, _status, msg}) when is_binary(msg) do
    cond do
      String.contains?(msg, "'q' is required") -> "missing_query"
      String.contains?(msg, "include_body") -> "invalid_include_body"
      String.contains?(msg, "only available for list enumeration") -> "cursor_with_query"
      String.contains?(msg, "cursor") -> "invalid_cursor"
      String.contains?(msg, "project_id") -> "invalid_project_id"
      true -> "bad_request"
    end
  end

  # ONE search command, three response shapes (#670 follow-up).
  #
  # `progressive_index/3` and `get_context/3` are not different searches. The first calls
  # `search_keyword/3` and then caps-and-stubs; the second is the combined search returning
  # full bodies. Exposed as separate TOOLS they asked an agent to decide, per query, which
  # door to knock on — and that decision is unobservable, so it confounds every measurement
  # of the ranking behind them: you cannot tell an algorithm's effect from an agent's choice
  # of entrypoint. A parameter is a variable we control; a tool choice is a confounder we do
  # not.
  #
  # The existing tools/endpoints stay and are NOT retired — they now share this path.
  #
  #   results (default) — ranked results + snippets. Unchanged; the only shape that
  #                       supports keyset pagination, which is why the dispatch sits on the
  #                       `:none` cursor branch.
  #   stubs             — capped stubs with hub enrichment, for surveying a broad topic
  #                       without pulling bodies into context.
  #   bodies            — full bodies plus linked references, for one deep read.
  @formats ~w(results stubs bodies)

  defp validate_format(params) do
    case params["format"] do
      nil -> {:ok, "results"}
      value when value in @formats -> {:ok, value}
      _other -> {:error, :bad_request, "format must be one of: #{Enum.join(@formats, ", ")}"}
    end
  end

  defp run_in_format(conn, tenant_id, query_spec, mode, opts, "results"),
    do: run_search(conn, tenant_id, query_spec, mode, opts)

  defp run_in_format(conn, tenant_id, query_spec, _mode, opts, format) do
    case search_text(query_spec) do
      nil ->
        # The shaped formats are relevance shapes; there is no stub or body rendering of an
        # enumeration page, and silently returning the ranked shape instead would answer a
        # different question than the one asked.
        {:error, :bad_request, "format=#{format} requires a query"}

      query ->
        shaped_result(conn, tenant_id, query, opts, format)
    end
  end

  defp shaped_result(conn, tenant_id, query, opts, "stubs") do
    case Knowledge.progressive_index(tenant_id, query, opts) do
      {:ok, result} ->
        record_shaped_attempt(conn, query, opts, "progressive", length(result.stubs))
        json(conn, LoopctlWeb.KnowledgeProgressiveJSON.index(result))

      {:error, :empty_query} ->
        {:error, :bad_request, "Query parameter 'q' is required and cannot be empty"}

      {:error, :bad_request, msg} ->
        {:error, :bad_request, msg}
    end
  end

  defp shaped_result(conn, tenant_id, query, opts, "bodies") do
    case Knowledge.get_context(tenant_id, query, opts) do
      {:ok, result} ->
        record_shaped_attempt(conn, query, opts, "context", length(result.results))
        json(conn, LoopctlWeb.KnowledgeContextJSON.context(result))

      {:error, :empty_query} ->
        {:error, :bad_request, "Query parameter 'q' is required and cannot be empty"}
    end
  end

  # Attributed to `knowledge_search`, because that is the tool the caller used — the shape is
  # a PARAMETER of this command, not a different surface. Recording it as the sibling tool
  # would split one command's traffic across three names and undo the very comparability the
  # parameter exists to create. The shape rides in `mode_used`.
  defp record_shaped_attempt(conn, query, opts, mode, result_count) do
    SearchTelemetry.record_attempt(conn, %{
      query: query,
      tool: "knowledge_search",
      mode_requested: Keyword.get(opts, :_mode_requested),
      mode_used: mode,
      result_count: result_count,
      duration_ms: shaped_duration_ms(opts)
    })
  end

  defp shaped_duration_ms(opts) do
    case Keyword.get(opts, :_started_at) do
      started when is_integer(started) -> System.monotonic_time(:millisecond) - started
      _ -> nil
    end
  end

  defp run_search(conn, tenant_id, query_spec, mode, opts) do
    case execute_search(tenant_id, query_spec, mode, opts) do
      {:ok, result} ->
        json(conn, LoopctlWeb.KnowledgeSearchJSON.search(result, mode))

      {:error, :embedding_unavailable} ->
        record_failed_search(conn, query_spec, mode, opts)

        conn
        |> put_status(503)
        |> json(%{error: %{status: 503, message: "Embedding service unavailable"}})

      {:error, :empty_query} ->
        {:error, :bad_request, "Query parameter 'q' is required and cannot be empty"}

      {:error, :bad_request, msg} ->
        {:error, :bad_request, msg}
    end
  end

  # The keyset cursor is a LIST-mode (enumeration) concept; pairing it with a
  # relevance `q` is a client error (the relevance modes return a ranked top-N,
  # not a stable-tuple walk), so reject rather than silently ignore one of them.
  defp run_keyset(_conn, _tenant_id, {:search, _q}, _cursor_mode, _opts) do
    {:error, :bad_request,
     "cursor pagination is only available for list enumeration; drop 'q' " <>
       "(supply 'tags' and/or 'category' to enumerate the filtered set)"}
  end

  # Empty cursor → start the walk from the beginning (no seek position).
  defp run_keyset(conn, tenant_id, :list, :start, opts) do
    render_keyset(conn, tenant_id, opts, nil)
  end

  # Token cursor → defensive decode (garbage / bit-flipped / wrong-tenant → 400,
  # never a 500 and never a silent reset to page 1, AC-27.9a.4). Tenant scope is
  # ALWAYS the principal's `tenant_id`; the cursor only carries a position.
  defp run_keyset(conn, tenant_id, :list, {:cursor, raw}, opts) do
    case ArticleCursor.decode(tenant_id, raw) do
      {:ok, position} ->
        render_keyset(conn, tenant_id, opts, position)

      {:error, :invalid} ->
        {:error, :bad_request,
         "Invalid or tampered cursor. Send an empty 'cursor' to start from the " <>
           "beginning, then follow 'meta.next_cursor' verbatim to paginate."}
    end
  end

  defp render_keyset(conn, tenant_id, opts, position) do
    {:ok, result} = Knowledge.list_keyset(tenant_id, Keyword.put(opts, :cursor, position))

    encoded =
      case result.next_cursor do
        nil -> nil
        cursor -> ArticleCursor.encode(tenant_id, cursor)
      end

    json(conn, LoopctlWeb.KnowledgeSearchJSON.keyset(%{result | next_cursor: encoded}))
  end

  # Classifies the `cursor` query param: ABSENT → `:none` (legacy offset path);
  # PRESENT-but-empty → `:start` (keyset from the beginning); a non-empty string →
  # `{:cursor, raw}` (keyset seek); a non-string `cursor[]=` form → `:invalid` (400,
  # not a 500 and not a silent page-1 reset).
  defp keyset_cursor(params) when is_map(params) do
    case Map.fetch(params, "cursor") do
      :error -> :none
      {:ok, ""} -> :start
      {:ok, raw} when is_binary(raw) -> {:cursor, raw}
      {:ok, _non_string} -> :invalid
    end
  end

  # Resolves the query parameter into either a relevance search (`{:search, q}`)
  # or a query-less enumeration (`:list`). `q` is optional only when a `tags`
  # and/or `category` filter is supplied, otherwise it is required.
  defp resolve_query(params) do
    trimmed = params |> Map.get("q") |> trim_query()

    cond do
      trimmed != "" and String.length(trimmed) > 500 ->
        {:error, :bad_request, "Query parameter 'q' exceeds maximum length of 500 characters"}

      trimmed != "" ->
        {:ok, {:search, trimmed}}

      filter_present?(params) ->
        {:ok, :list}

      true ->
        {:error, :bad_request,
         "Query parameter 'q' is required (or supply 'tags' and/or 'category' " <>
           "to enumerate the full filtered set)"}
    end
  end

  defp trim_query(q) when is_binary(q), do: String.trim(q)
  defp trim_query(_), do: ""

  defp filter_present?(params) do
    present?(params["tags"]) or present?(params["category"])
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp validate_mode(%{"mode" => mode}) when mode in @valid_modes, do: {:ok, mode}

  defp validate_mode(%{"mode" => _invalid}) do
    {:error, :bad_request, "Invalid search mode. Valid modes: keyword, semantic, combined"}
  end

  defp validate_mode(_), do: {:ok, "combined"}

  defp build_opts(params) do
    with :ok <- ProjectId.validate(params["project_id"]),
         {:ok, category} <- validate_category(params["category"]),
         {:ok, match} <- TagMatch.parse(params) do
      opts =
        []
        |> maybe_add_opt(:project_id, params["project_id"])
        |> maybe_add_opt(:category, category)
        |> maybe_add_tags(params["tags"])
        |> Keyword.put(:match, match)
        |> maybe_add_limit(params["limit"])
        |> maybe_add_offset(params["offset"])
        |> maybe_add_include_body(params["include_body"])

      {:ok, opts}
    end
  end

  # Threads the parsed `:include_body` flag into opts (US-27.10). Only added when
  # true; absent/false leaves the body-less default in place. `validate_include_body/1`
  # has already enforced the page-size bound before we get here.
  defp maybe_add_include_body(opts, raw) do
    if parse_include_body(raw), do: [{:include_body, true} | opts], else: opts
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: [{key, value} | opts]

  # Reject an unknown OR non-category-but-existing atom (e.g. "published") with a
  # 400, mirroring the index controller. Without this, list mode would either
  # crash on a CastError or silently drop the filter and return the whole catalog.
  defp validate_category(nil), do: {:ok, nil}
  defp validate_category(""), do: {:ok, nil}

  defp validate_category(category) when is_binary(category) do
    atom = String.to_existing_atom(category)
    if atom in @valid_categories, do: {:ok, atom}, else: invalid_category()
  rescue
    ArgumentError -> invalid_category()
  end

  defp invalid_category do
    valid = Enum.map_join(@valid_categories, ", ", &to_string/1)
    {:error, :bad_request, "Invalid category. Valid categories: #{valid}"}
  end

  defp maybe_add_tags(opts, nil), do: opts
  defp maybe_add_tags(opts, ""), do: opts

  defp maybe_add_tags(opts, tags_str) do
    tags =
      tags_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if tags == [], do: opts, else: [{:tags, tags} | opts]
  end

  # A requested `limit` is never rejected — it is CLAMPED downstream and the
  # effective value is reported in `meta.limit`, so a caller is never blocked.
  # List mode clamps to the shared max page size (via `maybe_add_limit/2`);
  # relevance modes clamp to the ranked-pool cap in the context. Full enumeration
  # of a relevance query is reached by dropping `q` (list mode + keyset cursor).
  defp validate_search_limit(_params, _query_spec), do: :ok

  # US-27.10: `include_body=true` is a KEYSET-path-only opt-in to full bodies, and
  # only for a requested `limit <= max_include_body_page/0`. Two 400s are enforced
  # here in the `with`, BEFORE the query runs (`include_body=false`/absent is the
  # unbounded body-less default, #166):
  #
  #   1. NO cursor param (offset/relevance path) → `include_body` is meaningless
  #      there (it's silently ignored, undermining the self-describing contract),
  #      so reject — mirroring the existing cursor+`q` rejection.
  #   2. requested `limit > max` → reject so a caller can never trigger an oversized
  #      chunked response by requesting bodies for a large page. The bound is on the
  #      REQUESTED limit (raw param), not the rows returned — so `limit=26 +
  #      include_body=true` is a 400 even if the page would return fewer.
  defp validate_include_body(params) do
    if parse_include_body(params["include_body"]) do
      validate_include_body_context(params)
    else
      :ok
    end
  end

  defp validate_include_body_context(params) do
    max = Knowledge.max_include_body_page()

    cond do
      keyset_cursor(params) == :none ->
        {:error, :bad_request,
         "include_body is only available for the cursor enumeration path; supply an " <>
           "empty 'cursor' to start a keyset walk (offset and relevance paths don't " <>
           "support bodies)."}

      over_include_body_limit?(params, max) ->
        {:ok, limit} = requested_limit(params["limit"])

        {:error, :bad_request,
         "include_body=true is only honored for limit <= #{max} (to avoid oversized " <>
           "responses); requested limit #{limit} exceeds it. Drop include_body for a " <>
           "body-less page, or lower the limit."}

      true ->
        :ok
    end
  end

  defp over_include_body_limit?(params, max) do
    match?({:ok, limit} when limit > max, requested_limit(params["limit"]))
  end

  # Parses the requested `limit` param for the include_body bound check. Returns
  # `{:ok, int}` only for a clean non-negative integer; anything else is `:none`
  # (no requested limit to bound — the default page size applies and is within the
  # include_body cap).
  #
  # KEEP IN SYNC with `maybe_add_limit/2`: both parse the same raw `limit` param
  # independently (this for the ≤25 include_body bound, that for the opt fed to the
  # query). A future change to how `limit` is parsed must touch both, or the bound
  # could be bypassed (e.g. accepting "26abc" here as :none while the query clamps).
  defp requested_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :none
    end
  end

  defp requested_limit(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp requested_limit(_), do: :none

  defp raw_requested_limit(params) do
    case requested_limit(params["limit"]) do
      {:ok, limit} -> limit
      :none -> nil
    end
  end

  # `include_body` is strictly opt-in: only the literal string "true" (or boolean
  # true) enables it; anything else — including "1", "yes", or a malformed value —
  # is false. This keeps the safe body-less default (#166) unless explicitly asked.
  defp parse_include_body("true"), do: true
  defp parse_include_body(true), do: true
  defp parse_include_body(_), do: false

  # `limit` is honored up to the relevant cap; over-cap requests are rejected
  # with 400 by `validate_search_limit/2` (in `search/2`) rather than silently
  # clamped here. The `min/2` is a safety net for direct/list callers.
  #
  # KEEP IN SYNC with `requested_limit/1`, which parses this same raw `limit` param
  # to enforce the ≤25 include_body bound (`validate_include_body/1`). If the two
  # diverge on what counts as a valid limit, the bound could be bypassed.
  defp maybe_add_limit(opts, nil), do: [{:limit, 10} | opts]

  defp maybe_add_limit(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:limit, int |> max(1) |> min(Knowledge.max_page_size())} | opts]
      _ -> [{:limit, 10} | opts]
    end
  end

  defp maybe_add_limit(opts, value) when is_integer(value) do
    [{:limit, value |> max(1) |> min(Knowledge.max_page_size())} | opts]
  end

  defp maybe_add_limit(opts, _), do: [{:limit, 10} | opts]

  # Upper bound on `offset` so an absurd value (e.g. `offset=99999999999999999999`) is
  # clamped rather than reaching the DB and raising a Postgres bigint-range error as a 500.
  # Well above any legitimate offset page; deep enumeration uses the keyset (`cursor`) path.
  @max_offset 1_000_000

  defp maybe_add_offset(opts, nil), do: [{:offset, 0} | opts]

  defp maybe_add_offset(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:offset, clamp_offset(int)} | opts]
      _ -> [{:offset, 0} | opts]
    end
  end

  defp maybe_add_offset(opts, value) when is_integer(value) do
    [{:offset, clamp_offset(value)} | opts]
  end

  defp maybe_add_offset(opts, _), do: [{:offset, 0} | opts]

  defp clamp_offset(value), do: value |> max(0) |> min(@max_offset)

  # List mode: query-less enumeration of the filtered set, regardless of `mode`.
  defp execute_search(tenant_id, :list, _mode, opts) do
    Knowledge.list_filtered(tenant_id, opts)
  end

  defp execute_search(tenant_id, {:search, q}, "keyword", opts) do
    Knowledge.search_keyword(tenant_id, q, opts)
  end

  defp execute_search(tenant_id, {:search, q}, "semantic", opts) do
    # `search_semantic/3` holds only the embedding, so it records `query: nil` unless the
    # request's own text rides along. Without this every explicit semantic search landed in
    # the "no query" bucket that exists to mean ENUMERATION.
    opts = Keyword.put(opts, :_query_string, q)

    # US-41.4 (AC-41.4.2): thread the request's `:project_id` filter into the egress
    # scope, so a PROJECT-only `local_only` marking is enforced on the explicit
    # semantic path exactly as it is on combined.
    case Knowledge.generate_embedding(tenant_id, q, project_id: opts[:project_id]) do
      {:ok, embedding} ->
        # US-37.5: an explicit semantic search whose heavy read is SHED (tenant over
        # its per-tenant in-flight HeavyRead cap) degrades to keyword-only — same
        # graceful fallback as a keyless tenant — instead of a 429, so a neighbour's
        # burst can't hard-fail this tenant's search.
        case Knowledge.search_semantic(tenant_id, embedding, opts) do
          # US-41.1 AC-41.1.8 joins `:semantic_recall_unavailable` to the same
          # labelled keyword degrade: the query vector cannot be compared against the
          # corpus this tenant actually has (non-1536 tenant pre-cutover, or a model
          # change mid-flight), so the response says so instead of 500-ing on a raw
          # pgvector dimension error or returning a bare empty list.
          {:error, reason} when reason in [:heavy_read_overloaded, :semantic_recall_unavailable] ->
            semantic_keyword_fallback(tenant_id, q, opts, reason)

          result ->
            result
        end

      {:error, :no_api_key} ->
        # Mandatory BYO (review #8): a keyless tenant's explicit semantic search must
        # NOT 503. Degrade to keyword-only with `fallback: true`, mirroring combined.
        semantic_keyword_fallback(tenant_id, q, opts, :no_api_key)

      # US-41.4 (AC-41.4.6/.7): an EGRESS refusal is a permanent LOCAL configuration
      # decision, not a provider outage. A bare 503 mislabels it, names neither the
      # reason nor the offending endpoint, and denies the interactive path the
      # keyword degrade the combined path already performs. Degrade identically.
      {:error, {tag, _details}} when tag in [:egress_blocked, :pin_stale, :egress_unavailable] ->
        semantic_keyword_fallback(tenant_id, q, opts, tag)

      {:error, _} ->
        {:error, :embedding_unavailable}
    end
  end

  defp execute_search(tenant_id, {:search, q}, "combined", opts) do
    Knowledge.search_combined(tenant_id, q, opts)
  end

  # Keyword-only degrade for a keyless-tenant semantic request: same shape as the
  # combined-search fallback so clients can detect it via `meta.fallback` /
  # `meta.search_mode`. Records the reason (#297) so this path is as diagnosable as
  # combined — `record_semantic_fallback/3` maps it to a stable, non-sensitive tag
  # and emits telemetry + a warning log.
  defp semantic_keyword_fallback(tenant_id, q, opts, reason) do
    fallback_reason = Knowledge.record_semantic_fallback(tenant_id, reason, q)

    # The keyword lane now runs as a DEGRADED attempt, and the row has to say so: filed as
    # `zero_results` a provider outage reads as a corpus gap (`SearchEvent`: degradation
    # outranks emptiness).
    degraded_opts =
      Keyword.merge(opts,
        _degraded: true,
        _fallback_reason: fallback_reason,
        _mode_requested: "semantic"
      )

    case Knowledge.search_keyword(tenant_id, q, degraded_opts) do
      {:ok, %{meta: meta} = result} ->
        {:ok,
         %{
           result
           | meta:
               meta
               |> Map.merge(%{
                 fallback: true,
                 search_mode: "keyword_only",
                 fallback_reason: fallback_reason
               })
               # AC-41.4.7: for an EGRESS refusal the meta must also name the
               # offending endpoint and carry the reserved `excluded_tiers` — the
               # SAME contract fragment the combined path emits, so the two cannot
               # drift. Omitted for non-egress reasons.
               |> Map.merge(Egress.degraded_contract_meta(tenant_id, fallback_reason))
         }}

      other ->
        other
    end
  end
end
