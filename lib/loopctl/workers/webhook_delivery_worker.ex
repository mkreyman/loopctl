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
  4. Make HTTP POST via delivery client, on the webhook's EGRESS SCOPE
  5. Update event status (delivered/failed/exhausted/blocked)
  6. Update webhook consecutive_failures

  ## Egress refusals are not delivery failures (US-41.5, AC-41.5.2/AC-41.5.5)

  `Loopctl.Egress.oban_result/1` is the reference mapping and this worker follows
  its SEMANTICS, not its literal return: the queue is `max_attempts: 1` with
  app-level snooze retries, so a refusal must not burn an attempt or re-enter the
  backoff ladder.

    * `:egress_blocked` is PERMANENT — the event is marked `:blocked` with an
      agent-readable reason, the aggregated blocked-decision counter is bumped,
      and the job returns `:ok`. TERMINAL: no snooze, no attempt consumed, no
      `consecutive_failures` increment (the subscriber never failed — loopctl
      refused to call it), so a misconfigured subscription cannot build an
      unbounded retry backlog (TC-41.5.5).
    * `:pin_stale` / `:egress_unavailable` are TRANSIENT — the job snoozes for
      `Egress.transient_snooze_seconds/0` WITHOUT consuming an attempt and
      WITHOUT recording a block. A DHCP lease change or a pool blip must never
      look like a privacy refusal.

  ### The transient path is BOUNDED (review fix)

  "Transient" is a claim about the CAUSE, not a promise that it ends. A webhook
  destination whose domain lapses classifies as `:egress_unavailable` on EVERY
  attempt (fail-closed for a tenant-supplied url), so an unconditional snooze —
  on a `max_attempts: 1` queue where each snooze also bumps `max_attempts` —
  produced one IMMORTAL job per event: `attempts` stayed 0, the event stayed
  `:pending`, `consecutive_failures` never rose, the subscription was never
  auto-disabled, and every new event added another permanent job. That
  contradicts AC-41.5.2 ("NOT an infinite retry").

  So a transient refusal snoozes for free at most `@max_transient_snoozes` times
  per job; after that it falls through to the ORDINARY failure ladder
  (`handle_failure/3`) — burning an attempt each time, reaching `:exhausted` at
  `@max_attempts`, incrementing `consecutive_failures` and reaching the
  auto-disable valve, exactly as an unreachable destination did before US-41.5.
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 1

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Egress
  alias Loopctl.Egress.Scope
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.Signing
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent

  @delivery_client Application.compile_env(
                     :loopctl,
                     :webhook_delivery,
                     Loopctl.Webhooks.ReqDelivery
                   )

  # Exponential backoff schedule in seconds
  @backoff_schedule [60, 300, 1500, 7200, 36_000]
  @max_attempts 6

  # How many times ONE job may snooze for free on a TRANSIENT egress refusal
  # before the refusal is treated as an ordinary delivery failure. Bounds the
  # snooze path (see the moduledoc) so an unresolvable destination cannot produce
  # an immortal job.
  @max_transient_snoozes 6

  @doc """
  Free (attempt-less) transient-egress snoozes allowed per job before the
  ordinary failure ladder takes over.
  """
  @spec max_transient_snoozes() :: pos_integer()
  def max_transient_snoozes, do: @max_transient_snoozes

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
  def perform(%Oban.Job{args: %{"webhook_event_id" => event_id, "tenant_id" => tenant_id}} = job) do
    with {:ok, event} <- load_event(tenant_id, event_id),
         {:ok, webhook} <- load_webhook(tenant_id, event.webhook_id) do
      # Check if webhook is active (unless test event)
      if webhook.active or event.event_type == "webhook.test" do
        attempt_delivery(job, event, webhook)
      else
        mark_deactivated(event)
      end
    else
      {:error, :not_found} ->
        Logger.warning("WebhookDeliveryWorker: event or webhook not found (event_id=#{event_id})")
        :ok
    end
  end

  defp attempt_delivery(job, event, webhook) do
    # Build and size-limit the delivery payload
    payload = build_delivery_payload(event)
    json_body = Signing.prepare_payload(payload)

    # Build headers with HMAC-SHA256 signature
    headers = build_headers(event, webhook, json_body)

    # The delivery scope is the webhook's own (tenant, project) pair —
    # most-restrictive-wins, and a project-less subscription follows the TENANT
    # marking (AC-41.4.2 / AC-41.5.1).
    scope = Scope.new(webhook.tenant_id, webhook.project_id)

    case @delivery_client.deliver(webhook.url, json_body, headers, scope) do
      {:ok, _response} ->
        mark_delivered(event, webhook)
        :ok

      {:refused, refusal} ->
        handle_refusal(job, event, webhook, scope, refusal)

      {:error, error_msg} ->
        handle_failure(event, webhook, error_msg)
    end
  end

  # AC-41.5.2: a blocked delivery is NOT a silent drop and NOT an infinite retry.
  defp handle_refusal(job, event, webhook, scope, refusal) do
    case Egress.block_kind(refusal) do
      :transient ->
        handle_transient_refusal(job, event, webhook, refusal)

      kind ->
        mark_blocked(event, scope, kind, refusal)
        :ok
    end
  end

  # BOUNDED (see the moduledoc): free snoozes first, then the ordinary failure
  # ladder, so a permanently-unresolvable destination still exhausts and still
  # reaches the auto-disable valve.
  defp handle_transient_refusal(job, event, webhook, refusal) do
    reason = Egress.refusal_reason(refusal)

    if transient_snoozes(job, event) < @max_transient_snoozes do
      Logger.info(
        "WebhookDeliveryWorker: transient egress refusal for webhook #{webhook.id}, " <>
          "snoozing without burning an attempt — #{reason}"
      )

      {:snooze, Egress.transient_snooze_seconds()}
    else
      Logger.warning(
        "WebhookDeliveryWorker: transient egress refusal for webhook #{webhook.id} PERSISTED " <>
          "past #{@max_transient_snoozes} free snoozes; treating it as a delivery failure — " <>
          reason
      )

      handle_failure(event, webhook, "egress_unavailable_persisted: #{reason}")
    end
  end

  # Free snoozes taken by THIS job so far, derived — no new column.
  #
  # Oban increments `attempt` on every execution and bumps `max_attempts` on a
  # snooze, so for a job that has executed `attempt` times of which `attempts`
  # (the EVENT's counter) burned a delivery attempt, the remainder are the free
  # transient snoozes. Clamped at 0 so a hand-built job (`attempt: 0`) is safe.
  defp transient_snoozes(%Oban.Job{attempt: attempt}, event) when is_integer(attempt) do
    max(attempt - event.attempts - 1, 0)
  end

  defp transient_snoozes(_job, _event), do: 0

  defp mark_blocked(event, scope, kind, refusal) do
    details = refusal_details(scope, refusal)
    reason = "#{kind}: #{Egress.refusal_reason(refusal)}"

    Logger.warning(
      "WebhookDeliveryWorker: delivery REFUSED before any request (event_id=#{event.id}) — " <>
        reason
    )

    # The aggregated, deduplicated AC-41.4.6 record + the unbuffered
    # [:loopctl, :egress, :blocked] telemetry counter.
    Egress.record_blocked(scope, details)

    event
    |> Ecto.Changeset.change(%{
      status: :blocked,
      last_attempt_at: DateTime.utc_now(),
      error: reason
    })
    |> AdminRepo.update!()
  end

  # `Egress.block_kind/1` classifies an UNRECOGNISED refusal term as terminal
  # (`:unrecognized`), so the details map it carries may not exist. Synthesize one
  # rather than crashing the block record — the aggregated counter still names the
  # scope, and the event's `error` carries the raw term.
  defp refusal_details(scope, refusal) do
    case Egress.refusal(refusal) do
      {_tag, details} ->
        details

      nil ->
        %{
          host: nil,
          scope: Scope.key(scope),
          verdict: :unrecognized_refusal,
          remediation:
            "The delivery client returned a refusal term the egress policy does not " <>
              "recognise. Nothing was sent. This is a loopctl BUG — report it."
        }
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
