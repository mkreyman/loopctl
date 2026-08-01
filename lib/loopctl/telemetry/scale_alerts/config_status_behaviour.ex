defmodule Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour do
  @moduledoc """
  DI seam for the US-32.4 config-guard (`ScaleAlerts.config_status/0`).

  `Loopctl.HealthCheck.Default` calls this (not `ScaleAlerts.config_status/0` directly)
  so the degraded branch — a misconfigured deploy where `:scale_alerts_enabled` is true
  but `:scale_alert_webhook_url` is unset — is exercisable in tests via `Mox.expect/3`
  without the forbidden `Application.put_env`. The default resolution
  (`Loopctl.Telemetry.ScaleAlerts`, which already implements `config_status/0`) is
  untouched in dev/prod.

  `{:warn, reason}` (#376) is the third state: an incoherent-but-legitimate configuration
  (a webhook URL set while the checker is disabled) that is surfaced in
  `checks`/`reasons` but deliberately does NOT block `ready`. See
  `ScaleAlerts.config_status/2` for why that one is graded below `{:error, _}`.
  """

  @callback config_status() :: :ok | {:warn, String.t()} | {:error, String.t()}
end
