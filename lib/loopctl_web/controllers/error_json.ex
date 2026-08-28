defmodule LoopctlWeb.ErrorJSON do
  @moduledoc """
  Renders JSON error responses for all HTTP error status codes.

  This module is invoked by the endpoint's error handler for unhandled
  exceptions (500s) and by the FallbackController for application errors.

  All responses follow the consistent format:

      {"error": {"status": <code>, "message": "<message>"}}
  """

  def render("404.json", _assigns) do
    %{error: %{status: 404, message: "Not found"}}
  end

  def render("401.json", _assigns) do
    %{error: %{status: 401, message: "Unauthorized"}}
  end

  def render("403.json", _assigns) do
    %{error: %{status: 403, message: "Forbidden"}}
  end

  # US-27.3: a DB exception in the catch-all class (DBError.map/1 → status 500,
  # mapped_code "db_error") that escapes an action uncaught is re-raised as a
  # LoopctlWeb.SanitizedDBError{status: 500, mapped_code: "db_error"} by
  # LoopctlWeb.Plugs.DBErrorBackstop, and Phoenix renders it here. Like the
  # 504/503 clauses, surface `code` (db_error for the mapped DB case; falls back
  # to the generic 500 for a plain logic crash with no SanitizedDBError reason)
  # so the escaped-error body carries the same self-identifying class the
  # FallbackController rescue path emits (mapping.code). Body stays safe and
  # generic — no SQL/params/vectors/stack trace.
  def render("500.json", assigns) do
    %{
      error: %{
        status: 500,
        code: db_code(assigns, "internal_server_error"),
        message: "Internal server error"
      }
    }
  end

  # US-27.3: raised DB exceptions that escape an action are mapped to these
  # statuses by LoopctlWeb.Plugs.DBErrorHandler (Plug.Exception) and re-raised as
  # a LoopctlWeb.SanitizedDBError by LoopctlWeb.Plugs.DBErrorBackstop carrying the
  # mapped_code. The body stays safe and generic — no SQL/params/vectors/stack
  # trace — and carries a `code` so a timeout/serialization/deadlock is
  # self-identifying vs. a logic 500. The deterministic SQLSTATE log happens on
  # the FallbackController rescue path AND the backstop; here we only ensure the
  # escaped-error body is safe AND that its `code` matches the mapped class so the
  # escaped 503 isn't coarser than the rescue path (db_serialization_failure /
  # db_deadlock vs. db_unavailable).
  def render("504.json", assigns) do
    %{
      error: %{
        status: 504,
        code: db_code(assigns, "db_statement_timeout"),
        message: "The request timed out while querying the database. Please retry."
      }
    }
  end

  def render("503.json", assigns) do
    %{
      error: %{
        status: 503,
        code: db_code(assigns, "db_unavailable"),
        message: "The database is temporarily unavailable. Please retry."
      }
    }
  end

  # US-37.5: a tenant over its per-tenant in-flight HeavyRead cap raises
  # Loopctl.HeavyRead.OverloadedError, which LoopctlWeb.Plugs.HeavyReadOverloadHandler
  # (Plug.Exception) maps to 429. Surface a self-identifying `code` so the client can
  # tell this per-tenant heavy-read backpressure apart from the generic request-rate
  # 429 (rendered by FallbackController, which carries no `code`). The read was shed to
  # protect OTHER tenants' access to the shared BYPASSRLS pool — retrying shortly, or
  # narrowing the query, will succeed.
  def render("429.json", _assigns) do
    %{
      error: %{
        status: 429,
        code: "heavy_read_overloaded",
        message:
          "This tenant has too many concurrent heavy reads in flight. Please retry shortly."
      }
    }
  end

  # US-43.3 (review): `Plug.Parsers` raises RequestTooLargeError in the ENDPOINT, before
  # any controller plug runs — so a corpus ingest batch that exceeds the byte cap never
  # reaches the 422 that names the item ceiling and used to fall to the catch-all below
  # as {"status": 413, "message": "Request Entity Too Large"}: no code, no remedy, and no
  # hint that the body rather than the item count was the binding bound. That is exactly
  # the opaque answer the mode B refusals exist to avoid. The cap is read from
  # LoopctlWeb.RequestLimits — the same value the parser enforces and the ingest OpenAPI
  # description publishes.
  def render("413.json", _assigns) do
    %{
      error: %{
        status: 413,
        code: "request_too_large",
        message:
          "The request body exceeds #{LoopctlWeb.RequestLimits.max_body_bytes()} bytes and " <>
            "was refused before it was parsed. Send the same work in smaller requests. " <>
            "On a client_embedded corpus this bound, not the per-request item ceiling, is " <>
            "usually what binds: a JSON-serialized vector costs roughly its dimension " <>
            "times 20 bytes, so a batch of them runs out of bytes long before it runs out " <>
            "of items."
      }
    }
  end

  # Catch-all for any other status code templates
  def render(template, _assigns) do
    status =
      template
      |> String.split(".")
      |> hd()
      |> String.to_integer()

    message = reason_phrase(status)
    %{error: %{status: status, message: message}}
  end

  alias Plug.Conn.Status

  defp reason_phrase(status), do: Status.reason_phrase(status)

  # US-27.3: prefer the precise mapped_code carried on the escaped exception
  # (set by LoopctlWeb.Plugs.DBErrorBackstop) so an escaped serialization failure
  # or deadlock surfaces as db_serialization_failure / db_deadlock rather than the
  # coarse db_unavailable. Falls back to `default` when no mapped exception is
  # present (e.g. a genuine connection drop with no SQLSTATE class).
  defp db_code(%{reason: %LoopctlWeb.SanitizedDBError{mapped_code: code}}, _default)
       when is_binary(code),
       do: code

  defp db_code(_assigns, default), do: default
end
