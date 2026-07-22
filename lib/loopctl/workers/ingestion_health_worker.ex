defmodule Loopctl.Workers.IngestionHealthWorker do
  @moduledoc """
  Oban worker that runs the ingestion **capture-silence** dead-man's-switch.

  Sibling of `Loopctl.Workers.CostAnomalyWorker`. Each run asks
  `Loopctl.Knowledge.IngestionHealth.detect/0` for capture-silence candidates
  (an established article `source_type` for a tenant whose most recent article is
  older than the staleness threshold) and, for each genuinely-new anomaly, records
  it and raises the alarm:

  - a `Loopctl.Audit` entry (`entity_type: "ingestion_anomaly"`, `action: "detected"`,
    `actor_type: "system"`),
  - an always-on operator-visible `Logger.error` (so a detected silence surfaces in
    logs/monitoring even when no optional alert channel or webhook is configured),
  - an OPERATOR alert enqueued via `Loopctl.Workers.ScaleAlertDeliveryWorker` (which
    resolves `SCALE_ALERT_WEBHOOK_URL` itself and no-ops when unset — channel-agnostic
    and safe when unconfigured; this worker never reads the URL), and
  - a per-tenant `knowledge.ingestion_anomaly_detected` webhook event.

  On an EXISTING unresolved anomaly it silently refreshes the figures — NO re-notify
  (anti-alarm-fatigue), exactly like `CostAnomalyWorker` — UNLESS that row was never
  successfully alerted (`alerted: false`), in which case it re-fires the operator
  alert + webhook once (at-least-once recovery; see "Alert durability" below).

  ## Retention-sweep stall detector (`:sweep_stalled`, #498)

  The same run also drives `IngestionHealth.detect_sweep_stalled/0` — the
  absence-of-success detector for the US-39.5 channel-post retention sweep
  (`Loopctl.Workers.ChannelPostSweeper`), which flags any tenant still holding expired
  `channel_posts` well past `expires_at`. It is hosted HERE rather than in a new worker
  because it is the same detector class and reuses this module's entire tested
  persist/notify/at-least-once/recovery machinery; a parallel worker would duplicate all
  of it for one query. Its anomalies are `:sweep_stalled` rows under the reserved
  sentinel `source_type` `IngestionHealth.sweep_source_type/0`.

  ### One GLOBAL cause ⇒ ONE operator alert

  `ChannelPostSweeper` is a single global, tenant-independent worker, so the failure this
  detector exists for ("the sweep is not running") is ONE event that happens to leave
  residue in N tenants. The per-tenant anomaly ROW and the per-tenant
  `coordination.channel_post_sweep_stalled` webhook stay per-tenant (a tenant subscriber
  cares about its OWN retention), but the OPERATOR alert is emitted ONCE PER RUN at
  system scope (`fire_sweep_system_alert/1`), listing the affected tenants, instead of
  N identical `ScaleAlertDeliveryWorker` jobs saying one thing. `notify/2` therefore
  skips the per-tenant operator alert for `:sweep_stalled` only — every other type keeps
  it, because for them the CAUSE really is per-tenant.

  That webhook is a DISTINCT event type from `knowledge.ingestion_anomaly_detected`
  (#498 review): the anomaly record and the alert machinery are reused, but a
  coordination retention event is not a knowledge-ingestion event and must not be pushed
  at subscribers who opted into the latter.

  ### Alert durability for the ONE system alert

  Because the type's only operator signal is emitted once per RUN rather than once per
  candidate, the `alerted` flip cannot happen during flagging — that would make the alert
  AT-MOST-once (rows committed as alerted, then an exception or a failed `Oban.insert`
  drops the single alert, and every later run takes the silent update path). So
  `notify/2` fires only the per-tenant webhook for `:sweep_stalled`, and
  `commit_sweep_system_alert/2` enqueues the system alert FIRST and marks the
  participating anomalies alerted only on success.

  ### Isolated failure domain

  `run_sweep_stalled_detection/0` is wrapped in its own rescue: its residue read is a
  cross-tenant aggregate on the small `AdminRepo` pool, and a statement timeout or
  checkout failure there must NOT take down capture-silence flagging, reject-rate
  recovery, or write-stats pruning in the same hourly job. Both failure shapes emit
  `Loopctl.TelemetryEvents.sweep_stall_detection_failed/0` so that isolation never makes
  the monitor's own death silent.

  ## Recovery: auto-resolve when the outage clears

  After detection, `Loopctl.Knowledge.IngestionHealth.auto_resolve_recovered/0`
  closes any open capture-silence anomaly whose `(tenant, source_type)` has produced
  an article newer than the anomaly's `last_event_at`.
  `auto_resolve_recovered_reject_rate/1` does the analogous close for high_reject_rate
  anomalies whose reject rate fell back below threshold (no longer a candidate).
  Without this a fully-recovered stream would keep a stale open anomaly forever,
  indistinguishable from an ongoing outage. The reject-rate close ALSO stamps
  `last_event_at` (episode ended), which re-arms suppression — see below.

  ## Suppression: resolve sticks, archive suppresses (reversibly)

  A resolved anomaly is NOT re-created on the next run just because the source_type
  is still silent — that would re-fire audit + operator alert + webhook every hour
  and defeat the whole point of resolving. `flag_candidate/1` suppresses re-creation
  while the current silence is already covered by a resolved anomaly (its
  `last_event_at` snapshot is at/after the candidate's), and only re-flags once
  captures RESUME (advancing `last_event_at`) and then go silent again.

  An **archived** anomaly suppresses re-detection for that source_type (the operator's
  escape hatch for a legitimately-retired workflow) — regardless of its resolved flag.
  Archiving is REVERSIBLE (`IngestionHealth.unarchive_anomaly/3`): un-archiving lifts
  the suppression, so it is not a permanent blind spot.

  ## Alert durability (at-least-once)

  The anomaly row + `detected` audit are inserted atomically, but the operator alert
  + webhook enqueues run POST-commit (they can't join the AdminRepo transaction — Oban
  jobs insert through `Loopctl.Repo`). A crash between commit and enqueue would leave
  an unresolved row with `alerted: false`; the next run detects that and re-fires the
  notifications rather than silently losing them on the no-notify update path.

  ## Race-safety

  Creation uses the same `insert_all` + `on_conflict: :nothing` against a unique
  partial index (`ingestion_anomalies_unresolved_unique`) that `CostAnomalyWorker`
  uses: `{1, [row]}` means we genuinely inserted (notify); `{0, _}` means a concurrent
  run already inserted + notified (skip). We still check-first so an update never emits
  audit/webhook.

  ## Atomic detection record

  The anomaly row insert and its `detected` audit entry are written in ONE
  `AdminRepo` transaction, so a crash mid-notify can never leave a persisted anomaly
  without its audit record (an Oban retry would otherwise find the row and take the
  no-notify update path, permanently losing the audit entry). The operator alert and
  webhook enqueues stay post-commit — they are Oban-durable once enqueued.

  ## Schedule

  Registered on the Oban crontab (hourly) in `Loopctl.ObanConfig.plugins/0` with a
  hardcoded schedule — no new env var gates app boot.
  """

  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: 600, fields: [:worker, :queue]]

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionHealth
  alias Loopctl.TelemetryEvents
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.ScaleAlertDeliveryWorker
  alias Loopctl.Workers.WebhookDeliveryWorker

  @webhook_event_type "knowledge.ingestion_anomaly_detected"

  # #498 review: `:sweep_stalled` is a COORDINATION retention event, not a knowledge
  # ingestion one. It reuses the anomaly RECORD and the alert machinery, but delivering it
  # on the knowledge event type would push coordination events at every tenant that
  # subscribed to watch KB ingestion, with no opt-out. It gets its own event type so a
  # subscriber opts in explicitly (`Loopctl.Webhooks.Webhook.valid_event_types/0`).
  @sweep_webhook_event_type "coordination.channel_post_sweep_stalled"

  # Bound on the `tenant_ids` sample carried in the system-scope sweep-stall alert: the
  # blast radius is reported as an exact `affected_tenants` count, so the id list is a
  # debugging sample, not an unbounded payload.
  @alert_tenant_sample 50

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if anomalies_table_ready?() do
      run()
    else
      # Version skew: code deployed on the hourly crontab before its table
      # migration landed. Skip quietly (self-heals next run) instead of crashing
      # the job and burning Oban retries on an UndefinedTable error.
      Logger.warning(
        "IngestionHealthWorker: ingestion_anomalies table not present yet " <>
          "(migration pending); skipping this run"
      )

      :ok
    end
  end

  defp run do
    candidates = IngestionHealth.detect()

    Logger.info(
      "IngestionHealthWorker: #{length(candidates)} capture-silence candidate(s) detected"
    )

    flag_candidates(candidates, :capture_silence)

    # PR B2: the no-persist / high-rejection-rate sibling detector. A rejected write
    # leaves no article row, so it is invisible to the capture-silence scan above;
    # this reads the durable `ingestion_write_stats` rollup instead.
    run_reject_rate_detection()

    # #498: the retention-sweep dead-man's-switch. Same detector class (absence of
    # expected success), same alert/recovery/webhook machinery — reused rather than
    # duplicated in a bespoke worker.
    run_sweep_stalled_detection()

    # Close capture-silence anomalies whose captures have resumed (recovered streams),
    # so an open anomaly always means "still silent" and not "recovered but never
    # cleared".
    resolved = IngestionHealth.auto_resolve_recovered()

    if resolved > 0 do
      Logger.info("IngestionHealthWorker: auto-resolved #{resolved} recovered anomaly(ies)")
    end

    :ok
  end

  # Reject-rate detection, recovery, and rollup pruning all read/write the
  # `ingestion_write_stats` table; guard the version-skew window (code on the hourly
  # crontab before the migration landed) exactly like the anomalies-table probe, so a
  # missing rollup table skips quietly instead of crashing the job. Crucially, recovery
  # is guarded TOO: an empty candidate list from a MISSING table must not be read as
  # "everything recovered" and mass-close active reject anomalies.
  defp run_reject_rate_detection do
    if write_stats_table_ready?() do
      reject_candidates = IngestionHealth.detect_high_reject_rate()

      Logger.info(
        "IngestionHealthWorker: #{length(reject_candidates)} high-reject-rate candidate(s) detected"
      )

      flag_candidates(reject_candidates, :high_reject_rate)

      # Close reject-rate anomalies whose reject rate recovered (no longer a candidate).
      # This resolves open rows that would otherwise freeze open, AND stamps the
      # recovery time so a resolved row stops suppressing a FUTURE storm (re-arm).
      closed = IngestionHealth.auto_resolve_recovered_reject_rate(reject_candidates)

      if closed > 0 do
        Logger.info(
          "IngestionHealthWorker: auto-closed #{closed} recovered high-reject-rate anomaly(ies)"
        )
      end

      # Retention: the rollup is append-only and only the rolling window is read, so
      # prune aged rows to keep the table (and the cross-tenant scan) bounded.
      pruned = IngestionHealth.prune_write_stats()

      if pruned > 0 do
        Logger.info("IngestionHealthWorker: pruned #{pruned} aged ingestion_write_stats row(s)")
      end
    else
      Logger.warning(
        "IngestionHealthWorker: ingestion_write_stats table not present yet " <>
          "(migration pending); skipping reject-rate detection this run"
      )

      :ok
    end
  end

  # The channel-post retention-sweep stall detector (#498). Gated on the CHECK-widening
  # migration exactly like the reject-rate path: in the version-skew window (this code
  # on the hourly crontab before `20260722090000_add_sweep_stalled_anomaly_type` landed)
  # a sweep_stalled insert would raise a CHECK violation inside the Multi and burn Oban
  # retries, so skip quietly and self-heal next run. Recovery is guarded TOO — an empty
  # candidate list from a skipped detection must never be read as "everything recovered"
  # and mass-close active stall anomalies.
  #
  # Wrapped in its OWN rescue: the residue read is an aggregate over `channel_posts` on
  # the 3-connection AdminRepo pool, and a statement timeout / checkout failure here must
  # not abort the whole hourly job (which would also stop capture-silence flagging,
  # reject-rate recovery and write-stats pruning). Oban retries buy nothing for a pool
  # that is saturated right now; the next hourly run re-detects.
  #
  # The isolation must not make the MONITOR's own death silent (#498 review): both
  # failure shapes emit `TelemetryEvents.sweep_stall_detection_failed/0` alongside the
  # error log, so a persistently failing residue read is observable outside the log
  # stream — otherwise the dead-man's switch reproduces, one level up, the
  # assumed-healthy failure it exists to close.
  defp run_sweep_stalled_detection do
    do_run_sweep_stalled_detection()
  rescue
    error ->
      Logger.error(
        "IngestionHealthWorker: sweep-stall detection failed (#{inspect(error.__struct__)}): " <>
          "#{Exception.message(error)}; other detectors continue"
      )

      observe_detection_failure(error.__struct__ |> Module.split() |> Enum.join("."))
  catch
    :exit, reason ->
      Logger.error(
        "IngestionHealthWorker: sweep-stall detection exited (#{inspect(reason)}); " <>
          "other detectors continue"
      )

      observe_detection_failure("exit")
  end

  # Bounded `error_class` tag only — never the failure's message (which can carry SQL or
  # bound params). Returns `:ok` so the isolated failure domain still yields `:ok`.
  defp observe_detection_failure(error_class) do
    :telemetry.execute(
      TelemetryEvents.sweep_stall_detection_failed(),
      %{count: 1},
      %{error_class: error_class}
    )

    :ok
  end

  defp do_run_sweep_stalled_detection do
    if sweep_stalled_check_ready?() do
      scan = IngestionHealth.detect_sweep_stalled_scan()
      candidates = scan.candidates

      Logger.info(
        "IngestionHealthWorker: #{length(candidates)} sweep-stalled candidate(s) detected"
      )

      # A truncated scan means DEGRADED COVERAGE, not "all clear": the LIMIT is
      # install-wide and oldest-first, so a tenant whose residue is newer than the sample
      # cutoff is invisible to THIS run. Recovery already refuses to close on it; say so
      # out loud rather than letting the gap be silent.
      if scan.truncated? do
        Logger.warning(
          "IngestionHealthWorker: sweep-stall residue scan TRUNCATED at " <>
            "#{scan.scanned} rows — tenant coverage is incomplete this run and no " <>
            "stall anomaly will be auto-closed"
        )
      end

      candidates
      |> flag_candidates(:sweep_stalled)
      |> fire_sweep_system_alert()

      # Recovery is decided on the RAW scan (residue set + truncation), never on the
      # post-capacity-filter candidate list — see
      # IngestionHealth.auto_resolve_recovered_sweep_stalled/1.
      closed = IngestionHealth.auto_resolve_recovered_sweep_stalled(scan)

      if closed > 0 do
        Logger.info("IngestionHealthWorker: auto-closed #{closed} recovered sweep-stall(s)")
      end

      :ok
    else
      Logger.warning(
        "IngestionHealthWorker: ingestion_anomalies CHECK does not admit 'sweep_stalled' yet " <>
          "(migration pending); skipping sweep-stall detection this run"
      )

      :ok
    end
  end

  # Reject-rate detection needs BOTH the rollup table (migration 20260717210000) AND
  # the WIDENED anomaly_type CHECK that admits 'high_reject_rate' (migration
  # 20260717210001). In a partial deploy where the first migration landed but the
  # second did not, a high_reject_rate insert would raise a CHECK violation inside the
  # Multi and fail the Oban job. Gate on both so the reject path skips quietly (and
  # self-heals next run) until the CHECK is widened, instead of burning retries.
  defp write_stats_table_ready? do
    relation_present?("ingestion_write_stats") and high_reject_rate_check_ready?()
  end

  defp relation_present?(relation) do
    case AdminRepo.query("SELECT to_regclass($1)", [relation]) do
      {:ok, %{rows: [[nil]]}} -> false
      {:ok, _} -> true
      _ -> false
    end
  end

  # True once the ingestion_anomalies anomaly_type CHECK admits 'high_reject_rate'.
  defp high_reject_rate_check_ready?, do: anomaly_type_check_admits?("high_reject_rate")

  # True once that CHECK admits 'sweep_stalled' (#498).
  defp sweep_stalled_check_ready?, do: anomaly_type_check_admits?("sweep_stalled")

  # Reads the constraint definition from the catalog (crash-free): absent constraint
  # or a definition that does not yet mention the value ⇒ not ready.
  defp anomaly_type_check_admits?(value) do
    case AdminRepo.query(
           "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
             "WHERE conname = 'ingestion_anomalies_anomaly_type_check'",
           []
         ) do
      {:ok, %{rows: [[definition]]}} when is_binary(definition) ->
        String.contains?(definition, value)

      _ ->
        false
    end
  end

  # `to_regclass` returns NULL when the relation does not exist (no exception),
  # so this is a cheap, crash-free readiness probe for the version-skew window.
  defp anomalies_table_ready?, do: relation_present?("ingestion_anomalies")

  # Batch the per-candidate existence/suppression probes into ONE set-based query per
  # detector type, then process each candidate against the in-memory result. Previously
  # each candidate ran 3-4 sequential AdminRepo queries (existing lookup + archived-
  # suppression + acknowledged/resolved-suppression + the insert), so a WIDESPREAD outage
  # (many candidates at once — the worst case this detector exists for) made the hourly
  # job O(open anomalies) on the 3-conn AdminRepo pool. Prefetching keeps the probe cost
  # constant, mirroring the set-based auto_resolve_recovered_* optimization.
  #
  # Returns the per-candidate outcomes (`{:notified, candidate}` when this run actually
  # fired the notifications for that candidate, else `:ok`/`:suppressed`) so a caller can
  # aggregate them — the retention-sweep path uses that to emit ONE system-scope operator
  # alert instead of N identical per-tenant ones.
  defp flag_candidates([], _anomaly_type), do: []

  defp flag_candidates(candidates, anomaly_type) do
    by_key = prefetch_anomalies(candidates, anomaly_type)

    Enum.map(candidates, fn candidate ->
      rows = Map.get(by_key, {candidate.tenant_id, candidate.source_type}, [])
      flag_candidate(anomaly_type, candidate, rows)
    end)
  end

  # Load EVERY anomaly of `anomaly_type` (any resolved/archived state) for the candidate
  # (tenant_id, source_type) keys in one query, grouped by key. Over-fetches the cartesian
  # of the distinct tenant_ids × source_types then filters to the exact key set in memory
  # (tuple IN is awkward in Ecto); the candidate set is small (bounded by tenants ×
  # source_types), so this is a handful of rows and a single round-trip.
  defp prefetch_anomalies(candidates, anomaly_type) do
    keys = MapSet.new(candidates, &{&1.tenant_id, &1.source_type})
    tenant_ids = candidates |> Enum.map(& &1.tenant_id) |> Enum.uniq()
    source_types = candidates |> Enum.map(& &1.source_type) |> Enum.uniq()

    IngestionAnomaly
    |> where([a], a.anomaly_type == ^anomaly_type)
    |> where([a], a.tenant_id in ^tenant_ids)
    |> where([a], a.source_type in ^source_types)
    |> AdminRepo.all()
    |> Enum.filter(&MapSet.member?(keys, {&1.tenant_id, &1.source_type}))
    |> Enum.group_by(&{&1.tenant_id, &1.source_type})
  end

  # Dispatch by detector type: capture_silence (writes stopped) vs high_reject_rate
  # (writes rejected). Both reuse the same persist/notify/at-least-once machinery and the
  # prefetched `rows` for the candidate's (tenant, source_type) key.
  defp flag_candidate(:high_reject_rate, candidate, rows),
    do: flag_episode(:high_reject_rate, candidate, rows)

  defp flag_candidate(:capture_silence, candidate, rows),
    do: flag_capture_silence(candidate, rows)

  defp flag_candidate(:sweep_stalled, candidate, rows),
    do: flag_episode(:sweep_stalled, candidate, rows)

  defp flag_capture_silence(
         %{
           tenant_id: tenant_id,
           source_type: source_type,
           last_event_at: last_event_at,
           hours_stale: hours_stale,
           sample_count: sample_count
         },
         rows
       ) do
    # Find the live (unresolved, non-archived) row like CostAnomalyWorker so an UPDATE
    # never emits audit/webhook/alert. The unique partial index still guards against
    # races on the insert path below. NB: an archived-but-unresolved row must not be
    # silently update-refreshed; archival is handled explicitly by the first cond branch.
    existing = Enum.find(rows, &(&1.resolved == false and &1.archived == false))

    cond do
      archived_suppression?(rows) ->
        # Operator archived this source_type — escape hatch, never re-flag (until un-archived).
        :suppressed

      existing && not existing.alerted ->
        # The row was persisted (+ audited atomically) but its POST-commit operator
        # alert + webhook never fired (worker crashed in the gap). Re-fire them now —
        # at-least-once recovery — then refresh figures. Without this, a genuine
        # capture-silence alert would be lost across all retries.
        recover_lost_notification(tenant_id, existing, last_event_at, hours_stale, sample_count)

      existing ->
        update_existing(existing, last_event_at, hours_stale, sample_count)

      acknowledged_silence?(rows, last_event_at) ->
        # This exact silence is already covered by a resolved anomaly (no capture
        # since it was resolved) — suppress re-creation to avoid re-firing audit +
        # operator alert + webhook every hour. Re-flags only once captures resume
        # (last_event_at advances) and the source goes silent again.
        :suppressed

      true ->
        create_new(tenant_id, source_type, last_event_at, hours_stale, sample_count)
    end
  end

  # An archived anomaly (resolved or not) suppresses re-detection for that
  # (source_type, anomaly_type) — the operator's escape hatch for a retired
  # workflow, reversible via IngestionHealth.unarchive_anomaly/3. `rows` are already
  # scoped to one (tenant, source_type, anomaly_type) key by the prefetch.
  defp archived_suppression?(rows), do: Enum.any?(rows, & &1.archived)

  # True when a resolved (non-archived) anomaly's snapshot is at/after the current
  # silence's last_event_at, i.e. no NEW capture has arrived since it was resolved.
  defp acknowledged_silence?(rows, last_event_at) do
    Enum.any?(rows, fn a ->
      a.resolved and not a.archived and not is_nil(a.last_event_at) and
        DateTime.compare(a.last_event_at, last_event_at) != :lt
    end)
  end

  # --- EPISODE-shaped flagging (:high_reject_rate PR B2, :sweep_stalled #498) ---

  # ONE flag path for both EPISODE-shaped detectors. Mirrors flag_capture_silence
  # structurally, reusing the SAME persist/notify/at-least-once machinery, but with
  # episode semantics: neither rejects nor stalls have a natural "resumed" signal (no
  # newer article), so recovery is defined as "no longer a candidate" and marked by
  # stamping `last_event_at` (episode ended). A resolved episode anomaly suppresses
  # re-creation ONLY while its episode is still active (`last_event_at IS NULL`) —
  # anti-alarm-fatigue while the condition persists — and re-arms once recovery stamps
  # `last_event_at`, so a future storm/stall re-fires. Archiving is the separate operator
  # escape hatch.
  #
  # The two types differ ONLY in the figures/metadata they record (`episode_figures/2`),
  # so they share this function rather than duplicating the alerted-flag ordering — the
  # at-least-once contract — in two places.
  #
  # Returns `{:notified, candidate, anomaly}` when THIS run fired the notifications (a
  # genuine create, or the at-least-once re-fire), else `:ok`/`:suppressed`. The ANOMALY
  # rides along because `:sweep_stalled` defers its `alerted` flip until after its one
  # system-scope alert is durably enqueued (see `fire_sweep_system_alert/1`).
  defp flag_episode(anomaly_type, %{tenant_id: tenant_id} = candidate, rows) do
    existing = Enum.find(rows, &(&1.resolved == false and &1.archived == false))

    cond do
      archived_suppression?(rows) ->
        :suppressed

      is_nil(existing) ->
        create_episode_unless_suppressed(anomaly_type, tenant_id, candidate, rows)

      not existing.alerted ->
        # At-least-once recovery: the row was persisted + audited atomically but its
        # post-commit alert/webhook never fired. Re-fire, then refresh figures.
        notify(tenant_id, existing)
        update_existing_episode(anomaly_type, existing, candidate)
        {:notified, candidate, existing}

      true ->
        update_existing_episode(anomaly_type, existing, candidate)
    end
  end

  # No live row: create one UNLESS a resolved-but-still-active episode is suppressing
  # (the operator resolved it while the condition persists — do not re-fire every run).
  defp create_episode_unless_suppressed(anomaly_type, tenant_id, candidate, rows) do
    if resolved_episode_suppression?(rows) do
      :suppressed
    else
      case create_new_episode(anomaly_type, tenant_id, candidate) do
        %IngestionAnomaly{} = anomaly -> {:notified, candidate, anomaly}
        _ -> :ok
      end
    end
  end

  # The per-type figures an episode anomaly records. `:high_reject_rate` has no staleness
  # dimension (its evidence is the reject ratio in metadata) so hours_stale is a
  # non-meaningful 0 and sample_count is the window's write attempts; `:sweep_stalled`
  # carries a real staleness (hours the oldest overdue row outlived expires_at) and counts
  # overdue rows.
  defp episode_figures(:high_reject_rate, candidate) do
    %{
      hours_stale: 0,
      sample_count: candidate.total_attempts,
      metadata: reject_metadata(candidate)
    }
  end

  defp episode_figures(:sweep_stalled, candidate) do
    %{
      hours_stale: candidate.hours_stale,
      sample_count: candidate.overdue_count,
      metadata: sweep_metadata(candidate)
    }
  end

  defp create_new_episode(anomaly_type, tenant_id, candidate) do
    attrs =
      Map.merge(episode_figures(anomaly_type, candidate), %{
        source_type: candidate.source_type,
        anomaly_type: anomaly_type,
        # nil last_event_at = the episode is ACTIVE; recovery stamps it
        # (IngestionHealth.auto_resolve_recovered_*), which re-arms detection.
        last_event_at: nil
      })

    changeset = IngestionAnomaly.create_changeset(%IngestionAnomaly{tenant_id: tenant_id}, attrs)

    if changeset.valid? do
      insert_new_anomaly(tenant_id, changeset)
    else
      Logger.warning(
        "IngestionHealthWorker: invalid #{anomaly_type} anomaly for tenant " <>
          "#{tenant_id}/#{candidate.source_type}, skipping: #{inspect(changeset.errors)}"
      )

      nil
    end
  end

  # Silently refresh the figures on an existing unresolved anomaly — no re-notify.
  defp update_existing_episode(anomaly_type, existing, candidate) do
    case existing
         |> IngestionAnomaly.create_changeset(episode_figures(anomaly_type, candidate))
         |> AdminRepo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning(
          "IngestionHealthWorker: failed to update #{anomaly_type} anomaly " <>
            "#{existing.id}: #{inspect(changeset.errors)}"
        )

        existing
    end
  end

  defp sweep_metadata(candidate) do
    %{
      "overdue_count" => candidate.overdue_count,
      "oldest_expires_at" => iso8601(candidate.oldest_expires_at),
      "grace_hours" => candidate.grace_hours,
      "hours_stale" => candidate.hours_stale
    }
  end

  # Shared by the two EPISODE-shaped detectors (high_reject_rate, sweep_stalled).
  # A resolved (non-archived) anomaly suppresses re-creation while the
  # condition persists — mirrors capture_silence's "resolve sticks". But only an
  # ACTIVE episode suppresses: `last_event_at IS NULL` means the episode has not yet
  # been marked recovered. Once IngestionHealth.auto_resolve_recovered_reject_rate/1
  # stamps `last_event_at` (rejects fell below threshold), the resolved row stops
  # suppressing, so a FRESH storm for the same source_type re-fires instead of being
  # silenced forever. Without this scope a single operator resolve would blind the
  # detector to every future outage of that source_type. `rows` are prefetched and
  # already scoped to the candidate's (tenant, source_type, high_reject_rate) key.
  defp resolved_episode_suppression?(rows) do
    Enum.any?(rows, &(&1.resolved and not &1.archived and is_nil(&1.last_event_at)))
  end

  defp reject_metadata(candidate) do
    %{
      "reject_rate" => candidate.reject_rate,
      "total_attempts" => candidate.total_attempts,
      "rejects" => candidate.rejects,
      "window_days" => candidate.window_days,
      "dominant_reason" => candidate.dominant_reason
    }
  end

  # Recovery path: the row exists but its post-commit notifications never fired
  # (alerted=false). Re-fire the operator alert + webhook (at-least-once), mark it
  # alerted, and refresh figures. Idempotent audit already exists from the atomic
  # detection insert, so we do NOT re-log "detected".
  defp recover_lost_notification(tenant_id, existing, last_event_at, hours_stale, sample_count) do
    notify(tenant_id, existing)
    update_existing(existing, last_event_at, hours_stale, sample_count)
  end

  # Fire the out-of-band operator alert + webhook, then flip `alerted` so a healthy
  # run never re-fires. Ordering makes notification at-least-once: if the process
  # dies before mark_alerted, the next run's recovery branch re-fires.
  #
  # `:sweep_stalled` is the ONE type whose OPERATOR alert is not fired here: its cause
  # (the single global `ChannelPostSweeper`) is shared across every affected tenant, so
  # the run emits ONE system-scope alert (`fire_sweep_system_alert/1`) instead of N
  # identical ones. The per-TENANT webhook still fires here — a tenant subscriber cares
  # about its own retention — but `mark_alerted` is DEFERRED to that system-alert step.
  #
  # Flipping `alerted` here (as the first cut did) made the operator alert AT-MOST-once:
  # `alerted: true` was committed per candidate during flagging, while the only operator
  # alert for the type was enqueued after the whole pipe. Anything between them — the
  # detector's own rescue/catch converting a raise to `:ok`, or a failed `Oban.insert` —
  # left rows alerted with no alert ever emitted, and the next run took the silent
  # update path forever. The flip now happens ONLY after a successful enqueue.
  defp notify(tenant_id, %IngestionAnomaly{anomaly_type: :sweep_stalled} = anomaly) do
    fire_anomaly_webhook(tenant_id, anomaly)
    :deferred
  end

  defp notify(tenant_id, anomaly) do
    fire_operator_alert(tenant_id, anomaly)
    fire_anomaly_webhook(tenant_id, anomaly)
    mark_alerted(anomaly)
  end

  # ONE system-scope operator alert per run for the retention-sweep stall, replacing the
  # per-tenant fan-out. Emitted only when this run actually notified at least one tenant
  # (a genuine create or an at-least-once re-fire), so a persistent stall does not
  # re-page hourly. Carries the blast radius (`affected_tenants`, a BOUNDED `tenant_ids`
  # sample) so the operator sees "the sweeper is down, N tenants affected" as one signal.
  #
  # ORDERING IS THE CONTRACT: the alert is enqueued FIRST and the participating anomalies
  # are marked `alerted` only on a successful enqueue. A failed enqueue (or a crash
  # anywhere before it) therefore leaves `alerted: false`, and the next hourly run's
  # `not existing.alerted` branch re-fires — at-least-once, as documented.
  defp fire_sweep_system_alert(results) do
    case Enum.flat_map(results, fn
           {:notified, candidate, anomaly} -> [{candidate, anomaly}]
           _ -> []
         end) do
      [] ->
        :ok

      notified ->
        commit_sweep_system_alert(notified)
    end
  end

  @doc false
  # The enqueue-THEN-flip step, factored out of the private pipeline so a test can drive
  # the DROPPED-ENQUEUE path with a plain function (`Oban.insert/1` cannot be made to
  # fail under the sandbox otherwise) — same seam shape as
  # `Loopctl.Workers.ChannelPostSweeper.observed/2`. `notified` is a list of
  # `{candidate, anomaly}`. Not a public API; prod always uses the default insert.
  @spec commit_sweep_system_alert([{map(), IngestionAnomaly.t()}], (Oban.Job.changeset() ->
                                                                      {:ok, Oban.Job.t()}
                                                                      | {:error, term()})) ::
          :ok | :error
  def commit_sweep_system_alert(notified, insert_fn \\ &Oban.insert/1)

  def commit_sweep_system_alert([], _insert_fn), do: :ok

  def commit_sweep_system_alert(notified, insert_fn) do
    candidates = Enum.map(notified, fn {candidate, _anomaly} -> candidate end)
    grace_hours = IngestionHealth.sweep_staleness_hours()

    payload = %{
      "alert" => "coordination.channel_post_sweep_stalled",
      "metric" => "coordination.channel_post_sweep_stalled.hours_stale",
      "value" => candidates |> Enum.map(& &1.hours_stale) |> Enum.max(),
      "threshold" => grace_hours,
      "window_seconds" => grace_hours * 3600,
      "scope" => "system",
      "affected_tenants" => length(candidates),
      "tenant_ids" => candidates |> Enum.map(& &1.tenant_id) |> Enum.take(@alert_tenant_sample),
      "overdue_count" => candidates |> Enum.map(& &1.overdue_count) |> Enum.sum(),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Logger.error(
      "IngestionHealthWorker: channel-post retention sweep stalled — " <>
        "affected_tenants=#{length(candidates)} max_hours_stale=#{payload["value"]}"
    )

    case enqueue_system_alert(payload, insert_fn) do
      :ok ->
        Enum.each(notified, fn {_candidate, anomaly} -> mark_alerted(anomaly) end)
        :ok

      :error ->
        # Deliberately leave every participating row `alerted: false`: the next hourly
        # run re-fires instead of silently dropping the only operator signal for a dead
        # retention sweep.
        Logger.error(
          "IngestionHealthWorker: sweep-stall system alert was NOT enqueued; " <>
            "#{length(notified)} anomaly(ies) left unalerted for re-fire next run"
        )

        :error
    end
  end

  defp enqueue_system_alert(payload, insert_fn) do
    case %{payload: payload} |> ScaleAlertDeliveryWorker.new() |> insert_fn.() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "IngestionHealthWorker: failed to enqueue system sweep-stall alert: #{inspect(reason)}"
        )

        :error
    end
  rescue
    # `Oban.insert/1` RAISES on some failures (no Oban instance running, a job-args
    # encoding fault) rather than returning an error tuple. Swallowing that raise here
    # is safe precisely because `alerted` has not been flipped yet — the run re-fires.
    error ->
      Logger.warning(
        "IngestionHealthWorker: failed to enqueue system sweep-stall alert " <>
          "(#{inspect(error.__struct__)}): #{Exception.message(error)}"
      )

      :error
  end

  defp mark_alerted(anomaly) do
    case anomaly |> IngestionAnomaly.mark_alerted_changeset() |> AdminRepo.update() do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "IngestionHealthWorker: failed to mark anomaly #{anomaly.id} alerted: " <>
            "#{inspect(changeset.errors)}"
        )
    end
  end

  # Always-on operator-visible signal, independent of the optional webhook URL and
  # per-tenant webhook subscriptions: a detected capture-silence is a genuine
  # operational event, so it must surface in logs/monitoring even when no alert
  # channel is wired.
  defp log_detected_alarm(tenant_id, %IngestionAnomaly{anomaly_type: :high_reject_rate} = anomaly) do
    md = anomaly.metadata || %{}

    Logger.error(
      "IngestionHealthWorker: high-reject-rate detected — tenant=#{tenant_id} " <>
        "source_type=#{anomaly.source_type} reject_rate=#{md["reject_rate"]} " <>
        "total_attempts=#{md["total_attempts"]} rejects=#{md["rejects"]} " <>
        "dominant_reason=#{md["dominant_reason"]} anomaly_id=#{anomaly.id}"
    )
  end

  defp log_detected_alarm(tenant_id, %IngestionAnomaly{anomaly_type: :sweep_stalled} = anomaly) do
    md = anomaly.metadata || %{}

    Logger.error(
      "IngestionHealthWorker: channel-post retention sweep stalled — tenant=#{tenant_id} " <>
        "overdue_count=#{md["overdue_count"]} hours_stale=#{anomaly.hours_stale} " <>
        "oldest_expires_at=#{md["oldest_expires_at"]} anomaly_id=#{anomaly.id}"
    )
  end

  defp log_detected_alarm(tenant_id, anomaly) do
    Logger.error(
      "IngestionHealthWorker: capture-silence detected — tenant=#{tenant_id} " <>
        "source_type=#{anomaly.source_type} hours_stale=#{anomaly.hours_stale} " <>
        "sample_count=#{anomaly.sample_count} anomaly_id=#{anomaly.id}"
    )
  end

  # Silently refresh the figures on an existing unresolved anomaly — no re-notify.
  defp update_existing(existing, last_event_at, hours_stale, sample_count) do
    case existing
         |> IngestionAnomaly.create_changeset(%{
           last_event_at: last_event_at,
           hours_stale: hours_stale,
           sample_count: sample_count
         })
         |> AdminRepo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning(
          "IngestionHealthWorker: failed to update anomaly #{existing.id}: #{inspect(changeset.errors)}"
        )

        existing
    end
  end

  # Validate through the changeset (create == update symmetry — insert_all bypasses it)
  # then write race-safely; notify ONLY on a genuine insert.
  defp create_new(tenant_id, source_type, last_event_at, hours_stale, sample_count) do
    changeset =
      IngestionAnomaly.create_changeset(
        %IngestionAnomaly{tenant_id: tenant_id},
        %{
          source_type: source_type,
          anomaly_type: :capture_silence,
          last_event_at: last_event_at,
          hours_stale: hours_stale,
          sample_count: sample_count
        }
      )

    if changeset.valid? do
      insert_new_anomaly(tenant_id, changeset)
    else
      Logger.warning(
        "IngestionHealthWorker: invalid anomaly for tenant #{tenant_id}/#{source_type}, " <>
          "skipping: #{inspect(changeset.errors)}"
      )

      nil
    end
  end

  # insert_all + on_conflict: :nothing against the unresolved unique partial index,
  # with the `detected` audit entry in the SAME transaction so the anomaly row can
  # never be persisted without its audit record (an Oban retry would otherwise find
  # the row, take the no-notify update path, and lose the audit entry permanently).
  # {1, [row]} = we inserted (audit + notify); {0, _} = concurrent run won the race.
  defp insert_new_anomaly(tenant_id, changeset) do
    now = DateTime.utc_now()

    entry =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Map.take([
        :tenant_id,
        :source_type,
        :anomaly_type,
        :last_event_at,
        :hours_stale,
        :sample_count,
        :resolved,
        :archived,
        :metadata
      ])
      |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

    multi =
      Multi.new()
      |> Multi.run(:anomaly, fn repo, _changes ->
        case repo.insert_all(IngestionAnomaly, [entry],
               on_conflict: :nothing,
               conflict_target:
                 {:unsafe_fragment,
                  ~s|("tenant_id","source_type","anomaly_type") WHERE resolved = false|},
               returning: true
             ) do
          {1, [anomaly]} -> {:ok, anomaly}
          {0, _} -> {:ok, :conflict}
        end
      end)
      |> Multi.run(:audit, fn _repo, %{anomaly: anomaly} ->
        case anomaly do
          :conflict -> {:ok, :skipped}
          %IngestionAnomaly{} = row -> log_detected(tenant_id, row)
        end
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{anomaly: :conflict}} ->
        # Lost the race: the concurrent inserter already emitted audit + alert + webhook.
        nil

      {:ok, %{anomaly: %IngestionAnomaly{} = anomaly}} ->
        # Audit is committed atomically with the row. The operator alert + webhook
        # can't join that transaction (Oban jobs insert via Loopctl.Repo), so they run
        # post-commit and `alerted` is flipped only after they're enqueued — a crash in
        # the gap leaves alerted=false and the next run re-fires (at-least-once).
        log_detected_alarm(tenant_id, anomaly)
        notify(tenant_id, anomaly)
        anomaly

      {:error, step, reason, _changes} ->
        Logger.warning(
          "IngestionHealthWorker: failed to persist anomaly for tenant #{tenant_id} " <>
            "(step #{inspect(step)}): #{inspect(reason)}"
        )

        nil
    end
  end

  # Writes the `detected` audit entry inside the create transaction (AdminRepo).
  defp log_detected(tenant_id, %IngestionAnomaly{anomaly_type: :high_reject_rate} = anomaly) do
    md = anomaly.metadata || %{}

    Audit.create_log_entry(tenant_id, %{
      entity_type: "ingestion_anomaly",
      entity_id: anomaly.id,
      action: "detected",
      actor_type: "system",
      new_state: %{
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "source_type" => anomaly.source_type,
        "reject_rate" => md["reject_rate"],
        "total_attempts" => md["total_attempts"],
        "rejects" => md["rejects"],
        "window_days" => md["window_days"],
        "dominant_reason" => md["dominant_reason"]
      },
      metadata: %{
        "anomaly_id" => anomaly.id,
        "source_type" => anomaly.source_type,
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "reject_rate" => md["reject_rate"]
      }
    })
  end

  defp log_detected(tenant_id, %IngestionAnomaly{anomaly_type: :sweep_stalled} = anomaly) do
    md = anomaly.metadata || %{}

    Audit.create_log_entry(tenant_id, %{
      entity_type: "ingestion_anomaly",
      entity_id: anomaly.id,
      action: "detected",
      actor_type: "system",
      new_state: %{
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "source_type" => anomaly.source_type,
        "hours_stale" => anomaly.hours_stale,
        "overdue_count" => md["overdue_count"],
        "oldest_expires_at" => md["oldest_expires_at"],
        "grace_hours" => md["grace_hours"]
      },
      metadata: %{
        "anomaly_id" => anomaly.id,
        "source_type" => anomaly.source_type,
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "hours_stale" => anomaly.hours_stale
      }
    })
  end

  defp log_detected(tenant_id, anomaly) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "ingestion_anomaly",
      entity_id: anomaly.id,
      action: "detected",
      actor_type: "system",
      new_state: %{
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "source_type" => anomaly.source_type,
        "hours_stale" => anomaly.hours_stale,
        "sample_count" => anomaly.sample_count,
        "last_event_at" => iso8601(anomaly.last_event_at)
      },
      metadata: %{
        "anomaly_id" => anomaly.id,
        "source_type" => anomaly.source_type,
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "hours_stale" => anomaly.hours_stale
      }
    })
  end

  # Enqueue an operator alert through ScaleAlertDeliveryWorker with an id-only payload.
  # That worker resolves SCALE_ALERT_WEBHOOK_URL itself and no-ops when unset, so this
  # is channel-agnostic and safe when unconfigured — we never read/require the URL here.
  defp fire_operator_alert(
         tenant_id,
         %IngestionAnomaly{anomaly_type: :high_reject_rate} = anomaly
       ) do
    md = anomaly.metadata || %{}
    window_days = md["window_days"] || IngestionHealth.reject_window_days()

    payload = %{
      "alert" => "ingestion.high_reject_rate",
      "metric" => "ingestion.high_reject_rate.reject_rate",
      "value" => md["reject_rate"],
      "threshold" => IngestionHealth.reject_rate_threshold(),
      "window_seconds" => window_days * 86_400,
      "tenant_id" => tenant_id,
      "source_type" => anomaly.source_type,
      "total_attempts" => md["total_attempts"],
      "rejects" => md["rejects"],
      "dominant_reason" => md["dominant_reason"],
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    enqueue_operator_alert(payload, anomaly)
  end

  # NB: there is deliberately NO `:sweep_stalled` clause here — that type's operator
  # alert is emitted ONCE PER RUN at system scope by `fire_sweep_system_alert/1`, since
  # its cause is the single global sweeper rather than anything tenant-specific.
  defp fire_operator_alert(tenant_id, anomaly) do
    # Conform to the ScaleAlert operator-alert contract (%{alert, metric, value,
    # threshold, window_seconds, at}) so the shared alert channel — including
    # ScaleAlertDeliveryWorker's no-URL skip log that reads metric=value — renders
    # meaningful values. Extra context fields (tenant_id/source_type/last_event_at)
    # ride alongside; consumers branch on the `alert` discriminator.
    staleness_hours = IngestionHealth.staleness_threshold_hours()

    payload = %{
      "alert" => "ingestion.capture_silence",
      "metric" => "ingestion.capture_silence.hours_stale",
      "value" => anomaly.hours_stale,
      "threshold" => staleness_hours,
      "window_seconds" => staleness_hours * 3600,
      "tenant_id" => tenant_id,
      "source_type" => anomaly.source_type,
      "hours_stale" => anomaly.hours_stale,
      "last_event_at" => iso8601(anomaly.last_event_at),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    enqueue_operator_alert(payload, anomaly)
  end

  defp enqueue_operator_alert(payload, anomaly) do
    case %{payload: payload} |> ScaleAlertDeliveryWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "IngestionHealthWorker: failed to enqueue operator alert for anomaly " <>
            "#{anomaly.id}: #{inspect(reason)}"
        )
    end
  end

  # Fires the tenant-scoped anomaly webhook on the event type that MATCHES the anomaly's
  # domain (knowledge ingestion vs coordination retention). Ingestion anomalies are
  # tenant-wide (no project), so project_id is nil — only tenant-wide webhook
  # subscriptions match. Errors are logged, not raised (the anomaly is already persisted;
  # losing the webhook must not lose the anomaly).
  defp fire_anomaly_webhook(tenant_id, anomaly) do
    event_type = webhook_event_type(anomaly)
    webhooks = EventGenerator.matching_webhooks(tenant_id, event_type, nil)

    if webhooks != [] do
      payload = anomaly_webhook_payload(anomaly)

      Enum.each(
        webhooks,
        &deliver_anomaly_event(tenant_id, &1, event_type, payload, anomaly.id)
      )
    end
  end

  defp webhook_event_type(%IngestionAnomaly{anomaly_type: :sweep_stalled}),
    do: @sweep_webhook_event_type

  defp webhook_event_type(_anomaly), do: @webhook_event_type

  defp anomaly_webhook_payload(%IngestionAnomaly{anomaly_type: :high_reject_rate} = anomaly) do
    md = anomaly.metadata || %{}

    %{
      "anomaly_id" => anomaly.id,
      "source_type" => anomaly.source_type,
      "anomaly_type" => to_string(anomaly.anomaly_type),
      "reject_rate" => md["reject_rate"],
      "total_attempts" => md["total_attempts"],
      "rejects" => md["rejects"],
      "window_days" => md["window_days"],
      "dominant_reason" => md["dominant_reason"]
    }
  end

  defp anomaly_webhook_payload(%IngestionAnomaly{anomaly_type: :sweep_stalled} = anomaly) do
    md = anomaly.metadata || %{}

    %{
      "anomaly_id" => anomaly.id,
      "source_type" => anomaly.source_type,
      "anomaly_type" => to_string(anomaly.anomaly_type),
      "hours_stale" => anomaly.hours_stale,
      "overdue_count" => md["overdue_count"],
      "oldest_expires_at" => md["oldest_expires_at"],
      "grace_hours" => md["grace_hours"]
    }
  end

  defp anomaly_webhook_payload(anomaly) do
    %{
      "anomaly_id" => anomaly.id,
      "source_type" => anomaly.source_type,
      "anomaly_type" => to_string(anomaly.anomaly_type),
      "hours_stale" => anomaly.hours_stale,
      "sample_count" => anomaly.sample_count,
      "last_event_at" => iso8601(anomaly.last_event_at)
    }
  end

  defp deliver_anomaly_event(tenant_id, webhook, event_type, payload, anomaly_id) do
    with {:ok, event} <-
           %WebhookEvent{tenant_id: tenant_id, webhook_id: webhook.id}
           |> WebhookEvent.create_changeset(%{
             event_type: event_type,
             payload: payload
           })
           |> AdminRepo.insert(),
         {:ok, _job} <-
           WebhookDeliveryWorker.new(%{webhook_event_id: event.id, tenant_id: tenant_id})
           |> Oban.insert() do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "IngestionHealthWorker: failed to create #{event_type} webhook event " <>
            "for anomaly #{anomaly_id}: #{inspect(reason)}"
        )
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
