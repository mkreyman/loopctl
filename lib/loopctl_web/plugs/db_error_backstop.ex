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

  Both hold for a DB fault that arrives as an EXIT (crash PROPAGATION from a
  pooled process) rather than a raise — see `handle_exit/4`.

  It wraps the router so it sees the dispatched `conn` (controller/action/assigns
  populated) carried on the `Plug.Conn.WrapperError`; an EXIT unwinds that frame, so the
  exit path restores what it can (`restore_request_context/1`). Non-DB exceptions, and
  exits this plug cannot place as a DB fault, are re-raised/re-exited untouched
  (let-it-crash) — this plug only translates recognized DB error classes.
  """

  alias Loopctl.ExitClass
  alias LoopctlWeb.{DBError, DBErrorLogger, SanitizedDBError}
  alias Plug.Conn
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
    kind, reason when kind in [:exit, :throw] ->
      handle_exit(conn, kind, reason, __STACKTRACE__)
  end

  # #558: a rescue sees only the RAISE shape, so crash PROPAGATION from a pooled process —
  # `exit({{%Postgrex.Error{}, stack}, {DBConnection, :execute, args}})` — walked past this
  # backstop into the crash log RAW (the struct carries the failing statement, `args` its bound
  # parameters). A DB fault `db_exception/1` can PLACE takes the SAME route as the raise path;
  # anything else is FOREIGN — re-exited untouched and NOT logged here (the crash report records
  # it, and a line per request would point a triaging operator at the DB for someone else).
  @spec handle_exit(Plug.Conn.t(), :exit | :throw, term(), Exception.stacktrace()) :: no_return()
  defp handle_exit(conn, kind, reason, stack) do
    if kind == :exit do
      case db_exception(reason) do
        nil -> :ok
        exception -> sanitize(restore_request_context(conn), exception, stack)
      end
    end

    :erlang.raise(kind, reason, stack)
  end

  # Placed by the NESTED reason FIRST: the leak is a property of the `%Postgrex.Error{}` and the
  # bound args, not of WHICH process called the pool, so `{{%Postgrex.Error{}, _}, {Task, ...}}`
  # is sanitized too; a nested NON-DB exception is a real fault even under a pool call element,
  # re-exited so the crash report still NAMES it rather than re-dressed as a retryable 503; a
  # BARE pool exit nests nothing and IS unavailability, named by its BOUNDED class alone.
  defp db_exception({{%struct{} = exception, _stack}, _call})
       when struct in [Postgrex.Error, DBConnection.ConnectionError],
       do: exception

  defp db_exception({{%_{}, _stack}, _call}), do: nil

  defp db_exception(reason) do
    if ExitClass.pool_exit?(reason),
      do: %DBConnection.ConnectionError{message: "pool #{ExitClass.classify(:exit, reason)}"},
      else: nil
  end

  # The exit unwinds the ROUTER, so this plug holds the PRE-router conn: unrestored, every
  # exit-shaped DB fault logs and counts UNATTRIBUTED (`tenant_id=`, `endpoint: :unknown`) in
  # exactly the wedge those are read in, and `render_errors` gives a JSON client HTML.
  # `tenant_id` survives in Logger metadata (`SeedTenantMetadata`); controller/action do not.
  defp restore_request_context(conn) do
    conn
    |> restore_tenant(Logger.metadata()[:tenant_id])
    |> restore_format(conn.private[:phoenix_format], conn.request_path)
  end

  defp restore_tenant(%{assigns: %{current_api_key: _}} = conn, _tid), do: conn
  defp restore_tenant(conn, nil), do: conn
  defp restore_tenant(conn, tid), do: Conn.assign(conn, :current_api_key, %{tenant_id: tid})

  defp restore_format(conn, nil, "/api/" <> _),
    do: Conn.put_private(conn, :phoenix_format, "json")

  defp restore_format(conn, _format, _path), do: conn

  # Config-based DI (CLAUDE.md convention) so a test can inject a router that raises/exits a DB
  # fault uncaught, exercising this backstop without a test-only production route.
  defp router do
    Application.get_env(:loopctl, :db_error_backstop_router, LoopctlWeb.Router)
  end

  # Only translate recognized DB exceptions; anything non-DB is re-raised as-is. Always
  # re-raises (translated or untouched), so it never returns normally.
  @spec handle(Plug.Conn.t(), term(), Exception.t(), Exception.stacktrace()) :: no_return()
  defp handle(conn, %struct{} = reason, wrapper, stack)
       when struct in [Postgrex.Error, DBConnection.ConnectionError] do
    sanitize(conn, reason, stack)
    reraise(wrapper, stack)
  end

  defp handle(_conn, _reason, wrapper, stack), do: reraise(wrapper, stack)

  # Log the structured SQLSTATE line and re-raise the scrubbed stand-in — shared by the raise and
  # EXIT paths. Returns `:unmapped` (without raising) for an unrecognized error.
  @spec sanitize(Plug.Conn.t(), term(), Exception.stacktrace()) :: :unmapped | no_return()
  defp sanitize(conn, reason, stack) do
    case DBError.map(reason) do
      {:ok, mapping} ->
        DBErrorLogger.log(conn, reason, mapping)

        sanitized = %SanitizedDBError{
          status: mapping.status,
          mapped_code: mapping.mapped_code,
          sqlstate: mapping.sqlstate
        }

        # Re-wrap in a Plug.Conn.WrapperError carrying the dispatched conn so render_errors
        # renders against the right conn and the crash log only sees the sanitized message.
        conn
        |> maybe_retry_after(mapping.retry_after)
        |> WrapperError.reraise(:error, sanitized, stack)

      :unmapped ->
        :unmapped
    end
  end

  # `db_unavailable`/`db_serialization_failure` are DOCUMENTED as carrying `Retry-After` (the
  # `DBError` table, the FallbackController rescue path) and `Plug.Exception` has no header hook.
  defp maybe_retry_after(conn, nil), do: conn

  defp maybe_retry_after(conn, seconds) when is_integer(seconds),
    do: Conn.register_before_send(conn, &Conn.put_resp_header(&1, "retry-after", "#{seconds}"))
end
