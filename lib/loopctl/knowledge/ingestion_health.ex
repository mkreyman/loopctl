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
  - `:sweep_scan_limit` -- default `100_000` (hard cap on the residue rows scanned per
    detection, so the cross-tenant read stays bounded on the small AdminRepo pool). MUST
    stay above `sweep_drain_rate_per_hour * sweep_staleness_hours` or the drain-capacity
    rule below becomes unreachable — see "Stalled vs merely BACKLOGGED".

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

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionWriteStats
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
end
