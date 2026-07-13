defmodule Loopctl.HealthCheck.Default do
  @moduledoc """
  Default health check implementation.

  Checks database connectivity (SELECT 1), Oban process status, and the US-32.4
  scale-alerts config-guard. Returns the application version from the mix project
  config.

  ## Liveness (`status`) vs readiness (`ready`) — US-32.4 post-review correction

  `fly.toml` wires plain `GET /health` as the CONTINUOUS `http_service` load-balancer
  check (10s interval, `min_machines_running: 1`, `strategy: rolling`) — it is not a
  deploy-only smoke probe, it decides whether a running node stays in traffic rotation
  RIGHT NOW. A benign, purely observational misconfiguration (scale alerts enabled but
  no webhook URL) must never depool an otherwise-healthy node on that continuous check.

  So `status` — the field `LoopctlWeb.HealthController.check/2` uses for `/health`'s
  HTTP code, i.e. the one Fly's proxy acts on — reflects ONLY `database` and `oban`:
  the things that mean this node genuinely cannot serve traffic. `scale_alerts` is
  still surfaced in `checks` (and `reasons` on failure) for visibility, but it does
  NOT flip `status`.

  A separate `ready` boolean additionally folds in `scale_alerts`, and is acted on
  ONLY by `GET /health/ready` (`LoopctlWeb.HealthController.ready/2`) — a genuine
  deploy-time smoke gate an operator or deploy pipeline can poll explicitly, distinct
  from the endpoint Fly's proxy continuously checks. This satisfies AC-32.4.1's
  "flip a readiness flag so /health (or the readiness endpoint) reports NOT-ready"
  via the readiness-endpoint branch of that disjunction.
  """

  @behaviour Loopctl.HealthCheck.Behaviour

  alias Ecto.Adapters.SQL
  alias Loopctl.Telemetry.ScaleAlerts

  @impl true
  def check do
    db_check = check_database()
    oban_check = check_oban()
    scale_alerts_check = check_scale_alerts()

    checks = %{
      database: elem(db_check, 0),
      oban: elem(oban_check, 0),
      scale_alerts: elem(scale_alerts_check, 0)
    }

    # Liveness: database/oban only — see the moduledoc on why scale_alerts must NOT
    # participate here (it would let a benign config-only issue depool a healthy node
    # on Fly's continuous load-balancer check).
    status =
      if checks.database == "ok" and checks.oban == "ok",
        do: "ok",
        else: "degraded"

    # Readiness: liveness AND the scale-alerts config-guard. Only `/health/ready` acts
    # on this — it is the deploy-time smoke signal, not the traffic-routing one.
    ready = status == "ok" and checks.scale_alerts == "ok"

    result = %{status: status, ready: ready, version: app_version(), checks: checks}
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
  # but no webhook URL configured) so a misconfigured deploy fails its readiness check
  # (`/health/ready`) instead of silently going inert. Does not affect alert DELIVERY
  # behavior for the healthy case, and — per the moduledoc — never flips the liveness
  # `status` that Fly's continuous load-balancer check acts on.
  #
  # Self-rescuing like its `check_database`/`check_oban` siblings: an unexpected raise
  # (e.g. a non-string config value reaching `ScaleAlerts.config_status/0`) must degrade
  # cleanly to an "error" check, never crash the whole endpoint into a 500.
  defp check_scale_alerts do
    case scale_alerts_config_checker().config_status() do
      :ok -> {"ok"}
      {:error, reason} -> {"error", reason}
    end
  rescue
    _ -> {"error", "scale alerts config check raised unexpectedly"}
  end

  # DI seam (Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour) so the degraded
  # branch above is exercisable in tests via Mox.expect/3 without `Application.put_env`.
  # Defaults to the real `ScaleAlerts` module (unchanged behavior in dev/prod).
  defp scale_alerts_config_checker,
    do: Application.get_env(:loopctl, :scale_alerts_config_checker, ScaleAlerts)

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
