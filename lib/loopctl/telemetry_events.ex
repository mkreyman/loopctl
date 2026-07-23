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

  @doc """
  A hybrid-resolver (US-31.2, `Loopctl.Knowledge.hybrid_search/3`) provenance
  decision fired. Turns the two dimensions `maybe_record_search_access/5` structurally
  CANNOT observe — a MISS (empty result page — `article_access_events.article_id` is
  NOT NULL) and a keyless call (no `api_key_id` to attribute a DB row to) — into an
  always-emitted signal, so "curated vs retrieved" and "hit vs miss" stay observable
  per tenant even off the `article_access_events`/`RetrievalMetrics` path.

  Fires on EVERY `hybrid_search/3` call, regardless of result-page emptiness or
  `:api_key_id` presence.

  ## Payload (id/atom/bool only — NEVER article content or the query text)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{tenant_id, provenance, hit}` where `provenance` is `"curated"` |
      `"retrieved"` (a BOUNDED 2-value tag) and `hit` is `true`/`false` (the page was
      non-empty / empty).

  Aggregated by `Loopctl.Telemetry.ScaleMetrics` as a counter tagged by
  `[:provenance, :hit, :tenant_id]` (tenant cap-gated, same convention as the other
  scale counters).
  """
  def knowledge_hybrid_provenance, do: [:loopctl, :knowledge, :hybrid_provenance]

  @doc """
  A genuine LLM/embedding PROVIDER failure (a REAL 4xx/5xx/transport/timeout error
  returned by a provider call that WAS ACTUALLY ATTEMPTED — a key was configured and
  present). Introduced by US-34.3 (AC-34.3.3) as the provider-error-rate ScaleAlerts
  signal. Emitted via `Loopctl.Llm.record_provider_error/2` from TWO choke points,
  each the ONE call site for its provider: `Loopctl.Llm.Anthropic`'s shared HTTP
  client (`provider: "anthropic"` — every Anthropic call site, content extraction/
  classification/merge/memory-promotion, funnels through it) and
  `Loopctl.Knowledge.run_embedding_task/3` (`provider: "embedding"`) — the SINGLE
  guarded entry point shared by both embedding Oban workers
  (`Loopctl.Workers.ArticleEmbeddingWorker` / `Loopctl.Workers.MemoryEmbeddingWorker`)
  AND every query-time embedding caller (combined/semantic search, novelty scoring,
  `Memory.recall/2`, promotion near-dup lookup) — once per genuine provider failure,
  gated by the same breaker-countable classification the circuit breaker uses
  (a per-tenant 4xx credential/quota problem never contributes), and never for the
  circuit breaker's own `:circuit_open` skip (a DERIVED consequence of prior
  failures already counted when they happened, not a fresh one).

  Distinct from `[:loopctl, :llm, :blocked]` (`Loopctl.Llm.record_blocked/2`), which
  fires when NO key is configured — a missing-credential CONFIG state checked BEFORE
  any provider call is attempted. Conflating the two would both false-page (a keyless
  tenant looks like a provider incident) and mask the real incident class (a genuine
  429/5xx/transport storm on a tenant WITH a key never touches `record_blocked/2` at
  all). See `Loopctl.Telemetry.ScaleMetrics`'s "AC-34.4.3 coordination" moduledoc note.

  ## Payload (id-free — never a tenant id, article/memory id, or provider body)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{provider, class}` where `provider` is `"anthropic"` |
      `"embedding"` | `"openai_compatible"` (a BOUNDED 3-value set since US-41.3 —
      the FIXED provider atom's string form, NEVER the tenant-supplied host, which
      would make the dimension unbounded) and `class` is
      `:transient` | `:permanent` (per `Loopctl.Llm.permanent_provider_error?/1`).
      The reason feeding classification has already been run through
      `Loopctl.Llm.ProviderError.sanitize/1`, so no key/body ever reaches this event.

  Windowed by `Loopctl.Telemetry.ScaleAlerts` as a per-minute rate.
  """
  def llm_provider_error, do: [:loopctl, :llm, :provider_error]

  @doc """
  The US-36.3 batch/single ingest backlog admission gate FAILED OPEN — it could not
  measure the calling tenant's in-flight `:ingestion` backlog (the count raised a
  `Postgrex.Error` statement_timeout or a `DBConnection.ConnectionError` pool-checkout
  timeout) and therefore ADMITTED the request rather than 429-ing it. While this fires,
  the backpressure valve is effectively OFF for that request: a genuine flood deep
  enough to time the count out will admit instead of shed.

  Turns an otherwise silent `:warning` log line into an alertable signal so operators
  can see "the ingestion backpressure valve is currently admitting because it can't
  measure" on a dashboard. Distinct from a valve that is simply BELOW threshold (that
  path emits nothing). Fires once per failed-open admission check.

  ## Payload (id/atom only — never a query, key, or PG message body)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{tenant_id, error_class}` where `error_class` is a BOUNDED 2-value
      tag (`"timeout"` for the `Postgrex.Error` statement_timeout, `"connection"` for the
      `DBConnection.ConnectionError` pool-checkout timeout). `tenant_id` is an id, and is
      cap-gated to a sentinel in the metric's `tag_values` so label cardinality stays
      bounded (same convention as the other scale counters).

  Aggregated by `Loopctl.Telemetry.ScaleMetrics` as a counter tagged by
  `[:error_class, :tenant_id]`.
  """
  def ingestion_backlog_gate_failed_open,
    do: [:loopctl, :ingestion, :backlog_gate, :failed_open]

  @doc """
  The article-linking corpus-size sample (US-36.4, AC-36.4.1). The
  corpus-size-vs-limit warning that `Loopctl.Workers.ArticleLinkingWorker` used to
  compute on EVERY linking job (a full `count(*)` over the tenant/project corpus,
  purely to feed a `Logger.warning`) now runs on a deterministic ~1/N sample of jobs
  and emits THIS event alongside the retained warning, so the signal stays observable
  on a dashboard without the per-job count cost. Purely observational — never a gate
  on linking.

  ## Payload (id-only — never an article body or a vector literal)

    * `measurements`: `%{total, limit}` where `total` is the sampled candidate-corpus
      size (self-excluded, published, embedded, project-scoped) and `limit` is the
      configured `article_link_max_comparisons` ceiling the warning compares against.
    * `metadata`: `%{tenant_id, project_id, article_id}` — all ids, never content.

  Aggregated by `Loopctl.Telemetry.ScaleMetrics` as a `last_value` gauge of `total`,
  tagged by a cap-gated `tenant_id` ONLY (`article_id`/`project_id` are never labels).
  """
  def article_linking_corpus_size, do: [:loopctl, :knowledge, :article_linking, :corpus_size]

  @doc """
  One HALF of the merged recall (`POST /api/v1/recall`, `Loopctl.Memory.recall_context/2`,
  #411 Gap 2) degraded to an EMPTY, non-fatal envelope so the OTHER half could still be
  served — turning an otherwise silent partial failure into an alertable signal (the
  merged `meta` only carries a coarse `degraded?`/`degraded_reason`, no per-side detail).

  Fires when either half of the merged recall degrades:

    * the KNOWLEDGE half: `search_combined/3` returned an `{:error, _}` (e.g. an
      invalid-weights or bad-request rejection) instead of a keyword-only fallback, so
      the knowledge side is empty by FAULT (not by scope), and
    * the MEMORY half: the per-tenant HeavyRead cap SHED the memory read (`{:error,
      :heavy_read_overloaded}`); on the merged path this degrades to an empty memory
      envelope (`on_overload: :tag`) rather than raising a 429 that would sink the whole
      endpoint.

  A keyword-only knowledge fallback (embedding unavailable / a memory ILIKE embedding
  fallback) already emits `knowledge_semantic_fallback/0` and is NOT re-emitted here —
  this event is specifically the empty-by-fault degradations that carried no signal.

  ## Payload (id/atom only — NEVER the raw query text, an api key, or a provider body)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{tenant_id, side, reason}` where `side` is `"memory"` | `"knowledge"`
      (a BOUNDED 2-value tag) and `reason` is a BOUNDED, sanitized tag
      (`"heavy_read_overloaded"` | `"empty_query"` | `"invalid_weights"` |
      `"bad_request"` | `"knowledge_error"`).
  """
  def recall_context_degraded, do: [:loopctl, :memory, :recall_context, :degraded]

  @doc """
  A KB article WRITE OUTCOME was rendered (PR B2). Emitted from EVERY outcome path of
  `LoopctlWeb.ArticleController.create` — both the create-path renderers (created,
  deduplicated, gated_to_draft, title_conflict, validation_error) AND the upfront
  rejection paths that return before a create is attempted (system-scope 403 and
  agent-identity-required 403 counted as `:forbidden` — excluded from the
  high_reject_rate detector; malformed project_id 422 as `:validation_error`) — so
  write outcomes are observable even when NOTHING is
  persisted (a rejected write leaves no article row). Folded into the durable
  `ingestion_write_stats` per-(tenant, source_type, day) rollup by the self-rescuing
  `Loopctl.Telemetry.IngestionWriteStats` handler, which
  `Loopctl.Knowledge.IngestionHealth` reads to flag a `:high_reject_rate` anomaly —
  the no-persist sibling of the capture-silence dead-man's-switch.

  ## Payload (id/atom only — never article content)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{tenant_id, source_type, outcome}` where `source_type` is the
      article's advisory source_type NORMALIZED against `Article.known_source_types/0`
      (any non-allowlisted value — including all rejected-write garbage — folds to
      `nil`, i.e. the unstamped bucket, so rollup cardinality stays bounded), and
      `outcome` is a BOUNDED atom: `:created` (novel/forced create), `:deduplicated`
      (200 idempotent/near-dup dedup), `:gated_to_draft` (novelty gate staged a
      draft), `:title_conflict` (409 title taken), `:validation_error`
      (changeset/other 4xx, including the upfront malformed-param 422), or `:forbidden`
      (upfront 403 authz rejection — wrong scope/role or missing agent identity;
      tracked separately and EXCLUDED from the high_reject_rate detector so authz
      misuse is not paged as an ingestion outage).
  """
  def article_write, do: [:loopctl, :knowledge, :article_write]

  @doc """
  The US-39.5 channel-post retention sweep (`Loopctl.Workers.ChannelPostSweeper`)
  COMPLETED a run (issue #498). Emitted on EVERY successful run, including a run that
  deleted nothing — a success-only-when-non-zero signal cannot distinguish "nothing to
  do" from "never ran", which is exactly the assumed-healthy failure #428 asked to
  close. Pair it with `channel_post_sweep_failed/0` (the failure half) and with the
  `:sweep_stalled` ingestion anomaly (the absence-of-success half, which catches a
  worker that stopped being SCHEDULED at all and therefore emits neither event).

  ## NOT a span

  The name is FLAT (`:channel_post_swept`), deliberately not the
  `[..., :channel_post_sweep, :stop]` span triple: there is no `:start` event and the
  measurement is a row count, not a `:duration`. A `Telemetry.Metrics` reporter wired the
  conventional way for a `:stop` name (`distribution(..., measurement: :duration)`) would
  silently record nothing. Every real span in this module (`api_request_*`,
  `webhook_delivery_*`) has a `:start` and a `:duration`; every non-span event has a flat
  name — this follows the latter.

  ## Payload (counts + bounded ints only — never post bodies, ids, or SQL)

    * `measurements`: `%{deleted: n}` — rows hard-deleted in this run (0 on a no-op).
    * `metadata`: `%{limit: n}` — the effective per-run batch bound after the
      `min(limit, @batch_size)` clamp. A bounded integer, not a label explosion.
  """
  def channel_post_swept, do: [:loopctl, :coordination, :channel_post_swept]

  @doc """
  The US-39.5 channel-post retention sweep FAILED (issue #498). Emitted from the
  worker's rescue/catch clauses immediately before the failure is RE-RAISED/RE-EXITED, so
  Oban still records it and retries (`max_attempts: 3`) — the telemetry never swallows
  the fault, it only makes it visible outside Oban's retry churn.

  Flat name for the same reason as `channel_post_swept/0` (no span, no `:duration`).

  ## Payload (atoms/bounded tags only — never a PG message body, SQL, or bound params)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{limit, error_class}` where `limit` is the effective per-run batch
      bound and `error_class` is the raised exception's MODULE name (e.g.
      `"Postgrex.Error"`, `"DBConnection.ConnectionError"`) or the literal `"exit"` for a
      non-exception process exit — a bounded dimension, never the failure's message.
  """
  def channel_post_sweep_failed,
    do: [:loopctl, :coordination, :channel_post_sweep_failed]

  @doc """
  The `:sweep_stalled` DETECTOR itself failed (issue #498 review) — i.e. the dead-man's
  switch that watches the US-39.5 retention sweep is the thing that is now dead.

  `Loopctl.Workers.IngestionHealthWorker` runs that detection inside its own
  rescue/catch so a saturated 3-connection `AdminRepo` pool cannot abort the sibling
  detectors (capture-silence flagging, reject-rate recovery, write-stats pruning). That
  isolation is deliberate — but with a log line as its ONLY signal, a persistently
  failing residue read (statement timeout, schema change, permission regression) would
  reproduce at the meta level exactly the "visible only in logs / assumed healthy"
  failure #498 exists to close. This event is the monitor's own heartbeat-of-death, so
  the isolated-failure-domain property is kept WITHOUT the silence.

  Flat name for the same reason as `channel_post_swept/0` (no span, no `:duration`).

  ## Payload (atoms/bounded tags only — never a PG message body, SQL, or bound params)

    * `measurements`: `%{count: 1}` — a pure increment.
    * `metadata`: `%{error_class}` — the raised exception's MODULE name (e.g.
      `"Postgrex.Error"`, `"DBConnection.ConnectionError"`) or the literal `"exit"` for a
      non-exception process exit. A bounded dimension, never the failure's message.
  """
  def sweep_stall_detection_failed,
    do: [:loopctl, :knowledge, :sweep_stall_detection_failed]

  @doc """
  The retroactive US-39.1 denylist rescan (`Loopctl.Workers.ChannelPostRescanWorker`)
  COMPLETED a run (issue #499). Emitted on EVERY successful run, including a run that
  scanned nothing and quarantined nothing — for the same reason as
  `channel_post_swept/0`: a success-only-when-non-zero signal cannot distinguish
  "nothing to do" from "never ran".

  Flat name (no `:start`, no `:duration`) — see `channel_post_swept/0`.

  ## Payload (counts + bounded ints only — never post bodies or matched values)

    * `measurements`: `%{scanned: n, quarantined: n, backlog: n}` — posts examined and
      posts quarantined in this run, plus the posts STILL due after it. `backlog` is the
      starvation signal: a run whose whole budget went to a continuously refilling
      never-scanned head, while the `rescanned_at < revision` backlog never advanced,
      would otherwise look byte-identical to a healthy sweep that drained everything.
    * `metadata`: `%{limit: n}` — the effective per-run batch bound after the
      `min(limit, @batch_size)` clamp.
  """
  def channel_post_rescanned, do: [:loopctl, :coordination, :channel_post_rescanned]

  @doc """
  The retroactive denylist rescan FAILED (issue #499). Emitted from the worker's
  rescue/catch clauses immediately before the failure is RE-RAISED/RE-EXITED, so Oban
  still records it and retries — the telemetry never swallows the fault.

  Flat name for the same reason as `channel_post_rescanned/0`.

  ## Payload (bounded tags only — never a PG message body, SQL, or bound params)

    * `measurements`: `%{count: 1}`.
    * `metadata`: `%{limit, error_class}` where `error_class` is the raised exception's
      MODULE name or the literal `"exit"` for a non-exception process exit.
  """
  def channel_post_rescan_failed, do: [:loopctl, :coordination, :channel_post_rescan_failed]

  @doc """
  ONE live channel post was QUARANTINED by the retroactive denylist rescan (#499) —
  i.e. a credential shape that the write-time gate did not know about at write time is
  present on a post that has been re-broadcast into every new session on that repo.

  Sibling of the write-time `[:loopctl, :coordination, :secret_blocked]` signal, and
  carries the same bounded metadata shape.

  ## Payload (bounded tags only — NEVER the body, the field value, or the match)

    * `measurements`: `%{count: 1}`.
    * `metadata`: `%{tenant_id, project_id, agent_id, fields}` where `fields` is the
      comma-joined list of offending FIELD NAMES (`"body,refs"`) — names only.
  """
  def channel_post_quarantined, do: [:loopctl, :coordination, :channel_post_quarantined]

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
      knowledge_semantic_fallback(),
      knowledge_hybrid_provenance(),
      llm_provider_error(),
      ingestion_backlog_gate_failed_open(),
      article_linking_corpus_size(),
      recall_context_degraded(),
      article_write(),
      channel_post_swept(),
      channel_post_sweep_failed(),
      sweep_stall_detection_failed(),
      channel_post_rescanned(),
      channel_post_rescan_failed(),
      channel_post_quarantined()
    ]
  end
end
