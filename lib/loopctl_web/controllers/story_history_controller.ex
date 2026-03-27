defmodule LoopctlWeb.StoryHistoryController do
  @moduledoc """
  Controller for the story history shortcut endpoint.

  GET /api/v1/stories/:id/history — full audit trail for a story.
  Accessible to agent role and above.
  """

  use LoopctlWeb, :controller

  action_fallback LoopctlWeb.FallbackController

  def show(conn, _params) do
    # Placeholder — implemented in US-3.3
    json(conn, %{data: [], pagination: %{total: 0, page: 1, page_size: 100}})
  end
end
