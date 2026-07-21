defmodule Loopctl.Workers.ScaleAlertDeliveryWorkerTest do
  @moduledoc """
  US-34.5 (AC-34.5.1) — worker-level coverage: proves Oban's NATIVE retry actually
  applies to a ScaleAlerts delivery. A delivery failure must return `{:error, _}` (the
  signal Oban uses to schedule the next attempt with its own backoff) rather than being
  swallowed to `{:ok, _}` and dropped; success returns `:ok`.

  Review fix (secrets-at-rest): job args carry ONLY `payload` — no `url` — so `perform/1`
  re-resolves the webhook URL via `ScaleAlerts.webhook_url/0` (config/test.exs sets
  `:scale_alert_webhook_url` to `@url` below) instead of trusting a persisted job arg.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  @payload %{
    "alert" => "scale_degradation",
    "metric" => "db_statement_timeout_rate",
    "value" => 6.0,
    "threshold" => 5,
    "window_seconds" => 60,
    "at" => "2026-01-01T00:00:00Z"
  }
  # Matches config/test.exs's `:scale_alert_webhook_url` — proves the worker resolves
  # the URL from config rather than from job args (which no longer carry it).
  @url "https://alerts.test.invalid/scale"

  defp job(args), do: %Oban.Job{args: args}

  describe "timeout/1 (review fix)" do
    test "enforces the same 30s wall-clock cap as the sibling WebhookDeliveryWorker" do
      assert ScaleAlertDeliveryWorker.timeout(job(%{"payload" => @payload})) ==
               :timer.seconds(30)
    end
  end

  describe "perform/1" do
    test "args carry no url — successful delivery resolves it from config and delivers the exact JSON payload + headers" do
      expect(Loopctl.MockDelivery, :deliver, fn url, body, headers, _scope ->
        assert url == @url
        assert {"content-type", "application/json"} in headers
        assert Jason.decode!(body) == @payload
        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok = ScaleAlertDeliveryWorker.perform(job(%{"payload" => @payload}))
    end

    test "delivery failure returns {:error, _} so Oban retries (not dropped)" do
      expect(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers, _scope ->
        {:error, "connection_refused"}
      end)

      assert {:error, "connection_refused"} =
               ScaleAlertDeliveryWorker.perform(job(%{"payload" => @payload}))
    end

    test "a job with a persisted url arg (legacy/pre-fix job) is ignored — the config url wins" do
      expect(Loopctl.MockDelivery, :deliver, fn url, _body, _headers, _scope ->
        assert url == @url
        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok =
               ScaleAlertDeliveryWorker.perform(
                 job(%{"url" => "https://attacker.invalid/steal", "payload" => @payload})
               )
    end
  end

  describe "deliver_or_skip/2 (review fix — URL resolved at run time, not from args)" do
    test "a nil url (unset by delivery time) logs and completes as a no-op :ok, no delivery attempted" do
      # No expect/3 set — verify_on_exit! would fail if `deliver/4` were called unexpectedly.
      assert :ok = ScaleAlertDeliveryWorker.deliver_or_skip(@payload, nil)
    end

    test "a binary url delivers exactly as perform/1 would" do
      expect(Loopctl.MockDelivery, :deliver, fn url, body, headers, _scope ->
        assert url == @url
        assert {"content-type", "application/json"} in headers
        assert Jason.decode!(body) == @payload
        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok = ScaleAlertDeliveryWorker.deliver_or_skip(@payload, @url)
    end
  end
end
