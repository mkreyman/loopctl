defmodule Loopctl.TelemetryEvents do
  @moduledoc """
  Defines telemetry event names for key operations in loopctl.

  All application-level telemetry events are defined here as constants
  to prevent typos and enable grep-ability. Use `:telemetry.execute/3`
  with these event names and appropriate measurements/metadata.

  ## Event naming convention

  Events follow the pattern `[:loopctl, <domain>, <action>]`.

  ## Usage

      :telemetry.execute(
        Loopctl.TelemetryEvents.api_request_stop(),
        %{duration: duration},
        %{route: route, status: status, tenant_id: tenant_id}
      )
  """

  @doc "API request started"
  def api_request_start, do: [:loopctl, :api, :request, :start]

  @doc "API request completed"
  def api_request_stop, do: [:loopctl, :api, :request, :stop]

  @doc "API request raised an exception"
  def api_request_exception, do: [:loopctl, :api, :request, :exception]

  @doc "Story agent_status or verified_status changed"
  def story_status_changed, do: [:loopctl, :story, :status_changed]

  @doc "Webhook delivery attempted"
  def webhook_delivery_start, do: [:loopctl, :webhook, :delivery, :start]

  @doc "Webhook delivery completed"
  def webhook_delivery_stop, do: [:loopctl, :webhook, :delivery, :stop]

  @doc "Webhook delivery failed"
  def webhook_delivery_exception, do: [:loopctl, :webhook, :delivery, :exception]

  @doc "Audit log entry written"
  def audit_log_write, do: [:loopctl, :audit, :write]

  @doc """
  A vector-search read under-filled (US-27.6b): it returned fewer than the
  requested `k` candidates AND above-threshold (near) neighbors the inner ANN
  surfaced were hidden by the already-linked anti-join — `above_threshold >
  returned`. NOT fired for a genuinely-sparse region whose whole ANN pool is
  below the similarity threshold (correct emptiness, not recall loss, so
  `above_threshold == returned`). Emitted at most ONCE per request.

  ## Payload (id-only — NEVER a vector literal or article body, AC-27.6b.5)

    * `measurements`: `%{requested, returned, pool, ann_candidates,
      above_threshold, excluded_by_link}` where
        - `pool` = the REQUESTED over-fetch ceiling (`pool_size/2`).
        - `ann_candidates` = how many rows the inner ANN actually delivered —
          bounded by `LIMIT pool` AND, under HNSW, by `~ef_search` (~40), so it
          is typically `< pool`. A recall-BREADTH diagnostic, NOT a pool-full
          gate (an `ann_candidates >= pool` check is degenerate under HNSW).
        - `above_threshold` = how many of `ann_candidates` clear the similarity
          bar — the near neighbors that actually exist.
        - `excluded_by_link` = `above_threshold - returned` — the above-threshold
          neighbors the already-linked anti-join HID. Because the signal only
          fires when `returned < limit` (so the outer LIMIT never bound and every
          unlinked above-threshold candidate WAS returned), this is an
          UN-CONFLATED recall-loss count — purely anti-join drops, with the
          below-threshold (sparse) drops already excluded. No extra read is
          needed to disentangle the two.
    * `metadata`: `%{tenant_id, endpoint}` — `tenant_id` is an id, not content.

  Aggregated by US-27.15 metrics/alerting.
  """
  def vector_search_under_fill, do: [:loopctl, :knowledge, :vector_search, :under_fill]

  @doc """
  A mapped DB error was surfaced to a client (US-27.15). Emitted by
  `LoopctlWeb.DBErrorLogger.log/3` after it logs the sanitized structured line, so
  EVERY controller (both the FallbackController rescue path and the uncaught
  `DBErrorBackstop` path) feeds the same aggregate. This is the count source for the
  `db_statement_timeout` (57014) counter and its sibling serialization/deadlock/
  catch-all classes (separated by the `mapped_code` label).

  ## Payload (id-only — NEVER raw SQL, bound params, vector literals, or a PG message body)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{mapped_code, sqlstate, endpoint}` where
        - `mapped_code` is the `LoopctlWeb.DBError` class
          (`"db_statement_timeout"` / `"db_serialization_failure"` / `"db_deadlock"`
          / `"db_invalid_input"` / `"db_error"` / `"db_unavailable"`) — a BOUNDED set.
        - `sqlstate` is the 5-char SQLSTATE string (e.g. `"57014"`) or `"unknown"`.
        - `endpoint` is the matched Phoenix `Controller.action` atom (e.g.
          `:"Elixir.LoopctlWeb.KnowledgeSearchController.suggested_links"`) or
          `:unknown` — the BOUNDED controller/action dimension, NEVER the raw
          request path (which would carry unbounded ids).

  `sqlstate`/`endpoint` ride in metadata for log/trace correlation but the metric
  definitions in `Loopctl.Telemetry.ScaleMetrics` only tag the counter by
  `[:endpoint, :mapped_code]` (+ a cap-gated `:tenant_id`), keeping label
  cardinality bounded (AC-27.15.3). Aggregated by US-27.15 metrics/alerting.
  """
  def db_error, do: [:loopctl, :db, :error]

  @doc """
  Semantic search silently degraded so semantic ranking did NOT contribute (#297).

  Covers BOTH silent-degradation causes the issue conflated:

    * an embedding-generation FAILURE that forced a keyword-only fallback
      (`fallback: true` in the response meta), and
    * an embedding SUCCESS whose semantic ranking returned zero rows
      (`reason: "semantic_empty"`, a recall/HNSW problem, `fallback: false`).

  Fires once per degraded request. Turns a silent 200 into an alertable signal.

  ## Payload (id-only — NEVER the raw query text, an api key, or a provider body)

    * `measurements`: `%{count: 1, query_len, semantic_result_count}` where
        - `count` is a pure increment (the Prometheus counter's measurement).
        - `query_len` is `byte_size(query)` — the query LENGTH only, never its text.
        - `semantic_result_count` is how many rows the semantic half contributed
          (`0` for an embed failure or a `semantic_empty` recall miss).
    * `metadata`: `%{tenant_id, reason}` where `reason` is a BOUNDED, sanitized tag
      (`no_embedding_key` | `embedding_circuit_open` | `embedding_timeout` |
      `embedding_provider_error_<status>` | `embedding_request_failed` |
      `embedding_crash` | `embedding_error` | `semantic_empty`) — sanitized through
      `Loopctl.Llm.ProviderError.sanitize/1`, so no key/body ever reaches the label.

  Aggregated by `Loopctl.Telemetry.ScaleMetrics` as a counter tagged by `reason`
  ONLY (no `tenant_id` label — keeps cardinality bounded to the fixed reason set).
  """
  def knowledge_semantic_fallback, do: [:loopctl, :knowledge, :semantic_fallback]

  @doc "Returns all defined event names for attachment"
  def all_events do
    [
      api_request_start(),
      api_request_stop(),
      api_request_exception(),
      story_status_changed(),
      webhook_delivery_start(),
      webhook_delivery_stop(),
      webhook_delivery_exception(),
      audit_log_write(),
      vector_search_under_fill(),
      db_error(),
      knowledge_semantic_fallback()
    ]
  end
end
