defmodule LoopctlWeb.Plugs.GithubIntakeThrottle do
  @moduledoc """
  Fail-CLOSED, per-IP throttle for the UNAUTHENTICATED GitHub intake webhook (issue #803).

  `POST /api/v1/intake/github/:source_id` authenticates by HMAC, not by API key, so it sits
  on the `:api` pipeline, which carries no limiter. Every request to it costs a source
  lookup and an HMAC over up to `Loopctl.Intake.max_body_bytes/0` bytes before it can be
  refused, so the gate runs first in the route's own pipeline.

  The ceiling is per IP and GitHub's webhook deliveries leave from a small set of shared
  egress addresses, so ONE bucket carries every tenant's legitimate deliveries from that
  address. `@default_max_requests_per_ip` is set well above the delivery rate of any
  configured repository for that reason, and is still far below a flood. Operators can
  retune without a code change to this module:

      config :loopctl, LoopctlWeb.Plugs.GithubIntakeThrottle,
        max_requests_per_ip: 1_200,
        window_ms: 60_000

  Resolved through `Loopctl.RateLimiter.gate_ok?/3`: a deny, a limiter fault, or the
  Postgres impl's fail-open sentinel all DENY. GitHub retries nothing on a 429 by itself,
  but a failed delivery can be redelivered from the repository's webhook settings, and a
  redelivery keeps its delivery id, so nothing is lost to a transient deny.

  An unresolvable client IP (proxy / non-tuple `remote_ip`) degrades to a no-op, with the
  same rationale as `LoopctlWeb.Plugs.AuthPathThrottle`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.RemoteIp

  @default_window_ms 60_000
  @default_max_requests_per_ip 1_200

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RemoteIp.bucket_key_tagged(conn.remote_ip) do
      {:client, ip} -> throttle(conn, "github_intake_ip:#{ip}")
      {:unresolved, _reason} -> conn
    end
  end

  defp throttle(conn, bucket) do
    {window_ms, max_requests} = limits()

    if Loopctl.RateLimiter.gate_ok?(bucket, window_ms, max_requests) do
      conn
    else
      conn
      |> put_resp_header("retry-after", to_string(div(window_ms, 1000)))
      |> put_status(:too_many_requests)
      |> Phoenix.Controller.json(%{
        error: %{status: 429, message: "Too many intake deliveries from this IP."}
      })
      |> halt()
    end
  end

  defp limits do
    config = Application.get_env(:loopctl, __MODULE__, [])

    {
      positive_int(config[:window_ms], @default_window_ms),
      positive_int(config[:max_requests_per_ip], @default_max_requests_per_ip)
    }
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
