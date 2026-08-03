defmodule Loopctl.Workers.LegacyEmbeddingRetirementWorker do
  @moduledoc """
  Daily driver for the US-41.1 legacy-column retirement trigger (GH #551).

  Each run takes one live reading of the legacy `articles.embedding` / `memories.embedding`
  footprint, records it as that UTC day's observation, and asks
  `Loopctl.Embeddings.LegacyRetirement` whether retirement is now owed. It never drops
  anything — the drop stays a deliberate human migration behind a reviewed PR.

  ## What a `:due` verdict raises

  Mirroring `Loopctl.Workers.IngestionHealthWorker`, the signal is multi-channel so it does
  not depend on optional configuration:

    * an always-on `Logger.error`, so the condition surfaces in logs even with no alert
      webhook configured (the CURRENT prod posture — scale alerting was switched off in
      #539 until a receiver exists), and
    * an operator alert enqueued via `Loopctl.Workers.ScaleAlertDeliveryWorker`, which
      resolves `SCALE_ALERT_WEBHOOK_URL` itself and no-ops when unset.

  It re-fires EVERY day while the condition holds, with no anti-alarm-fatigue suppression:
  the failure mode it prevents is a reminder that stopped arriving.

  ## Failure is loud, not silent

  Anything this worker cannot READ — the catalog probe, or the observation table's own
  existence check — returns `{:error, _}` from `perform/1`, so Oban retries with backoff,
  `Loopctl.TelemetryEvents.legacy_retirement_probe_failed/0` fires, and the failure shows up
  as a failed job instead of being swallowed into "nothing to do". A table that is genuinely
  ABSENT is the one quiet skip, and even then the run still EVALUATES — the deadline trigger
  needs no observation, which stops a monitor that fails forever from looking like one that
  keeps finding nothing.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.LegacyRetirement
  alias Loopctl.TelemetryEvents
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case observations_table_ready?() do
      {:ok, record?} -> run(record?)
      {:error, reason} -> monitor_failed(reason, "could not probe the observation table")
    end
  end

  # Injected (`Loopctl.Embeddings.LegacyRetirementBehaviour`) for ONE reason: the
  # `{:error, _}` branch below is this worker's fail-closed guarantee, and the test database
  # always answers the catalog query successfully, so without a seam it could never be
  # exercised. Production resolves to the real module.
  defp retirement, do: Application.get_env(:loopctl, :legacy_retirement, LegacyRetirement)

  # `now`/`today` are resolved ONCE and threaded into both calls: letting each derive its own
  # means a run straddling UTC midnight (a manual run, a delayed retry) records day D then
  # evaluates a window ending D+1 — a deficit that never happened.
  defp run(record?) do
    case retirement().probe() do
      {:ok, probe} ->
        now = DateTime.utc_now()
        today = DateTime.to_date(now)

        maybe_record(record?, probe, now: now, today: today)

        probe
        |> retirement().evaluate(today: today)
        |> react()

      {:error, reason} ->
        monitor_failed(reason, "could not read the legacy embedding footprint")
    end
  end

  defp monitor_failed(reason, what) do
    :telemetry.execute(TelemetryEvents.legacy_retirement_probe_failed(), %{count: 1}, %{
      error_class: error_class(reason)
    })

    Logger.error(
      "LegacyEmbeddingRetirementWorker: #{what}: #{inspect(reason)}. This is NOT " <>
        "evidence that the columns are gone — the retirement check did not run."
    )

    {:error, reason}
  end

  defp maybe_record(true, probe, opts), do: record(probe, opts)

  # Version skew: the crontab entry deployed ahead of the migration. Only the EVIDENCE path
  # needs the table, so the run still probes, evaluates and reacts — returning early here
  # silenced the deadline in exactly the deployment where evidence is impossible.
  defp maybe_record(false, _probe, _opts) do
    Logger.warning(
      "LegacyEmbeddingRetirementWorker: embedding_retirement_observations table is " <>
        "absent (migration pending); evaluating without today's observation"
    )

    :ok
  end

  # Recording is best-effort relative to REACTING: a day whose row failed to persist costs
  # one day of evidence, but suppressing the verdict over it turns a storage hiccup into
  # silence about a condition we just measured.
  defp record(probe, opts) do
    case retirement().record(probe, opts) do
      {:ok, _observation} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "LegacyEmbeddingRetirementWorker: failed to record today's observation: " <>
            inspect(changeset.errors)
        )

        :ok
    end
  end

  # Logged, not silent: `:retired` is also what a MIS-SCOPED or under-privileged probe
  # produces, and a permanently disabled monitor must not look like a satisfied one.
  defp react(%{verdict: :retired} = verdict) do
    Logger.info("LegacyEmbeddingRetirementWorker: #{reasons(verdict)} — trigger satisfied")
    :ok
  end

  # The deadline DID pass, so louder than a plain :not_due — but deliberately not a :due:
  # acting on it would drop the column the request path is reading right now.
  defp react(%{verdict: :not_due, trigger: :deadline_blocked} = verdict) do
    Logger.warning(
      "LegacyEmbeddingRetirementWorker: retirement BLOCKED for legacy embedding " <>
        "column(s) #{inspect(verdict.legacy_columns)} — " <> reasons(verdict)
    )

    :ok
  end

  defp react(%{verdict: :not_due} = verdict) do
    Logger.info(
      "LegacyEmbeddingRetirementWorker: legacy embedding columns " <>
        "#{inspect(verdict.legacy_columns)} not yet retirable — " <> reasons(verdict)
    )

    :ok
  end

  defp react(%{verdict: :due} = verdict) do
    Logger.error(
      "LegacyEmbeddingRetirementWorker: RETIREMENT DUE (#{verdict.trigger}) for legacy " <>
        "embedding column(s) #{inspect(verdict.legacy_columns)} — " <>
        reasons(verdict) <>
        ". Drop them in a reviewed migration (see GH #551), or move review_by out " <>
        "deliberately if the rollback is still wanted."
    )

    enqueue_alert(verdict)
    :ok
  end

  # Keeps the telemetry dimension BOUNDED: a module name or a stable exit tag, never a
  # message that could carry a query fragment or a connection string. DBConnection/Postgrex
  # EXIT with a TUPLE (`{:timeout, _}`, `{:noproc, _}`) — mirrors `LocalGuc.failure_tag/1`.
  defp error_class(%{__struct__: module}), do: inspect(module)
  defp error_class({tag, _details}) when is_atom(tag), do: to_string(tag)
  defp error_class(_), do: "rollback"

  defp reasons(%{reasons: []}), do: "no reason recorded"
  defp reasons(%{reasons: reasons}), do: Enum.join(reasons, "; ")

  # Conforms to the shared ScaleAlert operator-alert contract (%{alert, metric, value,
  # threshold, window_seconds, at}) so the channel — including ScaleAlertDeliveryWorker's
  # no-URL skip log, which renders metric=value — stays meaningful. Extra context rides
  # alongside; consumers branch on `alert`.
  defp enqueue_alert(verdict) do
    {metric, value, threshold} = alert_metric(verdict)

    payload = %{
      "alert" => "embeddings.legacy_retirement_due",
      "metric" => metric,
      "value" => value,
      "threshold" => threshold,
      "window_seconds" => verdict.required_clear_days * 86_400,
      "trigger" => to_string(verdict.trigger),
      "side_table_reads" => verdict.side_table_reads,
      "legacy_columns" => verdict.legacy_columns,
      "legacy_index_scans" => verdict.legacy_index_scans,
      "review_by" => Date.to_iso8601(verdict.review_by),
      "reasons" => verdict.reasons,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case %{payload: payload} |> ScaleAlertDeliveryWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        # Already logged at :error above, so a lost webhook does not lose the signal.
        Logger.warning(
          "LegacyEmbeddingRetirementWorker: failed to enqueue operator alert: " <>
            inspect(reason)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "LegacyEmbeddingRetirementWorker: failed to enqueue operator alert " <>
          "(#{inspect(error.__struct__)}): #{Exception.message(error)}"
      )

      :ok
  end

  # On the DEADLINE trigger `clear_days` is 0 BY CONSTRUCTION, so shipping it as the breach
  # pair renders "0 of 30" — which any consumer comparing value to threshold (including the
  # no-URL skip log) reads as healthy, the exact inversion of what the alert means.
  defp alert_metric(%{trigger: :deadline} = v),
    do: {"embeddings.legacy_retirement.days_past_review_by", v.days_past_review_by, 0}

  defp alert_metric(v),
    do: {"embeddings.legacy_retirement.clear_days", v.clear_days, v.required_clear_days}

  # An error is NOT folded into "absent": a saturated AdminRepo pool (3 connections) would
  # answer with the same `false` a pending migration does, and returning `:ok` from a run
  # that measured nothing — under a log naming an untrue cause — is the fail-open this
  # worker exists to prevent.
  defp observations_table_ready? do
    case AdminRepo.query("SELECT to_regclass('embedding_retirement_observations')", []) do
      {:ok, %{rows: [[nil]]}} -> {:ok, false}
      {:ok, %{rows: [[_oid]]}} -> {:ok, true}
      {:ok, %{rows: rows}} -> {:error, {:unexpected_table_probe_result, length(rows)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
