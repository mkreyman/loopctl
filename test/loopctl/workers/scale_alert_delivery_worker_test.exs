defmodule Loopctl.Workers.ScaleAlertDeliveryWorkerTest do
  @moduledoc """
  US-34.5 (AC-34.5.1) — worker-level coverage: proves Oban's NATIVE retry actually
  applies to a ScaleAlerts delivery. A delivery failure must return `{:error, _}` (the
  signal Oban uses to schedule the next attempt with its own backoff) rather than being
  swallowed to `{:ok, _}` and dropped; success returns `:ok`.
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
  @url "https://alerts.test.invalid/scale"

  defp job(args), do: %Oban.Job{args: args}

  describe "timeout/1 (review fix)" do
    test "enforces the same 30s wall-clock cap as the sibling WebhookDeliveryWorker" do
      assert ScaleAlertDeliveryWorker.timeout(job(%{"url" => @url, "payload" => @payload})) ==
               :timer.seconds(30)
    end
  end

  describe "perform/1" do
    test "successful delivery returns :ok and delivers the exact JSON payload + headers" do
      expect(Loopctl.MockDelivery, :deliver, fn url, body, headers ->
        assert url == @url
        assert {"content-type", "application/json"} in headers
        assert Jason.decode!(body) == @payload
        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok =
               ScaleAlertDeliveryWorker.perform(job(%{"url" => @url, "payload" => @payload}))
    end

    test "delivery failure returns {:error, _} so Oban retries (not dropped)" do
      expect(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
        {:error, "connection_refused"}
      end)

      assert {:error, "connection_refused"} =
               ScaleAlertDeliveryWorker.perform(job(%{"url" => @url, "payload" => @payload}))
    end
  end
end
