defmodule LoopctlWeb.Plugs.DBErrorHandler do
  @moduledoc """
  `Plug.Exception` safety net for *raised* DB exceptions (US-27.3).

  The FallbackController handles DB errors that a controller explicitly
  rescues and returns as `{:error, %Postgrex.Error{}}` — that path also does
  the structured SQLSTATE logging with request_id (AC-27.3.3).

  This module is the backstop for any DB exception that escapes an action
  uncaught and reaches Phoenix's `render_errors` path. `Plug.Exception.status/1`
  is consulted for the HTTP status of any raised exception, so we map the same
  SQLSTATE classes to the same pinned statuses here (504/503/500) instead of a
  blanket 500. The body is rendered by `LoopctlWeb.ErrorJSON` from the status's
  reason phrase — a safe, generic message with no SQL/params/stack trace.

  `status/1` is pure (no logging hook); deterministic structured logging is the
  rescue→tuple→FallbackController path. Phoenix still emits its own crash log for
  raised errors, which carries the SQLSTATE for diagnosis as a backstop.

  Mirrors `LoopctlWeb.Plugs.CastErrorHandler`: auto-compiled `defimpl`, no
  router/endpoint registration needed. phoenix_ecto's own `Postgrex.Error` impl
  is disabled via `config :phoenix_ecto, :exclude_ecto_exceptions_from_plug` so
  this is the single authoritative mapping. We preserve phoenix_ecto's
  `:character_not_in_repertoire -> 400` so pre-US-27.3 behavior is unchanged.
  """
end

defimpl Plug.Exception, for: Postgrex.Error do
  # Preserve phoenix_ecto's prior special case (invalid UTF-8 in input -> 400)
  # so US-27.3 only adds structured handling for previously-blanket-500 classes.
  def status(%{postgres: %{code: :character_not_in_repertoire}}), do: 400

  def status(error) do
    case LoopctlWeb.DBError.map(error) do
      {:ok, %{status: status}} -> status
      :unmapped -> 500
    end
  end

  def actions(_error), do: []
end

defimpl Plug.Exception, for: DBConnection.ConnectionError do
  def status(error) do
    case LoopctlWeb.DBError.map(error) do
      {:ok, %{status: status}} -> status
      :unmapped -> 503
    end
  end

  def actions(_error), do: []
end
