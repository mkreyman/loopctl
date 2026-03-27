defmodule LoopctlWeb.ChangeController do
  @moduledoc """
  Controller for the change feed polling endpoint.

  GET /api/v1/changes?since=ISO8601 — cursor-based change feed.
  Accessible to agent role and above.
  """

  use LoopctlWeb, :controller

  action_fallback LoopctlWeb.FallbackController

  def index(conn, _params) do
    # Placeholder — implemented in US-3.2
    json(conn, %{data: [], has_more: false, next_since: nil})
  end
end
