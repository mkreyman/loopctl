defmodule Loopctl.Workers.WebhookDeliveryWorker do
  @moduledoc """
  Oban worker that delivers webhook events to subscriber URLs.

  Processes pending webhook_events by making HTTP POST requests to the
  webhook URL with the event payload as JSON. Uses exponential backoff
  retry: 1m, 5m, 25m, 2h, 10h (max 6 attempts total).

  Delivery uses compile-time DI for the HTTP client, enabling Req.Test
  plug-based mocking in tests.

  ## Flow

  1. Load webhook_event and associated webhook
  2. Check webhook is active (mark failed if deactivated)
  3. Build delivery payload with signing headers (US-10.4)
  4. Make HTTP POST via delivery client
  5. Update event status (delivered/failed/exhausted)
  6. Update webhook consecutive_failures
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 1

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Oban.FairShare
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.Signing
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent

  @delivery_client Application.compile_env(
                     :loopctl,
                     :webhook_delivery,
                     Loopctl.Webhooks.ReqDelivery
                   )

  # Exponential backoff schedule in seconds. #461 item 6 (lifetime-cap sub-point):
  # this schedule bounds a repeatedly-failing delivery. The five backoff snoozes
  # sum to 60+300+1500+7200+36_000 = 45_060s (~12.5h), after which the 6th failed
  # attempt hits @max_attempts and `mark_exhausted/5` terminates the job (status
  # :exhausted) and calls `Webhooks.maybe_auto_disable/2`, auto-disabling the
  # endpoint.
  #
  # The HARD bound is ATTEMPTS (6 real delivery failures) — that is guaranteed and
  # is what actually terminates the job. The ~12.5h wall-clock figure is
  # BEST-EFFORT, not a hard cap: the FairShare gate at the top of perform/1 returns
  # {:snooze, n} WITHOUT consuming an attempt, so under sustained cross-tenant
  # contention on the :webhooks queue a failing delivery can be fair-share-snoozed
  # arbitrarily many times between real attempts, pushing actual wall-clock past
  # ~12.5h. This never affects termination (the job still stops deterministically
  # after 6 real failures); only the wall-clock figure is soft. No additional
  # explicit age cap is imposed — if a hard wall-clock bound is ever required,
  # derive it from event.inserted_at.
  @backoff_schedule [60, 300, 1500, 7200, 36_000]
  @max_attempts 6

  @doc """
  Returns the backoff duration in seconds for the given attempt number (1-based).
  """
  @spec backoff_seconds(pos_integer()) :: non_neg_integer()
  def backoff_seconds(attempt) when attempt >= 1 and attempt <= 5 do
    Enum.at(@backoff_schedule, attempt - 1)
  end

  def backoff_seconds(_attempt), do: List.last(@backoff_schedule)

  # Hard per-job wall-clock cap (backstop to the bounded DNS resolve in the egress
  # guard + Req receive_timeout). A hostile/slow webhook target can't pin a
  # :webhooks queue slot indefinitely (ie-02 / GHSA-jh42-wf7g-f5rg).
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: id,
        args: %{"webhook_event_id" => event_id, "tenant_id" => tenant_id}
      }) do
    # #461 item 6: per-tenant fair-share gate on the shared :webhooks queue. Without
    # it, one tenant's many failing/slow endpoints could fill every :webhooks slot
    # (width 5) and starve other tenants' deliveries. `gate/3` returns `{:snooze, n}`
    # — Oban reschedules WITHOUT consuming an attempt (loss-free, and compatible with
    # this worker's manual attempt tracking / max_attempts: 1) — when the tenant is
    # over its derived fair share (ceil(5/2)=3). `id` excludes THIS already-executing
    # job from its own executing-count (rank-based decision; see FairShare).
    case FairShare.gate(tenant_id, :webhooks, id) do
      {:snooze, _n} = snooze ->
        snooze

      :ok ->
        deliver(tenant_id, event_id)
    end
  end

  defp deliver(tenant_id, event_id) do
    with {:ok, event} <- load_event(tenant_id, event_id),
         {:ok, webhook} <- load_webhook(tenant_id, event.webhook_id) do
      # Check if webhook is active (unless test event)
      if webhook.active or event.event_type == "webhook.test" do
        attempt_delivery(event, webhook)
      else
        mark_deactivated(event)
      end
    else
      {:error, :not_found} ->
        Logger.warning("WebhookDeliveryWorker: event or webhook not found (event_id=#{event_id})")
        :ok
    end
  end

  defp attempt_delivery(event, webhook) do
    # Build and size-limit the delivery payload
    payload = build_delivery_payload(event)
    json_body = Signing.prepare_payload(payload)

    # Build headers with HMAC-SHA256 signature
    headers = build_headers(event, webhook, json_body)

    case @delivery_client.deliver(webhook.url, json_body, headers) do
      {:ok, _response} ->
        mark_delivered(event, webhook)
        :ok

      {:error, error_msg} ->
        handle_failure(event, webhook, error_msg)
    end
  end

  defp build_delivery_payload(event) do
    %{
      "id" => event.id,
      "event" => event.event_type,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "data" => event.payload
    }
  end

  defp build_headers(event, webhook, json_body) do
    timestamp = System.system_time(:second)
    signing_secret = webhook.signing_secret_encrypted

    signature = Signing.sign_payload(json_body, signing_secret)

    [
      {"content-type", "application/json"},
      {"user-agent", "Loopctl-Webhook/1.0"},
      {"x-webhook-id", event.id},
      {"x-webhook-timestamp", to_string(timestamp)},
      {"x-signature-256", signature}
    ]
  end

  defp mark_delivered(event, webhook) do
    now = DateTime.utc_now()

    event
    |> Ecto.Changeset.change(%{
      status: :delivered,
      delivered_at: now,
      attempts: event.attempts + 1,
      last_attempt_at: now
    })
    |> AdminRepo.update!()

    # Reset consecutive failures on success
    webhook
    |> Ecto.Changeset.change(%{
      consecutive_failures: 0,
      last_delivery_at: now
    })
    |> AdminRepo.update!()
  end

  defp handle_failure(event, webhook, error_msg) do
    now = DateTime.utc_now()
    new_attempts = event.attempts + 1

    if new_attempts >= @max_attempts do
      mark_exhausted(event, webhook, error_msg, now, new_attempts)
      :ok
    else
      # Mark as still pending with incremented attempts
      event
      |> Ecto.Changeset.change(%{
        attempts: new_attempts,
        last_attempt_at: now,
        error: error_msg
      })
      |> AdminRepo.update!()

      snooze_seconds = backoff_seconds(new_attempts)
      {:snooze, snooze_seconds}
    end
  end

  defp mark_exhausted(event, webhook, error_msg, now, new_attempts) do
    event
    |> Ecto.Changeset.change(%{
      status: :exhausted,
      attempts: new_attempts,
      last_attempt_at: now,
      error: error_msg
    })
    |> AdminRepo.update!()

    # Increment consecutive failures
    new_failures = webhook.consecutive_failures + 1

    updated_webhook =
      webhook
      |> Ecto.Changeset.change(%{consecutive_failures: new_failures})
      |> AdminRepo.update!()

    # Check auto-disable threshold
    Webhooks.maybe_auto_disable(webhook.tenant_id, updated_webhook)
  end

  defp mark_deactivated(event) do
    event
    |> Ecto.Changeset.change(%{
      status: :failed,
      error: "webhook_deactivated",
      last_attempt_at: DateTime.utc_now()
    })
    |> AdminRepo.update!()

    :ok
  end

  defp load_event(tenant_id, event_id) do
    case AdminRepo.get_by(WebhookEvent, id: event_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  defp load_webhook(tenant_id, webhook_id) do
    case AdminRepo.get_by(Webhook, id: webhook_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end
end
