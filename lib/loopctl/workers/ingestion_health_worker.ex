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
  - an OPERATOR alert enqueued via `Loopctl.Workers.ScaleAlertDeliveryWorker` (which
    resolves `SCALE_ALERT_WEBHOOK_URL` itself and no-ops when unset — channel-agnostic
    and safe when unconfigured; this worker never reads the URL), and
  - a per-tenant `knowledge.ingestion_anomaly_detected` webhook event.

  On an EXISTING unresolved anomaly it silently refreshes the figures — NO re-notify
  (anti-alarm-fatigue), exactly like `CostAnomalyWorker`.

  ## Race-safety

  Creation uses the same `insert_all` + `on_conflict: :nothing` against a unique
  partial index (`ingestion_anomalies_unresolved_unique`) that `CostAnomalyWorker`
  uses: `{1, [row]}` means we genuinely inserted (notify); `{0, _}` means a concurrent
  run already inserted + notified (skip). We still check-first so an update never emits
  audit/webhook.

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
    candidates = IngestionHealth.detect()

    Logger.info(
      "IngestionHealthWorker: #{length(candidates)} capture-silence candidate(s) detected"
    )

    Enum.each(candidates, &flag_candidate/1)

    :ok
  end

  defp flag_candidate(%{
         tenant_id: tenant_id,
         source_type: source_type,
         last_event_at: last_event_at,
         hours_stale: hours_stale,
         sample_count: sample_count
       }) do
    # Check first (like CostAnomalyWorker) so an UPDATE never emits audit/webhook/alert.
    # The unique partial index still guards against races on the insert path below.
    existing =
      IngestionAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.source_type == ^source_type)
      |> where([a], a.anomaly_type == :capture_silence)
      |> where([a], a.resolved == false)
      |> AdminRepo.one()

    if existing do
      update_existing(existing, last_event_at, hours_stale, sample_count)
    else
      create_new(tenant_id, source_type, last_event_at, hours_stale, sample_count)
    end
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

  # insert_all + on_conflict: :nothing against the unresolved unique partial index.
  # {1, [row]} = we inserted (notify); {0, _} = concurrent run won the race (skip).
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

    case AdminRepo.insert_all(IngestionAnomaly, [entry],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment,
              ~s|("tenant_id","source_type","anomaly_type") WHERE resolved = false|},
           returning: true
         ) do
      {1, [anomaly]} ->
        notify_new_anomaly(tenant_id, anomaly)
        anomaly

      {0, _} ->
        # Lost the race: the concurrent inserter already emitted audit + alert + webhook.
        nil
    end
  end

  # Audit + operator alert + per-tenant webhook. Called ONLY for a genuinely persisted
  # anomaly, never for a conflict/no-op insert.
  defp notify_new_anomaly(tenant_id, anomaly) do
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

    fire_operator_alert(tenant_id, anomaly)
    fire_anomaly_webhook(tenant_id, anomaly)

    :ok
  end

  # Enqueue an operator alert through ScaleAlertDeliveryWorker with an id-only payload.
  # That worker resolves SCALE_ALERT_WEBHOOK_URL itself and no-ops when unset, so this
  # is channel-agnostic and safe when unconfigured — we never read/require the URL here.
  defp fire_operator_alert(tenant_id, anomaly) do
    payload = %{
      "alert" => "ingestion.capture_silence",
      "tenant_id" => tenant_id,
      "source_type" => anomaly.source_type,
      "hours_stale" => anomaly.hours_stale,
      "last_event_at" => iso8601(anomaly.last_event_at),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

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
      payload = %{
        "anomaly_id" => anomaly.id,
        "source_type" => anomaly.source_type,
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "hours_stale" => anomaly.hours_stale,
        "sample_count" => anomaly.sample_count,
        "last_event_at" => iso8601(anomaly.last_event_at)
      }

      Enum.each(webhooks, &deliver_anomaly_event(tenant_id, &1, payload, anomaly.id))
    end
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
