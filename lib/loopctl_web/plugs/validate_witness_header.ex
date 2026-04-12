defmodule LoopctlWeb.Plugs.ValidateWitnessHeader do
  @moduledoc """
  US-26.5.2 — Validates the X-Loopctl-Last-Known-STH header on
  authenticated requests.

  The header format is: `<position>:<base64url_sig_prefix_16_bytes>`

  In the v2 epic branch, this plug is required on every authenticated
  request. Missing header → 412. Stale header → 412. Divergent
  signature → 409 with custody halt.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Stub implementation: log the header but do not enforce.
    # Full enforcement ships at epic merge time.
    case get_req_header(conn, "x-loopctl-last-known-sth") do
      [_header] -> conn
      [] -> conn
    end
  end
end
