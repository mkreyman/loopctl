defmodule LoopctlWeb.AdminStatsController do
  @moduledoc """
  Controller for system-wide statistics endpoint.

  GET /api/v1/admin/stats — aggregate counts across all tenants.
  Requires superadmin API key.
  """

  use LoopctlWeb, :controller

  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :superadmin

  @doc """
  GET /api/v1/admin/stats

  Returns system-wide aggregate statistics as a flat JSON object.
  """
  def show(conn, _params) do
    {:ok, stats} = Tenants.system_stats()

    json(conn, %{stats: stats})
  end
end
