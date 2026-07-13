defmodule Loopctl.Workers.ScaleAlertDeliveryWorker do
  @moduledoc """
  Durable delivery for `Loopctl.Telemetry.ScaleAlerts` (US-34.5, AC-34.5.1).

  ScaleAlerts is operator/system-scoped: unlike `Loopctl.Workers.WebhookDeliveryWorker`
  (tenant-scoped, backed by a `webhook_event`/`webhook` DB row it updates on every
  attempt), a scale alert has NO row to track. This worker leans on Oban's NATIVE
  retry/backoff instead of manual `{:snooze, _}` bookkeeping: returning `{:error, _}`
  from `perform/1` is enough for Oban to reschedule the next attempt with its
  (exponential + jittered) backoff, so a transient webhook failure retries instead of
  being logged-and-dropped by a synchronous in-process POST.

  ## Args

  Job args round-trip through JSON, so `perform/1` pattern-matches STRING keys (atom
  keys never survive Oban's JSON encode/decode):

      %{"payload" => payload}

  `payload` is the SAME id-only alert map `ScaleAlerts` already built (`%{alert,
  metric, value, threshold, window_seconds, at}`) — no tenant content, vectors, SQL, or
  request bodies are ever enqueued.

  ## No URL in args (secrets-at-rest review fix)

  The webhook URL is deliberately NOT carried in job args. `ScaleAlerts` treats it as
  resolve-once operator config (`ScaleAlerts.webhook_url/0`, read once at `init/1`);
  Oban persists job args as cleartext JSON in `oban_jobs` with no encryption plugin
  configured, and `Oban.Plugins.Pruner` retains terminal jobs for 7 days. A scale-alert
  webhook URL is commonly secret-bearing (Slack incoming-webhook / PagerDuty routing
  tokens), so persisting it in args would leak it into the DB, every backup, the Oban
  Web dashboard, and any Oban telemetry/APM consumer. Instead `perform/1` re-resolves the
  URL at run time via `ScaleAlerts.webhook_url/0` — behaviorally equivalent since the URL
  is static operator config, but keeps the secret out of the database. This mirrors the
  sibling `Loopctl.Workers.WebhookDeliveryWorker`, which stores only IDs in args and
  re-resolves URL + signing secret from the DB. If the URL is unset by the time the job
  runs (a config typo / race), the job logs a warning and completes as a no-op `:ok`
  rather than erroring — alerting is opt-in, so an unconfigured URL is not a delivery
  failure.

  ## Delivery DI

  Resolves `:webhook_delivery` via `Application.compile_env/3` — the SAME config key
  `ScaleAlerts` and `WebhookDeliveryWorker` use, mockable in tests via
  `Loopctl.MockDelivery` (config/test.exs).

  ## Wall-clock timeout (review fix)

  This worker shares the `:webhooks` queue with `Loopctl.Workers.WebhookDeliveryWorker`,
  which deliberately enforces `timeout(_job), do: :timer.seconds(30)` as a backstop ON
  TOP of Req's `receive_timeout` — a slow/hostile target must not pin a shared
  `:webhooks` slot indefinitely (see GHSA-jh42-wf7g-f5rg). `ReqDelivery`'s `10s`
  `receive_timeout` bounds awaiting a response but not a slow-drip connection or a
  connect stall, so this worker enforces the SAME 30s cap to keep every occupant of the
  shared queue under one hard ceiling.
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 6

  require Logger

  alias Loopctl.Telemetry.ScaleAlerts

  @delivery_client Application.compile_env(
                     :loopctl,
                     :webhook_delivery,
                     Loopctl.Webhooks.ReqDelivery
                   )

  # Hard per-job wall-clock cap — mirrors `WebhookDeliveryWorker.timeout/1` (same
  # shared `:webhooks` queue, same rationale: ie-02 / GHSA-jh42-wf7g-f5rg).
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payload" => payload}}) do
    deliver_or_skip(payload, ScaleAlerts.webhook_url())
  end

  @doc false
  # Takes the resolved URL as an ARG (rather than reading `ScaleAlerts.webhook_url/0`
  # internally) so both branches are unit-testable without `Application.put_env` —
  # mirrors `ScaleAlerts.config_status/2`'s "config as args" idiom.
  @spec deliver_or_skip(map(), String.t() | nil) :: :ok | {:error, term()}
  def deliver_or_skip(payload, nil) do
    Logger.warning(
      "ScaleAlertDeliveryWorker: scale_alert_webhook_url is unset at delivery time, " <>
        "skipping (alert already logged when enqueued): #{payload["metric"]}=#{payload["value"]}"
    )

    :ok
  end

  def deliver_or_skip(payload, url) when is_binary(url), do: deliver(url, payload)

  defp deliver(url, payload) do
    body = Jason.encode!(payload)
    headers = [{"content-type", "application/json"}]

    case @delivery_client.deliver(url, body, headers) do
      {:ok, _resp} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ScaleAlertDeliveryWorker: delivery failed (#{inspect(reason)}), Oban will retry"
        )

        {:error, reason}
    end
  end
end
