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

  def render("500.json", _assigns) do
    %{error: %{status: 500, message: "Internal server error"}}
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
