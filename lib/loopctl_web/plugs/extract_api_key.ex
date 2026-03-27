defmodule LoopctlWeb.Plugs.ExtractApiKey do
  @moduledoc """
  Extracts the raw API key from the `Authorization: Bearer <token>` header.

  Assigns `:raw_api_key` to `conn.assigns`. If no Authorization header
  is present, assigns `nil` (downstream plugs handle the missing key).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    raw_key =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> String.trim(token)
        _ -> nil
      end

    assign(conn, :raw_api_key, raw_key)
  end
end
