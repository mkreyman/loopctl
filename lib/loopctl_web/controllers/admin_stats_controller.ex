defmodule LoopctlWeb.AdminStatsController do
  @moduledoc """
  Controller for system-wide statistics endpoint.

  GET /api/v1/admin/stats — aggregate counts across all tenants.
  Requires superadmin API key.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :superadmin

  tags(["Admin"])

  operation(:show,
    summary: "System-wide stats (admin)",
    description:
      "Returns system-wide aggregate statistics. Requires superadmin. " <>
        "`total_api_keys` counts keys that can AUTHENTICATE right now: neither revoked nor " <>
        "past `expires_at`. It tested revocation alone until 846.8, so it included every " <>
        "expired-but-unrevoked key — a set that never empties, because " <>
        "RevokeExpiredApiKeysWorker deliberately leaves user/superadmin keys and any key " <>
        "with no agent un-revoked.",
    responses: %{
      200 =>
        {"System stats", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/admin/stats

  Returns system-wide aggregate statistics as a flat JSON object.
  """
  def show(conn, _params) do
    {:ok, stats} = Tenants.system_stats()

    json(conn, %{stats: stats})
  end
end
