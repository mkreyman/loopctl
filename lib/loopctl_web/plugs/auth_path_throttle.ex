defmodule LoopctlWeb.Plugs.AuthPathThrottle do
  @moduledoc """
  Fail-CLOSED, per-IP volumetric throttle on the API-key authentication path.

  ## Why this exists

  In the `:authenticated` pipeline the key-resolution plugs (`ResolveApiKey`,
  `RequireAuth`) reject a missing/invalid key with 401 BEFORE the per-key
  `LoopctlWeb.Plugs.RateLimiter` ever runs. Without this gate a flood of
  bad-key (or no-key) requests from one IP drives unbounded key-hash cache
  lookups + `api_keys` DB queries while consuming ZERO rate-limit budget — a
  volumetric amplification vector.

  This plug is placed FIRST in the pipeline (before `ExtractApiKey`) so it
  counts EVERY request — including the ones the auth plugs would 401 — against a
  coarse per-IP ceiling. It runs after the endpoint's `LoopctlWeb.Plugs.ClientIp`
  plug, so `conn.remote_ip` is already the trusted client (prefers the
  unspoofable `fly-client-ip`; never trusts `X-Forwarded-For`).

  ## Fail-CLOSED (distinct from the per-key limiter)

  The gate resolves the limiter through `Loopctl.RateLimiter.gate_ok?/3`, the
  fail-CLOSED anti-abuse helper: a genuine allow returns `true`; a deny, a
  limiter fault (`{:error, _}`, bad shape, raise/exit/throw), or the Postgres
  impl's `{:allow, 0}` fail-open sentinel all return `false` (denied). A
  limiter-store outage therefore DENIES here rather than silently unlocking the
  volumetric protection. This is deliberately the OPPOSITE of the per-key
  `LoopctlWeb.Plugs.RateLimiter`, which fails OPEN so a limiter outage never
  blocks all authenticated traffic. Both coexist: this coarse per-IP gate is
  purely additive and never replaces the per-key/per-tenant capacity limiter.

  Because it runs before the key (and therefore the role) is known, there is no
  superadmin exemption here — that exemption stays on the per-key limiter, which
  still runs later for authenticated traffic.

  ## Budget / window

  Coarse per-IP ceiling of 3000 requests per 60s window, counting ALL requests
  (including 401s). See `@max_requests_per_ip` below for the rationale.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.RemoteIp

  # Coarse per-IP volumetric ceiling over a 60s window. The per-KEY limiter
  # defaults to 300 req/min and the per-TENANT aggregate to 900 req/min
  # (`@default_per_key_limit` * 3 in `LoopctlWeb.Plugs.RateLimiter`), so this
  # ceiling sits generously ABOVE any legitimate single-IP authenticated volume
  # — normal valid traffic (already bounded by those limiters) never trips it,
  # but an unbounded bad-key/no-key flood does. It intentionally counts ALL
  # requests, including the 401s the auth plugs emit; "valid traffic unaffected"
  # holds because the ceiling is coarse, not because 401s are excluded.
  @window_ms 60_000
  @max_requests_per_ip 3_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    bucket = "auth_ip:#{RemoteIp.bucket_key(conn.remote_ip)}"

    if Loopctl.RateLimiter.gate_ok?(bucket, @window_ms, @max_requests_per_ip) do
      conn
    else
      deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_header("retry-after", to_string(div(@window_ms, 1000)))
    |> put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{
      error: %{
        status: 429,
        message: "Too many requests from this IP. Please slow down and retry shortly."
      }
    })
    |> halt()
  end
end
