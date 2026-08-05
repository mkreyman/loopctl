defmodule Loopctl.Telemetry.ScaleMetrics do
  @moduledoc """
  Scale-observability `Telemetry.Metrics` definitions (US-27.15, AC-27.15.1/.3).

  Turns the structured signals epic 27 already emits — `db_statement_timeout`
  (US-27.3), heavy-read latency (US-27.4), and recall under-fill (US-27.6b) — into
  aggregated metrics a reporter can scrape, so a degradation TREND is visible
  before it becomes an incident (instead of grepping 7-day logs after users hit it).

  These metrics are MERGED into `LoopctlWeb.Telemetry.metrics/0` and exposed to
  Fly's managed Prometheus by the reporter on the internal `:9568/metrics` port.
  `scale_metrics/0` has grown past its original US-27.15 scope as later stories
  added observability signals to the same list: #297 added the semantic-fallback
  counter and US-31.2 added the hybrid-provenance counter (both already present
  before this branch); US-33.1 adds TWO more, purely-additive metrics: per-pool
  connection-checkout `queue_time` distributions for `Loopctl.Repo` (the RLS pool,
  size 10) and `Loopctl.AdminRepo` (the BYPASSRLS pool, size 3). Ecto already emits
  `queue_time` (native time spent WAITING for a pooled connection) on every query
  telemetry event; before this branch only `heavy_read_repo.query.duration` was
  scraped, so there was no way to see where checkout contention lands between the
  two pools. See "Per-pool checkout queue_time (US-33.1)" below. US-34.4 adds TEN
  more, purely-additive counters: several `:telemetry.execute/3` calls already fire
  at the right code sites (LLM/embedding BYO-key blocks, a nightly index-health
  check, secret-rotation cleanup failures, witness-header divergence, and the
  Epic 29 memory-promotion pipeline) but had no `Telemetry.Metrics` definition
  consuming them, so the signal terminated in a no-op handler-less event — invisible
  to Prometheus/dashboards despite already being emitted. See "Wiring emitted-but-dead
  events (US-34.4)" below for the full inventory, including the events deliberately
  left OUT of scope with a cited reason. US-34.1 adds THREE more, purely-additive
  metrics: a periodic per-{state, queue} poll of `oban_jobs` (nothing previously
  exported ANY Oban queue/state metric), an `:executing`-older-than-N-min orphan
  gauge, and a poll-failure counter so a frozen gauge is distinguishable from a
  genuinely stable one — see "Oban queue/state gauges + `:executing` orphan gauge
  (US-34.1)" below. US-36.3 added the ingestion backlog-gate fail-open counter and
  US-36.4 adds the article-linking corpus-size gauge (metric 22 below). US-38.3 adds
  the clustering-readiness peer gauge (metric 23 below — `loopctl.cluster.peers.count`,
  a `last_value/2` gauge of `length(Node.list/0)` tagged by the bounded readiness
  `status`, fed by `poll_cluster_readiness/0`). `scale_metrics/0` itself is the
  inventory — never a count repeated here.

  ## The metrics (23 total)

    1. **Timeout / DB-error counter** — `loopctl.db.error.count`, keyed by
       `[:endpoint, :mapped_code]` (+ a cap-gated `:tenant_id`). `mapped_code`
       separates the `db_statement_timeout` (57014) counter the AC targets from the
       serialization / deadlock / catch-all classes. Sourced from
       `[:loopctl, :db, :error]` (emitted by `LoopctlWeb.DBErrorLogger`).
    2. **Heavy-read latency distribution** — `loopctl.heavy_read_repo.query.duration`,
       keyed by `[:endpoint]` ONLY (NO `:tenant_id` — endpoint × tenant × buckets is
       the multi-tenant cardinality bomb AC-27.15.3 forbids). Sourced from the Ecto
       query event `[:loopctl, :heavy_read_repo, :query]`, with `endpoint` read from
       `metadata.options[:endpoint]` (set by `Loopctl.HeavyRead.opts/1`).
    3. **Under-fill counter** — `loopctl.knowledge.vector_search.under_fill.count`,
       keyed by `[:endpoint]` (+ a cap-gated `:tenant_id`). Sourced from
       `[:loopctl, :knowledge, :vector_search, :under_fill]` (US-27.6b).
    4. **Semantic-fallback counter** (#297) — `loopctl.knowledge.semantic_fallback.count`,
       keyed by `[:reason]` ONLY (no `:tenant_id` — the reason set is fixed and
       small). Sourced from `[:loopctl, :knowledge, :semantic_fallback]`.
    5. **Hybrid-provenance counter** (US-31.2) — `loopctl.knowledge.hybrid_provenance.count`,
       keyed by `[:provenance, :hit]` (+ a cap-gated `:tenant_id`). Sourced from
       `[:loopctl, :knowledge, :hybrid_provenance]`.
    6. **RLS-pool checkout `queue_time` distribution** (US-33.1) —
       `loopctl.repo.checkout.queue_time`, with a static `[:repo]` tag (no cap gate
       needed). Sourced from the Ecto query event `[:loopctl, :repo, :query]`.
    7. **AdminRepo-pool checkout `queue_time` distribution** (US-33.1) —
       `loopctl.admin_repo.checkout.queue_time`, with a static `[:repo]` tag (no cap
       gate needed). Sourced from `[:loopctl, :admin_repo, :query]`.
    8. **LLM/embedding blocked counter** (US-34.4, AC-34.4.1/.3) —
       `loopctl.llm.blocked.count`, keyed by `[:operation, :provider]` (NEVER
       `:tenant_id`). Sourced from `[:loopctl, :llm, :blocked]` (`Loopctl.Llm.record_blocked/2`).
    9. **Embedding-skipped-no-key counter** (US-34.4, AC-34.4.1) —
       `loopctl.embedding.skipped_no_key.count`, keyed by `[:source]` (`"article"` /
       `"memory"`). Sourced from `[:loopctl, :embedding, :skipped_no_key]`
       (`ArticleEmbeddingWorker` / `MemoryEmbeddingWorker`).
    10. **Index-health-invalid counter** (US-34.4, AC-34.4.1) —
        `loopctl.index_health.invalid.count`, keyed by `[:index, :purpose, :state]`
        (all three bounded, fixed sets). Sourced from `[:loopctl, :index_health, :invalid]`
        (`Loopctl.IndexHealth.emit/3`).
    11. **Secret-orphan-cleanup-failed counter** (US-34.4, AC-34.4.2) —
        `loopctl.secrets.orphan_cleanup_failed.count`, keyed by `[:op, :reason]` —
        `reason` is CLASSIFIED into a bounded set (never the raw, potentially
        free-text Fly API error term). Sourced from
        `[:loopctl, :secrets, :orphan_cleanup_failed]` (`Loopctl.Tenants`).
    12. **Witness-divergence counter** (US-34.4, AC-34.4.2) —
        `loopctl.witness.divergence.count`, keyed by `[:reason]` ONLY (never
        `:tenant_id`/`:position`, both unbounded). Sourced from
        `[:loopctl, :witness, :divergence]` (`ValidateWitnessHeader.resync_required/5`).
    13. **Witness-bootstrap-already-consumed counter** (US-34.4, AC-34.4.2) —
        `loopctl.witness.bootstrap_already_consumed.count`, UNTAGGED (the only
        metadata is `tenant_id`, which is never a label). Sourced from
        `[:loopctl, :witness, :bootstrap_already_consumed]`.
    14. **Memory-promotion-failed counter** (US-34.4, AC-34.4.2) —
        `loopctl.memory_promotion.failed.count`, keyed by `[:stage]` (a bounded
        3-value enum: `:compile`/`:persist`/`:enqueue`). Sourced from
        `[:loopctl, :memory_promotion, :failed]`.
    15. **Memory-promotion-degraded counter** (US-34.4, AC-34.4.2) —
        `loopctl.memory_promotion.degraded.count`, UNTAGGED. Sourced from
        `[:loopctl, :memory_promotion, :degraded]`.
    16. **Memory-promotion-quota-exceeded counter** (US-34.4, AC-34.4.2) —
        `loopctl.memory_promotion.quota_exceeded.count`, UNTAGGED. Sourced from
        `[:loopctl, :memory_promotion, :quota_exceeded]`.
    17. **Memory-promotion-budget-exceeded counter** (US-34.4, AC-34.4.2) —
        `loopctl.memory_promotion.budget_exceeded.count`, UNTAGGED. Sourced from
        `[:loopctl, :memory_promotion, :budget_exceeded]`.

  ## Bounded cardinality (AC-27.15.3) — the no-leak contract

  Labels are SAFE DIMENSIONS only: `endpoint` (a matched controller.action / heavy-read
  endpoint atom — never a raw path with ids), `mapped_code` (a bounded DB-error class),
  and a cap-gated `tenant_id`. There is NO `:article_id` label, no raw vector / body /
  param ever reaches a tag — the upstream events carry id-only metadata.

  ### The tenant-label cap gate (no per-emit DB hit)

  `tenant_id` is a COUNTER label ONLY while the total tenant count is at or below
  `:metrics_tenant_label_cap` (default #{1000}); above the cap it is collapsed to the
  fixed sentinel `#{inspect(:_aggregated)}` so the label's cardinality is provably 1
  (per-tenant attribution then falls back to the 7-day logs, which still carry
  `tenant_id`). It is NEVER a label on the latency histogram (the buckets multiply).

  The gate is a boolean cached in `:persistent_term` under `#{inspect({__MODULE__, :tenant_label?})}`:

    * `tag_values` (`scale_tags/1`) reads it with `:persistent_term.get/2` — an O(1),
      lock-free read on the metric hot path, defaulting to `false` (drop/aggregate the
      label) if unseeded, so an un-warmed boot can NEVER emit an unbounded label.
    * `refresh_tenant_label_gate/0` recomputes `Tenants.count() <= cap` and writes the
      boolean. It is wired into `LoopctlWeb.Telemetry`'s `telemetry_poller` periodic
      measurements (every 10s) and is the ONLY place that touches the DB — so the
      cardinality decision costs one cheap `COUNT(*)` per poll interval, not one per
      metric emission.

  ### Why a SENTINEL, not an omitted tag

  A Prometheus metric series must carry a CONSISTENT label set across every emission;
  a `tag_values` map that sometimes includes `:tenant_id` and sometimes omits it would
  make the same metric flap between two label shapes (the core reporter would treat
  them as distinct series and can error on the inconsistency). Holding the tag list
  FIXED in the metric definition and collapsing the VALUE to a single sentinel when
  gated keeps the series shape stable AND pins the tenant dimension's cardinality to
  exactly 1 when over the cap. Below the cap the cardinality is bounded by the cap
  itself (≤ #{1000} by default).

  ## Wiring emitted-but-dead events (US-34.4)

  Producer code already fires `:telemetry.execute/3` at seven distinct code sites
  (AC-34.4.2's full inventory below); this story does NOT change what is emitted
  (with the two narrow, documented metadata additions noted per-event below) — it
  is PURELY additive metric-definition work that gives each event a consumer.

    * `[:loopctl, :llm, :blocked]` (metric 8) — `Loopctl.Llm.record_blocked/2`
      already carried `tenant_id` + `operation`; this story adds ONE bounded
      metadata key, `provider` (`"embedding"` or `"anthropic"`, derived from the
      same 2-way split `blocked_credential/1` already uses), so the counter can be
      windowed by provider. **IMPORTANT — this is NOT a provider-error signal.**
      `record_blocked/2` fires ONLY when a tenant has no BYO API/embedding key
      configured (a missing-credential CONFIG state, checked before any provider
      call is made); `provider` here is the credential TYPE (`"embedding"` /
      `"anthropic"`), not the LLM vendor. There is currently NO runtime
      provider-error telemetry event anywhere in the codebase —
      `Loopctl.Llm.ProviderError` only sanitizes error terms for logging/discard
      reasons and emits nothing. **AC-34.4.3 coordination with US-34.3 (unwritten
      as of this story)**: US-34.3's "provider-error rate" signal must NOT window
      this counter as a proxy for provider throttling — a tenant that simply
      never configured a key would inflate the signal (false paging on a
      non-incident), while an actual 429/5xx/transport-error storm (key present,
      so `llm.blocked` never fires at all) would go completely undetected — the
      exact incident class this epic exists to catch. US-34.3 must instead either
      (a) introduce its own genuine provider-error event (e.g. from the
      transient branch of `Loopctl.Llm.permanent_provider_error?/1`) and window
      THAT, or (b) if it chooses to consume `llm.blocked` anyway, scope its
      language to mean "missing-key blocks" explicitly rather than "provider
      errors". Should a future handler attach to `[:loopctl, :llm, :blocked]`
      for the missing-key case specifically, it would do so independently via
      telemetry fan-out (this counter's handler does not re-emit the event, so
      no double-count) — but that remains a DIFFERENT signal than "provider
      error" and must be named accordingly wherever it is consumed.
    * `[:loopctl, :embedding, :skipped_no_key]` (metric 9) — both emit sites
      (`ArticleEmbeddingWorker`, `MemoryEmbeddingWorker`) already carried
      `tenant_id` + an unbounded id (`article_id`/`memory_id`); this story adds ONE
      bounded metadata key, `source` (`"article"`/`"memory"`), at each site so the
      counter can distinguish the two without ever tagging the id. **Known overlap
      with metric 8**: both emit sites also call `Llm.record_blocked/2`
      immediately afterward, so a single missing-embedding-key skip increments
      BOTH `loopctl.embedding.skipped_no_key.count{source=...}` AND
      `loopctl.llm.blocked.count{operation="embedding"}`. This is intentional —
      the two counters answer different questions ("embedding work skipped" vs
      "LLM operation blocked for a key") — but an operator building a single
      "blocked operations" panel that sums across both series will double-count
      this one condition; do not sum them without accounting for the overlap.
    * `[:loopctl, :index_health, :invalid]` (metric 10) — wired AS-IS; `index`,
      `purpose`, and `state` are already three bounded, fixed sets (no metadata
      change needed).
    * `[:loopctl, :secrets, :orphan_cleanup_failed]` (metric 11) — wired, but NOT
      as-is: `reason` here is `{:error, term()}` from `Loopctl.Secrets.Behaviour`
      and can carry a raw Fly GraphQL error payload (`{:fly_api_error, errors}` —
      free text) or an arbitrary transport-error struct, so this story does NOT
      trust it as a label directly. `secrets_orphan_cleanup_tags/1` CLASSIFIES it
      into a small fixed set (`"fly_not_configured"`, `"http_error"`,
      `"fly_api_error"`, `"old_value_unavailable"`, `"other"`) before it ever
      reaches a tag — the same "mapped_code" classification precedent as the
      original DB-error counter. `secret_name` (unbounded) is never tagged.
    * `[:loopctl, :witness, :divergence]` (metric 12) — wired by `reason` ONLY
      (`"prefix_mismatch"` / `"future_position"`, a genuinely fixed 2-value set);
      `tenant_id` and `position` are dropped from the tag set (both unbounded).
    * `[:loopctl, :witness, :bootstrap_already_consumed]` (metric 13) — wired
      UNTAGGED. Its only metadata is `tenant_id`; rather than skip it, this story
      counts total occurrences with zero labels (cardinality exactly 1) — still
      useful trend data (how often fresh clients consume the one-time bootstrap
      grace) without ever exposing the tenant dimension.
    * `[:loopctl, :memory_promotion, *]` (`Loopctl.Memory.PromotionTelemetry`,
      11 possible event names) — a SUBSET is wired (metrics 14-17): the four
      DEGRADATION/failure signals an operator would actually want to alert on —
      `:failed` (tagged by the bounded `:stage` enum, present on every `:failed`
      emission), `:degraded`, `:quota_exceeded`, and `:budget_exceeded` (all three
      untagged — their only metadata besides the `:count` measurement is
      per-tenant/session identifiers, which are never tagged). **Explicitly
      OUT OF SCOPE, no silent omission**: `:swept`, `:skipped`, `:compiled`,
      `:promoted`, `:superseded`, `:gated_out`, and `:eval` are routine
      steady-state VOLUME/quality telemetry, not degradation signals — wiring all
      eleven sub-events would triple this module's metric count for observability
      value this story's scope does not need (a future story can extend the
      subset; the events remain available via `:telemetry.attach` in the
      meantime).
    * `[:loopctl, :knowledge, :keyset_byte_truncated]` — **explicitly OUT OF
      SCOPE, no silent omission**. Its ONLY metadata is `tenant_id`; there is no
      bounded dimension available to key a useful counter by (unlike
      `bootstrap_already_consumed` above, byte-truncation volume without ANY
      breakdown is not actionable trend data on its own), so wiring it would add
      a metric definition purely to avoid an omission rather than to serve
      observability. Cites the bounded-cardinality rule (AC-27.15.3): a metric
      whose only non-fixed dimension is `tenant_id` either drops the dimension
      (as `bootstrap_already_consumed` does, where the RAW event-name volume is
      itself the signal an operator watches) or stays unwired; this event's
      truncation volume is expected to correlate with the already-instrumented
      `loopctl.knowledge.vector_search.under_fill.count`/hybrid-provenance
      signals rather than needing its own series.

  ## Oban queue/state gauges + `:executing` orphan gauge (US-34.1)

  Before this story NOTHING exported any `oban_jobs` state metric — the exact blind
  spot that let 110 jobs sit stuck `:executing` for days (2026-06-22 → 2026-07-10)
  before anyone noticed (the incident that motivated adding `Oban.Plugins.Lifeline`,
  see `config/config.exs`). `oban_jobs` is a GLOBAL table — it has NO `tenant_id`
  column (only `args` carries one, per-job, inside a JSON blob) — so this is
  infrastructure observability, not tenant-scoped data.

  Two periodic pollers (wired into `LoopctlWeb.Telemetry.periodic_measurements/0`,
  the SAME shared `telemetry_poller` process that already refreshes the tenant-label
  gate every 10s) run a single lightweight raw-SQL query each against `Loopctl.Repo`
  (never `Loopctl.HeavyRead`, which structurally REJECTS any query whose base table
  lacks a `tenant_id` Ecto field — `oban_jobs` is not even an Ecto-queryable schema
  here, it's raw SQL, following the `Loopctl.IndexHealth` precedent). `Loopctl.Repo`
  — not `Loopctl.AdminRepo` — is used DELIBERATELY (review finding): `oban_jobs` has
  `relrowsecurity = false` (verified live), so RLS enforcement is a non-issue either
  way, and `Loopctl.Repo`'s pool (size 10) is more than 3x `Loopctl.AdminRepo`'s
  (size 3, the smallest pool in the app, shared with superadmin/BYPASSRLS work) — a
  recurring 10s poll has no business landing on the app's tightest pool when a
  larger, equally-permissioned one is available. Each poll wraps its query in a
  `Repo.transaction/1` that first issues a per-query `SET LOCAL statement_timeout`
  (config `:oban_metrics_poll_statement_timeout_ms`, default #{2_000}ms, validated
  to be a positive integer at read time before it is interpolated into the raw SQL
  string — Postgres's `SET` cannot take a bound parameter — the same guard
  `Loopctl.HeavyRead.transaction/2` applies before its identical interpolation) —
  NEVER a connection-startup `:parameters` override, which Fly MPG's pgbouncer
  rejects with `FATAL 08P01` (the US-27.13 outage class).

  `poll_oban_queue_state/0` restricts its `GROUP BY` and zero-fill to the
  NON-TERMINAL states (`oban_active_states/0` — `suspended`/`scheduled`/
  `available`/`executing`/`retryable`; review finding) rather than all 8 states:
  under normal pruner retention (`config/config.exs`, `max_age` 7 days) the
  terminal states (`completed`/`discarded`/`cancelled`) can hold hundreds of
  thousands of rows, forcing a full `Seq Scan` that at scale exceeds the 2s
  statement_timeout — `EXPLAIN` confirms the non-terminal restriction instead
  produces an `Index Only Scan` on `oban_jobs_state_queue_priority_scheduled_at_id_index`
  (the existing `(state, queue, priority, scheduled_at, id)` index Oban itself
  maintains), so the query stays cheap regardless of how large the terminal-state
  partitions grow. This also shrinks the zero-fill matrix (`oban_active_states/0` x
  `oban_queues/0` instead of the full `oban_states/0` x `oban_queues/0`) — terminal
  states never produce a Prometheus series under this gauge (their volume isn't the
  operational backlog signal this gauge exists to surface, and 7-day-retained
  terminal counts are not actionable trend data on a 10s cadence).

  Both pollers are defensive: `poll_oban_queue_state/0` and
  `poll_oban_executing_orphans/0` each `rescue` on ANY exception (review finding —
  broadened from a narrow DB-fault-only rescue), `Logger.warning`, EMIT the new
  poll-failure counter (metric 20 below), and return `:ok`.

  **Why a catch-all rescue, and what "crash the poller" actually means (review
  finding — the previous docs here were factually wrong):** `telemetry_poller`
  (verified against the vendored `telemetry_poller` 1.3.0 source,
  `src/telemetry_poller.erl`) wraps EVERY periodic measurement's
  `erlang:apply/3` in its OWN `try/catch` (`make_measurements_and_filter_misbehaving/1`)
  and keeps only the measurements that did NOT raise — so an uncaught raise here
  does NOT crash the shared poller process and does NOT take down the tenant-label
  gate refresh. What actually happens is worse for THIS specific measurement: the
  raising MFA is logged once by `telemetry_poller` itself and then PERMANENTLY
  DROPPED from the poll rotation until the next app restart — the gauge goes dark
  forever, silently, with no crash and no alert. A narrow rescue (the previous
  version, catching only `Postgrex.Error`/`DBConnection.ConnectionError`/
  `DBConnection.OwnershipError`) left every OTHER error class (a config shape
  error like `oban_queues/0` raising on a malformed `:queues` option, an
  `ArgumentError` from a bad config tunable, etc.) to propagate straight into that
  permanent-drop fate — precisely the invisible-failure class this observability
  epic exists to eliminate. The catch-all rescue below ensures NO measurement is
  ever silently dropped from the rotation: every exception is caught, logged, and
  reported via the poll-failure counter, and the gauge simply keeps its
  last-recorded value for one more cycle.

    18. **Oban queue/state gauge** (US-34.1, AC-34.1.1) —
        `loopctl.oban.jobs.count`, a `last_value/2` GAUGE keyed by `[:state, :queue]`
        — BOTH bounded, fixed sets (`oban_active_states/0`'s 5 non-terminal states;
        the 11 queues declared in `config :loopctl, Oban, queues: [...]`, resolved at
        call time via `Application.get_env/2`) — NEVER tenant/args-derived.
        `poll_oban_queue_state/0` runs
        `SELECT state, queue, count(*) FROM oban_jobs WHERE state = ANY($1) GROUP BY state, queue`
        (`$1` bound to `oban_active_states/0`), then ZERO-FILLS: it emits one
        `[:loopctl, :oban, :jobs, :count]` measurement for EVERY `{state, queue}`
        pair in the `oban_active_states/0` x `oban_queues/0` matrix, substituting
        `count: 0` for any pair the `GROUP BY` did not return a row for (a
        `count(*) GROUP BY` can only ever return rows with count >= 1, so the zero
        case is never present in `rows` — it must be synthesized). A drained
        combination is therefore explicitly reset to `0` every poll cycle rather
        than retaining a stale last-seen value — the correct gauge semantics for
        "how many jobs are in this state right now" (a `last_value/2` gauge itself
        has no expiry; without this zero-fill a drained `{state, queue}` pair would
        read stale-high forever). The one exception is a poll that FAILS outright
        (`rescue`d below): no measurement fires that cycle, so the gauge
        intentionally keeps its prior reading until the next successful poll —
        there is no fresher truth to report, and the poll-failure counter (metric
        20) makes that staleness detectable rather than silently indistinguishable
        from a genuinely stable reading.
    19. **`:executing`-older-than-N-min orphan gauge** (US-34.1, AC-34.1.2) —
        `loopctl.oban.jobs.executing_orphan.count`, an UNTAGGED `last_value/2` gauge.
        `poll_oban_executing_orphans/0` counts `oban_jobs` rows in state `executing`
        whose `attempted_at` is older than `:oban_metrics_orphan_threshold_minutes`
        (default #{45} minutes — deliberately ABOVE the Lifeline `rescue_after` window,
        30 min, so a non-zero reading means Lifeline is falling behind or a job is
        genuinely wedged past Lifeline's own rescue point, not merely mid-flight).
        `EXPLAIN` confirms this query is already an `Index Scan` over the tiny
        `executing` partition — unaffected by the Seq Scan risk metric 18 fixes.
    20. **Periodic-measurement poll-failure counter** (US-34.1, review finding) —
        `loopctl.oban.poll.error.count` (the `oban.` name predates the other
        measurements adopting it; renaming would break existing dashboards), keyed by
        `[:poller, :error_class]` — BOTH bounded, fixed sets (`poller` is one per
        measurement in `LoopctlWeb.Telemetry.periodic_measurements/0`:
        `"queue_state"`/`"executing_orphans"`/`"cluster_readiness"`/`"tenant_label_gate"`;
        `error_class` is CLASSIFIED via `oban_poll_error_class/1` into
        `"db_error"`/`"guc_capture_abort"`/`"config_error"`/`"other"`/`"unknown"`,
        or — for a non-local exit/throw — `"<kind>:<tag>"` over `Loopctl.ExitClass`'s
        closed tag set (`"exit:noproc"`, `"exit:timeout"`, `"throw:other"`, …; #558
        replaced the bare `"exit"`/`"throw"` labels, so re-point any selector on
        those), never the raw exception message or exit reason).
        Emitted from `guarded_measurement/5` — the ONE guard every periodic
        measurement runs under — on the `rescue` AND the `catch :exit`/`:throw` path
        alike, so a frozen gauge (metrics 18/19/23 retaining their last value, or the
        tenant-label gate holding/forcing OFF, because a cycle failed) is
        distinguishable in Prometheus from a genuinely stable reading — a
        non-zero, incrementing rate on this counter means the corresponding gauge is
        stale, not that the system is actually quiet.
    25. **Boot-cache-prime-failure counter** (#588) —
        `loopctl.system_config.prime_failed.count`, keyed by `[:error_class]` only
        (the already-CLASSIFIED closed set from `Loopctl.ExitClass`, plus
        `"unclassified"` — never a raw exit reason). Sourced from
        `[:loopctl, :system_config, :prime_failed]`
        (`Loopctl.SystemConfig.CachePrimer`). Wired for the same reason as metrics
        8-17: emitted-but-dead is invisible to Prometheus. It matters more here
        because the degradation it reports is UNBOUNDED — a node that missed its boot
        prime keeps answering `SystemConfig.get_int/2` with in-code defaults (the
        RETIRED legacy column for the embeddings read flag) until a
        `SystemConfigRefreshWorker` tick lands on it, and one `Logger.error` line in
        the log stream is not something a rolling deploy can be alerted on.
  """

  import Telemetry.Metrics

  @behaviour Loopctl.Telemetry.ScaleMetrics.OrphanCountBehaviour

  require Logger

  alias Loopctl.ExitClass
  alias Loopctl.ExitTag
  alias Loopctl.LocalGuc
  alias Loopctl.Repo
  alias Loopctl.Tenants

  @persistent_term_key {__MODULE__, :tenant_label?}

  # Process-dictionary key for the tenant-label gate's consecutive-failure streak — see
  # `resolve_gate/1`.
  @gate_failure_key {__MODULE__, :tenant_label_gate_failed?}

  # US-34.2 (review finding): the `:persistent_term` slot `poll_oban_executing_orphans/0`
  # writes on every SUCCESSFUL poll, and `cached_executing_orphan_count/0` reads —
  # lets `Loopctl.HealthCheck.Default`'s orphan sub-check reuse the last-polled value
  # instead of issuing its OWN fresh `Repo.transaction` + `SELECT count(*)` on every
  # `/health`/`/health/ready` hit (the shared `check/0` backs BOTH the continuous,
  # unauthenticated liveness probe AND readiness — a fresh DB round-trip on every
  # liveness hit is unwarranted request-amplification pressure on the Ecto pool).
  @executing_orphan_cache_key {__MODULE__, :cached_executing_orphan_count}

  # The fixed sentinel a `tenant_id` label collapses to when the gate is OFF (over the
  # tenant-count cap, or the gate is unseeded). Keeps the tenant label's cardinality at
  # exactly 1 while preserving a consistent Prometheus series shape.
  @aggregated_sentinel :_aggregated

  @default_tenant_label_cap 1_000

  # US-34.1: per-query SET LOCAL statement_timeout for the two Oban pollers below —
  # short and bounded (AC-34.1.3), so a slow poll can never itself saturate the
  # Repo pool. Configurable via :oban_metrics_poll_statement_timeout_ms.
  @default_oban_metrics_poll_timeout_ms 2_000

  # US-34.1: the `:executing` orphan gauge's age threshold (minutes). Deliberately
  # ABOVE the Lifeline `rescue_after` window (30 min, config/config.exs) so a
  # non-zero reading means Lifeline is genuinely falling behind or a job is wedged
  # past Lifeline's own rescue point — not merely a job that is still mid-flight.
  # Configurable via :oban_metrics_orphan_threshold_minutes.
  @default_oban_metrics_orphan_threshold_minutes 45

  # US-34.1: the terminal Oban job states EXCLUDED from the live poll/zero-fill
  # matrix (review finding). A job in one of these states will never transition
  # again, and under the pruner's 7-day retention these partitions can grow to
  # hundreds of thousands of rows — polling them forces a Seq Scan at scale. The
  # non-terminal complement (`oban_active_states/0`) is what `poll_oban_queue_state/0`
  # actually queries/zero-fills.
  @oban_terminal_states [:completed, :discarded, :cancelled]

  @doc """
  The scale metrics: the original US-27.15 trio, #297's semantic-fallback
  counter, US-31.2's hybrid-provenance counter, US-33.1's two per-pool checkout
  `queue_time` distributions, US-34.4's ten emitted-but-dead-event counters
  (LLM/embedding-blocked, index-health, secrets/witness/memory-promotion
  degradation signals), US-34.1's three Oban metrics (per-{state, queue}
  gauge over the non-terminal states, the `:executing` orphan gauge, and a
  poll-failure counter), US-36.3's ingestion backlog-gate fail-open counter,
  US-36.4's article-linking corpus-size gauge, US-38.3's clustering-readiness
  peer gauge, and #588's boot-cache-prime-failure counter. Appended to
  `LoopctlWeb.Telemetry.metrics/0`.
  """
  @spec scale_metrics() :: [Telemetry.Metrics.t()]
  def scale_metrics do
    [
      # 1. DB-error counter (the 57014 `db_statement_timeout` source). `mapped_code`
      #    separates the timeout class from serialization/deadlock/catch-all. The
      #    counter MAY carry a cap-gated `tenant_id` (sentinel when over cap).
      counter("loopctl.db.error.count",
        event_name: [:loopctl, :db, :error],
        measurement: :count,
        description: "Mapped DB errors surfaced to clients, by endpoint and mapped_code.",
        tags: [:endpoint, :mapped_code, :tenant_id],
        tag_values: &scale_tags/1
      ),

      # 2. Heavy-read latency distribution, by endpoint. NO tenant tag (AC-27.15.3 —
      #    endpoint × tenant × buckets blows up in a multi-tenant SaaS).
      distribution("loopctl.heavy_read_repo.query.duration",
        event_name: [:loopctl, :heavy_read_repo, :query],
        measurement: :total_time,
        unit: {:native, :millisecond},
        description: "Heavy-read (vector / enumeration) query latency, by endpoint.",
        tags: [:endpoint],
        tag_values: &latency_tags/1,
        reporter_options: [
          buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        ]
      ),

      # 3. Recall under-fill counter (US-27.6b), by endpoint. MAY carry a cap-gated
      #    `tenant_id` (sentinel when over cap).
      counter("loopctl.knowledge.vector_search.under_fill.count",
        event_name: [:loopctl, :knowledge, :vector_search, :under_fill],
        measurement: :requested,
        description: "Vector-search recall under-fill events, by endpoint.",
        tags: [:endpoint, :tenant_id],
        tag_values: &scale_tags/1
      ),

      # 3b. Under-fill PROBE degradation counter (#550 review). The probe's fail-soft exit
      #     turns a would-be 503 into a valid 200 whose truncation signal is simply ABSENT,
      #     so metric 3 above just stops firing — a log line alone is invisible to a
      #     dashboard (`TelemetryEvents.vector_search_under_fill_probe_degraded/0` says as
      #     much), and without this definition the emitted event terminated in a
      #     handler-less no-op. `error_class` is the same bounded set as the fail-open
      #     counter below; `tenant_id` is cap-gated to the sentinel.
      counter("loopctl.knowledge.vector_search.under_fill_probe_degraded.count",
        event_name: [:loopctl, :knowledge, :vector_search, :under_fill_probe_degraded],
        measurement: :count,
        description:
          "Vector-search under-fill PROBE degraded (no truncation signal), by error_class and tenant.",
        tags: [:error_class, :tenant_id],
        tag_values: &degraded_read_tags/1
      ),

      # 4. Semantic-fallback counter (#297), by REASON only. Turns the silent
      #    semantic→keyword degradation into an alertable trend. `reason` is a
      #    BOUNDED, sanitized tag set (no api key / provider body / raw query ever
      #    reaches it), so this needs NO tenant_id label — the reason dimension is
      #    fixed and small, and per-tenant attribution stays in the 7-day logs
      #    (which carry tenant_id). NO tenant label = no multi-tenant cardinality
      #    bomb (AC-27.15.3).
      counter("loopctl.knowledge.semantic_fallback.count",
        event_name: [:loopctl, :knowledge, :semantic_fallback],
        measurement: :count,
        description: "Semantic search degraded to keyword-only / contributed nothing, by reason.",
        tags: [:reason],
        tag_values: &semantic_fallback_tags/1
      ),

      # 5. Hybrid-resolver provenance counter (US-31.2, finding 6): every
      #    `hybrid_search/3` decision, by `provenance` (curated/retrieved) and `hit`
      #    (non-empty/empty page). Fires unconditionally (unlike the
      #    `article_access_events` recording, which cannot represent a MISS or a
      #    keyless call), so the hit/miss + keyless dimension stays observable. MAY
      #    carry a cap-gated `tenant_id` (sentinel when over cap).
      counter("loopctl.knowledge.hybrid_provenance.count",
        event_name: [:loopctl, :knowledge, :hybrid_provenance],
        measurement: :count,
        description:
          "Hybrid resolver (US-31.2) provenance decisions, by provenance, hit/miss, and tenant.",
        tags: [:provenance, :hit, :tenant_id],
        tag_values: &hybrid_provenance_tags/1
      ),

      # US-36.3 (review): the batch/single ingest backlog admission gate FAILED OPEN —
      # it could not measure the tenant's in-flight :ingestion backlog (count timed out /
      # lost its connection) and ADMITTED the request rather than shedding it. Makes "the
      # ingestion backpressure valve is currently admitting because it can't measure" an
      # alertable signal instead of a silent warning log. `error_class` is a bounded tag —
      # `TelemetryEvents.ingestion_backlog_gate_failed_open/0` is the source of truth for
      # its value set; `tenant_id` is cap-gated to a sentinel (same convention as the other
      # scale counters).
      counter("loopctl.ingestion.backlog_gate.failed_open.count",
        event_name: [:loopctl, :ingestion, :backlog_gate, :failed_open],
        measurement: :count,
        description:
          "Ingestion backlog admission gate could not MEASURE the backlog, sliced by outcome " <>
            "(admitted / unmetered / exhausted), error_class and tenant.",
        tags: [:error_class, :outcome, :tenant_id],
        tag_values: &backlog_gate_tags/1
      ),
      # The event is JOB-denominated as well as per-request: one 50-item batch is ONE
      # increment above but fifty jobs' worth of admission. Without this sum a burst of
      # large batches and a trickle of single-item ingests look identical on the
      # dashboard, which is the opposite of what an operator watching a wedged pool needs.
      sum("loopctl.ingestion.backlog_gate.failed_open.jobs",
        event_name: [:loopctl, :ingestion, :backlog_gate, :failed_open],
        measurement: :jobs,
        description:
          "Jobs' worth of ingestion admitted or refused while the backlog was unmeasurable, " <>
            "sliced by outcome, error_class and tenant.",
        tags: [:error_class, :outcome, :tenant_id],
        tag_values: &backlog_gate_tags/1
      ),

      # 6. Per-pool checkout queue_time (US-33.1): the RLS `Loopctl.Repo` pool (size
      #    10). Sourced from Ecto's default query event for that repo module
      #    (`[:loopctl, :repo, :query]`). `repo` is a STATIC single-value tag (not
      #    read from metadata) — the repo identity is encoded in the event name
      #    itself, so `tag_values` can never raise and needs no cap gate (AC-33.1.2).
      #    Distinct name from the existing `loopctl.repo.query.queue_time` SUMMARY in
      #    `LoopctlWeb.Telemetry.base_metrics/0` — same name + different metric type
      #    would conflict in the Prometheus reporter.
      distribution("loopctl.repo.checkout.queue_time",
        event_name: [:loopctl, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        description: "Connection-checkout wait for the RLS Repo pool, by repo.",
        tags: [:repo],
        tag_values: &queue_time_tags_repo/1,
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000]
        ]
      ),

      # 7. Per-pool checkout queue_time (US-33.1): the BYPASSRLS `Loopctl.AdminRepo`
      #    pool (size 3). Sourced from Ecto's default query event for that repo
      #    module (`[:loopctl, :admin_repo, :query]`). There was previously NO
      #    queue_time metric at all for this pool.
      distribution("loopctl.admin_repo.checkout.queue_time",
        event_name: [:loopctl, :admin_repo, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        description: "Connection-checkout wait for the AdminRepo pool, by repo.",
        tags: [:repo],
        tag_values: &queue_time_tags_admin_repo/1,
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000]
        ]
      ),

      # 8. LLM/embedding blocked counter (US-34.4, AC-34.4.1/.3). `operation` is the
      #    existing bounded 4-value enum (`Loopctl.Llm.operation()`); `provider` is the
      #    ONE bounded metadata tag this story adds at the `record_blocked/2` emit
      #    site. NEVER `tenant_id`. NOTE: this is a MISSING-BYO-KEY config gate, NOT
      #    a runtime provider-error (429/5xx/transport) signal — no such event exists
      #    today. See moduledoc "AC-34.4.3 coordination" for why US-34.3 must not
      #    window this counter as a provider-error-rate proxy.
      counter("loopctl.llm.blocked.count",
        event_name: [:loopctl, :llm, :blocked],
        measurement: :count,
        description:
          "Tenant LLM/embedding operations blocked for a missing BYO key, by operation and provider.",
        tags: [:operation, :provider],
        tag_values: &llm_blocked_tags/1
      ),

      # 9. Embedding-skipped-no-key counter (US-34.4, AC-34.4.1). `source`
      #    ("article"/"memory") is the ONE bounded metadata tag this story adds at
      #    both emit sites; the unbounded `article_id`/`memory_id` is never tagged.
      counter("loopctl.embedding.skipped_no_key.count",
        event_name: [:loopctl, :embedding, :skipped_no_key],
        measurement: :count,
        description:
          "Article/memory embedding generation skipped for a missing BYO embedding key, by source.",
        tags: [:source],
        tag_values: &embedding_skipped_tags/1
      ),

      # 10. Index-health-invalid counter (US-34.4, AC-34.4.1). `index`, `purpose`,
      #     and `state` are already three bounded, fixed sets in `Loopctl.IndexHealth`
      #     — wired as-is, no metadata change needed.
      counter("loopctl.index_health.invalid.count",
        event_name: [:loopctl, :index_health, :invalid],
        measurement: :count,
        description:
          "Index-health check results, by index, purpose, and state (valid/invalid/missing).",
        tags: [:index, :purpose, :state],
        tag_values: &index_health_tags/1
      ),

      # 11. Secret-orphan-cleanup-failed counter (US-34.4, AC-34.4.2). `reason` is
      #     CLASSIFIED into a bounded set (never the raw `{:error, term()}`, which
      #     can carry a free-text Fly API error payload) — see
      #     `secrets_orphan_cleanup_tags/1`. `secret_name` is never tagged.
      counter("loopctl.secrets.orphan_cleanup_failed.count",
        event_name: [:loopctl, :secrets, :orphan_cleanup_failed],
        measurement: :count,
        description:
          "Compensating audit-key secret delete/restore failures, by op and classified reason.",
        tags: [:op, :reason],
        tag_values: &secrets_orphan_cleanup_tags/1
      ),

      # 12. Witness-divergence counter (US-34.4, AC-34.4.2). `reason` is a genuinely
      #     fixed 2-value set (`"prefix_mismatch"`/`"future_position"`); `tenant_id`
      #     and `position` are dropped (both unbounded).
      counter("loopctl.witness.divergence.count",
        event_name: [:loopctl, :witness, :divergence],
        measurement: :count,
        description:
          "Client-reported witness-header divergence (resync, not custody halt), by reason.",
        tags: [:reason],
        tag_values: &witness_divergence_tags/1
      ),

      # 13. Witness-bootstrap-already-consumed counter (US-34.4, AC-34.4.2).
      #     UNTAGGED — the only metadata is `tenant_id`, which is never a label; the
      #     raw occurrence count is still useful trend data.
      counter("loopctl.witness.bootstrap_already_consumed.count",
        event_name: [:loopctl, :witness, :bootstrap_already_consumed],
        measurement: :count,
        description: "One-time witness bootstrap grace already consumed (412, retryable).",
        tags: []
      ),

      # 14. Memory-promotion-failed counter (US-34.4, AC-34.4.2). `stage` is a
      #     bounded 3-value enum (`:compile`/`:persist`/`:enqueue`) present on every
      #     `:failed` emission.
      counter("loopctl.memory_promotion.failed.count",
        event_name: [:loopctl, :memory_promotion, :failed],
        measurement: :count,
        description: "Memory-promotion compile/persist/enqueue failures, by stage.",
        tags: [:stage],
        tag_values: &memory_promotion_failed_tags/1
      ),

      # 15. Memory-promotion-degraded counter (US-34.4, AC-34.4.2). UNTAGGED — only
      #     per-tenant/session metadata besides the measurement, none of it bounded.
      counter("loopctl.memory_promotion.degraded.count",
        event_name: [:loopctl, :memory_promotion, :degraded],
        measurement: :count,
        description: "Memory-promotion runs snoozed for degraded (unavailable) embeddings.",
        tags: []
      ),

      # 16. Memory-promotion-quota-exceeded counter (US-34.4, AC-34.4.2). UNTAGGED.
      counter("loopctl.memory_promotion.quota_exceeded.count",
        event_name: [:loopctl, :memory_promotion, :quota_exceeded],
        measurement: :count,
        description:
          "Memory-promotion runs terminally discarded for hitting the subject memory quota.",
        tags: []
      ),

      # 17. Memory-promotion-budget-exceeded counter (US-34.4, AC-34.4.2). UNTAGGED.
      counter("loopctl.memory_promotion.budget_exceeded.count",
        event_name: [:loopctl, :memory_promotion, :budget_exceeded],
        measurement: :count,
        description:
          "Memory-promotion enqueues refused for hitting the tenant compiles/hour budget.",
        tags: []
      ),

      # 18. Oban queue/state gauge (US-34.1, AC-34.1.1). `poll_oban_queue_state/0` (a
      #     periodic measurement wired into
      #     `LoopctlWeb.Telemetry.periodic_measurements/0`) runs a single
      #     `GROUP BY state, queue` poll (restricted to the non-terminal states —
      #     review finding) against the GLOBAL `oban_jobs` table, then ZERO-FILLS the
      #     `oban_active_states/0` x `oban_queues/0` matrix (emitting `count: 0` for
      #     any pair the GROUP BY didn't return) before emitting. `last_value/2` is a
      #     Prometheus GAUGE — every poll records/overwrites the series for that
      #     `{state, queue}` pair, so a drained combination is explicitly reset to `0`
      #     instead of retaining a stale non-zero reading. Both tags are BOUNDED,
      #     FIXED sets (`oban_active_states/0`'s 5-value non-terminal state enum; the
      #     9 configured queues) — NEVER tenant/args-derived (AC-34.1.5).
      last_value("loopctl.oban.jobs.count",
        event_name: [:loopctl, :oban, :jobs, :count],
        measurement: :count,
        description: "Oban job counts by non-terminal state and queue (periodic GROUP BY poll).",
        tags: [:state, :queue],
        tag_values: &oban_queue_state_tags/1
      ),

      # 19. Oban `:executing`-older-than-N-min orphan gauge (US-34.1, AC-34.1.2).
      #     `poll_oban_executing_orphans/0` counts jobs stuck in `executing` whose
      #     `attempted_at` is older than the configured threshold (default ABOVE the
      #     Lifeline `rescue_after` window) — the signal that Lifeline is falling
      #     behind or a job is genuinely wedged (the 110-orphan / 17-day stall that
      #     motivated adding Lifeline in the first place). UNTAGGED — a single global
      #     count, never tenant-scoped.
      last_value("loopctl.oban.jobs.executing_orphan.count",
        event_name: [:loopctl, :oban, :jobs, :executing_orphan, :count],
        measurement: :count,
        description: "Oban jobs stuck in :executing older than the orphan threshold.",
        tags: []
      ),

      # 20. Periodic-measurement poll-failure counter (US-34.1, review finding). Emitted
      #     from `guarded_measurement/5` — the single guard EVERY periodic measurement
      #     runs under — so a stale (frozen) gauge above is distinguishable in Prometheus
      #     from a genuinely stable reading. `poller` identifies which measurement failed
      #     (bounded, one per entry in `periodic_measurements/0`); `error_class` is
      #     CLASSIFIED (never the raw exception message or exit reason) into a small
      #     bounded set. The `oban.` in the name predates the non-Oban measurements
      #     adopting the counter; it is kept so existing dashboards keep working.
      counter("loopctl.oban.poll.error.count",
        event_name: [:loopctl, :oban, :poll, :error],
        measurement: :count,
        description: "Periodic-measurement poll failures, by poller and classified error class.",
        tags: [:poller, :error_class],
        tag_values: &oban_poll_error_tags/1
      ),

      # 22. Article-linking corpus-size gauge (US-36.4, AC-36.4.1). Consumes the
      #     sampled `[:loopctl, :knowledge, :article_linking, :corpus_size]` event
      #     `Loopctl.Workers.ArticleLinkingWorker` emits on a deterministic ~1/N sample
      #     of linking jobs — previously an emitted-but-dead signal (no metric, no
      #     handler) whose "sampled telemetry path" delivered nothing to Prometheus. A
      #     `last_value/2` GAUGE of the corpus `:total` (the candidate count the
      #     over-limit warning compares against `article_link_max_comparisons`), tagged
      #     by a cap-gated `tenant_id` ONLY — the unbounded `article_id`/`project_id`
      #     in the event metadata are NEVER labels (AC-27.15.3).
      last_value("loopctl.knowledge.article_linking.corpus_size",
        event_name: [:loopctl, :knowledge, :article_linking, :corpus_size],
        measurement: :total,
        description:
          "Sampled article-linking candidate-corpus size (vs the comparison limit), by tenant.",
        tags: [:tenant_id],
        tag_values: &article_linking_corpus_size_tags/1
      ),

      # 23. Clustering-readiness peer gauge (US-38.3, AC-38.3.2). Fed by
      #     `poll_cluster_readiness/0` (a periodic measurement wired into
      #     `LoopctlWeb.Telemetry.periodic_measurements/0`) from
      #     `Loopctl.ClusterReadiness.readiness/0`. The measurement is the connected
      #     BEAM peer COUNT (`length(Node.list/0)`); the ONLY tag is the bounded 4-value
      #     `status` set (`:single_node`/`:clustered`/`:expected_peers_missing`/
      #     `:clustering_expected_dns_unconfigured`) — NEVER
      #     a node NAME or the DNS query string (both endpoints/ports are non-public,
      #     but the no-sensitive-data + bounded-cardinality contract AC-27.15.3 holds
      #     regardless). On a single node this reads `{status="single_node", count=0}`,
      #     the correct "clustering not required" signal rather than an error.
      last_value("loopctl.cluster.peers.count",
        event_name: [:loopctl, :cluster, :peers],
        measurement: :count,
        description:
          "Connected BEAM cluster peers (Node.list/0 length), by clustering-readiness status.",
        tags: [:status],
        tag_values: &cluster_peers_tags/1
      ),

      # 24. Egress-blocked counter (US-41.4, AC-41.4.6). The AGGREGATE blocked-rate
      #     signal that pairs with the deduplicated `egress_blocked_decisions` audit
      #     rows: the rows are bounded to one per (scope, endpoint, reason, window),
      #     so the EXACT per-call rate has to live here. Deliberately the REPLACEMENT
      #     for the provider-error signal a fail-CLOSED refusal must never feed — a
      #     `local_only` scope refusing a vendor endpoint is a configuration decision,
      #     not a provider outage, so it is exempt from the circuit breaker
      #     (`Knowledge.breaker_countable?/1`) and from
      #     `[:loopctl, :llm, :provider_error]`. Without this counter a fleet-wide
      #     misconfiguration would be invisible on the dashboards.
      #
      #     `reason` is the bounded `Loopctl.Egress.Policy.verdict()` enum
      #     (`non_local`/`denylisted`/`tenant_declared`/`network_local`/
      #     `unclassifiable`); `tenant_id` is CAP-GATED exactly like the other scale
      #     counters. The `endpoint_host` in the event metadata is deliberately NOT a
      #     label — it is tenant-supplied and therefore unbounded (AC-27.15.3). The
      #     host lives in the aggregated decision row and in `egress_posture`, where
      #     it is answerable per tenant instead of per time series.
      counter("loopctl.egress.blocked.count",
        event_name: [:loopctl, :egress, :blocked],
        measurement: :count,
        description:
          "Outbound provider calls refused by the fail-closed egress guard, by reason and tenant.",
        tags: [:reason, :tenant_id],
        tag_values: &egress_blocked_tags/1
      ),

      # 25. Boot-cache-prime-failure counter (#588). `Loopctl.SystemConfig.CachePrimer`
      #     emits `[:loopctl, :system_config, :prime_failed]` when the boot prime fails;
      #     without this definition that event terminates in a handler-less no-op (the
      #     emitted-but-dead class above), leaving ONE `Logger.error` line as the only
      #     trace of an unbounded degradation: a node that missed its prime answers
      #     `SystemConfig.get_int/2` with the caller's in-code default — for the
      #     embeddings read flag, the RETIRED legacy column — until a
      #     `SystemConfigRefreshWorker` tick happens to land on that node. A log line in
      #     the Fly stream is not alertable and is easy to miss on a rolling deploy; the
      #     counter is.
      #
      #     `error_class` is the already-CLASSIFIED string `CachePrimer.error_class/1`
      #     produces — `Loopctl.ExitClass`'s closed `"<kind>:<tag>"` set plus the
      #     `"unclassified"` catch-all — never the raw exit reason (which carries the
      #     failing statement and its bound parameters, #562) or an inspected Postgrex
      #     struct (which names the backend host, database and role). UNTAGGED by
      #     tenant: `system_configs` is a global, non-tenant table.
      counter("loopctl.system_config.prime_failed.count",
        event_name: [:loopctl, :system_config, :prime_failed],
        measurement: :count,
        description:
          "Boot-time SystemConfig cache primes that failed (node serves in-code defaults), " <>
            "by classified error class.",
        tags: [:error_class],
        tag_values: &system_config_prime_failed_tags/1
      )
    ]
  end

  @doc """
  `tag_values` for the boot-cache-prime-failure counter (#588). Passes through the
  BOUNDED `error_class` `Loopctl.SystemConfig.CachePrimer.error_class/1` already
  produced (`Loopctl.ExitClass`'s closed set, or `"unclassified"`) and NOTHING else —
  the raw reason never reaches a label. A missing key defaults to `"unknown"` so a
  direct `:telemetry.execute/3` with a partial map never emits a blank label.
  """
  @spec system_config_prime_failed_tags(map()) :: map()
  def system_config_prime_failed_tags(metadata) do
    %{error_class: Map.get(metadata, :error_class) || "unknown"}
  end

  @doc """
  `tag_values` for the egress-blocked counter (US-41.4). Emits the bounded
  `Loopctl.Egress.Policy` verdict as `reason` plus a CAP-GATED `tenant_id`. The
  tenant-supplied `endpoint_host` is never a label (unbounded cardinality); it is
  carried on the aggregated `egress_blocked_decisions` row and reported by
  `egress_posture` instead. A missing reason defaults to `"unknown"` so a direct
  `:telemetry.execute/3` with a partial map never emits a blank label.
  """
  @spec egress_blocked_tags(map()) :: map()
  def egress_blocked_tags(metadata) do
    %{reason: Map.get(metadata, :reason, "unknown"), tenant_id: gated_tenant_id(metadata)}
  end

  @doc """
  `tag_values` for the clustering-readiness peer gauge (US-38.3). Emits ONLY the
  bounded `status` label (`:single_node`/`:clustered`/`:expected_peers_missing`/
  `:clustering_expected_dns_unconfigured`) —
  NEVER a node name or the DNS query string. Defaults a missing status to `"unknown"`
  so a direct `:telemetry.execute/3` with a partial map never raises or emits blank.
  """
  @spec cluster_peers_tags(map()) :: map()
  def cluster_peers_tags(metadata) do
    %{status: Map.get(metadata, :status, "unknown")}
  end

  @doc """
  `tag_values` for the article-linking corpus-size gauge (US-36.4). Emits ONLY a
  cap-gated `tenant_id` (reusing the same `gated_tenant_id/1` sentinel-collapse as the
  other scale counters, so its cardinality is bounded identically) — the unbounded
  `article_id`/`project_id` carried in the event metadata are never tagged.
  """
  @spec article_linking_corpus_size_tags(map()) :: map()
  def article_linking_corpus_size_tags(metadata) do
    %{tenant_id: gated_tenant_id(metadata)}
  end

  @doc """
  `tag_values` for the semantic-fallback counter (#297). Emits ONLY the bounded
  `reason` label (never `tenant_id` — the reason set is fixed and small, so no cap
  gate is needed). Defaults a missing reason to `"unknown"` so the label is never
  blank.
  """
  @spec semantic_fallback_tags(map()) :: map()
  def semantic_fallback_tags(metadata) do
    %{reason: Map.get(metadata, :reason, "unknown")}
  end

  @doc """
  `tag_values` for the hybrid-provenance counter (US-31.2). `provenance` and `hit` are
  small, fixed-cardinality dimensions (2 values each) so they need no cap gate;
  `tenant_id` reuses the SAME cap-gated sentinel collapse as the other two counters
  (`gated_tenant_id/1`) to keep its cardinality bounded identically.
  """
  @spec hybrid_provenance_tags(map()) :: map()
  def hybrid_provenance_tags(metadata) do
    %{
      provenance: Map.get(metadata, :provenance, "unknown"),
      hit: Map.get(metadata, :hit, false),
      tenant_id: gated_tenant_id(metadata)
    }
  end

  @doc """
  `tag_values` for the two DEGRADED-READ counters — the ingestion backlog gate fail-open
  (US-36.3 review) and the under-fill probe degradation — which share the same
  `(error_class, tenant_id)` shape.

  `error_class` is a small fixed-cardinality tag, defaulting to `"unknown"`. Its value set
  is NOT enumerated here — it is per-emitter, and enumerating it twice is how this doc came
  to claim a "2-value" tag long after a fourth value shipped: see
  `Loopctl.TelemetryEvents.ingestion_backlog_gate_failed_open/0` and
  `vector_search_under_fill_probe_degraded/0`, which document their own bounded sets.
  `tenant_id` reuses the same cap-gated sentinel collapse as the other scale counters to
  keep cardinality bounded.
  """
  @spec degraded_read_tags(map()) :: map()
  def degraded_read_tags(metadata) do
    %{
      error_class: Map.get(metadata, :error_class, "unknown"),
      tenant_id: gated_tenant_id(metadata)
    }
  end

  @doc """
  `tag_values` for the ingestion backlog-gate counters ONLY.

  Deliberately NOT an extension of `degraded_read_tags/1`: the under-fill probe shares that
  function and has no `:outcome`, so widening it would add a permanently-`admitted` label to
  an unrelated series.

  `:outcome` exists because the gate's event now fires on EVERY unmeasurable-count outcome,
  not just the admitting one. Without the label a REFUSAL increments the same counter as an
  admission, so the series would over-report admissions during precisely the sustained
  incident an operator alerts on — the failure the refusal-branch emit was added to prevent,
  reintroduced one layer up. It defaults to `:admitted` so the pre-existing series keeps its
  meaning for any emitter that has not been updated.

  Bounded at three values (`:admitted | :unmetered | :exhausted`);
  `Loopctl.TelemetryEvents.ingestion_backlog_gate_failed_open/0` is the source of truth.
  """
  @spec backlog_gate_tags(map()) :: map()
  def backlog_gate_tags(metadata) do
    %{
      error_class: Map.get(metadata, :error_class, "unknown"),
      outcome: Map.get(metadata, :outcome, :admitted),
      tenant_id: gated_tenant_id(metadata)
    }
  end

  @doc """
  `tag_values` for the two COUNTERS.

  Always returns the full fixed label set so the Prometheus series shape is stable:

    * `:endpoint` — `metadata.endpoint` (a bounded controller.action / endpoint atom),
      defaulting to `:unknown`.
    * `:mapped_code` — `metadata.mapped_code` for the DB-error counter (defaulting to
      `"unknown"`); the under-fill event has none, so this key is simply absent from
      that counter's `:tags` and ignored.
    * `:tenant_id` — `metadata.tenant_id` ONLY when the cap gate is ON; otherwise the
      `#{inspect(@aggregated_sentinel)}` sentinel (cardinality 1). A missing/`nil`
      tenant_id also collapses to the sentinel so the label is never blank.
  """
  @spec scale_tags(map()) :: map()
  def scale_tags(metadata) do
    %{
      endpoint: Map.get(metadata, :endpoint, :unknown),
      mapped_code: Map.get(metadata, :mapped_code, "unknown"),
      tenant_id: gated_tenant_id(metadata)
    }
  end

  @doc """
  `tag_values` for the latency DISTRIBUTION. Endpoint ONLY — NEVER tenant_id
  (AC-27.15.3: tenant on a histogram multiplies by every bucket). `endpoint` comes
  from `metadata.options[:endpoint]` (set by `Loopctl.HeavyRead.opts/1`), defaulting
  to `:unknown` for any heavy-pool query issued without an endpoint tag.
  """
  @spec latency_tags(map()) :: map()
  def latency_tags(metadata) do
    options = Map.get(metadata, :options) || []
    %{endpoint: Keyword.get(options, :endpoint, :unknown)}
  end

  @doc """
  `tag_values` for the RLS `Loopctl.Repo` checkout `queue_time` distribution
  (US-33.1). Returns a FIXED, static `%{repo: "repo"}` map — the repo identity is
  already encoded in the event name (`[:loopctl, :repo, :query]`), so this ignores
  `metadata` entirely and cannot raise regardless of what Ecto passes (AC-33.1.4).
  """
  @spec queue_time_tags_repo(map()) :: map()
  def queue_time_tags_repo(_metadata), do: %{repo: "repo"}

  @doc """
  `tag_values` for the `Loopctl.AdminRepo` checkout `queue_time` distribution
  (US-33.1). Returns a FIXED, static `%{repo: "admin_repo"}` map for the same
  reason as `queue_time_tags_repo/1` — the event name already identifies the pool.
  """
  @spec queue_time_tags_admin_repo(map()) :: map()
  def queue_time_tags_admin_repo(_metadata), do: %{repo: "admin_repo"}

  @doc """
  `tag_values` for the LLM/embedding blocked counter (US-34.4). Returns ONLY
  `operation` (`Loopctl.Llm`'s existing bounded 4-value enum) and `provider`
  (the ONE bounded metadata tag this story adds at the `Loopctl.Llm.record_blocked/2`
  emit site) — NEVER `tenant_id`, even if one leaks into metadata. Both default to
  `"unknown"` so a direct `:telemetry.execute/3` missing either key (e.g. TC-34.4.1)
  never raises and never emits a blank label.
  """
  @spec llm_blocked_tags(map()) :: map()
  def llm_blocked_tags(metadata) do
    %{
      operation: Map.get(metadata, :operation) || "unknown",
      provider: Map.get(metadata, :provider) || "unknown"
    }
  end

  @doc """
  `tag_values` for the embedding-skipped-no-key counter (US-34.4). Returns ONLY the
  bounded `source` label (`"article"`/`"memory"`, the ONE bounded metadata tag this
  story adds at both emit sites) — NEVER the unbounded `article_id`/`memory_id`,
  and NEVER `tenant_id`. Defaults a missing `source` to `"unknown"`.
  """
  @spec embedding_skipped_tags(map()) :: map()
  def embedding_skipped_tags(metadata) do
    %{source: Map.get(metadata, :source) || "unknown"}
  end

  @doc """
  `tag_values` for the index-health-invalid counter (US-34.4). `index`, `purpose`,
  and `state` are already three bounded, fixed sets in `Loopctl.IndexHealth` — this
  is wired as-is (no metadata change), defaulting any missing key to `"unknown"`.
  """
  @spec index_health_tags(map()) :: map()
  def index_health_tags(metadata) do
    %{
      index: Map.get(metadata, :index) || "unknown",
      purpose: Map.get(metadata, :purpose) || "unknown",
      state: Map.get(metadata, :state) || "unknown"
    }
  end

  @doc """
  `tag_values` for the secret-orphan-cleanup-failed counter (US-34.4). `op` is
  normalized to the bounded `:delete`/`:restore` set. `reason` is CLASSIFIED (never
  passed through raw) — `Loopctl.Secrets.Behaviour`'s `{:error, term()}` can carry a
  free-text Fly GraphQL error payload (`{:fly_api_error, errors}`) or an arbitrary
  transport-error struct, so `secrets_reason_class/1` collapses anything outside
  the known bounded shapes to `"other"` rather than ever emitting raw error content
  as a label (the same "mapped_code" classification precedent as the DB-error
  counter). `secret_name` is never tagged (unbounded).
  """
  @spec secrets_orphan_cleanup_tags(map()) :: map()
  def secrets_orphan_cleanup_tags(metadata) do
    %{
      op: normalize_secrets_op(Map.get(metadata, :op)),
      reason: secrets_reason_class(Map.get(metadata, :reason))
    }
  end

  defp normalize_secrets_op(op) when op in [:delete, :restore], do: op
  defp normalize_secrets_op(_other), do: :unknown

  defp secrets_reason_class(:fly_not_configured), do: "fly_not_configured"
  defp secrets_reason_class(:old_value_unavailable), do: "old_value_unavailable"
  defp secrets_reason_class({:http_error, _status}), do: "http_error"
  defp secrets_reason_class({:fly_api_error, _errors}), do: "fly_api_error"
  defp secrets_reason_class(nil), do: "unknown"
  defp secrets_reason_class(_other), do: "other"

  @doc """
  `tag_values` for the witness-divergence counter (US-34.4). Returns ONLY the
  bounded `reason` label (`"prefix_mismatch"`/`"future_position"`, a genuinely
  fixed 2-value set) — NEVER `tenant_id`/`position` (both unbounded). Defaults a
  missing reason to `"unknown"`.
  """
  @spec witness_divergence_tags(map()) :: map()
  def witness_divergence_tags(metadata) do
    %{reason: Map.get(metadata, :reason) || "unknown"}
  end

  @doc """
  `tag_values` for the memory-promotion-failed counter (US-34.4). Returns ONLY the
  bounded `stage` label (`:compile`/`:persist`/`:enqueue`, present on every
  `:failed` emission) — NEVER `tenant_id`/`subject_id`/`session_id`. Defaults a
  missing stage to `"unknown"`.
  """
  @spec memory_promotion_failed_tags(map()) :: map()
  def memory_promotion_failed_tags(metadata) do
    %{stage: Map.get(metadata, :stage) || "unknown"}
  end

  @doc """
  `tag_values` for the Oban queue/state gauge (US-34.1). Both `state` and `queue`
  are bounded, fixed sets sourced directly from the poller's GROUP BY row — NEVER
  derived from job `args`/tenant. Defaults a missing key to `"unknown"` so this can
  never raise even when invoked directly with a partial map.
  """
  @spec oban_queue_state_tags(map()) :: map()
  def oban_queue_state_tags(metadata) do
    %{
      state: Map.get(metadata, :state, "unknown"),
      queue: Map.get(metadata, :queue, "unknown")
    }
  end

  @doc """
  The fixed, bounded set of ALL Oban job states (`Oban.Job.states/0` — 8 values,
  including the terminal `:completed`/`:discarded`/`:cancelled`). This is a
  documentation/reference enum — the LIVE poll/zero-fill matrix uses the
  narrower `oban_active_states/0` (review finding), NOT this function.
  """
  @spec oban_states() :: [atom()]
  def oban_states, do: Oban.Job.states()

  @doc """
  The NON-TERMINAL Oban job states (`oban_states/0` minus `:completed`,
  `:discarded`, `:cancelled` — 5 values: `:suspended`, `:scheduled`, `:available`,
  `:executing`, `:retryable`) — the set `poll_oban_queue_state/0` actually queries
  and zero-fills (US-34.1, review finding).

  Restricting to these states keeps the poll on the cheap `Index Only Scan` path
  over `oban_jobs_state_queue_priority_scheduled_at_id_index` (Oban's own
  `(state, queue, priority, scheduled_at, id)` index) regardless of how large the
  terminal-state partitions grow under the pruner's 7-day retention — a bare
  `GROUP BY state, queue` over ALL 8 states forces a full `Seq Scan` once the
  terminal partitions dominate the table (verified via `EXPLAIN` on production
  scale data), which at scale exceeds the poll's own `SET LOCAL statement_timeout`.
  """
  @spec oban_active_states() :: [atom()]
  def oban_active_states, do: oban_states() -- @oban_terminal_states

  @doc """
  The fixed, bounded set of configured Oban queue names, resolved at CALL time
  via `Application.get_env/2` (never `Application.compile_env/2` — queue WIDTHS
  are env-tunable at runtime per `Loopctl.ObanConfig`/`config/runtime.exs`, but
  the set of queue NAMES itself is static across every environment). Used
  together with `oban_active_states/0` to zero-fill the per-`{state, queue}`
  gauge — this also structurally bounds the `:queue` label to the configured
  set, so an unconfigured/ad-hoc queue name can never appear as a Prometheus
  series (US-34.1, AC-34.1.1/.5).

  Defensive against a malformed `:queues` shape (review finding): Oban documents
  `queues: false` as a valid option to disable all queues, and `Keyword.keys/1`
  raises `FunctionClauseError` on a non-list. Rather than let that propagate,
  any non-list `:queues` value (including `false`) resolves to an empty queue
  set — a zero-queue poll, not a crash.
  """
  @spec oban_queues() :: [atom()]
  def oban_queues do
    :loopctl
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> queues_from_config()
  end

  @doc """
  Pure helper for `oban_queues/0`'s defensive shape guard (review finding),
  exposed directly so the `queues: false` case is testable WITHOUT mutating the
  global `:loopctl, Oban` application config. A list `:queues` keyword resolves
  to its keys as usual; anything else (notably the documented `queues: false`
  option, which `Keyword.keys/1` would raise `FunctionClauseError` on) resolves
  to an empty queue set instead of raising.
  """
  @spec queues_from_config(term()) :: [atom()]
  def queues_from_config(queues) when is_list(queues), do: Keyword.keys(queues)
  def queues_from_config(_other), do: []

  @doc """
  Polls `oban_jobs` for per-`{state, queue}` counts, restricted to the
  non-terminal states (`oban_active_states/0` — review finding), and emits one
  ZERO-FILLED telemetry measurement for every pair in the
  `oban_active_states/0` x `oban_queues/0` matrix (US-34.1, AC-34.1.1).

  This is a `telemetry_poller` periodic measurement (wired in
  `LoopctlWeb.Telemetry.periodic_measurements/0`, the SAME shared process that
  refreshes the tenant-label gate every 10s). It runs a SINGLE lightweight
  `SELECT state, queue, count(*) FROM oban_jobs WHERE state = ANY($1) GROUP BY
  state, queue` against `Loopctl.Repo` (raw SQL — `oban_jobs` is a GLOBAL table
  with no `tenant_id` column, so `Loopctl.HeavyRead` would structurally reject
  it; follows the `Loopctl.IndexHealth` raw-SQL precedent). `Loopctl.Repo` (pool
  size 10), not `Loopctl.AdminRepo` (pool size 3, the app's smallest), is used
  deliberately (review finding) — `oban_jobs` has no RLS policy
  (`relrowsecurity = false`, verified live), so RLS enforcement is a non-issue
  either way, and a recurring 10s poll should land on the larger pool. Wrapped in
  a transaction that first issues a per-query `SET LOCAL statement_timeout`
  (`:oban_metrics_poll_statement_timeout_ms`, default
  #{@default_oban_metrics_poll_timeout_ms}ms, validated positive-integer at read
  time before interpolation) so a slow poll can never itself saturate the pool
  (AC-34.1.3).

  A `GROUP BY count(*)` can only ever return rows with count >= 1 — it never
  returns a row for a `{state, queue}` pair with zero jobs. So the returned rows
  are folded into a lookup map, then EVERY pair in `oban_active_states/0` x
  `oban_queues/0` is emitted, substituting `count: 0` for any pair absent from
  that lookup. Without this, a `last_value/2` gauge (which has no expiry — it
  just overwrites its ETS entry, `TelemetryMetricsPrometheus.Core.LastValue`)
  would retain a drained pair's last non-zero reading forever, indistinguishable
  from a genuinely-stuck backlog.

  Defensive: `rescue`s ANY exception (review finding — broadened from a narrow
  DB-fault-only rescue, since `telemetry_poller` permanently drops a raising
  measurement from its rotation rather than crashing — see the moduledoc
  section above), logs a warning, EMITS the poll-failure counter (metric 20),
  and returns `:ok` without emitting the state/queue gauge. On a FAILED poll (as
  opposed to a successful poll that finds zero rows), no zero-fill happens
  either — the gauge intentionally keeps its last-recorded value until the next
  successful poll, since a failed query has no fresher truth to report, and the
  poll-failure counter makes that staleness observable. Always returns `:ok`.
  """
  @spec poll_oban_queue_state() :: :ok
  def poll_oban_queue_state do
    guarded_measurement(
      :queue_state,
      "Oban queue/state poll",
      "the oban.jobs.count gauge simply keeps its last-recorded value until the next poll",
      :ok,
      &collect_oban_queue_state/0
    )
  end

  defp collect_oban_queue_state do
    timeout_ms = oban_metrics_poll_statement_timeout_ms()
    active_states = Enum.map(oban_active_states(), &Atom.to_string/1)

    {:ok, rows} =
      LocalGuc.timed_transaction(Repo, timeout_ms, fn ->
        %{rows: rows} =
          Repo.query!(
            "SELECT state, queue, count(*) FROM oban_jobs WHERE state = ANY($1) GROUP BY state, queue",
            [active_states]
          )

        rows
      end)

    counts = Map.new(rows, fn [state, queue, count] -> {{state, queue}, count} end)

    for state <- oban_active_states(), queue <- oban_queues() do
      state_str = Atom.to_string(state)
      queue_str = Atom.to_string(queue)
      count = Map.get(counts, {state_str, queue_str}, 0)

      :telemetry.execute([:loopctl, :oban, :jobs, :count], %{count: count}, %{
        state: state_str,
        queue: queue_str
      })
    end

    :ok
  end

  @doc """
  Counts `oban_jobs` rows stuck in state `executing` whose `attempted_at` is older
  than the configured orphan AGE threshold (`oban_metrics_orphan_threshold_minutes/0`).

  Extracted from `poll_oban_executing_orphans/0` (US-34.2, AC-34.2.3) originally so
  `Loopctl.HealthCheck.Default`'s `check_oban_orphans/0` health sub-check could
  reuse the EXACT same bounded, tz-correct query rather than duplicating it.

  Post-review (US-34.2, request-amplification finding): the health check no longer
  calls this directly on every `/health`/`/health/ready` hit — it reads
  `cached_executing_orphan_count/0`'s `:persistent_term` cache instead (populated
  by `poll_oban_executing_orphans/0` below, unchanged 10s cadence), so this
  function's only remaining caller in dev/prod is the poller. It stays public and
  directly callable (unchanged signature/behavior) because
  `test/support/data_case.ex`'s default Mox stub for
  `Loopctl.MockObanOrphanCountChecker.cached_executing_orphan_count/0` deliberately
  calls THIS fresh-query function rather than the shared `:persistent_term` cache —
  reading the true global cache from every async `DataCase` test would leak state
  across concurrently running tests (the cache is one VM-wide slot, not
  per-sandboxed-transaction); calling this function fresh keeps each test scoped to
  its own sandboxed connection, exactly like every other health sub-check's default
  stub.

  Deliberately does NOT rescue here: `poll_oban_executing_orphans/0` keeps its own
  catch-all rescue around this call (US-34.1 behavior, unchanged). `statement_timeout`
  (set via `SET LOCAL` below) only bounds the query AFTER a connection is checked
  out — under pool pressure the checkout wait itself would fall back to the Ecto
  pool's default (~15s). The `:timeout` option below bounds `Repo.transaction/2`'s
  checkout-and-run the same way `check_database/0` bounds its own call with an
  explicit `timeout: 5_000`.
  """
  @spec count_oban_executing_orphans() :: non_neg_integer()
  def count_oban_executing_orphans do
    timeout_ms = oban_metrics_poll_statement_timeout_ms()
    threshold_minutes = oban_metrics_orphan_threshold_minutes()

    # `:timeout` bounds this transaction's checkout-and-run the same way
    # `check_database/0` bounds its `SQL.query/4` call with `timeout: 5_000` — see
    # the moduledoc above. `statement_timeout` (SET LOCAL below) only bounds the
    # query itself, AFTER a connection is already checked out.
    {:ok, count} =
      LocalGuc.timed_transaction(
        Repo,
        timeout_ms,
        fn ->
          # `attempted_at` is a `timestamp without time zone` column populated by
          # Ecto's `:utc_datetime_usec` dump — i.e. it holds a UTC wall-clock reading
          # with no tz attached. `now()` is `timestamptz`; comparing it directly
          # against a naive column implicitly casts `now()` using the CONNECTION's
          # `TimeZone` GUC (e.g. Fly Postgres defaults can be non-UTC), which skews
          # the comparison by that offset. `now() AT TIME ZONE 'UTC'` converts to a
          # naive UTC wall-clock timestamp first, matching what's actually stored.
          %{rows: [[count]]} =
            Repo.query!(
              """
              SELECT count(*)
              FROM oban_jobs
              WHERE state = 'executing'
                AND attempted_at < (now() AT TIME ZONE 'UTC') - ($1 * interval '1 minute')
              """,
              [threshold_minutes]
            )

          count
        end,
        timeout: 5_000
      )

    count
  end

  @doc """
  Reads the `:executing`-orphan count that `poll_oban_executing_orphans/0` cached
  in `:persistent_term` on its last SUCCESSFUL poll (US-34.2 review finding).

  `Loopctl.HealthCheck.Default.check_oban_orphans/0` calls this (via the
  `Loopctl.Telemetry.ScaleMetrics.OrphanCountBehaviour` DI seam) instead of
  `count_oban_executing_orphans/0` directly — the health check backs BOTH the
  continuous, unauthenticated `/health` liveness probe and `/health/ready`, so
  issuing a fresh `Repo.transaction` + `SELECT count(*)` on every hit is
  unwarranted request-amplification pressure on the Ecto pool; reading a cache
  the poller already refreshes every 10s (`telemetry_poller`'s `period: 10_000`)
  costs a lock-free `:persistent_term.get/2` instead.

  Returns `{:ok, count}` once at least one poll has completed, or
  `:not_yet_polled` in the brief window between app boot and the poller's first
  tick — `telemetry_poller`'s `init_delay: 0` schedules that first collection
  essentially immediately (not after the full 10s period), so this window is
  sub-second in practice, not a sustained gap.

  Never touches the database itself. A FAILED poll intentionally leaves the
  prior cached value in place (identical staleness semantics to the
  `last_value/2` Prometheus gauge this same count also feeds) — the cache is
  never reset to a false "no orphans" reading just because a poll cycle failed.

  Implements the `Loopctl.Telemetry.ScaleMetrics.OrphanCountBehaviour` callback.
  """
  @impl true
  @spec cached_executing_orphan_count() :: {:ok, non_neg_integer()} | :not_yet_polled
  def cached_executing_orphan_count do
    case :persistent_term.get(@executing_orphan_cache_key, :not_yet_polled) do
      :not_yet_polled -> :not_yet_polled
      count when is_integer(count) -> {:ok, count}
    end
  end

  @spec poll_oban_executing_orphans() :: :ok
  def poll_oban_executing_orphans do
    guarded_measurement(
      :executing_orphans,
      "Oban executing-orphan poll",
      "the executing_orphan gauge AND the health-check cache simply keep their last-recorded " <>
        "value until the next successful poll",
      :ok,
      fn ->
        count = count_oban_executing_orphans()

        :persistent_term.put(@executing_orphan_cache_key, count)

        :telemetry.execute(
          [:loopctl, :oban, :jobs, :executing_orphan, :count],
          %{count: count},
          %{}
        )

        :ok
      end
    )
  end

  @doc """
  Periodic measurement (US-38.3, AC-38.3.2) feeding the `loopctl.cluster.peers.count`
  gauge (metric 23). Reads `Loopctl.ClusterReadiness.readiness/0` and emits the
  connected BEAM peer COUNT with the bounded readiness `status` as the sole tag —
  NEVER a node name or the DNS query string. Wired into
  `LoopctlWeb.Telemetry.periodic_measurements/0` (the same 10s poller as the Oban
  gauges). Runs under `guarded_measurement/5` like every other periodic measurement,
  so neither a raise nor an exit/throw can let `telemetry_poller` permanently drop
  this MFA, and a failed cycle increments the poll-failure counter (metric 20,
  `poller="cluster_readiness"`) instead of freezing this gauge silently.
  `ClusterReadiness.readiness/0` makes no inter-process call today (env reads,
  `Node.list/0`, pure classification), so only its RAISE path is reachable — the
  exit/throw half is the uniform guard, not a claim that a readiness process exists
  to die. On a single node it reads `{status="single_node", count=0}`.
  """
  @spec poll_cluster_readiness() :: :ok
  def poll_cluster_readiness do
    guarded_measurement(
      :cluster_readiness,
      "Clustering-readiness poll",
      "the cluster.peers gauge keeps its last-recorded value until the next successful poll",
      :ok,
      fn ->
        readiness = Loopctl.ClusterReadiness.readiness()

        :telemetry.execute([:loopctl, :cluster, :peers], %{count: readiness.peers}, %{
          status: readiness.status
        })

        :ok
      end
    )
  end

  @doc false
  # Runs a periodic measurement's body under the guard `telemetry_poller` requires, and
  # returns `fallback` if it fails.
  #
  # ONE implementation for all four measurements (`LoopctlWeb.Telemetry.periodic_measurements/0`):
  # telemetry_poller PERMANENTLY drops a measurement MFA that escapes, so an unguarded gauge
  # goes dark for the life of the node — and it drops it on ALL THREE non-local exit kinds,
  # which is why this catches `:exit` and `:throw` alongside the catch-all `rescue` (a pool
  # checkout against a saturated/wedged pool EXITS rather than raising; four hand-written
  # copies of that guard had already diverged). Every failure also emits the poll-failure
  # counter (metric 20), so a frozen gauge stays distinguishable from a genuinely stable one.
  #
  # Public-but-`@doc false`: not API, but the seam that lets the guard be tested ONCE,
  # directly, with a body that exits/throws — no poller can be made to exit on demand through
  # Ecto (which raises on every lookup/ownership failure), which is how four copies of this
  # shipped unexercised.
  @spec guarded_measurement(atom(), String.t(), String.t(), term(), (-> term())) :: term()
  def guarded_measurement(poller, subject, consequence, fallback, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("#{subject} failed (#{inspect(e.__struct__)}); #{consequence}")

      emit_poll_error(poller, e)

      fallback
  catch
    kind, reason when kind in [:exit, :throw] ->
      tag = ExitTag.tag(reason)

      Logger.warning("#{subject} aborted (#{kind}: #{tag}); #{consequence}")

      emit_poll_error(poller, {kind, tag})

      fallback
  end

  # Emits the poll-failure counter (metric 20) from `guarded_measurement/5`.
  # `metadata.exception` is a UNION: the RAW exception struct on the rescue path (like
  # `secrets_orphan_cleanup_tags/1`'s raw `{:error, term()}`, so another attached handler
  # still sees the real error), or `{:exit | :throw, bounded_tag}` on the catch path — an
  # exit is not an exception, and its raw reason carries the whole DBConnection call tuple,
  # module and args, so only `ExitTag.tag/1`'s bounded class travels. A consumer must NOT
  # assume a struct. Classification into the bounded `error_class` tag happens at
  # `tag_values` time (`oban_poll_error_tags/1`), never here.
  defp emit_poll_error(poller, exception) do
    :telemetry.execute([:loopctl, :oban, :poll, :error], %{count: 1}, %{
      poller: poller,
      exception: exception
    })
  end

  @doc """
  `tag_values` for the periodic-measurement poll-failure counter (US-34.1, metric 20).
  `poller` passes through as a bounded atom (one per measurement in
  `LoopctlWeb.Telemetry.periodic_measurements/0`: `:queue_state`/`:executing_orphans`/
  `:cluster_readiness`/`:tenant_label_gate`);
  `error_class` CLASSIFIES `metadata.exception` into a small bounded set
  (never the raw exception message/struct) — the same "mapped_code"/
  `secrets_reason_class/1` classification precedent used elsewhere in this
  module. Defaults missing keys to `"unknown"` so this can never raise.
  """
  @spec oban_poll_error_tags(map()) :: map()
  def oban_poll_error_tags(metadata) do
    %{
      poller: Map.get(metadata, :poller) || "unknown",
      error_class: oban_poll_error_class(Map.get(metadata, :exception))
    }
  end

  defp oban_poll_error_class(%Postgrex.Error{}), do: "db_error"

  # A LocalGuc capture abort must be classified BEFORE the generic ConnectionError clause
  # below: it is raised as a `DBConnection.ConnectionError` (deliberately — see
  # `LocalGuc.capture_fallback!/2`), so without this branch it lands as `"db_error"` and
  # reads as a pool fault. It is not one: it is this poller declining to override a GUC an
  # enclosing scope owns, which is a correctness-preserving refusal with a completely
  # different remedy. Reachability, precisely: `capture_fallback!/2` aborts only when an
  # ENCLOSING scope in the SAME process already owns the name, and each poller opens the
  # OUTERMOST `LocalGuc.timed_transaction/3` on the shared poller process — so no poller can
  # abort today. The branch exists for uniform classification with the three sites that DO
  # discriminate it, and to keep a future nested caller out of the `"db_error"` bucket, not
  # because these two pollers can reach it. Matches those three sites —
  # `Loopctl.Knowledge`, `LoopctlWeb.KnowledgeIngestionController` and
  # `Loopctl.Workers.ArticleLinkingWorker` — on the same `"guc_capture_abort"` tag.
  defp oban_poll_error_class(%DBConnection.ConnectionError{} = e) do
    if LocalGuc.capture_abort?(e), do: "guc_capture_abort", else: "db_error"
  end

  defp oban_poll_error_class(%DBConnection.OwnershipError{}), do: "db_error"
  defp oban_poll_error_class(%ArgumentError{}), do: "config_error"
  defp oban_poll_error_class(%FunctionClauseError{}), do: "config_error"
  # An EXIT/THROW is not an exception, so it can never be a struct above:
  # `guarded_measurement/5` hands it over wrapped as `{kind, bounded_tag}`. Its own class
  # because a pool checkout that exits has a different remedy from one that raises.
  #
  # #558: routed through `ExitClass.bounded/2` so the label reads `exit:noproc`, matching the
  # ingest-gate and under-fill-probe counters. It previously emitted a bare `"exit"`, which
  # made three coexisting encodings of one concept across three counters — an operator
  # correlating them had to know which series used which spelling, and the bare form threw
  # away the discriminator (`noproc` vs `timeout`) that decides where to look.
  defp oban_poll_error_class({kind, tag}) when kind in [:exit, :throw] and is_binary(tag),
    do: ExitClass.bounded(kind, tag)

  defp oban_poll_error_class({kind, reason}) when kind in [:exit, :throw],
    do: ExitClass.classify(kind, reason)

  defp oban_poll_error_class(nil), do: "unknown"
  defp oban_poll_error_class(_other), do: "other"

  @doc """
  The configured per-poll `SET LOCAL statement_timeout` (ms) for the two Oban
  pollers above (`:oban_metrics_poll_statement_timeout_ms`, default
  #{@default_oban_metrics_poll_timeout_ms}). Validated to be a POSITIVE INTEGER
  at read time (review finding) — this value is interpolated directly into a raw
  SQL string (Postgres's `SET` cannot take a bound parameter), the same guard
  `Loopctl.HeavyRead.transaction/2` applies before its identical interpolation.
  Raises `ArgumentError` on an invalid config override rather than silently
  building malformed SQL.
  """
  @spec oban_metrics_poll_statement_timeout_ms() :: pos_integer()
  def oban_metrics_poll_statement_timeout_ms do
    :loopctl
    |> Application.get_env(
      :oban_metrics_poll_statement_timeout_ms,
      @default_oban_metrics_poll_timeout_ms
    )
    |> validate_positive_poll_timeout!()
  end

  @doc """
  Pure validation helper for `oban_metrics_poll_statement_timeout_ms/0` (review
  finding), exposed directly so the invalid-config-value case is testable
  WITHOUT mutating the global `:loopctl, :oban_metrics_poll_statement_timeout_ms`
  application config. Raises `ArgumentError` on anything that is not a positive
  integer — this value is interpolated directly into a raw SQL string (Postgres's
  `SET` cannot take a bound parameter), the same guard
  `Loopctl.HeavyRead.transaction/2` applies before its identical interpolation.
  """
  @spec validate_positive_poll_timeout!(term()) :: pos_integer()
  def validate_positive_poll_timeout!(ms) when is_integer(ms) and ms > 0, do: ms

  def validate_positive_poll_timeout!(other) do
    raise ArgumentError,
          ":oban_metrics_poll_statement_timeout_ms (got #{inspect(other)}) must be a " <>
            "positive integer (ms) — it is interpolated directly into a raw SQL " <>
            "SET LOCAL statement_timeout statement"
  end

  @doc """
  The configured `:executing`-orphan age threshold, in minutes
  (`:oban_metrics_orphan_threshold_minutes`, default
  #{@default_oban_metrics_orphan_threshold_minutes} — above the Lifeline
  `rescue_after` window).
  """
  @spec oban_metrics_orphan_threshold_minutes() :: pos_integer()
  def oban_metrics_orphan_threshold_minutes do
    Application.get_env(
      :loopctl,
      :oban_metrics_orphan_threshold_minutes,
      @default_oban_metrics_orphan_threshold_minutes
    )
  end

  # The cap gate read on the hot path: a lock-free O(1) persistent_term lookup,
  # defaulting to `false` (aggregate) if unseeded — an un-warmed boot can never emit
  # an unbounded tenant label.
  defp gated_tenant_id(metadata) do
    if tenant_label?() do
      case Map.get(metadata, :tenant_id) do
        nil -> @aggregated_sentinel
        tenant_id -> tenant_id
      end
    else
      @aggregated_sentinel
    end
  end

  @doc """
  Whether the `tenant_id` counter label is currently allowed (tenant count ≤ cap).

  Reads the boolean from `:persistent_term`, defaulting to `false` (drop/aggregate)
  when unseeded — so the safe, bounded behavior holds before the first poll.
  """
  @spec tenant_label?() :: boolean()
  def tenant_label? do
    :persistent_term.get(@persistent_term_key, false)
  end

  @doc """
  Recomputes the tenant-label cap gate and caches it in `:persistent_term`.

  This is the `telemetry_poller` periodic measurement (wired in
  `LoopctlWeb.Telemetry`). It performs the ONLY DB read in the gating mechanism — one
  cheap `Tenants.count()` per poll interval — so the per-emit `tag_values` path never
  touches the DB. A failed count is fail-soft: the gate holds its current value for ONE
  cycle and is forced OFF (aggregate to the sentinel) from the second CONSECUTIVE failure
  on, rather than crashing the poller — bounded cardinality without flapping the gate
  (and the label) every 10s through an intermittent pool incident. Returns the boolean it
  stored.

  Note: this returns the gate boolean rather than calling `:telemetry.execute/3`
  itself — the poller only needs the side effect of refreshing the cached gate, and
  no metric is derived from a `[:loopctl, :telemetry, :tenant_label_gate]` event.
  """
  @spec refresh_tenant_label_gate() :: boolean()
  def refresh_tenant_label_gate do
    # Fail-soft for EVERY failure shape — this is a `telemetry_poller` measurement, and
    # telemetry_poller PERMANENTLY drops an MFA that escapes. A narrow rescue (DB exceptions
    # only, everything else re-raised) did not surface a programmer error here: it froze the
    # gate at whatever boolean `:persistent_term` last held, with nothing left to re-evaluate
    # it. If that value was `true`, `tenant_id` stays a live label after the fleet crosses the
    # cap — the unbounded cardinality AC-27.15.3 forbids. Visibility comes from the :warning
    # log and metric 20, not from crashing the poller.
    allowed? =
      :tenant_label_gate
      |> guarded_measurement(
        "tenant-label gate refresh",
        "holding the gate for one cycle, then forcing it OFF (tenant_id label aggregates to " <>
          "the sentinel until the count succeeds)",
        :failed,
        fn -> Tenants.count() <= tenant_label_cap() end
      )
      |> resolve_gate()

    # Put ONLY on an actual transition (team review F3). `:persistent_term.put/2` triggers
    # a global term-table scan, so writing the unchanged steady-state value every 10s is
    # wasteful; the gate is stable once a fleet settles above/below the cap, so this makes
    # the steady-state cost zero puts and writes only on a real gate flip.
    if :persistent_term.get(@persistent_term_key, :unset) != allowed? do
      :persistent_term.put(@persistent_term_key, allowed?)
    end

    allowed?
  end

  # One GRACE cycle before a failed count flips the gate (review finding): an intermittently
  # wedged pool otherwise alternates OFF/ON every 10s, and each flip pays the global
  # `:persistent_term.put/2` term-table scan the transition check above exists to avoid —
  # during the incident when the node can least afford it, while every per-tenant series
  # alternates between the real `tenant_id` and the sentinel and gaps the dashboards. TWO
  # CONSECUTIVE failures still force the gate OFF, so a persistently-failing count can never
  # leave an unbounded label live (AC-27.15.3). The streak lives in the poller PROCESS's
  # dictionary — this measurement always runs in the single `telemetry_poller` process, so it
  # costs no global write and needs no extra term.
  defp resolve_gate(:failed) do
    if Process.put(@gate_failure_key, true), do: false, else: tenant_label?()
  end

  defp resolve_gate(allowed?) do
    Process.delete(@gate_failure_key)
    allowed?
  end

  @doc """
  The documented tenant-count cap (`:metrics_tenant_label_cap`, default
  #{@default_tenant_label_cap}). At or below it, the `tenant_id` counter label is
  allowed; above it, the label collapses to the aggregated sentinel.
  """
  @spec tenant_label_cap() :: non_neg_integer()
  def tenant_label_cap do
    Application.get_env(:loopctl, :metrics_tenant_label_cap, @default_tenant_label_cap)
  end

  @doc "The sentinel value a gated-off `tenant_id` label collapses to."
  @spec aggregated_sentinel() :: atom()
  def aggregated_sentinel, do: @aggregated_sentinel
end
