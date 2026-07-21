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

  Coarse per-IP ceiling of 3000 requests per 60s window (both defaults), counting
  ALL requests (including 401s). See `@default_max_requests_per_ip` below for the
  rationale, and the "Operator configuration" section for how to override them.

  ## Operator configuration

  Unlike the sibling per-KEY limiter — whose ceiling is tenant-overridable via
  `Tenants.get_tenant_settings(tenant, "rate_limit_requests_per_minute", 300)` —
  this coarse per-IP ceiling is a single global knob, configurable via
  Application env (defaults preserved when unset):

      config :loopctl, LoopctlWeb.Plugs.AuthPathThrottle,
        max_requests_per_ip: 3_000,
        window_ms: 60_000

  `config/runtime.exs` wires these to the `AUTH_THROTTLE_MAX_REQUESTS_PER_IP` and
  `AUTH_THROTTLE_WINDOW_MS` env vars (safe-parsed: a missing/invalid value leaves
  the default in place, never crashing release boot), so an operator has a
  zero-redeploy remedy.

  ### Interaction with configured per-tenant limits

  This gate keys `auth_ip:<ip>` and counts EVERY request from that IP, so it
  aggregates across all keys/tenants sharing one egress IP (a Fly machine's
  outbound IP, a CI runner, a corporate/cloud NAT). Two consequences an operator
  should understand:

    1. Many legitimate keys/tenants behind ONE egress IP share this single
       bucket, so their COMBINED valid traffic counts toward `max_requests_per_ip`
       even while each key stays under its per-key limit (300/min default) and
       each tenant under its per-tenant aggregate (900/min default). With the
       default 3000/60s ceiling this leaves generous headroom; a shared-egress
       deployment that legitimately exceeds it should raise the knob.
    2. If an operator raises a tenant's per-key limit above ~1000 (per-tenant
       aggregate > 3000), this coarse 3000/IP ceiling silently becomes the
       binding constraint and caps that tenant BELOW its configured allowance.
       Raise `max_requests_per_ip` accordingly (rule of thumb: keep it at or
       above the largest configured per-tenant aggregate that shares an IP).
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.RemoteIp

  # Coarse per-IP volumetric ceiling over a 60s window (DEFAULTS; operator-
  # overridable via Application env — see the moduledoc). The per-KEY limiter
  # defaults to 300 req/min and the per-TENANT aggregate to 900 req/min
  # (`@default_per_key_limit` * 3 in `LoopctlWeb.Plugs.RateLimiter`), so this
  # ceiling sits generously ABOVE any legitimate single-IP authenticated volume
  # — normal valid traffic (already bounded by those limiters) never trips it,
  # but an unbounded bad-key/no-key flood does. It intentionally counts ALL
  # requests, including the 401s the auth plugs emit; "valid traffic unaffected"
  # holds because the ceiling is coarse, not because 401s are excluded.
  @default_window_ms 60_000
  @default_max_requests_per_ip 3_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    bucket = "auth_ip:#{RemoteIp.bucket_key(conn.remote_ip)}"
    {window_ms, max_requests_per_ip} = limits()

    if Loopctl.RateLimiter.gate_ok?(bucket, window_ms, max_requests_per_ip) do
      conn
    else
      deny(conn, window_ms)
    end
  end

  # Resolve the ceiling/window at call time from Application env so an operator
  # override (via config/runtime.exs env vars) takes effect without a code
  # change. Falls back to the coarse defaults when unset. A non-positive or
  # non-integer configured value is ignored in favour of the default so a
  # misconfiguration can never disable the gate (0/negative would make every
  # request trip it, or silently unbound it).
  defp limits do
    config = Application.get_env(:loopctl, __MODULE__, [])

    {
      positive_int(config[:window_ms], @default_window_ms),
      positive_int(config[:max_requests_per_ip], @default_max_requests_per_ip)
    }
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp deny(conn, window_ms) do
    conn
    |> put_resp_header("retry-after", to_string(div(window_ms, 1000)))
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
