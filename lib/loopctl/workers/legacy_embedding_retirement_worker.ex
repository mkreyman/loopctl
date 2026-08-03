defmodule Loopctl.Workers.LegacyEmbeddingRetirementWorker do
  @moduledoc """
  Daily driver for the US-41.1 legacy-column retirement trigger (GH #551).

  Each run takes one live reading of the legacy `articles.embedding` /
  `memories.embedding` footprint, records it as that UTC day's observation, and asks
  `Loopctl.Embeddings.LegacyRetirement` whether retirement is now owed. It never
  drops anything — the drop stays a deliberate human migration behind a reviewed PR.

  ## What a `:due` verdict raises

  Mirroring `Loopctl.Workers.IngestionHealthWorker`, the signal is deliberately
  multi-channel so it does not depend on optional configuration:

    * an always-on `Logger.error`, so the condition surfaces in logs/monitoring even
      with no alert webhook configured (which is the CURRENT prod posture — scale
      alerting was switched off in #539 until a receiver exists), and
    * an operator alert enqueued via `Loopctl.Workers.ScaleAlertDeliveryWorker`,
      which resolves `SCALE_ALERT_WEBHOOK_URL` itself and no-ops when unset.

  It re-fires EVERY day for as long as the condition holds. That is the point rather
  than an oversight: this is a "the build is red until you deal with it" signal, and
  the failure mode it exists to prevent is precisely a reminder that stopped arriving.
  There is no per-run anti-alarm-fatigue suppression here for the same reason — one
  daily line about a standing 1.36 GB debt is the cheapest possible nag.

  ## Failure is loud, not silent

  A probe that cannot read the catalog returns `{:error, _}` and this worker returns
  `{:error, _}` too, so Oban retries with backoff and the failure is visible as a job
  failure rather than being swallowed into "nothing to do". It emits
  `Loopctl.TelemetryEvents.legacy_retirement_probe_failed/0` on the way out so the
  monitor's own death is itself observable.

  Even so, a monitor that fails forever LOOKS like a monitor that keeps finding
  nothing. That is why `LegacyRetirement`'s deadline trigger exists and does not
  depend on any observation being recorded.
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
    if observations_table_ready?() do
      run()
    else
      # Version skew: this worker's crontab entry deployed before its migration ran.
      # Skip quietly and self-heal next run rather than burning retries — the daily
      # cadence means at most one day of evidence is lost, and the deadline trigger
      # does not depend on the table at all.
      Logger.warning(
        "LegacyEmbeddingRetirementWorker: embedding_retirement_observations table " <>
          "is absent (migration pending); skipping this run"
      )

      :ok
    end
  end

  # Injected (`Loopctl.Embeddings.LegacyRetirementBehaviour`) for ONE reason: the
  # `{:error, _}` branch below is the fail-closed guarantee this worker exists to
  # provide, and the test database always answers the catalog query successfully, so
  # without a seam that branch could never be exercised. Production resolves to the
  # real module.
  defp retirement do
    Application.get_env(:loopctl, :legacy_retirement, LegacyRetirement)
  end

  defp run do
    case retirement().probe() do
      {:ok, probe} ->
        record(probe)

        probe
        |> retirement().evaluate([])
        |> react()

      {:error, reason} ->
        :telemetry.execute(TelemetryEvents.legacy_retirement_probe_failed(), %{count: 1}, %{
          error_class: error_class(reason)
        })

        Logger.error(
          "LegacyEmbeddingRetirementWorker: could not read the legacy embedding " <>
            "footprint: #{inspect(reason)}. This is NOT evidence that the columns " <>
            "are gone — the retirement check did not run."
        )

        {:error, reason}
    end
  end

  # Recording is best-effort relative to REACTING: a day whose row failed to persist
  # costs one day of evidence, but suppressing the verdict over it would turn a
  # storage hiccup into silence about a condition we just successfully measured.
  defp record(probe) do
    case retirement().record(probe, []) do
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

  defp react(%{verdict: :retired}), do: :ok

  defp react(%{verdict: :not_due} = verdict) do
    Logger.info(
      "LegacyEmbeddingRetirementWorker: legacy embedding columns " <>
        "#{inspect(verdict.legacy_columns)} not yet retirable — " <>
        reasons(verdict)
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

  # Keeps the telemetry dimension BOUNDED: a module name, never a message that could
  # carry a query fragment or a connection string.
  defp error_class(%{__struct__: module}), do: inspect(module)
  defp error_class(_), do: "rollback"

  defp reasons(%{reasons: []}), do: "no reason recorded"
  defp reasons(%{reasons: reasons}), do: Enum.join(reasons, "; ")

  # Conforms to the shared ScaleAlert operator-alert contract (%{alert, metric, value,
  # threshold, window_seconds, at}) so the channel — including
  # ScaleAlertDeliveryWorker's no-URL skip log, which renders metric=value — stays
  # meaningful. Extra context rides alongside; consumers branch on `alert`.
  defp enqueue_alert(verdict) do
    payload = %{
      "alert" => "embeddings.legacy_retirement_due",
      "metric" => "embeddings.legacy_retirement.clear_days",
      "value" => verdict.clear_days,
      "threshold" => verdict.required_clear_days,
      "window_seconds" => verdict.required_clear_days * 86_400,
      "trigger" => to_string(verdict.trigger),
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

  defp observations_table_ready? do
    case AdminRepo.query("SELECT to_regclass('embedding_retirement_observations')", []) do
      {:ok, %{rows: [[nil]]}} -> false
      {:ok, %{rows: [[_oid]]}} -> true
      _ -> false
    end
  end
end
