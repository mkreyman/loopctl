defmodule LoopctlWeb.DBError do
  @moduledoc """
  Maps low-level database exceptions to safe, pinned HTTP responses.

  Today an uncaught DB exception (e.g. a `57014` statement-timeout on the
  `suggested_links` vector scan) collapses into a blanket `500` via Phoenix's
  error view, erasing the SQLSTATE — the single most useful diagnostic. This
  module maps known DB error classes to pinned status codes + a safe JSON body
  + structured fields for an error log carrying the real SQLSTATE.

  ## Mapping (US-27.3)

  | SQLSTATE / class          | atom                    | status | code                    | extra        |
  |---------------------------|-------------------------|--------|-------------------------|--------------|
  | 57014 statement timeout   | `:query_canceled`       | 504    | `db_statement_timeout`  | —            |
  | 40001 serialization       | `:serialization_failure`| 503    | `db_serialization_failure` | Retry-After |
  | 40P01 deadlock            | `:deadlock_detected`    | 503    | `db_deadlock`           | Retry-After  |
  | 22021 invalid byte seq    | `:character_not_in_repertoire` | 400 | `db_invalid_input` | —          |
  | any other `Postgrex.Error`| *                       | 500    | `db_error`              | log sqlstate |
  | `DBConnection.ConnectionError` | —                  | 503    | `db_unavailable`        | Retry-After  |

  The `22021` (character_not_in_repertoire — invalid UTF-8 in input) → 400
  mapping mirrors the `Plug.Exception` impl in `LoopctlWeb.Plugs.DBErrorHandler`,
  which preserves phoenix_ecto's prior special case. Keeping it here too means the
  FallbackController rescue path and the uncaught Plug.Exception path AGREE on 400
  for the same SQLSTATE (a rescued invalid-UTF-8 byte is a client input error, not
  a server 500).

  Only `db_statement_timeout` (504) is pinned by the acceptance criteria; the
  other codes are descriptive and asserted in tests.

  ## Safety

  - The client body NEVER contains raw SQL, bound parameters, vector literals,
    article bodies, or an Elixir stack trace — only `%{error: %{status, code,
    message}}` with a safe, generic message.
  - `Postgrex.Error.message/1` interpolates `e.query` (raw SQL) and metadata —
    so we NEVER call `Exception.message/1` on the error for either the client
    body or the log. We surface only the bare PG message (`e.postgres.message`),
    which does not include bound values, and the SQLSTATE.
  - Log fields are sanitized: vectors are elided to dimensionality, params are
    never logged.

  Anything that is not a recognized DB error is left for the caller to re-raise
  (let-it-crash). This module never swallows non-DB errors.
  """

  @retry_after_seconds 1

  @typedoc "Structured mapping for a recognized DB error."
  @type mapping :: %{
          status: 500..504,
          code: String.t(),
          message: String.t(),
          sqlstate: String.t() | nil,
          mapped_code: String.t(),
          retry_after: pos_integer() | nil
        }

  @doc """
  Returns `true` for exceptions this module knows how to map.
  """
  @spec db_error?(term()) :: boolean()
  def db_error?(%Postgrex.Error{}), do: true
  def db_error?(%DBConnection.ConnectionError{}), do: true
  def db_error?(_), do: false

  @doc """
  Maps a recognized DB exception to a safe HTTP `t:mapping/0`.

  Returns `:unmapped` for anything that is not a `Postgrex.Error` or
  `DBConnection.ConnectionError` so callers can re-raise / let it crash.
  """
  @spec map(term()) :: {:ok, mapping()} | :unmapped
  def map(%Postgrex.Error{postgres: %{code: :query_canceled}} = e) do
    {:ok,
     %{
       status: 504,
       code: "db_statement_timeout",
       mapped_code: "db_statement_timeout",
       message: "The request timed out while querying the database. Please retry.",
       sqlstate: sqlstate(e),
       retry_after: nil
     }}
  end

  def map(%Postgrex.Error{postgres: %{code: :serialization_failure}} = e) do
    {:ok,
     %{
       status: 503,
       code: "db_serialization_failure",
       mapped_code: "db_serialization_failure",
       message: "The database could not serialize concurrent access. Please retry.",
       sqlstate: sqlstate(e),
       retry_after: @retry_after_seconds
     }}
  end

  def map(%Postgrex.Error{postgres: %{code: :deadlock_detected}} = e) do
    {:ok,
     %{
       status: 503,
       code: "db_deadlock",
       mapped_code: "db_deadlock",
       message: "The database detected a deadlock. Please retry.",
       sqlstate: sqlstate(e),
       retry_after: @retry_after_seconds
     }}
  end

  def map(%Postgrex.Error{postgres: %{code: :character_not_in_repertoire}} = e) do
    {:ok,
     %{
       status: 400,
       code: "db_invalid_input",
       mapped_code: "db_invalid_input",
       message: "The request contained invalid input that the database rejected.",
       sqlstate: sqlstate(e),
       retry_after: nil
     }}
  end

  def map(%Postgrex.Error{} = e) do
    {:ok,
     %{
       status: 500,
       code: "db_error",
       mapped_code: "db_error",
       message: "A database error occurred.",
       sqlstate: sqlstate(e),
       retry_after: nil
     }}
  end

  def map(%DBConnection.ConnectionError{}) do
    {:ok,
     %{
       status: 503,
       code: "db_unavailable",
       mapped_code: "db_unavailable",
       message: "The database is temporarily unavailable. Please retry.",
       sqlstate: nil,
       retry_after: @retry_after_seconds
     }}
  end

  def map(_), do: :unmapped

  @doc """
  The numeric SQLSTATE string (e.g. `"57014"`) for a `Postgrex.Error`, or `nil`.

  Uses `e.postgres.pg_code` (the raw 5-char SQLSTATE Postgrex preserves), never
  the human message which can echo the query.
  """
  @spec sqlstate(term()) :: String.t() | nil
  def sqlstate(%Postgrex.Error{postgres: %{pg_code: pg_code}}) when is_binary(pg_code),
    do: pg_code

  def sqlstate(_), do: nil
end
