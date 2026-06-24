defmodule LoopctlWeb.Plugs.DBErrorHandler do
  @moduledoc """
  `Plug.Exception` safety net for *raised* DB exceptions (US-27.3).

  The FallbackController handles DB errors that a controller explicitly
  rescues and returns as `{:error, %Postgrex.Error{}}` — that path also does
  the structured SQLSTATE logging with request_id (AC-27.3.3).

  This module supplies the HTTP STATUS for any DB exception that escapes an
  action uncaught and reaches Phoenix's `render_errors` path.
  `Plug.Exception.status/1` is consulted for the status of any raised exception,
  so we map the same SQLSTATE classes to the same pinned statuses here
  (504/503/500) instead of a blanket 500. The body is rendered by
  `LoopctlWeb.ErrorJSON` — a safe, generic message with no SQL/params/stack trace.

  `status/1` is pure (no logging hook). The STRUCTURED logging and SQL-leak
  sanitization for the uncaught path are handled separately by
  `LoopctlWeb.Plugs.DBErrorBackstop` (an endpoint-level wrapping plug): it catches
  the escaped DB exception, emits the same sanitized structured SQLSTATE line as
  the FallbackController rescue path (via `LoopctlWeb.DBErrorLogger`), and
  re-raises a `LoopctlWeb.SanitizedDBError` so the web-server crash log can never
  echo the raw query. Together, AC-27.3.3 (structured fields) and AC-27.3.8
  (no raw SQL/vector leakage) hold for EVERY controller, not just suggested_links
  — while THIS module keeps owning the status mapping.

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
