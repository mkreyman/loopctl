defmodule LoopctlWeb.SanitizedDBError do
  @moduledoc """
  A scrubbed stand-in for a DB exception that escaped a controller uncaught
  (US-27.3).

  `LoopctlWeb.Plugs.DBErrorBackstop` re-raises this in place of the original
  `Postgrex.Error` / `DBConnection.ConnectionError` so the downstream web-server
  crash log (Bandit calls `Exception.format/3`, which invokes
  `Postgrex.Error.message/1` and interpolates `e.query` — the raw SQL + vector
  literal) can NEVER echo the query (AC-27.3.8). Its `message/1` carries only the
  SQLSTATE and mapped code; its `Plug.Exception.status/1` preserves the pinned
  504/503/500 mapping so `LoopctlWeb.ErrorJSON` still renders the right body.
  """
  defexception [:status, :mapped_code, :sqlstate]

  @impl true
  def message(%__MODULE__{status: status, mapped_code: mapped_code, sqlstate: sqlstate}) do
    "database error (sanitized): mapped to HTTP #{status} " <>
      "mapped_code=#{mapped_code} sqlstate=#{sqlstate || "unknown"} " <>
      "(query/params/vector elided — see structured db_error log)"
  end
end

defimpl Plug.Exception, for: LoopctlWeb.SanitizedDBError do
  def status(%{status: status}), do: status
  def actions(_error), do: []
end

defmodule LoopctlWeb.Plugs.DBErrorBackstop do
  @moduledoc """
  Endpoint-level backstop that gives EVERY controller the same structured,
  sanitized DB-error surfacing the `suggested_links` rescue path already has
  (US-27.3, AC-27.3.3 + AC-27.3.8).

  ## Why a wrapping plug and not just `Plug.Exception`

  `Plug.Exception.status/1` (see `LoopctlWeb.Plugs.DBErrorHandler`) maps the HTTP
  status for a raised DB exception, but `status/1` is pure — it has no logging
  hook, so an uncaught DB exception in any controller OTHER than `suggested_links`
  would map its status correctly yet emit NO structured SQLSTATE line, and the web
  server's own crash log (`Exception.format/3` → `Postgrex.Error.message/1`) would
  leak the raw SQL/vector. This plug closes both gaps for the uncaught path:

    * it logs the same sanitized structured fields via `LoopctlWeb.DBErrorLogger`
      (single source of truth shared with the FallbackController rescue path), and
    * it re-raises a `LoopctlWeb.SanitizedDBError` whose `message/1` cannot echo
      the query, so any subsequent crash log is leak-free while the pinned
      504/503/500 status is preserved.

  It wraps the router so it sees the dispatched `conn` (controller/action/assigns
  populated) carried on the `Plug.Conn.WrapperError`. Non-DB exceptions are
  re-raised untouched (let-it-crash) — this plug only translates recognized DB
  error classes.
  """

  require Logger

  alias Loopctl.ExitClass
  alias LoopctlWeb.{DBError, DBErrorLogger, SanitizedDBError}
  alias Plug.Conn.WrapperError

  @behaviour Plug

  @impl true
  def init(opts), do: router().init(opts)

  @impl true
  def call(conn, opts) do
    router().call(conn, opts)
  rescue
    wrapper in WrapperError ->
      handle(wrapper.conn || conn, wrapper.reason, wrapper, __STACKTRACE__)
  catch
    # #558: a rescue sees only the RAISE shape. Crash PROPAGATION from a pooled process —
    # `exit({{%Postgrex.Error{}, stacktrace}, {DBConnection, :execute, args}})` — is an EXIT,
    # so it walked past this backstop entirely and reached the crash log RAW: the Postgrex
    # struct carries the failing statement, and `args` carries its bound parameters, which on
    # this app's read paths means query text and vector literals.
    #
    # This does NOT translate the response. The backstop's contract is that a DB exception
    # gets a pinned status, and an exit is not something we can turn into one here without
    # guessing at the request's state. It logs the BOUNDED class so the fault is attributable,
    # then re-exits unchanged so supervision and the crash report behave exactly as before.
    # The only thing that changes is that the raw reason stops being the first record of it.
    kind, reason when kind in [:exit, :throw] ->
      Logger.error(
        "DBErrorBackstop: request #{kind} (#{ExitClass.classify(kind, reason)}) " <>
          "on #{conn.method} #{conn.request_path}"
      )

      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Config-based DI (CLAUDE.md convention) so a test can inject a router that
  # raises a DB exception uncaught, exercising the backstop's catch/log/sanitize
  # path without mounting a test-only route on the production router.
  defp router do
    Application.get_env(:loopctl, :db_error_backstop_router, LoopctlWeb.Router)
  end

  # Only translate recognized DB exceptions. The reason may itself be a nested
  # WrapperError (defensive) — unwrap once. Anything non-DB is re-raised as-is.
  # Always re-raises (translated or untouched), so it never returns normally.
  @spec handle(Plug.Conn.t(), term(), Exception.t(), Exception.stacktrace()) :: no_return()
  defp handle(conn, %struct{} = reason, wrapper, stack)
       when struct in [Postgrex.Error, DBConnection.ConnectionError] do
    case DBError.map(reason) do
      {:ok, mapping} ->
        DBErrorLogger.log(conn, reason, mapping)

        sanitized = %SanitizedDBError{
          status: mapping.status,
          mapped_code: mapping.mapped_code,
          sqlstate: mapping.sqlstate
        }

        # Re-wrap in a Plug.Conn.WrapperError carrying the dispatched conn so
        # Phoenix's render_errors path renders against the right conn and the
        # crash log only ever sees the sanitized message (never the raw query).
        WrapperError.reraise(conn, :error, sanitized, stack)

      :unmapped ->
        reraise(wrapper, stack)
    end
  end

  defp handle(_conn, _reason, wrapper, stack), do: reraise(wrapper, stack)
end
