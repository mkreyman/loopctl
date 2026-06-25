defmodule LoopctlWeb.StreamingExport do
  @moduledoc """
  Shared controller helper that streams a `.tar.gz` knowledge export over a
  chunked HTTP response (US-27.16), used by both `KnowledgeExportController`
  (Obsidian) and `OKFController` (OKF).

  Flow:

    1. `acquire/1` a streaming-export slot (per-tenant + global cap, AC-27.16.6).
       Over the cap → `429 too_many_exports` with `Retry-After`, BEFORE any body
       and off the admin pool.
    2. Set `application/gzip` + a `*.tar.gz` content-disposition and `send_chunked`
       a `200` (this COMMITS the status — there is no going back to an error code).
    3. Drive `Loopctl.Knowledge.StreamingExport.stream/4`, flushing each compressed
       chunk via `Plug.Conn.chunk/2`.
    4. On success the writer emits the tar end-of-archive + gzip trailer. On a
       mid-stream error the writer is aborted WITHOUT a valid end-of-archive
       (fail-closed, AC-27.16.4) and the chunked response is simply ended — the
       consumer detects truncation. The error is logged via the sanitized
       `LoopctlWeb.DBError`/`DBErrorLogger` path so NO SQL/params/vector
       literals/stack traces leak (US-27.3); none is ever written to the body.
    5. `release/1` the slot in an `after` so a crash still frees it (and the
       GenServer monitor reclaims it as a backstop).
  """

  import Plug.Conn

  require Logger

  alias Loopctl.Knowledge.ExportConcurrency
  alias Loopctl.Knowledge.StreamingExport
  alias LoopctlWeb.DBError

  @retry_after_seconds 30

  @doc """
  Streams `tenant_id`'s published articles in `format` (an
  `Loopctl.Knowledge.StreamingExport.Format` module) as a chunked `.tar.gz`.

  `filename_prefix` builds the download name (`<prefix>-<date>.tar.gz`). `opts` is
  forwarded to `StreamingExport.stream/4` (e.g. `:project_id`).

  Returns the (sent) `conn`.
  """
  @spec stream(Plug.Conn.t(), Ecto.UUID.t(), module(), String.t(), keyword()) :: Plug.Conn.t()
  def stream(conn, tenant_id, format, filename_prefix, opts \\ []) do
    case ExportConcurrency.acquire(tenant_id) do
      :ok ->
        try do
          do_stream(conn, tenant_id, format, filename_prefix, opts)
        after
          ExportConcurrency.release(tenant_id)
        end

      {:error, :too_many_exports} ->
        too_many(conn)
    end
  end

  defp do_stream(conn, tenant_id, format, filename_prefix, opts) do
    date = Date.utc_today() |> Date.to_iso8601()

    conn =
      conn
      # Set the content-type WITHOUT a charset (this is a gzipped binary, not text).
      |> put_resp_content_type("application/gzip", nil)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename_prefix}-#{date}.tar.gz")
      )
      # send_chunked COMMITS the 200 before any body — a later error can no longer
      # change the status code, hence the fail-closed (no end-of-archive) contract.
      |> send_chunked(200)

    # `Plug.Conn.chunk/2` returns an UPDATED conn (the adapter accumulates the sent
    # bytes in it), so each chunk must be sent on the conn returned by the previous
    # one. The streaming core's emit fun is arity-1 (iodata only), so we thread the
    # current conn through the process dictionary (the request runs in one process)
    # rather than rebuild the whole stream API around conn threading.
    pd_key = {__MODULE__, :conn, make_ref()}
    Process.put(pd_key, conn)

    emit = fn iodata ->
      current = Process.get(pd_key)

      # Producer-memory telemetry is emitted by the TarGz writer (the true producer),
      # so it fires on EVERY export path (HTTP + the in-memory test helper), not just
      # here. This emit fun only flushes the compressed chunk to the wire.
      case chunk(current, iodata) do
        {:ok, next} ->
          Process.put(pd_key, next)
          {:ok, next}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end

    result = StreamingExport.stream(tenant_id, format, emit, opts)
    final_conn = Process.get(pd_key, conn)
    Process.delete(pd_key)

    case result do
      {:ok, _conn} ->
        final_conn

      {:error, reason} ->
        # Fail-closed: the writer already aborted (no valid end-of-archive). We do
        # NOT write any error text into the chunk stream — the partial bytes carry
        # only article content, never SQL/params/vectors/stack traces. Log it
        # sanitized for ops, then just end the (already-truncated) response.
        log_stream_failure(reason)
        final_conn
    end
  end

  defp too_many(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{
      error: %{
        status: 429,
        code: "too_many_exports",
        message:
          "Too many concurrent knowledge exports in flight. Retry shortly — exports " <>
            "are bounded to protect the database connection pool."
      }
    })
  end

  # Sanitized failure logging (US-27.3): never log the raw query/params/vectors. For
  # a recognized DB error, log ONLY the pinned mapped_code + SQLSTATE (the value-free
  # diagnostics `DBError` exposes) — never `Exception.message/1` (which interpolates
  # the raw SQL). For anything else, log only the exception struct name.
  defp log_stream_failure({:transport, reason}) do
    Logger.warning("streaming export aborted: client transport closed (#{inspect(reason)})")
  end

  defp log_stream_failure(reason) do
    if DBError.db_error?(reason) do
      {:ok, mapping} = DBError.map(reason)

      Logger.error(
        "streaming export aborted (fail-closed): mapped_code=#{mapping.mapped_code} " <>
          "sqlstate=#{mapping.sqlstate || "unknown"} — archive truncated, " <>
          "no end-of-archive emitted"
      )
    else
      detail = if is_exception(reason), do: inspect(reason.__struct__), else: inspect(reason)

      Logger.error(
        "streaming export aborted (fail-closed): #{detail} — archive truncated, " <>
          "no end-of-archive emitted"
      )
    end
  end
end
