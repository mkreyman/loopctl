defmodule LoopctlWeb.Plugs.CastErrorHandler do
  @moduledoc """
  Implements `Plug.Exception` for Ecto cast errors to return 404.

  When an invalid UUID format is passed to a GET-by-ID endpoint
  (e.g., `/api/v1/projects/not-a-uuid`), Ecto raises a `CastError`.
  Without this, Phoenix returns a 500 Internal Server Error.
  With these protocol implementations, it correctly returns 404 Not Found.
  """
end

defimpl Plug.Exception, for: Ecto.CastError do
  def status(_exception), do: 404
  def actions(_exception), do: []
end

defimpl Plug.Exception, for: Ecto.Query.CastError do
  def status(_exception), do: 404
  def actions(_exception), do: []
end
