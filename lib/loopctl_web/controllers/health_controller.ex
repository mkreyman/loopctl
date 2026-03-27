defmodule LoopctlWeb.HealthController do
  @moduledoc """
  Health check endpoint for monitoring and deployment verification.

  GET /health — returns application health status including database
  connectivity, Oban status, and application version.

  This endpoint is unauthenticated so external probes (nginx, monitoring
  systems, deploy scripts) can reach it without an API key.
  """

  use LoopctlWeb, :controller

  action_fallback LoopctlWeb.FallbackController

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

  defp health_checker do
    Application.get_env(:loopctl, :health_checker, Loopctl.HealthCheck.Default)
  end
end
