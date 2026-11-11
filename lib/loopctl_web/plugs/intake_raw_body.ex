defmodule LoopctlWeb.Plugs.IntakeRawBody do
  @moduledoc """
  Captures the RAW request body of a GitHub intake delivery (issue #803) or a chg change
  event (US-47.3) before `Plug.Parsers` runs.

  GitHub's `X-Hub-Signature-256` is an HMAC over the exact bytes of the body, and
  `Plug.Conn.read_body/2` is destructive: once `Plug.Parsers` has read and decoded the
  JSON, the bytes are gone and a re-encoding of the params does not reproduce them. So
  this plug is mounted in `LoopctlWeb.Endpoint` AHEAD of `Plug.Parsers` and, for
  `POST /api/v1/intake/github/:source_id` and `POST /api/v1/change_events/:source_id` only:

  - refuses a body over the route's cap — `Loopctl.Intake.max_body_bytes/0` or
    `Loopctl.Changes.Events.max_body_bytes/0` — with `413 payload_too_large`, by its declared
    `content-length` before reading and by counting while reading;
  - stores the bytes in `conn.private[:intake_raw_body]`, where
    `LoopctlWeb.GithubIntakeController` and `LoopctlWeb.ChangeEventController` read them.

  Because the body is consumed here, `Plug.Parsers` then reads an empty body and decodes
  nothing, so the untrusted JSON is never parsed before its signature is checked. Every
  other request passes through untouched.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Changes.Events
  alias Loopctl.Intake

  @private_key :intake_raw_body
  @read_length 65_536

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["api", "v1", "intake", "github", _]} = conn, _),
    do: capture(conn, {Intake.max_body_bytes(), "An intake delivery"})

  # US-47.3: chg-server's change events are signed over `"<timestamp>.<raw body>"`, so they
  # need the same bytes, under their own cap.
  def call(%Plug.Conn{method: "POST", path_info: ["api", "v1", "change_events", _]} = conn, _),
    do: capture(conn, {Events.max_body_bytes(), "A change event"})

  def call(conn, _opts), do: conn

  # `limit` is `{max_bytes, what}`: the route's cap and how its 413 names the body.
  defp capture(conn, {max, _what} = limit) do
    if declared_length(conn) > max do
      too_large(conn, limit)
    else
      read(conn, limit, [], 0)
    end
  end

  @doc "The `conn.private` key the raw body is stored under."
  @spec private_key() :: atom()
  def private_key, do: @private_key

  defp declared_length(conn) do
    with [value | _] <- get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> 0
    end
  end

  defp read(conn, {max, _what} = limit, acc, size) do
    case read_body(conn, length: max + 1 - size, read_length: @read_length) do
      {:ok, chunk, conn} ->
        finish(conn, limit, [acc, chunk], size + byte_size(chunk))

      {:more, chunk, conn} ->
        size = size + byte_size(chunk)

        if size > max,
          do: too_large(conn, limit),
          else: read(conn, limit, [acc, chunk], size)

      {:error, _reason} ->
        conn |> send_error(400, "unreadable_body", "The request body could not be read.")
    end
  end

  defp finish(conn, {max, _what} = limit, _acc, size) when size > max,
    do: too_large(conn, limit)

  defp finish(conn, _limit, acc, _size),
    do: put_private(conn, @private_key, IO.iodata_to_binary(acc))

  defp too_large(conn, {max, what}) do
    send_error(conn, 413, "payload_too_large", "#{what} body may be at most #{max} bytes.")
  end

  defp send_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{status: status, code: code, message: message}}))
    |> halt()
  end
end
