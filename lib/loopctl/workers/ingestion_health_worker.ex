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
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.ScaleAlertDeliveryWorker
  alias Loopctl.Workers.WebhookDeliveryWorker

  @webhook_event_type "knowledge.ingestion_anomaly_detected"

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

    Enum.each(candidates, &flag_candidate/1)

    # PR B2: the no-persist / high-rejection-rate sibling detector. A rejected write
    # leaves no article row, so it is invisible to the capture-silence scan above;
    # this reads the durable `ingestion_write_stats` rollup instead.
    run_reject_rate_detection()

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

      Enum.each(reject_candidates, &flag_candidate/1)

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
  # Reads the constraint definition from the catalog (crash-free): absent constraint
  # or a definition that does not yet mention the value ⇒ not ready.
  defp high_reject_rate_check_ready? do
    case AdminRepo.query(
           "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
             "WHERE conname = 'ingestion_anomalies_anomaly_type_check'",
           []
         ) do
      {:ok, %{rows: [[definition]]}} when is_binary(definition) ->
        String.contains?(definition, "high_reject_rate")

      _ ->
        false
    end
  end

  # `to_regclass` returns NULL when the relation does not exist (no exception),
  # so this is a cheap, crash-free readiness probe for the version-skew window.
  defp anomalies_table_ready?, do: relation_present?("ingestion_anomalies")

  # Dispatch by detector type: capture_silence (writes stopped) vs high_reject_rate
  # (writes rejected). Both reuse the same persist/notify/at-least-once machinery.
  defp flag_candidate(%{anomaly_type: :high_reject_rate} = candidate),
    do: flag_reject_rate(candidate)

  defp flag_candidate(candidate), do: flag_capture_silence(candidate)

  defp flag_capture_silence(%{
         tenant_id: tenant_id,
         source_type: source_type,
         last_event_at: last_event_at,
         hours_stale: hours_stale,
         sample_count: sample_count
       }) do
    # Check first (like CostAnomalyWorker) so an UPDATE never emits audit/webhook/alert.
    # The unique partial index still guards against races on the insert path below.
    # NB: exclude archived rows here — an archived-but-unresolved row must not be
    # silently update-refreshed; archival is handled explicitly below.
    existing =
      IngestionAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.source_type == ^source_type)
      |> where([a], a.anomaly_type == :capture_silence)
      |> where([a], a.resolved == false)
      |> where([a], a.archived == false)
      |> AdminRepo.one()

    cond do
      archived_suppression?(tenant_id, source_type, :capture_silence) ->
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

      acknowledged_silence?(tenant_id, source_type, last_event_at) ->
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
  # workflow, reversible via IngestionHealth.unarchive_anomaly/3.
  defp archived_suppression?(tenant_id, source_type, anomaly_type) do
    IngestionAnomaly
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.source_type == ^source_type)
    |> where([a], a.anomaly_type == ^anomaly_type)
    |> where([a], a.archived == true)
    |> AdminRepo.exists?()
  end

  # True when a resolved (non-archived) anomaly's snapshot is at/after the current
  # silence's last_event_at, i.e. no NEW capture has arrived since it was resolved.
  defp acknowledged_silence?(tenant_id, source_type, last_event_at) do
    IngestionAnomaly
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.source_type == ^source_type)
    |> where([a], a.anomaly_type == :capture_silence)
    |> where([a], a.resolved == true)
    |> where([a], a.archived == false)
    |> where([a], not is_nil(a.last_event_at) and a.last_event_at >= ^last_event_at)
    |> AdminRepo.exists?()
  end

  # --- High-reject-rate flagging (PR B2) ---

  # Mirrors flag_capture_silence structurally, reusing the SAME persist/notify/
  # at-least-once machinery, but with reject-rate semantics: rejects have no natural
  # "resumed" signal (no newer article), so recovery is defined as "no longer a
  # candidate" and marked by stamping `last_event_at` (episode ended). A resolved
  # reject-rate anomaly suppresses re-creation ONLY while its episode is still active
  # (`last_event_at IS NULL`) — anti-alarm-fatigue while rejects persist — and re-arms
  # once recovery stamps `last_event_at`, so a future storm re-fires. Archiving is the
  # separate operator escape hatch.
  defp flag_reject_rate(%{tenant_id: tenant_id, source_type: source_type} = candidate) do
    existing =
      IngestionAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.source_type == ^source_type)
      |> where([a], a.anomaly_type == :high_reject_rate)
      |> where([a], a.resolved == false)
      |> where([a], a.archived == false)
      |> AdminRepo.one()

    cond do
      archived_suppression?(tenant_id, source_type, :high_reject_rate) ->
        :suppressed

      existing && not existing.alerted ->
        # At-least-once recovery: the row was persisted + audited atomically but its
        # post-commit alert/webhook never fired. Re-fire, then refresh figures.
        notify(tenant_id, existing)
        update_existing_reject(existing, candidate)

      existing ->
        update_existing_reject(existing, candidate)

      resolved_reject_suppression?(tenant_id, source_type) ->
        # Operator resolved it and rejects still persist — do not re-fire every run.
        :suppressed

      true ->
        create_new_reject(tenant_id, candidate)
    end
  end

  # A resolved (non-archived) high_reject_rate anomaly suppresses re-creation while the
  # reject condition persists — mirrors capture_silence's "resolve sticks". But only an
  # ACTIVE episode suppresses: `last_event_at IS NULL` means the episode has not yet
  # been marked recovered. Once IngestionHealth.auto_resolve_recovered_reject_rate/1
  # stamps `last_event_at` (rejects fell below threshold), the resolved row stops
  # suppressing, so a FRESH storm for the same source_type re-fires instead of being
  # silenced forever. Without this scope a single operator resolve would blind the
  # detector to every future outage of that source_type.
  defp resolved_reject_suppression?(tenant_id, source_type) do
    IngestionAnomaly
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.source_type == ^source_type)
    |> where([a], a.anomaly_type == :high_reject_rate)
    |> where([a], a.resolved == true)
    |> where([a], a.archived == false)
    |> where([a], is_nil(a.last_event_at))
    |> AdminRepo.exists?()
  end

  defp create_new_reject(tenant_id, candidate) do
    changeset =
      IngestionAnomaly.create_changeset(
        %IngestionAnomaly{tenant_id: tenant_id},
        %{
          source_type: candidate.source_type,
          anomaly_type: :high_reject_rate,
          # No staleness dimension for a reject-rate anomaly: last_event_at nil,
          # hours_stale 0, sample_count = total write attempts in the window.
          last_event_at: nil,
          hours_stale: 0,
          sample_count: candidate.total_attempts,
          metadata: reject_metadata(candidate)
        }
      )

    if changeset.valid? do
      insert_new_anomaly(tenant_id, changeset)
    else
      Logger.warning(
        "IngestionHealthWorker: invalid high_reject_rate anomaly for tenant " <>
          "#{tenant_id}/#{candidate.source_type}, skipping: #{inspect(changeset.errors)}"
      )

      nil
    end
  end

  # Silently refresh the reject figures on an existing unresolved anomaly — no re-notify.
  defp update_existing_reject(existing, candidate) do
    case existing
         |> IngestionAnomaly.create_changeset(%{
           hours_stale: 0,
           sample_count: candidate.total_attempts,
           metadata: reject_metadata(candidate)
         })
         |> AdminRepo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning(
          "IngestionHealthWorker: failed to update high_reject_rate anomaly " <>
            "#{existing.id}: #{inspect(changeset.errors)}"
        )

        existing
    end
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
  defp notify(tenant_id, anomaly) do
    fire_operator_alert(tenant_id, anomaly)
    fire_anomaly_webhook(tenant_id, anomaly)
    mark_alerted(anomaly)
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

  # Fires a tenant-scoped knowledge.ingestion_anomaly_detected webhook. Ingestion
  # anomalies are tenant-wide (no project), so project_id is nil — only tenant-wide
  # webhook subscriptions match. Errors are logged, not raised (the anomaly is already
  # persisted; losing the webhook must not lose the anomaly).
  defp fire_anomaly_webhook(tenant_id, anomaly) do
    webhooks = EventGenerator.matching_webhooks(tenant_id, @webhook_event_type, nil)

    if webhooks != [] do
      payload = anomaly_webhook_payload(anomaly)
      Enum.each(webhooks, &deliver_anomaly_event(tenant_id, &1, payload, anomaly.id))
    end
  end

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

  defp deliver_anomaly_event(tenant_id, webhook, payload, anomaly_id) do
    with {:ok, event} <-
           %WebhookEvent{tenant_id: tenant_id, webhook_id: webhook.id}
           |> WebhookEvent.create_changeset(%{
             event_type: @webhook_event_type,
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
          "IngestionHealthWorker: failed to create #{@webhook_event_type} webhook event " <>
            "for anomaly #{anomaly_id}: #{inspect(reason)}"
        )
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
