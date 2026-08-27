defmodule Loopctl.Knowledge.IngestionHealth do
  @moduledoc """
  Capture-silence detection + query context for `ingestion_anomalies`.

  A **dead-man's-switch** for knowledge ingestion. loopctl already detects the
  *presence of errors* (`Loopctl.TokenUsage.CostAnomaly`, `Loopctl.Telemetry.ScaleAlerts`)
  but had no detector for the *absence of expected success* — the failure mode
  where session-knowledge capture silently stopped (articles rejected/dropped)
  and nothing noticed the missing writes for months.

  `detect/1` scans every active tenant and each monitored article `source_type`
  in ONE grouped query (joined against active tenants — no per-tenant fan-out).
  For a source_type that is **recently established** (has produced at least
  `established_threshold` articles WITHIN `establishment_window_hours`) but whose
  most recent article is older than `staleness_threshold_hours`, it emits a
  `:capture_silence` candidate — UNLESS the write-outcome rollup shows a row-less
  write (an idempotent dedup, or an `on_low_novelty: :skip` discard) inside the same
  window, which is a live pipeline the articles table cannot see. A tenant that never
  produced captures of a source_type is never flagged (it was never established), so
  this fires only on genuine *went-silent* regressions.

  ## Index / scan cost

  The grouped scan filters `articles.inserted_at >= window_start`; the supporting
  index (`articles_inserted_tenant_source_idx`) LEADS with `inserted_at` so that
  predicate is an index RANGE SEEK — the read is bounded to the rolling window
  (recent activity), NOT the whole corpus, so cost does not grow unbounded as the
  article table ages. This boundedness holds ONLY while that index is present and
  valid; because a silently-missing index would degrade this monitor to a Seq Scan
  (the very "silently stop monitoring" failure it exists to prevent), it — and the
  reject-rate detector's `ingestion_write_stats_day_index` — are registered
  in `Loopctl.IndexHealth`'s critical-index list so a boot probe alarms if either is
  missing/invalid rather than letting the scan quietly go unbounded.

  ## Monitoring contract: source_type must be stamped

  detect/1 only sees articles with a NON-NULL `source_type` (`where not is_nil`).
  `source_type` is an advisory, nullable field on `Loopctl.Knowledge.Article`, so
  a write path that omits it produces articles this monitor CANNOT see — a silent
  outage on such a path would go undetected. Any ingestion path you want covered
  by the dead-man's-switch (session capture, batch ingest, content ingestion)
  MUST stamp a known `source_type` (see `Article.known_source_types/0`). Whether a
  given upstream writer is required to stamp one is a product/contract decision;
  this module's guarantee is scoped to paths that do.

  ## Recency window (no perpetual false positives)

  Establishment is scoped to a rolling `establishment_window_hours` window, not an
  all-time count. A source_type that produced captures long ago and then
  legitimately wound down (project completed, workflow retired) drops out of the
  window once its last capture ages past it, so it stops being flagged instead of
  being reported as stale forever. Genuine regressions (recently active, now
  silent) still fire because their captures are inside the window. For a
  source_type an operator KNOWS is retired, archiving its anomaly suppresses
  re-detection (see `Loopctl.Workers.IngestionHealthWorker`); archiving is
  REVERSIBLE via `unarchive_anomaly/3` so a mistaken suppression can be lifted.

  The persistence + notification (audit / operator alert / per-tenant webhook) of a
  candidate lives in `Loopctl.Workers.IngestionHealthWorker`, mirroring how
  `Loopctl.Workers.CostAnomalyWorker` owns anomaly creation. This module owns the
  detection query and the `list_anomalies/2` / `resolve_anomaly/3` read+resolve
  surface the API exposes.

  ## Config-based DI

  The tunables resolve from `Application.get_env(:loopctl, :ingestion_health, [])`
  with in-code defaults (never opts, never `Application.put_env` in tests):

  - `:monitored_source_types` -- default `:all` (every source_type that crosses the
    established threshold; a list narrows monitoring to specific source_types)
  - `:established_threshold` -- default `5`
  - `:established_threshold_overrides` -- default `%{}` (per-source-type establishment
    thresholds, e.g. `%{"session_log" => 2}` to monitor a low-volume critical source)
  - `:staleness_threshold_hours` -- default `72`
  - `:establishment_window_hours` -- default `720` (30 days)
  - `:reject_rate_threshold` -- default `0.5` (reject fraction that flags high_reject_rate)
  - `:min_attempts` -- default `10` (window write-attempt floor before a reject rate is trusted)
  - `:min_attempts_overrides` -- default `%{}` (per-source-type overrides of the attempt
    floor, e.g. `%{"session_log" => 3}` to monitor a low-volume critical source that
    would otherwise fall below `min_attempts` and evade high_reject_rate detection)
  - `:reject_window_days` -- default `7`
  - `:write_stats_retention_days` -- default `90`
  - `:sweep_staleness_hours` -- default `6` (grace hours past `expires_at` after which
    a still-present `channel_posts` row means the retention sweep is not running)
  - `:sweep_hard_stale_hours` -- default `24` (the ceiling past which an overdue row is
    flagged REGARDLESS of drain capacity — see the retention-sweep detector below)
  - `:sweep_drain_rate_per_hour` -- default `12_000` (rows/hour the bounded sweep can
    delete install-wide: `@batch_size` 1000 × the `*/5 * * * *` cadence's 12 runs/hour)
  - `:knowledge_consumer_stall_runs` -- default `7` (consecutive nightly runs a knowledge-lint
    consumer must dispose of nothing, with work waiting, before it is flagged). Also
    resolvable from the `SystemConfig` row of the same name.
  - `:knowledge_consumer_pass_staleness_hours` -- default `72` (hours since the last completed
    nightly pass past which the pass itself is flagged). Also a `SystemConfig` row.
  - `:knowledge_consumer_scan_limit` -- default `20_000` (hard cap on `knowledge.lint_completed`
    rows read per detection run). Also a `SystemConfig` row.
  - `:sweep_scan_limit` -- default `100_000` (hard cap on the residue rows scanned per
    detection, so the cross-tenant read stays bounded on the small AdminRepo pool). MUST
    stay above `sweep_drain_rate_per_hour * sweep_staleness_hours` or the drain-capacity
    rule below becomes unreachable — see "Stalled vs merely BACKLOGGED".

  ## Nightly consumer-stall detector (`:consumer_stalled`, #765 item 6)

  `detect_sweep_stalled/0`'s third sibling, and the one that watches a WORKER rather than
  a table: `detect_consumer_stalled_scan/1` reads the nightly `knowledge.lint_completed`
  audit events and flags a consumer that has disposed of nothing for
  `consumer_stall_runs/0` consecutive runs while work was waiting, plus a nightly pass
  that has stopped completing at all. Full contract on
  `detect_consumer_stalled_scan/0`; its config knobs are `consumer_stall_runs/0`,
  `consumer_pass_staleness_hours/0`, `consumer_scan_limit/0` and the DERIVED
  `consumer_history_days/0`.

  ## Retention-sweep stall detector (`:sweep_stalled`, issue #498)

  `detect_sweep_stalled/0` is the absence-of-success detector for the US-39.5
  channel-post retention sweep (`Loopctl.Workers.ChannelPostSweeper`). It lives here,
  next to its siblings, because it is the same detector class (the absence of expected
  success) and it reuses the whole tested `ingestion_anomalies` alert / recovery /
  webhook / operator-API path rather than inventing a parallel one. Unlike the other
  two its evidence is `channel_posts` residue, not knowledge ingestion data — but it
  never queries that table itself: the residue read is
  `Loopctl.Coordination.system_retention_stall_candidates/2`, the owning context's API, so
  the knowledge context does not build queries on a coordination schema. The sentinel
  `sweep_source_type/0` (`"channel_post_sweep"`) keeps its anomalies from colliding with
  any real article source_type.

  ### Stalled vs merely BACKLOGGED

  "Overdue rows exist past the grace window" alone does NOT mean the sweep is dead: the
  sweeper is bounded at 1000 rows/run on a `*/5` cron (~12k rows/hour install-wide), so a
  large expiry burst legitimately takes hours to drain and would page an operator about a
  perfectly healthy sweep. The detector therefore compares the tenant's OWN observed
  residue against the sweep's DRAIN CAPACITY over the elapsed staleness
  (`sweep_drain_rate_per_hour * hours_stale`):

    * `hours_stale >= sweep_hard_stale_hours` -> ALWAYS a candidate. This is the case the
      capacity comparison cannot excuse: a backlog the batch bound can never drain, or a
      sweep that is genuinely dead behind a large backlog.
    * `overdue_count >= capacity` -> NOT a candidate. The backlog itself explains the age;
      a running sweep could not have reached these rows yet.
    * otherwise -> a candidate: the sweep had ample capacity to delete these rows in the
      elapsed window and did not, so it is not running (or is running and deleting
      nothing).

  ### The comparison is PER TENANT (review of #498)

  The capacity comparison uses the CANDIDATE's `overdue_count`, never the install-wide
  `scanned` total, and the install-wide `truncated?` flag never vetoes a candidate. Both
  were previously global, which made `channel_posts` volume a cross-tenant
  denial-of-detection lever: one tenant's backlog saturating the scan suppressed every
  other tenant's sub-ceiling candidate until the 24h ceiling — 4x the advertised 6h
  window. Under truncation a tenant's `overdue_count` is a LOWER bound, so the comparison
  can now over-flag (page) rather than under-detect during a genuine install-wide
  backlog; that direction is the safe one for a release gate, and the rows involved are
  by construction the OLDEST in the install.

  For the capacity rule to be REACHABLE at all, `sweep_scan_limit` must exceed
  `sweep_drain_rate_per_hour * sweep_staleness_hours` — otherwise the bounded scan can
  never observe a residue as large as the capacity threshold and the "merely BACKLOGGED"
  branch is dead code (it was, before this review: 50k cap vs a 72k threshold). That
  invariant is asserted by a test; keep the three knobs consistent when tuning any of
  them.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.DraftConsumer
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionWriteStats
  alias Loopctl.SystemConfig
  alias Loopctl.Tenants.Tenant

  @default_monitored_source_types :all
  @default_established_threshold 5
  @default_staleness_threshold_hours 72
  @default_establishment_window_hours 720
  @default_established_threshold_overrides %{}

  # High-reject-rate detector defaults (PR B2).
  @default_reject_rate_threshold 0.5
  @default_min_attempts 10
  @default_min_attempts_overrides %{}
  @default_reject_window_days 7
  @default_write_stats_retention_days 90

  # Channel-post retention-sweep stall detector defaults (#498). The sweep runs every
  # 5 minutes, so 6 hours of overdue rows is ~72 consecutive missed runs — well past
  # any transient backlog or deploy window, and still far inside the 30-day retention
  # promise it protects.
  @default_sweep_staleness_hours 6

  # Ceiling past which an overdue row is flagged regardless of drain capacity: at the
  # default drain rate this is ~288k rows of headroom, so anything still overdue after
  # 24h is a backlog the bounded sweep can never drain (or a dead sweep behind one).
  # Deliberately well INSIDE the 30-day retention promise it protects: this is the worst
  # case alarm latency for a dead sweep hiding behind a backlog larger than the scan cap.
  @default_sweep_hard_stale_hours 24

  # Install-wide rows/hour the bounded sweep can delete: `ChannelPostSweeper`'s
  # @batch_size (1000) × the `*/5 * * * *` crontab's 12 runs/hour. Config-overridable so
  # a changed batch size or cadence can be reflected without a code change.
  @default_sweep_drain_rate_per_hour 12_000

  # Hard cap on residue rows scanned per detection run (see
  # `Coordination.system_retention_stall_candidates/2`): the residue only grows while the
  # sweep is behind, so the scan MUST be bounded or the detector becomes most expensive
  # exactly when the system is least healthy — on the 3-connection AdminRepo pool.
  #
  # It is deliberately ABOVE `@default_sweep_drain_rate_per_hour *
  # @default_sweep_staleness_hours` (12_000 × 6 = 72_000). At the previous 50_000 the
  # capacity threshold could never be observed, so the "residue >= capacity ⇒ merely
  # BACKLOGGED" rule was arithmetically unreachable and `sweep_drain_rate_per_hour` was an
  # inert knob (#498 review). The larger cap costs nothing in a healthy install: the scan
  # only ever touches rows ALREADY past `expires_at + grace`, of which there are zero when
  # the sweep is running.
  @default_sweep_scan_limit 100_000

  # Fixed sentinel `source_type` for the retention-sweep detector. `ingestion_anomalies`
  # requires a NOT NULL source_type (and the unresolved-unique partial index keys on it),
  # but the sweep is not an article source_type at all — so it is recorded under this
  # reserved, non-article sentinel (precedent: @unstamped_source_type below).
  # Nightly knowledge-lint consumer-stall detector defaults (#765 item 6).
  #
  # SEVEN consecutive nightly runs with nothing disposed. Measured cadence on the hosted
  # corpus 2026-08-27: ~11 drafts arrive a night, `:generic_title` produces ~1 and
  # `:duplicate_capture` 0-1 — so a two-night window fires on ordinary quiet, and a
  # fortnight is half a month of a dead consumer. A QUIET night never extends the streak
  # (see `detect_consumer_stalled_scan/1`), so seven is seven nights on which work was
  # actually waiting or the step could not act.
  @default_consumer_stall_runs 7

  # Three consecutive missed nightly runs before the PASS ITSELF is flagged — the same
  # 72 hours `@default_staleness_threshold_hours` uses for capture silence, and for the
  # same reason: past any deploy window or single bad night, well inside the point at
  # which a human would have wanted to know. This is the half that catches #761.
  @default_consumer_pass_staleness_hours 72

  # Backstop on the bounded cross-tenant read: `runs x tenants` rows at the default is
  # 2,000 tenants, on the 3-connection AdminRepo pool.
  @default_consumer_scan_limit 20_000

  # `Loopctl.Workers.AuditPartitionWorker`'s @default_retention_days. The detector reads
  # `audit_log`, so this is the hard ceiling on how far back any window can see, and
  # `consumer_history_days/2` clamps to it rather than asking for rows that were dropped
  # with their partition.
  @audit_retention_days 90

  @lint_entity_type "knowledge_lint"
  @lint_action "knowledge.lint_completed"

  # Reserved sentinel `source_type`s for the consumer-stall detector, for the same reason
  # @sweep_source_type is one: `ingestion_anomalies.source_type` is NOT NULL and the
  # unresolved-unique partial index keys on it, but a nightly consumer is not an article
  # source_type. ONE PER CONSUMER, so archiving a legitimately-paused draft drain does not
  # also blind the conflict judge.
  @consumer_pass_source_type "knowledge_lint_pass"

  @consumer_classes [
    %{key: :drafts, source_type: "knowledge_lint_drafts", label: "draft publishing"},
    %{
      key: :duplicates,
      source_type: "knowledge_lint_duplicates",
      label: "duplicate unpublishing"
    },
    %{
      key: :generic_titles,
      source_type: "knowledge_lint_generic_titles",
      label: "generic-title retitling"
    },
    %{
      key: :conflict_judge,
      source_type: "knowledge_lint_conflict_judge",
      label: "conflict judging"
    }
  ]

  @sweep_source_type "channel_post_sweep"

  # Fixed sentinel `source_type` for the retroactive denylist rescan detector (#499),
  # for exactly the same reason as @sweep_source_type: a quarantined coordination post
  # is not an article source_type, but `ingestion_anomalies.source_type` is NOT NULL and
  # the unresolved-unique partial index keys on it. Distinct from @sweep_source_type so
  # a retention stall and a credential detection never collide on that index.
  @rescan_source_type "channel_post_rescan"

  # Sentinel `source_type` for the NULL/unstamped write bucket. `source_type` on a
  # KB write is advisory + nullable, so the MAJORITY of agent captures (patterns,
  # decisions, session findings) omit it — those rejected writes land in the
  # COALESCE('') bucket of `ingestion_write_stats`. `ingestion_anomalies.source_type`
  # is NOT NULL (and `validate_required` rejects ""), so a reject-rate outage on
  # unstamped writes is recorded under THIS sentinel rather than being a permanent
  # blind spot (the exact 409 title_conflict outage class this detector exists to catch).
  @unstamped_source_type "(unstamped)"

  @type candidate :: %{
          tenant_id: Ecto.UUID.t(),
          source_type: String.t(),
          anomaly_type: :capture_silence,
          last_event_at: DateTime.t(),
          hours_stale: non_neg_integer(),
          sample_count: non_neg_integer()
        }

  @type reject_candidate :: %{
          tenant_id: Ecto.UUID.t(),
          source_type: String.t(),
          anomaly_type: :high_reject_rate,
          total_attempts: non_neg_integer(),
          rejects: non_neg_integer(),
          reject_rate: float(),
          window_days: pos_integer(),
          dominant_reason: String.t()
        }

  @type sweep_candidate :: %{
          tenant_id: Ecto.UUID.t(),
          source_type: String.t(),
          anomaly_type: :sweep_stalled,
          overdue_count: pos_integer(),
          oldest_expires_at: DateTime.t(),
          hours_stale: non_neg_integer(),
          grace_hours: pos_integer()
        }

  @typedoc """
  One retention-residue scan: the tenants to FLAG plus the RAW facts recovery needs.
  See `detect_sweep_stalled_scan/0`.
  """
  @type sweep_scan :: %{
          candidates: [sweep_candidate()],
          residue_tenant_ids: MapSet.t(Ecto.UUID.t()),
          truncated?: boolean(),
          scanned: non_neg_integer()
        }

  @type consumer_candidate :: %{
          tenant_id: Ecto.UUID.t(),
          source_type: String.t(),
          anomaly_type: :consumer_stalled,
          consumer: :pass | :drafts | :duplicates | :generic_titles | :conflict_judge,
          reason: :no_completion | :no_dispositions,
          hours_stale: non_neg_integer(),
          runs_examined: pos_integer(),
          evidence: map()
        }

  @typedoc """
  One consumer-stall scan: the `{tenant, consumer}` pairs to FLAG plus the raw facts
  recovery needs. See `detect_consumer_stalled_scan/0`.
  """
  @type consumer_scan :: %{
          candidates: [consumer_candidate()],
          evaluated_keys: MapSet.t({Ecto.UUID.t(), String.t()}),
          truncated?: boolean(),
          runs_scanned: non_neg_integer()
        }

  # --- Config accessors (documented defaults) ---

  @doc """
  Article `source_type`s monitored for capture silence.

  `:all` (the default) monitors every source_type that crosses the established
  threshold; a list narrows monitoring to specific source_types.
  """
  @spec monitored_source_types() :: :all | [String.t()]
  def monitored_source_types,
    do: Keyword.get(config(), :monitored_source_types, @default_monitored_source_types)

  @doc "Minimum article count (within the establishment window) for a source_type to count as ESTABLISHED (default 5)."
  @spec established_threshold() :: pos_integer()
  def established_threshold,
    do: Keyword.get(config(), :established_threshold, @default_established_threshold)

  @doc """
  Per-source-type overrides for the establishment threshold.

  A map of `source_type => pos_integer`. A low-volume but critical source_type
  (e.g. 3-4 captures/month) would never cross the global `established_threshold`
  and so would never be monitored; an override lets an operator lower the bar for
  that specific source_type without weakening the default for noisy ones. Default
  `%{}` (no overrides — every source_type uses the global threshold).
  """
  @spec established_threshold_overrides() :: %{optional(String.t()) => pos_integer()}
  def established_threshold_overrides,
    do:
      Keyword.get(
        config(),
        :established_threshold_overrides,
        @default_established_threshold_overrides
      )

  @doc "Hours since the last article beyond which an established source_type is stale (default 72)."
  @spec staleness_threshold_hours() :: pos_integer()
  def staleness_threshold_hours,
    do: Keyword.get(config(), :staleness_threshold_hours, @default_staleness_threshold_hours)

  @doc """
  Rolling window (in hours) within which a source_type's captures must fall to
  count toward establishment (default 720 = 30 days). Scopes establishment to
  RECENT activity so a wound-down source_type is not perpetually flagged.
  """
  @spec establishment_window_hours() :: pos_integer()
  def establishment_window_hours,
    do: Keyword.get(config(), :establishment_window_hours, @default_establishment_window_hours)

  @doc """
  Fraction of write attempts (0.0-1.0) above which a source_type's rolling window is
  flagged `:high_reject_rate` (`rejects / total_attempts > threshold`). Default 0.5.
  """
  @spec reject_rate_threshold() :: float()
  def reject_rate_threshold,
    do: Keyword.get(config(), :reject_rate_threshold, @default_reject_rate_threshold)

  @doc """
  Minimum total write attempts in the window before a reject rate is trusted enough
  to flag (avoids alerting on statistical noise from a handful of writes). Default 10.
  """
  @spec min_attempts() :: pos_integer()
  def min_attempts, do: Keyword.get(config(), :min_attempts, @default_min_attempts)

  @doc """
  Per-source-type overrides for the minimum-attempts floor (mirrors
  `established_threshold_overrides/0` for the capture-silence detector).

  A map of `source_type => pos_integer`. A LOW-VOLUME but critical source (fewer than
  the global `min_attempts` write attempts in the window) that is 100% rejecting would
  otherwise fall between BOTH detectors — never enough attempts for high_reject_rate,
  and (if it never established) never a capture_silence candidate either — leaving a
  full-reject outage silent for the whole window. An override lets an operator monitor
  such a source at a lower attempt floor without lowering the bar for noisy ones. The
  unstamped bucket is addressed under the `unstamped_source_type/0` sentinel key.
  Default `%{}` (no overrides — every source_type uses the global floor).
  """
  @spec min_attempts_overrides() :: %{optional(String.t()) => pos_integer()}
  def min_attempts_overrides,
    do: Keyword.get(config(), :min_attempts_overrides, @default_min_attempts_overrides)

  @doc """
  Rolling window (in days) over the `ingestion_write_stats` rollup for the
  reject-rate scan. Default 7.
  """
  @spec reject_window_days() :: pos_integer()
  def reject_window_days,
    do: Keyword.get(config(), :reject_window_days, @default_reject_window_days)

  @doc """
  Retention (in days) for the `ingestion_write_stats` rollup. Rows older than this are
  pruned by the hourly worker so the table does not grow unbounded (only the rolling
  `reject_window_days` window is ever read). Default 90.
  """
  @spec write_stats_retention_days() :: pos_integer()
  def write_stats_retention_days,
    do: Keyword.get(config(), :write_stats_retention_days, @default_write_stats_retention_days)

  @doc """
  Sentinel `source_type` under which reject-rate anomalies for NULL/unstamped writes
  are recorded (see the module attribute for why the NULL bucket needs a sentinel).
  """
  @spec unstamped_source_type() :: String.t()
  def unstamped_source_type, do: @unstamped_source_type

  @doc """
  Grace period (in hours) past `expires_at` after which a still-present `channel_posts`
  row means the US-39.5 retention sweep is not being enforced. Default 6 (~72 missed
  5-minute runs).
  """
  @spec sweep_staleness_hours() :: pos_integer()
  def sweep_staleness_hours,
    do: Keyword.get(config(), :sweep_staleness_hours, @default_sweep_staleness_hours)

  @doc """
  Staleness ceiling (in hours) past which an overdue `channel_posts` row is flagged
  REGARDLESS of the sweep's drain capacity. Default 24. This is the backstop for a
  backlog the bounded sweep can never drain — the case the capacity comparison in
  `detect_sweep_stalled/1` deliberately excuses below the ceiling.
  """
  @spec sweep_hard_stale_hours() :: pos_integer()
  def sweep_hard_stale_hours,
    do: Keyword.get(config(), :sweep_hard_stale_hours, @default_sweep_hard_stale_hours)

  @doc """
  Rows/hour the bounded US-39.5 sweep can delete install-wide (default 12_000 = the
  worker's 1000-row batch × the `*/5` crontab's 12 runs/hour). Used to tell a STALLED
  sweep from one that is merely BACKLOGGED.
  """
  @spec sweep_drain_rate_per_hour() :: pos_integer()
  def sweep_drain_rate_per_hour,
    do: Keyword.get(config(), :sweep_drain_rate_per_hour, @default_sweep_drain_rate_per_hour)

  @doc """
  Hard cap on residue rows scanned per stall detection (default 100_000). Keeps the
  cross-tenant read bounded on the small AdminRepo pool; hitting the cap is itself
  evidence of a large backlog, and makes the scan sample INCOMPLETE — which is why a
  truncated scan closes no anomalies (see `auto_resolve_recovered_sweep_stalled/1`).

  MUST stay above `sweep_drain_rate_per_hour() * sweep_staleness_hours()`, or the
  drain-capacity branch of `detect_sweep_stalled/1` can never be reached (a residue can
  never be OBSERVED as large as the threshold it is compared against).
  """
  @spec sweep_scan_limit() :: pos_integer()
  def sweep_scan_limit,
    do: Keyword.get(config(), :sweep_scan_limit, @default_sweep_scan_limit)

  @doc """
  Reserved sentinel `source_type` under which `:sweep_stalled` anomalies are recorded
  (`"channel_post_sweep"`). The sweep is not an article source_type; see the module
  attribute for why a sentinel is required.
  """
  @spec sweep_source_type() :: String.t()
  def sweep_source_type, do: @sweep_source_type

  @doc """
  Reserved sentinel `source_type` under which `:secret_detected` anomalies are recorded
  (`"channel_post_rescan"`, issue #499). A quarantined coordination post is not an
  article source_type; see the module attribute for why a sentinel is required.
  """
  @spec rescan_source_type() :: String.t()
  def rescan_source_type, do: @rescan_source_type

  defp config, do: Application.get_env(:loopctl, :ingestion_health, [])

  # --- Detection ---

  @doc """
  Scans every active tenant for capture-silence candidates using the configured
  tunables. Returns a flat list of `t:candidate/0` maps — PURE, no DB writes.

  The worker turns each candidate into a persisted anomaly (race-safe) and notifies.
  """
  @spec detect() :: [candidate()]
  def detect do
    detect(%{
      monitored_source_types: monitored_source_types(),
      established_threshold: established_threshold(),
      established_threshold_overrides: established_threshold_overrides(),
      staleness_threshold_hours: staleness_threshold_hours(),
      establishment_window_hours: establishment_window_hours()
    })
  end

  @doc """
  `detect/0` with explicit config (`:monitored_source_types`, `:established_threshold`,
  `:staleness_threshold_hours`, optional `:establishment_window_hours`). Exposed so a
  caller can drive detection with a specific configuration without touching global
  app env.
  """
  @spec detect(%{
          required(:monitored_source_types) => :all | [String.t()],
          required(:established_threshold) => pos_integer(),
          required(:staleness_threshold_hours) => pos_integer(),
          optional(:established_threshold_overrides) => %{optional(String.t()) => pos_integer()},
          optional(:establishment_window_hours) => pos_integer()
        }) :: [candidate()]
  def detect(
        %{
          monitored_source_types: source_types,
          established_threshold: established,
          staleness_threshold_hours: staleness_hours
        } = opts
      ) do
    now = DateTime.utc_now()
    window_hours = Map.get(opts, :establishment_window_hours, establishment_window_hours())
    window_start = DateTime.add(now, -window_hours * 3600, :second)
    overrides = Map.get(opts, :established_threshold_overrides, %{})

    # ONE grouped query across ALL active tenants (no per-tenant fan-out): the
    # join to active tenants + group_by (tenant_id, source_type) yields
    # sample_count + last_event_at per (tenant, source_type). Establishment is
    # scoped to the recency window (inserted_at >= window_start) so wound-down
    # source_types age out instead of being flagged forever, AND so the read is
    # bounded to the window via the inserted_at-leading index (articles_inserted_
    # tenant_source_idx) rather than scanning the whole corpus. A source_type with
    # no recent articles never appears in the result (not recently established).
    Article
    |> join(:inner, [a], t in Tenant, on: t.id == a.tenant_id and t.status == :active)
    |> where([a], not is_nil(a.source_type))
    |> where([a], a.inserted_at >= ^window_start)
    |> filter_source_types(source_types)
    |> group_by([a], [a.tenant_id, a.source_type])
    |> select([a], %{
      tenant_id: a.tenant_id,
      source_type: a.source_type,
      sample_count: count(a.id),
      last_event_at: max(a.inserted_at)
    })
    |> AdminRepo.all()
    |> Enum.flat_map(fn %{
                          tenant_id: tid,
                          source_type: st,
                          sample_count: count,
                          last_event_at: last
                        } ->
      threshold = Map.get(overrides, st, established)
      candidate_or_skip(tid, st, count, last, threshold, staleness_hours, now)
    end)
    |> reject_rowless_but_live(source_types, staleness_hours)
  end

  # Not every healthy write leaves an article row. A saturated capture source running
  # `on_low_novelty: :skip` can spend most of its writes on high-overlap proposals that
  # are DISCARDED, and `max(articles.inserted_at)` cannot see them, so this dead-man's
  # switch would page the operator for a pipeline that is writing all day. The
  # write-outcome rollup is the complementary liveness signal: a (tenant, source_type)
  # with a skipped write inside the staleness window is NOT silent.
  #
  # `deduplicated` deliberately does NOT count as liveness. An idempotent re-post is a
  # replay of content captured long ago — a source whose every write dedups is producing
  # NO new knowledge, which is precisely the regression this switch exists to page for;
  # letting it suppress the alert would silence the outage forever.
  #
  # The rollup's grain is a DAY, so the lookback rounds staleness UP to whole days —
  # deliberately generous. A dead-man's switch must under-page rather than false-page;
  # a genuinely stopped source clears the window a day later and is flagged then.
  defp reject_rowless_but_live([], _source_types, _staleness_hours), do: []

  defp reject_rowless_but_live(candidates, source_types, staleness_hours) do
    since_day = Date.add(Date.utc_today(), -ceil(staleness_hours / 24))

    live =
      IngestionWriteStats
      |> join(:inner, [s], t in Tenant, on: t.id == s.tenant_id and t.status == :active)
      |> where([s], not is_nil(s.source_type))
      |> where([s], s.day >= ^since_day)
      |> where([s], s.skipped_count > 0)
      |> filter_source_types(source_types)
      |> select([s], {s.tenant_id, s.source_type})
      |> AdminRepo.all()
      |> MapSet.new()

    Enum.reject(candidates, &MapSet.member?(live, {&1.tenant_id, &1.source_type}))
  end

  # `:all` monitors every source_type; a list narrows to the given source_types.
  defp filter_source_types(query, :all), do: query

  defp filter_source_types(query, source_types) when is_list(source_types),
    do: where(query, [a], a.source_type in ^source_types)

  defp candidate_or_skip(
         tenant_id,
         source_type,
         sample_count,
         last_event_at,
         established,
         staleness_hours,
         now
       ) do
    hours_stale = hours_between(last_event_at, now)

    if sample_count >= established and is_integer(hours_stale) and hours_stale > staleness_hours do
      [
        %{
          tenant_id: tenant_id,
          source_type: source_type,
          anomaly_type: :capture_silence,
          last_event_at: to_utc_datetime(last_event_at),
          hours_stale: hours_stale,
          sample_count: sample_count
        }
      ]
    else
      []
    end
  end

  # --- High-reject-rate detection (PR B2) ---

  @doc """
  Scans the `ingestion_write_stats` rollup for `:high_reject_rate` candidates using
  the configured tunables. Returns a flat list of `t:reject_candidate/0` maps — PURE,
  no DB writes.

  A rejected write leaves NO article row, so the capture-silence detector (which reads
  `articles`) is blind to it. This complementary detector reads the durable write-
  outcome rollup instead: for each `(tenant, non-null source_type)` over a rolling
  `reject_window_days` window, it sums all outcome counters into `total_attempts`,
  sums `title_conflict + validation_error` into `rejects`, and flags when
  `total_attempts >= min_attempts` AND `rejects / total_attempts > reject_rate_threshold`.

  NULL/unstamped `source_type` writes are NOT excluded: since `source_type` is optional
  on a KB write, the reject path's source_type is chosen by the FAILING client, so
  "just stamp it" is no mitigation. The NULL bucket (`COALESCE(source_type, '')`) is
  folded into a single candidate under `unstamped_source_type/0` (`ingestion_anomalies`
  requires a non-null source_type, so the sentinel stands in), ensuring an unstamped
  reject outage is not a permanent blind spot.
  """
  @spec detect_high_reject_rate() :: [reject_candidate()]
  def detect_high_reject_rate do
    detect_high_reject_rate(%{
      reject_rate_threshold: reject_rate_threshold(),
      min_attempts: min_attempts(),
      min_attempts_overrides: min_attempts_overrides(),
      reject_window_days: reject_window_days()
    })
  end

  @doc """
  `detect_high_reject_rate/0` with explicit config. Exposed so a caller can drive
  detection with a specific configuration without touching global app env.
  """
  @spec detect_high_reject_rate(%{
          required(:reject_rate_threshold) => float(),
          required(:min_attempts) => pos_integer(),
          required(:reject_window_days) => pos_integer(),
          optional(:min_attempts_overrides) => %{optional(String.t()) => pos_integer()}
        }) :: [reject_candidate()]
  def detect_high_reject_rate(
        %{
          reject_rate_threshold: threshold,
          min_attempts: min_attempts,
          reject_window_days: window_days
        } = opts
      ) do
    overrides = Map.get(opts, :min_attempts_overrides, %{})
    # Inclusive rolling window of `window_days` days ending today. The day-leading
    # index (`ingestion_write_stats_day_index`) makes `day >= window_start` a range
    # seek, so the read is bounded to the window rather than a seq-scan of the rollup.
    window_start = Date.add(Date.utc_today(), -(window_days - 1))

    # Group by COALESCE(source_type, '') so NULL and empty-string writes fold into ONE
    # bucket (surfaced as `unstamped_source_type/0` downstream) — an unstamped reject
    # outage is caught, not silently dropped into a NULL rollup row no detector scans.
    IngestionWriteStats
    |> join(:inner, [s], t in Tenant, on: t.id == s.tenant_id and t.status == :active)
    |> where([s], s.day >= ^window_start)
    |> group_by([s], [s.tenant_id, fragment("COALESCE(?, '')", s.source_type)])
    |> select([s], %{
      tenant_id: s.tenant_id,
      source_type: fragment("COALESCE(?, '')", s.source_type),
      created: sum(s.created_count),
      deduplicated: sum(s.deduplicated_count),
      drafted: sum(s.drafted_count),
      title_conflict: sum(s.title_conflict_count),
      validation_error: sum(s.validation_error_count)
    })
    |> AdminRepo.all()
    |> Enum.flat_map(
      &reject_candidate_or_skip(&1, threshold, min_attempts, overrides, window_days)
    )
  end

  defp reject_candidate_or_skip(row, threshold, min_attempts, overrides, window_days) do
    created = to_int(row.created)
    deduplicated = to_int(row.deduplicated)
    drafted = to_int(row.drafted)
    title_conflict = to_int(row.title_conflict)
    validation_error = to_int(row.validation_error)

    # Denominator = ALL ingestion write outcomes EXCEPT `skipped`, so it includes the
    # SUCCESSFUL deduplicated and drafted ones. `reject_rate` is therefore "fraction of
    # ALL write attempts rejected", not "fraction of new-content-CREATE attempts
    # rejected". That is deliberate (tenant-wide, a pipeline that mostly dedups is
    # largely working), but it is a KNOWN blind spot: a genuine title_conflict/validation
    # reject storm on a source_type that ALSO carries heavy legitimate idempotent-dedup
    # traffic can be diluted below `reject_rate_threshold` and evade this detector
    # (e.g. 600 rejects / (1000 dedup + 600) = 0.375 < 0.5). `skipped` is excluded (like
    # `:forbidden`) precisely so the blind spot is not WIDENED by an outcome designed to
    # be high-volume: a writer running `on_low_novelty: :skip` is expected to skip the
    # majority of its captures, which would swamp any reject signal on that tenant. If a
    # source with high idempotent-dedup volume needs coverage, prefer a
    # create+reject-only denominator or an absolute rejects/window rate for it.
    total_attempts = created + deduplicated + drafted + title_conflict + validation_error

    rejects = title_conflict + validation_error
    reject_rate = if total_attempts > 0, do: rejects / total_attempts, else: 0.0

    # A low-volume critical source can be monitored below the global floor via a
    # per-source override (keyed by the operator-facing source_type, sentinel included).
    source_type = reject_source_type(row.source_type)
    effective_min_attempts = Map.get(overrides, source_type, min_attempts)

    if total_attempts >= effective_min_attempts and reject_rate > threshold do
      [
        %{
          tenant_id: row.tenant_id,
          source_type: source_type,
          anomaly_type: :high_reject_rate,
          total_attempts: total_attempts,
          rejects: rejects,
          reject_rate: reject_rate,
          window_days: window_days,
          dominant_reason: dominant_reason(title_conflict, validation_error)
        }
      ]
    else
      []
    end
  end

  # The COALESCE('') NULL/empty bucket surfaces under the sentinel so it can be
  # persisted as an anomaly (non-null source_type) and matched by the worker's queries.
  defp reject_source_type(""), do: @unstamped_source_type
  defp reject_source_type(source_type), do: source_type

  # The reject reason that contributed the most drops (ties -> title_conflict).
  defp dominant_reason(title_conflict, validation_error) do
    if title_conflict >= validation_error, do: "title_conflict", else: "validation_error"
  end

  # A `sum(bigint)` comes back from Postgres as `numeric` -> Ecto `Decimal`; normalize
  # to an integer (nil when a group somehow has no rows).
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n

  # --- Retention-sweep stall detection (#498) ---

  @doc """
  Scans for tenants whose US-39.5 channel-post retention sweep has STALLED, using the
  configured grace window. Returns a flat list of `t:sweep_candidate/0` maps — PURE,
  no DB writes.

  A tenant is a candidate when it still holds `channel_posts` rows whose `expires_at`
  is more than `sweep_staleness_hours/0` in the past AND that residue is NOT explainable
  by the bounded sweep's own drain capacity (see the moduledoc's "Stalled vs merely
  BACKLOGGED"). That is an OUTCOME check, not a liveness proxy: rows that should have
  been hard-deleted are still there and the sweep had the capacity to delete them, so
  the 30-day retention window is by construction not being enforced for that tenant —
  whether the worker crashed, stopped being scheduled, lost its permissions, or is
  running but never draining. The complementary in-band signals (a run that happened
  and succeeded/failed) are the `channel_post_swept/channel_post_sweep_failed` telemetry
  the worker emits; this detector is the half that survives the worker never running.

  Cross-tenant and set-based: ONE BOUNDED grouped read via
  `Loopctl.Coordination.system_retention_stall_candidates/2` (the owning context's API),
  joined to ACTIVE tenants (same shape as `detect/1`), so a suspended tenant's leftovers
  never page anyone.

  Returns only the candidate list. The worker uses `detect_sweep_stalled_scan/0,1`
  instead, because RECOVERY must be decided against the RAW residue rather than this
  post-filter list (a suppressed-but-still-stalled tenant is not a recovered one).
  """
  @spec detect_sweep_stalled() :: [sweep_candidate()]
  def detect_sweep_stalled, do: detect_sweep_stalled_scan().candidates

  @doc """
  `detect_sweep_stalled/0` with explicit config. `:sweep_staleness_hours` is required;
  `:sweep_hard_stale_hours`, `:sweep_drain_rate_per_hour` and `:sweep_scan_limit` fall
  back to their accessors. Exposed so a caller can drive detection with a specific
  configuration without touching global app env.
  """
  @spec detect_sweep_stalled(map()) :: [sweep_candidate()]
  def detect_sweep_stalled(%{sweep_staleness_hours: _} = opts),
    do: detect_sweep_stalled_scan(opts).candidates

  @doc """
  `detect_sweep_stalled/0` plus the RAW scan facts recovery needs.

  Returns `t:sweep_scan/0`:

    * `:candidates` — exactly what `detect_sweep_stalled/0` returns (post drain-capacity
      filter): the tenants to FLAG.
    * `:residue_tenant_ids` — every ACTIVE tenant observed holding overdue residue,
      BEFORE the drain-capacity filter. This is the recovery predicate: a tenant excused
      as "merely backlogged" has NOT recovered, and closing its open anomaly would write
      a false `resolved` claim into the append-only audit log.
    * `:truncated?` — the bounded scan hit its cap, so `residue_tenant_ids` is INCOMPLETE
      (the LIMIT is install-wide and oldest-first, so a tenant with newer residue can be
      missing altogether). Recovery must not run at all on a truncated scan.
    * `:scanned` — rows scanned (bounded by `sweep_scan_limit`), for observability.
  """
  @spec detect_sweep_stalled_scan() :: sweep_scan()
  def detect_sweep_stalled_scan do
    detect_sweep_stalled_scan(%{
      sweep_staleness_hours: sweep_staleness_hours(),
      sweep_hard_stale_hours: sweep_hard_stale_hours(),
      sweep_drain_rate_per_hour: sweep_drain_rate_per_hour(),
      sweep_scan_limit: sweep_scan_limit()
    })
  end

  @doc """
  `detect_sweep_stalled_scan/0` with explicit config (same option handling as
  `detect_sweep_stalled/1`).
  """
  @spec detect_sweep_stalled_scan(map()) :: sweep_scan()
  def detect_sweep_stalled_scan(%{sweep_staleness_hours: grace_hours} = opts) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -grace_hours * 3600, :second)
    hard_hours = Map.get(opts, :sweep_hard_stale_hours, sweep_hard_stale_hours())
    drain_rate = Map.get(opts, :sweep_drain_rate_per_hour, sweep_drain_rate_per_hour())
    scan_limit = Map.get(opts, :sweep_scan_limit, sweep_scan_limit())

    %{rows: rows, scanned: scanned, truncated?: truncated?} =
      Coordination.system_retention_stall_candidates(cutoff, scan_limit)

    observed = Enum.map(rows, &sweep_candidate(&1, grace_hours, now))

    %{
      candidates: Enum.filter(observed, &stalled?(&1, hard_hours, drain_rate)),
      residue_tenant_ids: MapSet.new(observed, & &1.tenant_id),
      truncated?: truncated?,
      scanned: scanned
    }
  end

  # Tell a STALLED sweep from a merely BACKLOGGED one (#498 review). Above the hard
  # ceiling everything is a stall — that is the backlog-the-bound-can-never-drain case.
  # Below it, a residue at least as large as what the sweep could have deleted in the
  # elapsed window is explained by the backlog itself, so it is NOT paged.
  #
  # PER TENANT by construction: the comparison uses THIS candidate's `overdue_count`, and
  # the install-wide `truncated?`/`scanned` figures are deliberately absent. Making them
  # inputs (as the first cut did) let any one tenant's `channel_posts` volume veto
  # detection for every other tenant — see the moduledoc's "The comparison is PER TENANT".
  defp stalled?(candidate, hard_hours, drain_rate) do
    candidate.hours_stale >= hard_hours or
      candidate.overdue_count < drain_rate * max(candidate.hours_stale, 1)
  end

  defp sweep_candidate(
         %{tenant_id: tenant_id, overdue_count: count, oldest_expires_at: oldest},
         grace_hours,
         now
       ) do
    oldest_dt = to_utc_datetime(oldest)

    %{
      tenant_id: tenant_id,
      source_type: @sweep_source_type,
      anomaly_type: :sweep_stalled,
      overdue_count: count,
      oldest_expires_at: oldest_dt,
      # How long retention has ACTUALLY been unenforced: whole hours the oldest overdue
      # row has outlived its own expires_at (>= grace_hours by construction, but the
      # figure reported is the true age, not the threshold).
      hours_stale: max(hours_between(oldest_dt, now), 0),
      grace_hours: grace_hours
    }
  end

  @doc """
  Closes `:sweep_stalled` anomalies whose sweep has RECOVERED.

  Like `:high_reject_rate`, a stall has no natural "resumed" event, so recovery is
  defined by the RAW residue: the tenant holds no overdue expired `channel_posts` at all
  (the sweep drained the backlog). `scan` is the SAME `t:sweep_scan/0` the worker just
  computed, so this shares one scan.

  ## Recovery is decided on the RAW residue, never the filtered candidate list

  `scan.candidates` is post-`stalled?` — a tenant can drop out of it for two reasons that
  are NOT recovery: its residue was excused as merely BACKLOGGED (drain capacity), or the
  bounded scan truncated. Closing on those would stamp `resolved: true` + a `resolved`
  transition into the append-only hash-chained audit log, asserting a release-gate
  recovery that did not happen — and, because the close also stamps `last_event_at` and
  therefore RE-ARMS detection, a residue oscillating across that boundary would
  close/re-create/re-alert every hourly run. So:

    * the predicate is `scan.residue_tenant_ids` (every tenant OBSERVED holding residue),
      not the candidate list; and
    * a `truncated?` scan closes NOTHING — under an install-wide, oldest-first LIMIT a
      still-stalled tenant can be missing from the sample entirely, and absence there is
      not evidence of absence on the table.

  For each ACTIVE stall anomaly (`archived == false` and `last_event_at IS NULL`,
  covering both open rows and operator-resolved-but-still-stalled episodes) whose
  tenant is NOT in the residue set, it stamps `last_event_at` with the recovery time
  and sets `resolved: true`. This is the type's OWN close path: the existing
  auto-resolvers are anomaly_type-scoped (`:capture_silence` / `:high_reject_rate`), so
  without it a `sweep_stalled` row would freeze open forever AND keep suppressing a
  future stall. Returns the number of anomalies closed. Called by the hourly worker.

  ## Only an ACTIVE tenant can "recover"

  Detection inner-joins ACTIVE tenants, so SUSPENDING a tenant (or deleting the project
  whose `channel_posts` cascade away) drops it from the residue set even though the
  sweep may still be dead. Closing on that would write `resolved: true` plus an audit
  entry ASSERTING retention recovered into the append-only, hash-chained log — a false
  claim about a release gate. So the close is gated on the anomaly's tenant still being
  ACTIVE: a suspended tenant's stall row stays OPEN (and re-closes normally if the
  tenant is reactivated and the backlog is genuinely gone).
  """
  @spec auto_resolve_recovered_sweep_stalled(sweep_scan()) :: non_neg_integer()
  def auto_resolve_recovered_sweep_stalled(%{truncated?: true}), do: 0

  def auto_resolve_recovered_sweep_stalled(%{residue_tenant_ids: residue}) do
    now = DateTime.utc_now()

    anomalies = active_episode_anomalies(:sweep_stalled)
    active_tenants = active_tenant_ids(Enum.map(anomalies, & &1.tenant_id))

    Enum.reduce(anomalies, 0, fn anomaly, acc ->
      recovered? =
        MapSet.member?(active_tenants, anomaly.tenant_id) and
          not MapSet.member?(residue, anomaly.tenant_id)

      if recovered?,
        do: acc + close_recovered_episode(anomaly, now, "auto_resolve_sweep_stalled"),
        else: acc
    end)
  end

  # The ACTIVE-episode rows for an episode-shaped detector: not archived, and
  # `last_event_at IS NULL` (covering both open rows and operator-resolved-but-still-
  # active episodes). Shared by the reject-rate and sweep-stall auto-resolvers.
  defp active_episode_anomalies(anomaly_type) do
    IngestionAnomaly
    |> where([a], a.anomaly_type == ^anomaly_type)
    |> where([a], a.archived == false)
    |> where([a], is_nil(a.last_event_at))
    |> AdminRepo.all()
  end

  defp active_tenant_ids([]), do: MapSet.new()

  defp active_tenant_ids(tenant_ids) do
    ids = Enum.uniq(tenant_ids)

    Tenant
    |> where([t], t.id in ^ids and t.status == :active)
    |> select([t], t.id)
    |> AdminRepo.all()
    |> MapSet.new()
  end

  # --- Nightly knowledge-lint consumer-stall detector (#765 item 6) ---

  @doc """
  Reserved sentinel `source_type` for the "the nightly pass is not completing at all"
  half of the consumer-stall detector. See `consumer_source_types/0`.
  """
  @spec consumer_pass_source_type() :: String.t()
  def consumer_pass_source_type, do: @consumer_pass_source_type

  @doc """
  Every reserved sentinel `source_type` the `:consumer_stalled` detector records under,
  newest-run-first order irrelevant: `consumer_pass_source_type/0` plus one per consumer
  class.

  One row PER CONSUMER rather than one per tenant, so the existing per-`source_type`
  operator escape hatches keep working at the granularity that matters: archiving a
  legitimately-paused draft drain must not blind the conflict judge as well.
  """
  @spec consumer_source_types() :: [String.t()]
  def consumer_source_types,
    do: [@consumer_pass_source_type | Enum.map(@consumer_classes, & &1.source_type)]

  @doc """
  Consecutive nightly runs a consumer must dispose of NOTHING before it is flagged.

  Resolution order is DB row -> app config -> module default, the same order (and the
  same reason) as `Loopctl.Workers.KnowledgeLintWorker`'s caps: this is the operator's
  only mid-incident lever over an alarm, and a lever that needs a deploy is not one.

  The default is #{@default_consumer_stall_runs}. Measured cadence on the hosted corpus
  2026-08-27: drafts arrive ~11 a night, `:generic_title` produces ~1, and
  `:duplicate_capture` produces 0-1 — so a 2-night window would fire on ordinary
  quiet, and 14+ is half a month of a dead consumer. Seven is also comfortably inside
  the 90-day `audit_log` retention this detector reads through, so the streak never
  spans a dropped partition.
  """
  @spec consumer_stall_runs() :: pos_integer()
  def consumer_stall_runs do
    max(
      tunable(
        "knowledge_consumer_stall_runs",
        :knowledge_consumer_stall_runs,
        @default_consumer_stall_runs
      ),
      1
    )
  end

  @doc """
  Hours since the last completed nightly pass past which the PASS itself is flagged.

  Same DB row -> app config -> module default resolution as `consumer_stall_runs/0`.
  The default is #{@default_consumer_pass_staleness_hours} — three consecutive missed
  nightly runs, which matches `staleness_threshold_hours/0`'s reasoning for capture
  silence and survives a deploy window or a single bad night. This is the half that
  catches #761: six consecutive nights died inside the judge with `Oban.TimeoutError`,
  wrote NO `knowledge.lint_completed` event at all, and nothing noticed.
  """
  @spec consumer_pass_staleness_hours() :: pos_integer()
  def consumer_pass_staleness_hours do
    max(
      tunable(
        "knowledge_consumer_pass_staleness_hours",
        :knowledge_consumer_pass_staleness_hours,
        @default_consumer_pass_staleness_hours
      ),
      1
    )
  end

  @doc """
  Hard cap on `knowledge.lint_completed` rows read per detection run.

  The read is bounded by `runs x tenants` already; this is the backstop that keeps it
  bounded when the tenant count grows, on the 3-connection AdminRepo pool.
  """
  @spec consumer_scan_limit() :: pos_integer()
  def consumer_scan_limit do
    max(
      tunable(
        "knowledge_consumer_scan_limit",
        :knowledge_consumer_scan_limit,
        @default_consumer_scan_limit
      ),
      1
    )
  end

  @doc """
  How far back the detector reads `knowledge.lint_completed` events, in whole days.

  DERIVED from the two thresholds rather than picked beside them — the #761 lesson, in
  which a 2000-call ceiling sat inside a 10-minute job because the two numbers were
  chosen independently. It is DOUBLE the longer of the two windows, so a tenant that
  misses up to half its nightly runs still has `consumer_stall_runs/0` events inside the
  window to judge, and it is CLAMPED to the `audit_log` retention (#{@audit_retention_days}
  days, `Loopctl.Workers.AuditPartitionWorker`), past which the rows this reads do not
  exist at all.

  The clamp is the detector's real coverage limit and it is worth stating plainly: a
  pass that has been dead longer than the retention leaves no events in the window, so
  the tenant becomes UNEVALUABLE rather than recovered. That is why recovery is gated on
  `:evaluated_keys` (see `auto_resolve_recovered_consumer_stalled/1`) — an open stall
  anomaly stays open instead of being auto-closed by its own evidence expiring.
  """
  @spec consumer_history_days() :: pos_integer()
  def consumer_history_days,
    do: consumer_history_days(consumer_stall_runs(), consumer_pass_staleness_hours())

  @doc false
  @spec consumer_history_days(pos_integer(), pos_integer()) :: pos_integer()
  def consumer_history_days(runs, pass_staleness_hours) do
    pass_days = ceil(pass_staleness_hours / 24)

    runs
    |> max(pass_days)
    |> Kernel.*(2)
    |> max(1)
    |> min(@audit_retention_days)
  end

  @doc """
  The nightly consumer-stall dead-man's-switch: candidates only.

  The worker uses `detect_consumer_stalled_scan/0,1` instead, because RECOVERY must be
  decided against the keys this run could actually JUDGE, not against the absence of a
  candidate — a tenant whose pass is so dead that its events aged out of the window has
  no candidate and has not recovered.
  """
  @spec detect_consumer_stalled() :: [consumer_candidate()]
  def detect_consumer_stalled, do: detect_consumer_stalled_scan().candidates

  @doc """
  `detect_consumer_stalled/0` with explicit config (`:consumer_stall_runs`,
  `:consumer_pass_staleness_hours`, `:consumer_scan_limit`), so a caller can drive
  detection without touching global app env.
  """
  @spec detect_consumer_stalled(map()) :: [consumer_candidate()]
  def detect_consumer_stalled(%{} = opts), do: detect_consumer_stalled_scan(opts).candidates

  @doc """
  `detect_consumer_stalled/0` plus the raw facts recovery needs.

  ## What it detects, and what it deliberately does not

  Once every queue class has an automatic consumer, the remaining failure is not a
  crash — a crash logs. It is a pass that completes and disposes of NOTHING, night
  after night, because a step is broken, starved of its shared wall-clock reserve, or
  gated off. In the audit event and the summary line alike, that night is
  byte-identical to a night on a clean corpus.

  So the detector separates the two the same way the truncation flags already do:

    * **Quiet** — the class was offered nothing and its gate was `open`. A clean corpus
      is quiet forever and MUST never alert. Quiet neither starts nor extends a streak.
    * **Work waiting** — the class had candidates (`*_offered`, `conflicts_judge_candidates`,
      or the consolidation report's own `by_class` proposal count, which is recorded
      even on a night the apply never ran) and applied zero.
    * **Hard-blind** — the step could not act at all: an `apply_failed` / `scan_failed`
      gate, the `-1` step-failed sentinel, or a wall-clock `*_budget_exhausted` that cut
      in before the first application. This counts on its own, because a step that
      crashes or is starved every night is a defect whether or not work happened to be
      waiting.
    * **Paused** — an operator set a cap to `0` (`drain_disabled`), the tenant has no
      embedding key (`no_embedding_key`), or the two-run agreement gate refused
      (`report_gap` / `insufficient_history`). These short-circuit BEFORE the candidate
      query, so the tally reports `offered: 0` and cannot say whether a queue is full or
      empty. A pause therefore counts only when work is corroborated independently —
      `by_class` for the two consolidation classes, `DraftConsumer.held_drafts?/1` for
      drafts. Without that a keyless tenant with an empty draft queue would alarm
      forever, which is how a real switch gets muted.

  A class is a candidate when, across the last `consumer_stall_runs/0` runs, it applied
  ZERO and at least one run showed work waiting or was hard-blind (or paused with work
  corroborated).

  ## The pass half

  A run that never completes writes no event, so a streak counted over EVENTS would
  freeze exactly when the system is broken — the detector becoming the thing it watches.
  The `consumer_pass_source_type/0` candidate closes that: an ESTABLISHED tenant (at
  least one completed run inside the window) whose most recent run is older than
  `consumer_pass_staleness_hours/0` is flagged, and the per-class checks only ever judge
  runs that did complete.

  ## Independence

  This reads `audit_log`, which `Loopctl.Workers.KnowledgeLintWorker` writes, and it runs
  from `Loopctl.Workers.IngestionHealthWorker` — a different worker, on a different
  queue, on a different cadence. Hosting it inside the nightly pass would have made a
  dead pass unable to report itself, which is the failure mode this whole class of
  detector exists to remove.

  Returns `t:consumer_scan/0`:

    * `:candidates` — the `{tenant, consumer}` pairs to flag.
    * `:evaluated_keys` — every `{tenant_id, source_type}` this run could actually judge.
      A key absent from it was NOT observed healthy; it was not observed at all, so
      recovery must leave its anomaly open.
    * `:truncated?` — the bounded read hit `consumer_scan_limit/0`, so tenants past the
      cut were not read. They are absent from `:evaluated_keys` by construction, so this
      flag is for observability rather than a recovery veto.
    * `:runs_scanned` — rows read, for observability.
  """
  @spec detect_consumer_stalled_scan() :: consumer_scan()
  def detect_consumer_stalled_scan, do: detect_consumer_stalled_scan(%{})

  @doc """
  `detect_consumer_stalled_scan/0` with explicit config (same option handling as
  `detect_consumer_stalled/1`).
  """
  @spec detect_consumer_stalled_scan(map()) :: consumer_scan()
  def detect_consumer_stalled_scan(%{} = opts) do
    now = DateTime.utc_now()
    runs = Map.get(opts, :consumer_stall_runs, consumer_stall_runs())
    pass_hours = Map.get(opts, :consumer_pass_staleness_hours, consumer_pass_staleness_hours())
    scan_limit = Map.get(opts, :consumer_scan_limit, consumer_scan_limit())
    cutoff = DateTime.add(now, -consumer_history_days(runs, pass_hours) * 86_400, :second)

    rows = consumer_runs(cutoff, runs, scan_limit)

    by_tenant =
      rows
      |> Enum.group_by(& &1.tenant_id)
      |> Enum.map(fn {tenant_id, tenant_rows} ->
        {tenant_id, Enum.sort_by(tenant_rows, & &1.inserted_at, {:desc, DateTime})}
      end)

    {candidates, evaluated} =
      Enum.reduce(by_tenant, {[], MapSet.new()}, fn {tenant_id, tenant_runs}, acc ->
        evaluate_tenant_consumers(tenant_id, tenant_runs, runs, pass_hours, now, acc)
      end)

    %{
      candidates: Enum.reverse(candidates),
      evaluated_keys: evaluated,
      truncated?: length(rows) >= scan_limit,
      runs_scanned: length(rows)
    }
  end

  # One tenant's whole reading: the pass freshness check (evaluable from a single run)
  # plus the per-class streak (evaluable only with a full window of runs).
  defp evaluate_tenant_consumers(
         tenant_id,
         tenant_runs,
         runs,
         pass_hours,
         now,
         {cands, evaluated}
       ) do
    {cands, evaluated} =
      case pass_candidate(tenant_id, tenant_runs, pass_hours, now) do
        nil -> {cands, evaluated}
        candidate -> {[candidate | cands], evaluated}
      end

    evaluated = MapSet.put(evaluated, {tenant_id, @consumer_pass_source_type})

    window = Enum.take(tenant_runs, runs)

    # A window SHORT of `runs` is not enough to judge a streak. Deliberately neither a
    # candidate nor an evaluated key: a tenant that ran the pass for the first time last
    # night has no drought to report, and one whose runs STOPPED is the pass half's
    # business — and leaving the key unevaluated is what keeps recovery from closing its
    # anomaly on evidence that went missing.
    if length(window) < runs,
      do: {cands, evaluated},
      else:
        Enum.reduce(
          @consumer_classes,
          {cands, evaluated},
          &class_step(&1, &2, tenant_id, window, now)
        )
  end

  # One class's contribution to the tenant's fold. Extracted so `evaluate_tenant_consumers/6`
  # stays inside Credo's nesting bar.
  defp class_step(class, {cands, evaluated}, tenant_id, window, now) do
    evaluated = MapSet.put(evaluated, {tenant_id, class.source_type})

    case class_candidate(tenant_id, class, window, now) do
      nil -> {cands, evaluated}
      candidate -> {[candidate | cands], evaluated}
    end
  end

  defp pass_candidate(tenant_id, [latest | _] = tenant_runs, pass_hours, now) do
    hours = max(hours_between(latest.inserted_at, now), 0)

    if hours > pass_hours do
      %{
        tenant_id: tenant_id,
        source_type: @consumer_pass_source_type,
        anomaly_type: :consumer_stalled,
        consumer: :pass,
        reason: :no_completion,
        hours_stale: hours,
        runs_examined: length(tenant_runs),
        evidence: %{
          "consumer" => "pass",
          "reason" => "no_completion",
          "hours_since_last_run" => hours,
          "threshold_hours" => pass_hours,
          "last_run_at" => iso8601(latest.inserted_at),
          "runs_in_window" => length(tenant_runs)
        }
      }
    end
  end

  defp class_candidate(tenant_id, class, window, now) do
    readings = Enum.map(window, &class_reading(class.key, &1.state))
    applied_total = readings |> Enum.map(&max(&1.applied, 0)) |> Enum.sum()
    work? = Enum.any?(readings, & &1.work?)
    hard_blind = Enum.count(readings, & &1.hard_blind?)
    paused = Enum.count(readings, & &1.paused?)
    oldest = List.last(window)

    stalled? =
      applied_total == 0 and
        (work? or hard_blind > 0 or (paused > 0 and corroborated?(class.key, tenant_id)))

    if stalled? do
      %{
        tenant_id: tenant_id,
        source_type: class.source_type,
        anomaly_type: :consumer_stalled,
        consumer: class.key,
        reason: :no_dispositions,
        hours_stale: max(hours_between(oldest.inserted_at, now), 0),
        runs_examined: length(window),
        evidence: %{
          "consumer" => to_string(class.key),
          "label" => class.label,
          "reason" => "no_dispositions",
          "runs_examined" => length(window),
          "applied_total" => applied_total,
          "work_observed" => work?,
          "hard_blind_runs" => hard_blind,
          "paused_runs" => paused,
          "gates" => readings |> Enum.map(& &1.gate) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
          "newest_run_at" => iso8601(hd(window).inserted_at),
          "oldest_run_at" => iso8601(oldest.inserted_at)
        }
      }
    end
  end

  # The ONE place a paused-but-uncorroborated class can still become a candidate, and it
  # is deliberately a LIVE read rather than another audit field: `drain_disabled` /
  # `no_embedding_key` short-circuit before the draft candidate query, so `drafts_offered`
  # is 0 whether the queue holds 113 drafts or none. The consolidation classes need no
  # equivalent — their `by_class` proposal count is written by the SCAN, which runs even
  # on a night the apply is paused. Guarded by the caller's `and`, so it is reached only
  # for a class that is otherwise about to be dismissed as quiet.
  defp corroborated?(:drafts, tenant_id), do: DraftConsumer.held_drafts?(tenant_id)
  defp corroborated?(_class, _tenant_id), do: false

  # Per-class reading of ONE night's audit event. Every key is read defensively: an event
  # written before a class existed simply has none of its keys, and that night is QUIET
  # for it — a step that did not run cannot have starved.
  defp class_reading(:drafts, state) do
    applied = int_at(state, "drafts_published")
    gate = string_at(state, "drafts_gate")
    budget_exhausted? = state_true?(state, "drafts_budget_exhausted")

    %{
      applied: applied,
      work?: int_at(state, "drafts_offered") > 0,
      hard_blind?: gate == "apply_failed" or (budget_exhausted? and applied == 0),
      paused?: gate in ["drain_disabled", "no_embedding_key"],
      gate: gate
    }
  end

  defp class_reading(:duplicates, state) do
    consolidation = map_at(state, "consolidation")
    applied = int_at(consolidation, "duplicates_unpublished")
    gate = string_at(consolidation, "duplicate_apply_gate")

    touched =
      int_at(consolidation, "duplicate_groups_skipped") +
        int_at(consolidation, "duplicates_unpublish_failed") +
        int_at(consolidation, "duplicate_groups_uncorroborated")

    %{
      applied: applied,
      work?: proposals_for(consolidation, "duplicate_capture") > 0 or touched > 0,
      hard_blind?: gate in ["apply_failed", "scan_failed"],
      paused?: gate in ["drain_disabled", "report_gap", "insufficient_history"],
      gate: gate
    }
  end

  defp class_reading(:generic_titles, state) do
    consolidation = map_at(state, "consolidation")
    applied = int_at(consolidation, "generic_titles_retitled")
    gate = string_at(consolidation, "generic_title_apply_gate")
    budget_exhausted? = state_true?(consolidation, "generic_title_budget_exhausted")

    %{
      applied: applied,
      work?:
        int_at(consolidation, "generic_titles_offered") > 0 or
          proposals_for(consolidation, "generic_title") > 0,
      hard_blind?:
        gate in ["apply_failed", "scan_failed"] or (budget_exhausted? and applied == 0),
      paused?: gate in ["drain_disabled", "report_gap", "insufficient_history"],
      gate: gate
    }
  end

  defp class_reading(:conflict_judge, state) do
    applied = int_at(state, "conflicts_judged_redundant")
    candidates = int_at(state, "conflicts_judge_candidates", 0)
    budget_exhausted? = state_true?(state, "conflicts_judge_budget_exhausted")

    %{
      applied: applied,
      work?: candidates > 0,
      # `-1` is the step-FAILED sentinel (`@judging_failed`), deliberately not 0 —
      # see `Loopctl.Workers.KnowledgeLintWorker`. It is the only field that can carry
      # a judge that died, because both truncation flags are hardcoded false there.
      hard_blind?: candidates == -1 or (budget_exhausted? and applied == 0),
      paused?: false,
      gate: nil
    }
  end

  defp proposals_for(consolidation, class) do
    consolidation |> map_at("by_class") |> int_at(class)
  end

  defp map_at(state, key) do
    case Map.get(state, key) do
      %{} = nested -> nested
      _ -> %{}
    end
  end

  defp int_at(state, key, default \\ 0) do
    case Map.get(state, key) do
      n when is_integer(n) -> n
      _ -> default
    end
  end

  defp string_at(state, key) do
    case Map.get(state, key) do
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp state_true?(state, key), do: Map.get(state, key) == true

  # The last `runs` completed passes PER TENANT, cross-tenant, in one bounded read.
  #
  # `row_number()` rather than a per-tenant query: the alternative is one round trip per
  # active tenant on the 3-connection AdminRepo pool, and the alternative to THAT — an
  # unwindowed read — is unbounded in a tenant's run history.
  #
  # `new_state - 'summary'` strips the lint report's own findings block, which is by far
  # the largest thing in the row and which no consumer reading here uses. What remains is
  # the tally: scalars plus the `consolidation` object.
  defp consumer_runs(cutoff, runs, scan_limit) do
    ranked =
      from(a in AuditLog,
        where: a.entity_type == ^@lint_entity_type,
        where: a.action == ^@lint_action,
        where: a.inserted_at >= ^cutoff,
        where: not is_nil(a.new_state),
        select: %{
          tenant_id: a.tenant_id,
          inserted_at: a.inserted_at,
          state: fragment("? - 'summary'::text", a.new_state),
          rn:
            fragment(
              "row_number() OVER (PARTITION BY ? ORDER BY ? DESC)",
              a.tenant_id,
              a.inserted_at
            )
        }
      )

    from(r in subquery(ranked),
      where: r.rn <= ^runs,
      order_by: [asc: r.tenant_id, desc: r.inserted_at],
      limit: ^scan_limit,
      select: %{tenant_id: r.tenant_id, inserted_at: r.inserted_at, state: r.state}
    )
    |> AdminRepo.all()
    |> Enum.map(&%{&1 | inserted_at: to_utc_datetime(&1.inserted_at), state: &1.state || %{}})
  end

  @doc """
  Closes `:consumer_stalled` anomalies whose consumer has RECOVERED.

  Episode-shaped like its two siblings — a stalled consumer has no natural "resumed"
  event — but with one difference that matters: recovery is gated on
  `scan.evaluated_keys` rather than on mere absence from `scan.candidates`. A key can be
  absent for two reasons that are NOT recovery: the tenant produced too few completed
  runs to judge a streak, or its events aged past `consumer_history_days/0` entirely
  because the pass has been dead for longer than that. Closing on either would stamp
  `resolved: true` into the append-only, hash-chained audit log as a claim that a
  consumer resumed, on the exact tenants where it most likely did not.

  Gated on the anomaly's tenant still being ACTIVE, for the same reason
  `auto_resolve_recovered_sweep_stalled/1` is: a suspended tenant stops producing runs,
  and that is not a consumer that recovered.

  Returns the number of anomalies closed.
  """
  @spec auto_resolve_recovered_consumer_stalled(consumer_scan()) :: non_neg_integer()
  def auto_resolve_recovered_consumer_stalled(%{
        candidates: candidates,
        evaluated_keys: evaluated
      }) do
    now = DateTime.utc_now()
    candidate_keys = MapSet.new(candidates, &{&1.tenant_id, &1.source_type})
    anomalies = active_episode_anomalies(:consumer_stalled)
    active_tenants = active_tenant_ids(Enum.map(anomalies, & &1.tenant_id))

    Enum.reduce(anomalies, 0, fn anomaly, acc ->
      key = {anomaly.tenant_id, anomaly.source_type}

      recovered? =
        MapSet.member?(active_tenants, anomaly.tenant_id) and
          MapSet.member?(evaluated, key) and
          not MapSet.member?(candidate_keys, key)

      if recovered?,
        do: acc + close_recovered_episode(anomaly, now, "auto_resolve_consumer_stalled"),
        else: acc
    end)
  end

  @doc """
  Whether the tenant has EVER seen ingestion activity for `source_type` — either a
  recorded write-outcome (`ingestion_write_stats`, the create-path telemetry) OR a
  persisted `articles` row (which covers non-create write paths like bulk/content
  ingestion that never emit create telemetry). Used by the controller to warn when a
  `source_type` filter names a genuinely never-seen source, so an EMPTY anomaly list is
  not mistaken for "healthy".

  The `unstamped_source_type/0` sentinel (`"(unstamped)"`) is special-cased: unstamped
  writes are stored with a NULL/empty `source_type`, so it probes those rows rather than
  matching the literal sentinel string (which no row carries) — otherwise a tenant with
  real unstamped traffic would be falsely warned "no recorded activity".

  The `sweep_source_type/0` sentinel (`"channel_post_sweep"`) is likewise special-cased
  and always reports SEEN: it names the retention-sweep detector rather than an
  ingestion stream, so no `articles`/`ingestion_write_stats` row will ever carry it and
  the generic probe would falsely warn on a legitimate filter.
  """
  @spec source_type_seen?(Ecto.UUID.t(), String.t()) :: boolean()
  def source_type_seen?(_tenant_id, @sweep_source_type), do: true

  # Same special case, for the consumer-stall sentinels: they name nightly consumers
  # rather than ingestion streams, so no `articles` / `ingestion_write_stats` row will
  # ever carry one and the generic probe would falsely warn on a legitimate filter.
  def source_type_seen?(_tenant_id, source_type)
      when source_type in [
             @consumer_pass_source_type,
             "knowledge_lint_drafts",
             "knowledge_lint_duplicates",
             "knowledge_lint_generic_titles",
             "knowledge_lint_conflict_judge"
           ],
      do: true

  def source_type_seen?(tenant_id, source_type) when is_binary(source_type) do
    write_stats_seen?(tenant_id, source_type) or articles_seen?(tenant_id, source_type)
  end

  defp write_stats_seen?(tenant_id, @unstamped_source_type) do
    IngestionWriteStats
    |> where([s], s.tenant_id == ^tenant_id and (is_nil(s.source_type) or s.source_type == ""))
    |> AdminRepo.exists?()
  end

  defp write_stats_seen?(tenant_id, source_type) do
    IngestionWriteStats
    |> where([s], s.tenant_id == ^tenant_id and s.source_type == ^source_type)
    |> AdminRepo.exists?()
  end

  defp articles_seen?(tenant_id, @unstamped_source_type) do
    Article
    |> where([a], a.tenant_id == ^tenant_id and is_nil(a.source_type))
    |> AdminRepo.exists?()
  end

  defp articles_seen?(tenant_id, source_type) do
    Article
    |> where([a], a.tenant_id == ^tenant_id and a.source_type == ^source_type)
    |> AdminRepo.exists?()
  end

  # --- Query surface (mirrors Loopctl.TokenUsage.list_anomalies/resolve_anomaly) ---

  @doc """
  Lists capture-silence anomalies for a tenant.

  ## Options (keyword list)

  - `:source_type` -- filter by source_type
  - `:anomaly_type` -- filter by anomaly type (`:capture_silence`)
  - `:resolved` -- filter by resolved status: `false` (default, unresolved only),
    `true` (resolved only), or `:all` (both — the complete timeline in one call)
  - `:include_archived` -- when `true`, include archived anomalies (default `false`)
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)

  For UNRESOLVED rows, `hours_stale` is recomputed at read time from
  `last_event_at` to now, so a long-running outage reports its TRUE current age
  rather than the frozen detection-time snapshot. Resolved rows keep their
  historical (detection-time) figures.

  ## Returns

  `{:ok, %{data: [IngestionAnomaly.t()], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_anomalies(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [IngestionAnomaly.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_anomalies(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size
    resolved = Keyword.get(opts, :resolved, false)
    include_archived = Keyword.get(opts, :include_archived, false)

    base_query =
      IngestionAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> apply_resolved_filter(resolved)
      |> apply_archive_filter(include_archived)
      |> apply_filter(:source_type, Keyword.get(opts, :source_type))
      |> apply_filter(:anomaly_type, Keyword.get(opts, :anomaly_type))

    total = AdminRepo.aggregate(base_query, :count, :id)

    data =
      base_query
      |> order_by([a], desc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()
      |> Enum.map(&refresh_staleness(&1, DateTime.utc_now()))

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  # `resolved: :all` returns both resolved and unresolved (the complete timeline);
  # a boolean narrows to that status. Default (false) is unresolved-only.
  defp apply_resolved_filter(query, :all), do: query
  defp apply_resolved_filter(query, resolved), do: where(query, [a], a.resolved == ^resolved)

  # Recompute hours_stale for an UNRESOLVED anomaly from its last_event_at to now,
  # so a long outage reports its true current age instead of the frozen
  # detection-time snapshot. Resolved rows keep their historical figures.
  defp refresh_staleness(%IngestionAnomaly{resolved: false, last_event_at: last} = anomaly, now)
       when not is_nil(last) do
    case hours_between(last, now) do
      hours when is_integer(hours) and hours > anomaly.hours_stale ->
        %{anomaly | hours_stale: hours}

      _ ->
        anomaly
    end
  end

  defp refresh_staleness(anomaly, _now), do: anomaly

  @doc """
  Gets a single ingestion anomaly by ID, scoped to a tenant.

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}`.
  """
  @spec get_anomaly(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found}
  def get_anomaly(tenant_id, anomaly_id) do
    case AdminRepo.get_by(IngestionAnomaly, id: anomaly_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      anomaly -> {:ok, anomaly}
    end
  end

  @doc """
  Marks an ingestion anomaly as resolved, writing an audit entry in the same transaction.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}` / `{:error, changeset}`.
  """
  @spec resolve_anomaly(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def resolve_anomaly(tenant_id, anomaly_id, opts \\ []) do
    with {:ok, anomaly} <- get_anomaly(tenant_id, anomaly_id) do
      # Idempotent + audit-honest: re-resolving an already-resolved anomaly is a
      # no-op that returns it as-is, so we never write a bogus `false -> true`
      # audit transition for a row that was already resolved.
      if anomaly.resolved,
        do: {:ok, anomaly},
        else: do_resolve(tenant_id, anomaly, opts)
    end
  end

  defp do_resolve(tenant_id, anomaly, opts) do
    transition(
      tenant_id,
      anomaly,
      opts,
      :resolved,
      false,
      true,
      "resolved",
      &IngestionAnomaly.resolve_changeset/1
    )
  end

  @doc """
  Archives an ingestion anomaly, writing an audit entry in the same transaction.

  Archiving is the operator's escape hatch for a legitimately-retired
  `source_type`: an archived anomaly is hidden from the default list AND suppresses
  re-detection for that source_type in `Loopctl.Workers.IngestionHealthWorker`, so a
  wound-down workflow is not re-flagged on every hourly run. It is REVERSIBLE via
  `unarchive_anomaly/3` — a mistaken archive (e.g. a workflow later revived) can be
  undone to restore monitoring, so the escape hatch is not a permanent blind spot.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}` / `{:error, changeset}`.
  Re-archiving an already-archived anomaly is an idempotent no-op.
  """
  @spec archive_anomaly(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def archive_anomaly(tenant_id, anomaly_id, opts \\ []) do
    with {:ok, anomaly} <- get_anomaly(tenant_id, anomaly_id) do
      if anomaly.archived,
        do: {:ok, anomaly},
        else: do_archive(tenant_id, anomaly, opts)
    end
  end

  defp do_archive(tenant_id, anomaly, opts) do
    transition(
      tenant_id,
      anomaly,
      opts,
      :archived,
      false,
      true,
      "archived",
      &IngestionAnomaly.archive_changeset/1
    )
  end

  @doc """
  Un-archives an ingestion anomaly — the inverse of `archive_anomaly/3`.

  Restores monitoring for a source_type whose anomaly was archived: once
  un-archived, `Loopctl.Workers.IngestionHealthWorker` no longer suppresses
  re-detection, so a revived-then-silent workflow is caught again. This is what
  keeps archive from being an irreversible, permanent blind spot. Writes an
  audit entry in the same transaction. Un-archiving a non-archived anomaly is an
  idempotent no-op.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}` / `{:error, changeset}`.
  """
  @spec unarchive_anomaly(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def unarchive_anomaly(tenant_id, anomaly_id, opts \\ []) do
    with {:ok, anomaly} <- get_anomaly(tenant_id, anomaly_id) do
      if anomaly.archived,
        do: do_unarchive(tenant_id, anomaly, opts),
        else: {:ok, anomaly}
    end
  end

  defp do_unarchive(tenant_id, anomaly, opts) do
    transition(
      tenant_id,
      anomaly,
      opts,
      :archived,
      true,
      false,
      "unarchived",
      &IngestionAnomaly.unarchive_changeset/1
    )
  end

  @doc """
  Auto-resolves open anomalies whose captures have RESUMED.

  Scans every unresolved, non-archived capture-silence anomaly and, when at least
  one article of that `(tenant, source_type)` has arrived AFTER the anomaly's
  `last_event_at`, resolves it (actor_type "system"). Without this an anomaly for
  a fully-recovered stream would stay open forever showing frozen figures, so an
  operator could not tell "recovered" from "still silent". Called by the hourly
  worker. Returns the number of anomalies auto-resolved.
  """
  @spec auto_resolve_recovered() :: non_neg_integer()
  def auto_resolve_recovered do
    # Set-based recovery filter: load ONLY the anomalies that already have a newer
    # article (i.e. captures genuinely resumed), via a correlated EXISTS — ONE query
    # instead of an `exists?` per open anomaly (the previous N+1 that grew with the
    # open-anomaly count during a widespread incident). The per-row resolve below is
    # then necessary work (locked flip + audit entry) run only for recovered rows.
    recovered =
      from(a in IngestionAnomaly, as: :anomaly)
      |> where([anomaly: a], a.resolved == false and a.archived == false)
      |> where([anomaly: a], a.anomaly_type == :capture_silence)
      |> where([anomaly: a], not is_nil(a.last_event_at))
      |> where(
        [anomaly: a],
        exists(
          from(art in Article,
            where:
              art.tenant_id == parent_as(:anomaly).tenant_id and
                art.source_type == parent_as(:anomaly).source_type and
                art.inserted_at > parent_as(:anomaly).last_event_at
          )
        )
      )
      |> AdminRepo.all()

    Enum.reduce(recovered, 0, fn anomaly, acc ->
      case do_resolve(anomaly.tenant_id, anomaly,
             actor_type: "system",
             actor_label: "ingestion_health:auto_resolve"
           ) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  @doc """
  Closes `:high_reject_rate` anomalies whose reject rate has RECOVERED.

  A rejected write has no natural "resumed" signal like capture-silence's newer
  article, so recovery is defined as: the `(tenant, source_type)` is no longer a
  current reject candidate (rate dropped back below threshold, or volume fell below
  the noise floor). `current_candidates` is the SAME list the worker just computed,
  so this shares one scan of the rollup.

  For each ACTIVE reject anomaly (archived == false and `last_event_at IS NULL`, which
  covers both open rows and operator-resolved-but-still-active episodes) whose
  `(tenant, source_type)` is NOT in the candidate set, it stamps `last_event_at` with
  the recovery time (marking the episode ENDED) and sets `resolved: true`. Two
  problems are fixed at once:

  - **Open anomalies never froze open**: a recovered stream's open anomaly is resolved
    instead of staying `resolved: false` forever with stale figures.
  - **Resolved-suppression re-arms**: `Loopctl.Workers.IngestionHealthWorker`'s
    `resolved_reject_suppression?` only counts resolved rows with `last_event_at IS
    NULL`, so once recovery stamps `last_event_at` the resolved row stops suppressing —
    a FUTURE reject storm for the same source_type re-fires instead of being silenced
    forever. Mirrors how capture-silence re-arms when `last_event_at` advances.

  Returns the number of anomalies closed. Called by the hourly worker.
  """
  @spec auto_resolve_recovered_reject_rate([reject_candidate()]) :: non_neg_integer()
  def auto_resolve_recovered_reject_rate(current_candidates) do
    active_keys = MapSet.new(current_candidates, &{&1.tenant_id, &1.source_type})
    now = DateTime.utc_now()

    :high_reject_rate
    |> active_episode_anomalies()
    |> Enum.reduce(0, fn anomaly, acc ->
      if MapSet.member?(active_keys, {anomaly.tenant_id, anomaly.source_type}),
        do: acc,
        else: acc + close_recovered_episode(anomaly, now, "auto_resolve_reject_rate")
    end)
  end

  # The ONE close path for both episode-shaped detectors (`:high_reject_rate`,
  # `:sweep_stalled`) — they differ only in the audit `actor_label`, so parameterizing
  # it keeps this audit-chain-writing transaction correct in exactly one place.
  #
  # Stamps the recovery time (episode ended) + marks resolved, auditing the resolve
  # transition only when the row was previously unresolved (an already-resolved row is
  # a system bookkeeping mark, not a state change worth a resolved-audit entry).
  #
  # The candidate struct was bulk-loaded UNLOCKED by the caller (AdminRepo.all, no FOR
  # UPDATE). If an operator PATCH-resolves or archives the same anomaly between that load
  # and this transaction, `anomaly.resolved` would be STALE (false), so trusting it would
  # write a bogus resolved:false->true entry into the append-only, hash-chained audit log
  # for a flip that already happened. So re-read the row FOR UPDATE inside the transaction
  # and compute `was_resolved` from the LOCKED row — matching transition/8's locked,
  # audit-honest flip.
  defp close_recovered_episode(%IngestionAnomaly{id: id, tenant_id: tenant_id}, now, actor_label) do
    multi =
      Multi.new()
      |> Multi.run(:locked, fn repo, _changes ->
        locked =
          IngestionAnomaly
          |> where([a], a.id == ^id and a.tenant_id == ^tenant_id)
          |> lock("FOR UPDATE")
          |> repo.one()

        {:ok, locked}
      end)
      |> Multi.run(:anomaly, fn repo, %{locked: locked} ->
        case locked do
          nil -> {:error, :not_found}
          row -> row |> IngestionAnomaly.episode_recovered_changeset(now) |> repo.update()
        end
      end)
      |> Multi.run(:audit, fn repo, %{locked: locked, anomaly: updated} ->
        if locked.resolved do
          {:ok, :skipped}
        else
          audit_insert(
            repo,
            audit_attrs(
              tenant_id,
              updated.id,
              "resolved",
              [actor_type: "system", actor_label: "ingestion_health:#{actor_label}"],
              %{old_state: %{"resolved" => false}, new_state: %{"resolved" => true}}
            )
          )
        end
      end)

    case AdminRepo.transaction(multi) do
      {:ok, _} -> 1
      {:error, _step, _reason, _changes} -> 0
    end
  end

  @doc """
  Prunes `ingestion_write_stats` rows older than `write_stats_retention_days`.

  The rollup is append-only (one row per tenant/source_type/day) and only the rolling
  `reject_window_days` window is ever read, so without pruning it would grow forever.
  Deletes by the day-leading index (`day < cutoff`). Called by the hourly worker.
  Returns the number of rows deleted.
  """
  @spec prune_write_stats() :: non_neg_integer()
  def prune_write_stats do
    cutoff = Date.add(Date.utc_today(), -write_stats_retention_days())

    {deleted, _} =
      IngestionWriteStats
      |> where([s], s.day < ^cutoff)
      |> AdminRepo.delete_all()

    deleted
  end

  # --- Private helpers ---

  # Locked, audit-honest boolean flip: re-reads the row FOR UPDATE inside the
  # transaction and only updates + audits when it is actually in the `from` state.
  # Two concurrent callers therefore serialize — the first transitions and audits,
  # the second observes the row already at `to` and is a no-op with NO bogus audit
  # entry (the append-only log never records a transition that did not happen).
  defp transition(tenant_id, anomaly, opts, field, from, to, action, changeset_fun) do
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes ->
      locked =
        IngestionAnomaly
        |> where([a], a.id == ^anomaly.id and a.tenant_id == ^tenant_id)
        |> lock("FOR UPDATE")
        |> repo.one()

      {:ok, locked}
    end)
    |> Multi.run(:anomaly, fn repo, %{locked: locked} ->
      cond do
        is_nil(locked) -> {:error, :not_found}
        Map.fetch!(locked, field) == from -> repo.update(changeset_fun.(locked))
        true -> {:ok, locked}
      end
    end)
    |> Multi.run(:audit, fn repo, %{locked: locked, anomaly: updated} ->
      if not is_nil(locked) and Map.fetch!(locked, field) == from do
        audit_insert(
          repo,
          audit_attrs(tenant_id, updated.id, action, opts, %{
            old_state: %{Atom.to_string(field) => from},
            new_state: %{Atom.to_string(field) => to}
          })
        )
      else
        {:ok, :skipped}
      end
    end)
    |> run_anomaly_multi()
  end

  # Inserts an audit entry via the transaction's repo (keeps audit atomic with the
  # anomaly update), mirroring Loopctl.Audit.log_in_multi's changeset construction.
  defp audit_insert(repo, attrs) do
    {tenant_id, attrs} = Map.pop(attrs, :tenant_id)

    attrs
    |> AuditLog.create_changeset()
    |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
    |> repo.insert()
  end

  defp audit_attrs(tenant_id, entity_id, action, opts, states) do
    Map.merge(
      %{
        tenant_id: tenant_id,
        entity_type: "ingestion_anomaly",
        entity_id: entity_id,
        action: action,
        actor_type: Keyword.get(opts, :actor_type, "api_key"),
        actor_id: Keyword.get(opts, :actor_id),
        actor_label: Keyword.get(opts, :actor_label)
      },
      states
    )
  end

  defp run_anomaly_multi(multi) do
    case AdminRepo.transaction(multi) do
      {:ok, %{anomaly: anomaly}} -> {:ok, anomaly}
      {:error, :anomaly, changeset, _} -> {:error, changeset}
      {:error, _step, error, _} -> {:error, error}
    end
  end

  # Exclude archived anomalies by default; include them when requested.
  defp apply_archive_filter(query, true), do: query
  defp apply_archive_filter(query, _), do: where(query, [a], a.archived == false)

  defp apply_filter(query, _field, nil), do: query
  defp apply_filter(query, _field, ""), do: query

  defp apply_filter(query, :source_type, value) when is_binary(value),
    do: where(query, [a], a.source_type == ^value)

  defp apply_filter(query, :anomaly_type, value) when is_binary(value) do
    known = Enum.map(IngestionAnomaly.anomaly_types(), &Atom.to_string/1)

    if value in known do
      atom_val = String.to_existing_atom(value)
      where(query, [a], a.anomaly_type == ^atom_val)
    else
      where(query, [_a], false)
    end
  end

  defp apply_filter(query, :anomaly_type, value) when is_atom(value),
    do: where(query, [a], a.anomaly_type == ^value)

  # Whole hours between an aggregate max(inserted_at) and now. `max/1` over a
  # :utc_datetime_usec column can come back as a NaiveDateTime, so normalize both.
  defp hours_between(nil, _now), do: nil

  defp hours_between(last, now) do
    div(DateTime.diff(now, to_utc_datetime(last), :second), 3600)
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp iso8601(nil), do: nil
  defp iso8601(value), do: value |> to_utc_datetime() |> DateTime.to_iso8601()

  # DB row -> app config -> module default, the resolution order (and the reasoning)
  # `Loopctl.Workers.KnowledgeLintWorker.tunable/3` established for the nightly caps: the
  # DB row is the only layer an operator can move mid-incident without a deploy, and it
  # survives a restart and propagates to the fleet, which `Application.put_env/3` does
  # neither of. `SystemConfig.get_int/2` reads `:persistent_term` and never raises, so
  # this costs no query.
  #
  # Used ONLY by the consumer-stall knobs. The older accessors above stay app-config-only
  # deliberately: retrofitting them is a behaviour change to detectors nobody asked to
  # change here.
  defp tunable(db_key, app_key, default) do
    SystemConfig.get_int(db_key, coerce_int(Application.get_env(:loopctl, app_key), default))
  end

  # `SystemConfig.get_int/2` requires an INTEGER default and would raise a
  # FunctionClauseError on a `nil` or a `"7"` from a hand-edited config — inside the
  # worker's rescue that surfaces as an outage rather than the config typo it is.
  defp coerce_int(value, _default) when is_integer(value), do: value
  defp coerce_int(nil, default), do: default

  defp coerce_int(other, default) do
    Logger.warning(
      "IngestionHealth: ignoring non-integer consumer-stall setting #{inspect(other)}; " <>
        "using #{default}."
    )

    default
  end
end
