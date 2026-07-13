defmodule Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour do
  @moduledoc """
  DI seam for the US-32.4 config-guard (`ScaleAlerts.config_status/0`).

  `Loopctl.HealthCheck.Default` calls this (not `ScaleAlerts.config_status/0` directly)
  so the degraded branch — a misconfigured deploy where `:scale_alerts_enabled` is true
  but `:scale_alert_webhook_url` is unset — is exercisable in tests via `Mox.expect/3`
  without the forbidden `Application.put_env`. The default resolution
  (`Loopctl.Telemetry.ScaleAlerts`, which already implements `config_status/0`) is
  untouched in dev/prod.
  """

  @callback config_status() :: :ok | {:error, String.t()}
end
