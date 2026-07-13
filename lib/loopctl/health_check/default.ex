defmodule Loopctl.HealthCheck.Default do
  @moduledoc """
  Default health check implementation.

  Checks database connectivity (SELECT 1) and Oban process status.
  Returns the application version from the mix project config.
  """

  @behaviour Loopctl.HealthCheck.Behaviour

  alias Ecto.Adapters.SQL
  alias Loopctl.Telemetry.ScaleAlerts

  @impl true
  def check do
    db_check = check_database()
    oban_check = check_oban()
    scale_alerts_check = check_scale_alerts()
    version = app_version()

    checks = %{
      database: elem(db_check, 0),
      oban: elem(oban_check, 0),
      scale_alerts: elem(scale_alerts_check, 0)
    }

    status =
      if Enum.all?(Map.values(checks), &(&1 == "ok")),
        do: "ok",
        else: "degraded"

    result = %{status: status, version: version, checks: checks}
    result = maybe_put_reasons(result, scale_alerts_check)

    {:ok, result}
  end

  defp check_database do
    case SQL.query(Loopctl.Repo, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> {"ok"}
      {:error, _} -> {"error"}
    end
  rescue
    _ -> {"error"}
  end

  defp check_oban do
    case Oban.check_queue(queue: :default) do
      %{paused: _} -> {"ok"}
      _ -> {"error"}
    end
  rescue
    _ -> {"error"}
  end

  # US-32.4 config-guard: surfaces `ScaleAlerts.config_status/0` (scale alerts enabled
  # but no webhook URL configured) so a misconfigured deploy fails readiness instead of
  # silently going inert. Does not affect alert DELIVERY behavior for the healthy case.
  defp check_scale_alerts do
    case ScaleAlerts.config_status() do
      :ok -> {"ok"}
      {:error, reason} -> {"error", reason}
    end
  end

  defp app_version do
    Application.spec(:loopctl, :vsn) |> to_string()
  end

  # Only attach a `reasons` field when a check actually failed with a reason — keeps the
  # healthy-path response shape unchanged (AC-32.4.2/3). No secret is included: the reason
  # string names the env var only (see `ScaleAlerts.config_status/2`).
  defp maybe_put_reasons(result, {"error", reason}) do
    Map.put(result, :reasons, %{scale_alerts: reason})
  end

  defp maybe_put_reasons(result, _check), do: result
end
