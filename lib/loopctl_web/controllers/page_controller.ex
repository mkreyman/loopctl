defmodule LoopctlWeb.PageController do
  @moduledoc """
  Landing page controller for loopctl.com.

  Serves the public marketing page at GET /. Uses a plain controller
  with HEEx templates -- no LiveView WebSocket for static content.

  NOTE: This controller uses `formats: [:html]` instead of the default
  `:controller` macro (which sets `formats: [:json]` for API endpoints).
  """

  use Phoenix.Controller, formats: [:html]

  use Gettext, backend: LoopctlWeb.Gettext

  import Plug.Conn

  use Phoenix.VerifiedRoutes,
    endpoint: LoopctlWeb.Endpoint,
    router: LoopctlWeb.Router,
    statics: LoopctlWeb.static_paths()

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end

  def terms(conn, _params) do
    render(conn, :terms, layout: false)
  end

  def privacy(conn, _params) do
    render(conn, :privacy, layout: false)
  end
end
