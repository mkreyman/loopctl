defmodule LoopctlWeb.HealthController do
  @moduledoc """
  Health check endpoints for monitoring and deployment verification.

  GET /health — LIVENESS. Returns application health status including database
  connectivity and Oban status (the running app version is deliberately NOT
  disclosed to these unauthenticated endpoints — #461 item 5). Used by `fly.toml`'s
  `http_service` check as the CONTINUOUS load-balancer probe (10s interval) that
  decides whether a running node stays in traffic rotation — so its HTTP code is
  driven by `result.status`, which reflects database/oban only (see
  `Loopctl.HealthCheck.Default`'s moduledoc: a benign config-only issue must never
  depool an otherwise-healthy node).

  GET /health/ready — READINESS (US-32.4, extended by US-34.2). Same underlying check,
  but the HTTP code is driven by `result.ready`, which additionally folds in the
  scale-alerts config-guard (`:scale_alerts_enabled` true with no
  `SCALE_ALERT_WEBHOOK_URL`) AND (US-34.2) the Oban `:executing`-orphan backlog guard
  (`checks.oban_orphans`) — a queue backlog is a readiness signal, not a liveness one,
  so it never depools a node from Fly's LB even though a node with a stalled queue
  can't finish background work. This is the deploy-time smoke gate an operator or
  deploy pipeline polls explicitly — it is deliberately NOT wired into `fly.toml`'s
  continuous check.

  Both endpoints are unauthenticated so external probes (nginx, monitoring systems,
  deploy scripts) can reach them without an API key.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  action_fallback LoopctlWeb.FallbackController

  tags(["Health"])

  operation(:check,
    summary: "Health check",
    description: "Returns application health including database and Oban status.",
    security: [],
    responses: %{
      200 =>
        {"Healthy", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      503 =>
        {"Degraded", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}}
    }
  )

  def check(conn, _params) do
    case health_checker().check() do
      {:ok, %{status: "ok"} = result} ->
        conn
        |> put_status(:ok)
        |> json(result)

      {:ok, %{status: _degraded} = result} ->
        conn
        |> put_status(:service_unavailable)
        |> json(result)

      {:error, reason} ->
        {:error, :unprocessable_entity, "Health check failed: #{inspect(reason)}"}
    end
  end

  operation(:ready,
    summary: "Readiness check (US-32.4, US-34.2)",
    description:
      "Deploy-time smoke gate distinct from the /health liveness probe. Fails when " <>
        "scale alerts are enabled but no webhook URL is configured, or when the Oban " <>
        "`:executing`-orphan backlog exceeds its configured threshold, in addition to " <>
        "the database/oban checks. Not wired into Fly's continuous load-balancer check.",
    security: [],
    responses: %{
      200 =>
        {"Ready", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      503 =>
        {"Not ready", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}}
    }
  )

  def ready(conn, _params) do
    case health_checker().check() do
      {:ok, result} ->
        # Fall back to `status` when a health_checker doesn't report `ready` (e.g. a
        # bespoke implementation of the behaviour) so this action never crashes.
        ready? = Map.get(result, :ready, Map.get(result, :status) == "ok")

        conn
        |> put_status(if ready?, do: :ok, else: :service_unavailable)
        |> json(result)

      {:error, reason} ->
        {:error, :unprocessable_entity, "Readiness check failed: #{inspect(reason)}"}
    end
  end

  defp health_checker do
    Application.get_env(:loopctl, :health_checker, Loopctl.HealthCheck.Default)
  end
end
