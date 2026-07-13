defmodule Loopctl.Telemetry.ScaleAlertsConfigTest do
  @moduledoc """
  US-32.4: unit tests for the pure `ScaleAlerts.config_status/2` guard. Config is passed
  as ARGS (never `Application.put_env`) so these stay `async: true`.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Telemetry.ScaleAlerts

  describe "config_status/2" do
    test "TC-32.4.1: enabled + missing url (nil) returns an error naming the env var" do
      assert {:error, reason} = ScaleAlerts.config_status(true, nil)
      assert reason =~ "SCALE_ALERT_WEBHOOK_URL"
    end

    test "enabled + blank url (empty string) is treated as unset" do
      assert {:error, reason} = ScaleAlerts.config_status(true, "")
      assert reason =~ "SCALE_ALERT_WEBHOOK_URL"
    end

    test "enabled + whitespace-only url is treated as unset" do
      assert {:error, reason} = ScaleAlerts.config_status(true, "   ")
      assert reason =~ "SCALE_ALERT_WEBHOOK_URL"
    end

    test "TC-32.4.2: enabled + url present is ok" do
      assert ScaleAlerts.config_status(true, "https://hooks.example.test/alert") == :ok
    end

    test "TC-32.4.3: disabled + nil url needs no url" do
      assert ScaleAlerts.config_status(false, nil) == :ok
    end

    test "disabled + missing url regardless of url value stays ok (opt-out is clean)" do
      assert ScaleAlerts.config_status(false, "anything") == :ok
    end

    test "AC-32.4.5: the error reason never includes a URL value" do
      assert {:error, reason} = ScaleAlerts.config_status(true, nil)
      refute reason =~ "http"
    end

    test "enabled + a non-binary config value (e.g. a config typo) degrades cleanly instead of raising" do
      assert {:error, reason} = ScaleAlerts.config_status(true, :not_a_string)
      assert reason =~ "SCALE_ALERT_WEBHOOK_URL"

      assert {:error, _reason} = ScaleAlerts.config_status(true, ~c"charlist")
    end
  end

  describe "config_status/0" do
    test "reads live app env and matches config_status/2 with the same values" do
      enabled = Application.get_env(:loopctl, :scale_alerts_enabled, false)
      url = ScaleAlerts.webhook_url()

      assert ScaleAlerts.config_status() == ScaleAlerts.config_status(enabled, url)
    end
  end
end
