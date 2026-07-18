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
  `:capture_silence` candidate. A tenant that never produced captures of a
  source_type is never flagged (it was never established), so this fires only on
  genuine *went-silent* regressions.

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
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
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
  """
  @spec source_type_seen?(Ecto.UUID.t(), String.t()) :: boolean()
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

    IngestionAnomaly
    |> where([a], a.anomaly_type == :high_reject_rate)
    |> where([a], a.archived == false)
    |> where([a], is_nil(a.last_event_at))
    |> AdminRepo.all()
    |> Enum.reduce(0, fn anomaly, acc ->
      if MapSet.member?(active_keys, {anomaly.tenant_id, anomaly.source_type}),
        do: acc,
        else: acc + close_recovered_reject(anomaly, now)
    end)
  end

  # Stamp the recovery time (episode ended) + mark resolved, auditing the resolve
  # transition only when the row was previously unresolved (an already-resolved row is
  # a system bookkeeping mark, not a state change worth a resolved-audit entry).
  defp close_recovered_reject(%IngestionAnomaly{tenant_id: tenant_id} = anomaly, now) do
    was_resolved = anomaly.resolved

    multi =
      Multi.new()
      |> Multi.run(:anomaly, fn repo, _changes ->
        anomaly |> IngestionAnomaly.reject_recovered_changeset(now) |> repo.update()
      end)
      |> Multi.run(:audit, fn repo, %{anomaly: updated} ->
        if was_resolved do
          {:ok, :skipped}
        else
          audit_insert(
            repo,
            audit_attrs(
              tenant_id,
              updated.id,
              "resolved",
              [actor_type: "system", actor_label: "ingestion_health:auto_resolve_reject_rate"],
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
