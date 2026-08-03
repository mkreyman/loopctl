defmodule Loopctl.Test.BackstopRouter do
  @moduledoc """
  US-27.3 test seam for `LoopctlWeb.Plugs.DBErrorBackstop`.

  A thin REAL plug (not a global Mox mock) wired as `:db_error_backstop_router`
  in `config/test.exs`. By default it delegates `init/1` and `call/2` straight to
  `LoopctlWeb.Router`, so EVERY request flows through the production router
  exactly as in prod — no Mox allowance on the hot path, no blast radius if a
  request is dispatched from a spawned process or before a stub is installed.

  Only when a request carries the opt-in header `x-test-raise-db-error: <kind>`
  does it raise a DB exception UNCAUGHT — wrapped in a `Plug.Conn.WrapperError`
  carrying the dispatched conn, exactly as an un-rescued DB-touching controller
  action would — so the backstop's catch/log/sanitize path is exercised
  end-to-end through the real endpoint + RenderErrors. The header is opt-in
  per-test, so unrelated tests are completely unaffected.

  Supported `kind` values map to the shaped exceptions below:

    * `"57014"` — `Postgrex.Error` `:query_canceled` (statement timeout → 504)
    * `"40001"` — `Postgrex.Error` `:serialization_failure` (→ 503)
    * `"42P01"` — `Postgrex.Error` `:undefined_table` (catch-all → 500)
    * `"conn"`  — `DBConnection.ConnectionError` (→ 503)
    * `"runtime"` — a plain `RuntimeError` (non-DB → let-it-crash, unchanged)
    * `"exit-propagation"` — a pooled-process crash EXIT nesting a `Postgrex.Error`
    * `"exit-foreign"` — an exit with no pool module in its call element

  The 57014 exception deliberately carries `query:` with SQL + a vector literal
  that WOULD leak if anything called `Exception.message/1` on it, so tests can
  prove neither the response, the structured log, nor the sanitized re-raise
  echoes it.
  """

  @behaviour Plug

  @header "x-test-raise-db-error"

  @impl true
  def init(opts), do: LoopctlWeb.Router.init(opts)

  @impl true
  def call(conn, opts) do
    case Plug.Conn.get_req_header(conn, @header) do
      [kind | _] -> raise_uncaught(conn, kind)
      [] -> LoopctlWeb.Router.call(conn, opts)
    end
  end

  # Raise the way a controller action does: wrapped in a Plug.Conn.WrapperError
  # carrying the dispatched conn so controller/action/assigns are populated for
  # the structured log. We stamp a phoenix_controller so the log line has a
  # controller field, mirroring a real dispatched request.
  # #558: crash PROPAGATION from a pooled process is an EXIT, not a raise, so it needs its
  # own shape here — a `rescue`-only backstop never sees it. The reason carries the failing
  # Postgrex struct (statement text) and the call's bound args, which is exactly what must not
  # reach the crash log raw: the backstop translates it to a SanitizedDBError instead.
  defp raise_uncaught(_conn, "exit-propagation") do
    exit(
      {{%Postgrex.Error{
          postgres: %{code: :undefined_table, pg_code: "42P01", severity: "ERROR", message: "x"},
          query: "SELECT id FROM things ORDER BY embedding <=> '[0.123,0.456]'::vector LIMIT 5"
        }, []}, {DBConnection, :execute, [:secret_bound_param]}}
    )
  end

  # A NON-pool exit: the backstop must leave it alone (no translation, no DB attribution).
  defp raise_uncaught(_conn, "exit-foreign") do
    exit({:timeout, {GenServer, :call, [:some_other_server, :ping]}})
  end

  defp raise_uncaught(conn, kind) do
    dispatched = %{conn | private: Map.put(conn.private, :phoenix_controller, SomeCtl)}

    raise Plug.Conn.WrapperError,
      conn: dispatched,
      kind: :error,
      reason: exception_for(kind),
      stack: []
  end

  defp exception_for("57014") do
    %Postgrex.Error{
      postgres: %{
        code: :query_canceled,
        pg_code: "57014",
        severity: "ERROR",
        message: "canceling statement due to statement timeout"
      },
      query: "SELECT id FROM things ORDER BY embedding <=> '[0.123,0.456]'::vector LIMIT 5"
    }
  end

  defp exception_for("40001") do
    %Postgrex.Error{
      postgres: %{
        code: :serialization_failure,
        pg_code: "40001",
        severity: "ERROR",
        message: "could not serialize access due to concurrent update"
      }
    }
  end

  defp exception_for("42P01") do
    %Postgrex.Error{
      postgres: %{
        code: :undefined_table,
        pg_code: "42P01",
        severity: "ERROR",
        message: ~s|relation "nope" does not exist|
      }
    }
  end

  defp exception_for("conn") do
    %DBConnection.ConnectionError{message: "tcp closed"}
  end

  defp exception_for("runtime") do
    %RuntimeError{message: "boom"}
  end
end
