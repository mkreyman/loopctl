defmodule LoopctlWeb.Plugs.RegistrationRateLimiter do
  @moduledoc """
  IP-based rate limiting for the tenant registration endpoint.

  Limits to 5 registrations per IP per hour to prevent abuse.
  This is separate from the per-API-key rate limiting in US-2.7.
  """

  @behaviour Plug

  import Plug.Conn

  @max_registrations 5
  @window_ms 60_000 * 60

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    bucket = "registration:#{ip}"

    case rate_limiter().check_rate(bucket, @window_ms, @max_registrations) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{
          error: %{
            status: 429,
            message: "Too many registration attempts. Please try again later."
          }
        })
        |> halt()
    end
  end

  defp rate_limiter do
    Application.get_env(:loopctl, :rate_limiter, Loopctl.RateLimiter.Hammer)
  end
end
