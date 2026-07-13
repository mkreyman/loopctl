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

      %{"url" => url, "payload" => payload}

  `payload` is the SAME id-only alert map `ScaleAlerts` already built (`%{alert,
  metric, value, threshold, window_seconds, at}`) — no tenant content, vectors, SQL, or
  request bodies are ever enqueued.

  ## Delivery DI

  Resolves `:webhook_delivery` via `Application.compile_env/3` — the SAME config key
  `ScaleAlerts` and `WebhookDeliveryWorker` use, mockable in tests via
  `Loopctl.MockDelivery` (config/test.exs).
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 6

  require Logger

  @delivery_client Application.compile_env(
                     :loopctl,
                     :webhook_delivery,
                     Loopctl.Webhooks.ReqDelivery
                   )

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "payload" => payload}}) do
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
