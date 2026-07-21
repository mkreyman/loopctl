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
  still runs later for authenticated traffic. This is a CONSCIOUS accept, not an
  oversight: exempting superadmin would require resolving the key/role FIRST,
  which defeats the whole point of a gate that must count the missing/invalid-key
  flood the auth plugs would otherwise 401. Consequence: superadmin traffic —
  previously exempt at the per-key limiter — is now also subject to this coarse
  per-IP ceiling. At the default 3000/60s that is generous headroom for the rare
  superadmin operator, and a legitimate single-IP superadmin bulk job that needs
  more has the zero-redeploy remedy of raising `AUTH_THROTTLE_MAX_REQUESTS_PER_IP`
  (see "Operator configuration").

  ## Availability tradeoff on a limiter-store OUTAGE (conscious accept)

  Because this gate is fail-CLOSED AND runs first in the shared `:authenticated`
  pipeline (both `/api/v1` and `/api/v1/admin`), a sustained limiter-store fault
  429s EVERY authenticated request — valid-key and superadmin included — a full
  authenticated-API denial. That is the deliberate INVERSE of the per-key limiter
  (fail-OPEN) and is pinned by a valid-key test. Blast radius is bounded in
  practice: the default node-local ETS limiter is in-process and effectively never
  faults, so this only bites a `RATE_LIMITER=postgres` deployment when Postgres is
  already down (the whole app is unavailable anyway). The fault is already
  OBSERVABLE — `Loopctl.RateLimiter.gate_ok?/3` logs every limiter fault through
  the throttled, PII-safe `Loopctl.RateLimiter.FailOpenLog` — so an operator gets
  a bounded heartbeat to alert on. Note the `AUTH_THROTTLE_*` knobs tune the
  ceiling, NOT this outage behaviour; a fail-OPEN "circuit breaker" here would
  silently unlock the volumetric protection during a fault and is intentionally
  NOT provided.

  ## Limiter-pool sizing dependency

  Every request (including ones about to be 429'd) calls the limiter, so a
  single-IP flood drives `check_rate/3` at full rate even while denied. That load
  passes through Hammer's poolboy worker pool (shared by ALL rate-limiter call
  sites). On Hammer's default 4-worker pool a checkout can time out and exit under
  saturation, which this fail-CLOSED gate normalises to a denial — spilling 429s
  onto legitimate traffic from OTHER IPs. `config/config.exs` therefore sizes the
  pool generously (`pool_size: 20, pool_max_overflow: 10`, overridable via
  `HAMMER_POOL_SIZE` / `HAMMER_POOL_MAX_OVERFLOW`); operators running the
  `RATE_LIMITER=postgres` backend (where each check is a DB round-trip, not a
  microsecond ETS op) should size the pool and AdminRepo to their peak per-IP
  request rate so the gate cannot become a cross-tenant availability dependency.

  ## Unresolvable client IP (degrade-to-no-op is OBSERVABLE)

  When `conn.remote_ip` is a configured proxy or a non-tuple, no stable per-client
  bucket exists, so the gate cannot throttle. Rather than key a shared bucket on a
  proxy IP (which would collapse every proxy-fronted visitor onto ONE bucket — a
  cross-tenant DoS) the gate SKIPS the limiter entirely on that path. Skipping
  also avoids the memory-growth vector of inserting a unique, never-reused 60-min
  Hammer ETS bucket per request (`"req:<n>"`). Because the gate now runs on EVERY
  authenticated request (not just signup), this no-op is worth observing, so the
  path emits a `[:loopctl, :auth_path_throttle, :unresolved_ip]` telemetry event
  (measurement `count: 1`, metadata `%{reason: :proxy | :non_tuple}`, no PII) —
  the signal an operator would otherwise lack that the throttle was defeated by IP
  resolution (e.g. off-Fly without `X-Forwarded-For`, a misconfigured `:proxies`
  CIDR, or 6PN service-to-service traffic hitting `/api/v1`).

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

  @telemetry_unresolved_ip [:loopctl, :auth_path_throttle, :unresolved_ip]

  @impl true
  def call(conn, _opts) do
    case RemoteIp.bucket_key_tagged(conn.remote_ip) do
      {:client, ip} ->
        throttle(conn, "auth_ip:#{ip}")

      {:unresolved, reason} ->
        # No stable per-client bucket exists (proxy / non-tuple remote_ip). The
        # gate cannot throttle here, so SKIP the limiter entirely — a unique
        # "req:<n>" key never throttles yet accretes a 60-min ETS bucket per
        # request. Emit a PII-free telemetry signal so the degrade-to-no-op is
        # observable (see moduledoc), then pass through.
        :telemetry.execute(@telemetry_unresolved_ip, %{count: 1}, %{reason: reason})
        conn
    end
  end

  defp throttle(conn, bucket) do
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
