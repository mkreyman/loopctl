defmodule LoopctlWeb.RedirectController do
  @moduledoc """
  Simple redirects for common URL aliases.
  """

  use LoopctlWeb, :controller

  def swagger(conn, _params) do
    redirect(conn, to: "/swaggerui")
  end
end
