defmodule Loopctl.Knowledge.SearchEvent do
  @moduledoc """
  Schema for the `search_events` table — one immutable row per SEARCH ATTEMPT (#658).

  ## Why this exists alongside `ArticleAccessEvent`

  `ArticleAccessEvent` records one row per SURFACED RESULT. That is the right shape for
  "which articles do agents actually read", and the wrong shape for "which searches
  failed", because a search with no results surfaces nothing and therefore writes nothing.
  `Loopctl.Knowledge.maybe_record_search_access/5` makes that explicit — it returns `:ok`
  early when `results in [nil, []]`.

  The consequence, measured: the two failure modes that matter most were both invisible.
  A hand-mined catalogue of 6,457 Claude session transcripts across two machines found 86
  `knowledge_search` calls rejected before they ran (8% of every search made) and a silent
  degradation path where an embedding timeout returns HTTP 200 with an empty result array.
  Neither is recoverable from the database. An analysis that needs someone to grep six
  thousand transcripts is an analysis nobody runs twice.

  This table makes the ATTEMPT the unit of record, so a miss is a row.

  ## Outcomes

  - `"ok"` — results returned on the requested path
  - `"zero_results"` — ran normally, matched nothing. The signal the corpus or the query
    needs work, and the one thing the old schema could never express.
  - `"degraded"` — ran, but not on the requested path: semantic ranking was unavailable and
    it fell back to keyword-only. `fallback_reason` names why. A degraded search that also
    returned nothing is recorded as `"degraded"`, because the cause is the degradation and
    counting it as `zero_results` would blame the corpus for a provider outage.
  - `"rejected"` — never ran: a validation failure (a missing query, a malformed id).
    `rejection_reason` carries the code.

  ## Reading it back

  There is deliberately no API endpoint yet: this is an operator/analysis table, and the
  analysis that motivated it was run with psql against prod. The canonical queries are kept
  HERE, beside the schema, so the read path is discoverable from the thing it reads — a
  capture surface with no documented way to query it is how a table becomes write-only.

      -- Outcome mix, and the zero-result rate that was previously unknowable.
      SELECT outcome, count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
        FROM search_events
       WHERE tenant_id = $1 AND inserted_at > now() - interval '30 days'
       GROUP BY 1 ORDER BY 2 DESC;

      -- Query SHAPE against success. The single-token and machine-noise classes fall out.
      SELECT CASE WHEN query_terms IS NULL THEN 'no query'
                  WHEN query_terms = 1 THEN '1 token'
                  WHEN query_terms <= 3 THEN '2-3'
                  ELSE '4+' END AS shape,
             count(*), count(*) FILTER (WHERE outcome = 'zero_results') AS zero
        FROM search_events WHERE tenant_id = $1 GROUP BY 1 ORDER BY 1;

      -- WHO searches and who fails, once enriched. `client_host IS NOT NULL` is the
      -- filter that matters: rows without it never came through the MCP client at all
      -- (the recall hook and scripts/smoke.sh call the API directly), so including them
      -- measures this project's own automation rather than its agents.
      SELECT client_kind, client_repo, client_effort, count(*),
             count(*) FILTER (WHERE outcome IN ('zero_results','rejected')) AS bad
        FROM search_events
       WHERE tenant_id = $1 AND client_host IS NOT NULL
       GROUP BY 1,2,3 ORDER BY 4 DESC;

      -- Degradation, by cause.
      SELECT fallback_reason, count(*), count(*) FILTER (WHERE result_count = 0) AS empty
        FROM search_events WHERE degraded GROUP BY 1 ORDER BY 2 DESC;

      -- Follow-through: did the searcher OPEN anything? The 27:1 search-to-read ratio is
      -- the biggest number in this whole area, and this join is how to watch it move.
      SELECT count(*) AS searches,
             count(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM article_access_events a
                WHERE a.tenant_id = s.tenant_id
                  AND a.access_type IN ('get','context','drill')
                  AND a.accessed_at BETWEEN s.inserted_at AND s.inserted_at + interval '30 minutes'
             )) AS followed_through
        FROM search_events s
       WHERE s.tenant_id = $1 AND s.outcome = 'ok';

  THREE of the `client_*` columns cannot be filled by the client and are enriched offline
  from the session transcript, joined on `client_session_id`:

  - `client_model` and `client_effort` — neither variable exists in the environment the MCP
    server is spawned with (`CLAUDE_EFFORT` is set for Bash-tool invocations but not for the
    MCP server, so `client_effort` was permanently NULL until the enrichment filled it).
  - `client_kind` — the client reports the kind of the SESSION, not of the CALLER. One MCP
    process serves a session and every agent it dispatches, with an environment frozen at
    spawn, so it labels EVERY search `main`. Only the transcript can say whether a search
    came from the main session, a subagent, or a workflow agent.

  So do NOT read `client_kind` as caller-level truth on an un-enriched row: before the
  enrichment runs it means "some search from this session".

  That join is implemented — `mix loopctl.enrich_search_events`, see
  `Loopctl.Knowledge.SearchEventEnrichment` — and the monthly procedure that runs it and
  then runs the queries above is `docs/runbooks/search-events-analysis.md`.

  It is the ONE sanctioned write after insert, and it does not weaken "immutable" above:
  what is immutable is the ATTEMPT — what was asked, what came back, and when. The
  enrichment only FILLS the two columns whose value no client could ever have sent, never
  overwrites a value a client did send, and refines `client_kind` only from `child` to the
  sub-class the transcript proves. Any future writer here needs the same three properties.

  ## Recording is best-effort and MUST NOT fail a search

  A telemetry write that can break the read path is a worse defect than the blindness it
  cures, so the recorder swallows its own errors. The trade is deliberate: an occasional
  lost row is acceptable, a failed search is not.
  """
  use Loopctl.Schema
  import Ecto.Changeset

  @outcomes ~w(ok zero_results degraded rejected)

  schema "search_events" do
    field :tenant_id, :binary_id
    field :search_id, :binary_id
    field :api_key_id, :binary_id
    field :agent_id, :binary_id
    field :project_id, :binary_id
    field :story_id, :binary_id

    field :query, :string
    field :query_terms, :integer

    field :tool, :string
    field :mode_requested, :string
    field :mode_used, :string

    # The corpus slice actually queried. tenant_id says WHICH KB; these say which PART.
    field :filters, :map, default: %{}
    field :limit_requested, :integer
    field :offset_requested, :integer

    field :total_count, :integer
    field :top_result_id, :binary_id
    field :top_result_score, :float

    field :result_count, :integer, default: 0
    field :degraded, :boolean, default: false
    field :fallback_reason, :string
    field :ann_iterative_scan, :string
    field :duration_ms, :integer

    # Client-supplied context — UNTRUSTED, analytics only, never authorization. See the
    # migration for why none of it is derivable server-side.
    field :client_session_id, :string
    field :client_effort, :string
    field :client_model, :string
    field :client_host, :string
    field :client_repo, :string
    field :client_entrypoint, :string
    field :client_kind, :string
    field :client_version, :string

    field :outcome, :string
    field :rejection_reason, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(search_id api_key_id agent_id project_id story_id query query_terms tool
               mode_requested mode_used filters limit_requested offset_requested
               total_count top_result_id top_result_score result_count degraded
               fallback_reason ann_iterative_scan duration_ms outcome rejection_reason
               client_session_id client_effort client_model client_host client_repo
               client_entrypoint client_kind client_version)a

  @doc """
  Builds an insert changeset. `tenant_id` is set programmatically by the caller and is
  deliberately NOT castable (multi-tenancy rule 4).
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:outcome])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:result_count, greater_than_or_equal_to: 0)
  end

  @doc "The valid `outcome` values."
  def outcomes, do: @outcomes

  @doc """
  Derives the outcome from a search's shape.

  DEGRADATION OUTRANKS EMPTINESS. A degraded search that returned nothing is `"degraded"`,
  not `"zero_results"` — the cause is a provider failure, and filing it under
  `zero_results` would read as a corpus gap and send the next investigation after the
  wrong thing. That misattribution is exactly what cost this investigation its first hour.
  """
  def derive_outcome(%{rejected?: true}), do: "rejected"
  def derive_outcome(%{degraded?: true}), do: "degraded"
  def derive_outcome(%{result_count: 0}), do: "zero_results"
  def derive_outcome(_), do: "ok"

  @doc """
  Counts whitespace-separated terms in a query, for query-shape analysis.

  Returns nil for a nil/blank query (enumeration mode has none), so "no query" and
  "one-word query" stay distinguishable — they are different defects.
  """
  def term_count(nil), do: nil

  def term_count(query) when is_binary(query) do
    case String.split(query, ~r/\s+/, trim: true) do
      [] -> nil
      terms -> length(terms)
    end
  end

  def term_count(_), do: nil
end
