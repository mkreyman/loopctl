defmodule LoopctlWeb.DBErrorLogger do
  @moduledoc """
  Shared, sanitized structured logging for mapped DB exceptions (US-27.3).

  Both surfacing paths funnel through here so AC-27.3.3 (structured fields) and
  AC-27.3.8 (no raw SQL / vector / param leakage) hold identically regardless of
  HOW the DB exception reached the response layer:

    1. **Rescue → tuple → FallbackController** — a controller that explicitly
       rescues `Postgrex.Error` / `DBConnection.ConnectionError` and returns it
       as `{:error, exception}`. `FallbackController.render_db_error/2` calls
       `log/3` here before rendering the safe body.

    2. **Uncaught → Plug.Exception backstop** — a DB exception that escapes a
       controller action uncaught. `LoopctlWeb.Plugs.DBErrorBackstop` catches it
       at the endpoint, calls `log/3` here (so EVERY controller — not just
       `suggested_links` — emits the structured SQLSTATE line), and re-raises a
       sanitized exception so the web server's own crash log can never echo the
       raw query.

  The diagnostic fields are emitted BOTH inline in the message string
  (`key=value`) and as Logger metadata: the prod JSON formatter
  (`LoggerJSON.Formatters.Basic`) surfaces the metadata, while the inline form
  keeps the fields visible under any formatter/metadata configuration. We log
  only the bare PG message (`postgres.message`), NEVER `Exception.message/1`
  (which interpolates `e.query` — the raw SQL + vector literal).

  The bare PG message is logged ONLY for the value-free timeout/serialization/
  deadlock classes (`db_statement_timeout` / `db_serialization_failure` /
  `db_deadlock`). For the catch-all `db_error` (and `db_invalid_input`) classes —
  which also match constraint-violation errors whose `postgres.message` embeds a
  user/row value such as `Key (slug)=(foo) already exists` — `pg_message` is
  omitted (AC-27.3.8 disclosure control). `sqlstate` + `mapped_code` are logged
  for every class regardless, so diagnosability is preserved.
  """

  require Logger

  alias LoopctlWeb.DBError

  @doc """
  Logs a mapped DB error at `:error` level with sanitized structured fields.

  `mapping` is the `LoopctlWeb.DBError.map/1` result; `error` is the original
  exception (used only for the bare PG message). `conn` supplies controller,
  action, tenant_id, and request_id correlation fields. Returns `:ok`.
  """
  @spec log(Plug.Conn.t(), term(), DBError.mapping()) :: :ok
  def log(conn, error, mapping) do
    sqlstate = mapping.sqlstate || "unknown"
    controller = phoenix_private(conn, :phoenix_controller)
    action = phoenix_private(conn, :phoenix_action)
    tenant_id = tenant_id(conn)
    request_id = request_id(conn)

    message =
      "db_error mapped to HTTP #{mapping.status} " <>
        "sqlstate=#{sqlstate} mapped_code=#{mapping.mapped_code} " <>
        "controller=#{controller} action=#{action} " <>
        "tenant_id=#{tenant_id} request_id=#{request_id}"

    Logger.error(message,
      sqlstate: sqlstate,
      mapped_code: mapping.mapped_code,
      controller: controller,
      action: action,
      tenant_id: tenant_id,
      request_id: request_id,
      pg_message: safe_pg_message(error, mapping.mapped_code)
    )
  end

  # AC-27.3.8 (disclosure control): the bare PG message is value-free for the
  # three timeout/serialization/deadlock classes this story targets, but the
  # catch-all `db_error` (and the new `db_invalid_input`) class also matches
  # constraint-violation errors whose `postgres.message` embeds a user/row value
  # (e.g. "Key (slug)=(foo) already exists"). Restrict pg_message logging to the
  # value-free allowlist so a catch-all DB error reaching the backstop/rescue can
  # never spill a constraint value into the structured log. sqlstate + mapped_code
  # are still logged for every class, so diagnosability for the catch-all is
  # unchanged.
  @pg_message_allowlist ~w(db_statement_timeout db_serialization_failure db_deadlock)

  defp safe_pg_message(error, mapped_code) when mapped_code in @pg_message_allowlist do
    safe_pg_message(error)
  end

  defp safe_pg_message(_error, _mapped_code), do: nil

  defp phoenix_private(conn, key) do
    case conn.private do
      %{^key => value} -> inspect(value)
      _ -> nil
    end
  end

  defp tenant_id(conn) do
    case conn.assigns do
      %{current_api_key: %{tenant_id: tid}} -> tid
      _ -> nil
    end
  end

  defp request_id(conn) do
    conn |> Plug.Conn.get_resp_header("x-request-id") |> List.first() ||
      Logger.metadata()[:request_id]
  end

  # The bare PostgreSQL message (`postgres.message`) does NOT include bound
  # values or the query text, unlike `Exception.message/1`. For connection
  # errors there is no `.postgres` map; we omit the message entirely rather than
  # risk leaking anything. Defensive truncation as a belt-and-suspenders guard.
  defp safe_pg_message(%Postgrex.Error{postgres: %{message: msg}}) when is_binary(msg) do
    String.slice(msg, 0, 200)
  end

  defp safe_pg_message(_), do: nil
end
