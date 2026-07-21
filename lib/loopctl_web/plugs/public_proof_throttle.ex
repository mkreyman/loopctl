defmodule LoopctlWeb.Plugs.PublicProofThrottle do
  @moduledoc """
  Fail-CLOSED, per-IP throttle for the UNAUTHENTICATED merkle inclusion-proof
  endpoint (US-41.7, AC-41.7.4).

  ## Why this route needs its own gate

  Every other public route (`/audit/sth/:tenant_id`, the tenant audit key, system
  articles) is a single indexed lookup. `GET /audit/sth/:tenant_id/inclusion/:position`
  is a different class of work: `Loopctl.AuditChain.inclusion_proof/2` reads EVERY
  `entry_hash` from position 0 up to the STH and folds the whole merkle tree to
  extract one O(log n) path — O(chain length) DB rows, O(n) memory and O(n)
  SHA-256 per request, on a read routed through the primary-pinned
  `:sth_incremental` HeavyRead endpoint. Before this story that work ran only
  inside the periodic STH Oban job; exposing it anonymously, for any tenant id an
  anonymous caller can already obtain from the public STH endpoint, is a new
  amplification vector.

  The `:api` pipeline that serves the public scope carries no limiter at all —
  `AuthPathThrottle` and `RateLimiter` live exclusively in the `:authenticated`
  pipeline — so the gate has to be attached to the route.

  ## Budget

  Deliberately much tighter than the coarse 3000/60s authenticated ceiling: a
  proof is verifiable EVIDENCE, fetched once and re-checked offline, not a polled
  API. `@default_max_requests_per_ip` per `@default_window_ms` is ample for a
  human or agent verifying a batch of rows and nowhere near enough to turn the
  endpoint into a CPU amplifier. Operators can retune:

      config :loopctl, LoopctlWeb.Plugs.PublicProofThrottle,
        max_requests_per_ip: 60,
        window_ms: 60_000

  ## Fail-CLOSED

  Resolved through `Loopctl.RateLimiter.gate_ok?/3` — a deny, a limiter fault, or
  the Postgres impl's fail-open sentinel all DENY here. A limiter outage must not
  silently unlock an anonymous O(n) endpoint. The blast radius of that choice is
  one public, retryable evidence endpoint (the STH itself stays available), which
  is the right side of the tradeoff.

  An unresolvable client IP (proxy / non-tuple `remote_ip`) degrades to a no-op
  with the same telemetry-free rationale as `AuthPathThrottle`: keying a shared
  bucket on a proxy IP would collapse every visitor onto one bucket.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.RemoteIp

  @default_window_ms 60_000
  @default_max_requests_per_ip 60

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RemoteIp.bucket_key_tagged(conn.remote_ip) do
      {:client, ip} -> throttle(conn, "public_proof_ip:#{ip}")
      {:unresolved, _reason} -> conn
    end
  end

  defp throttle(conn, bucket) do
    {window_ms, max_requests} = limits()

    if Loopctl.RateLimiter.gate_ok?(bucket, window_ms, max_requests) do
      conn
    else
      deny(conn, window_ms)
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

  defp deny(conn, window_ms) do
    conn
    |> put_resp_header("retry-after", to_string(div(window_ms, 1000)))
    |> put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{
      error: %{
        status: 429,
        message:
          "Too many inclusion-proof requests from this IP. A proof is stable evidence — " <>
            "fetch it once and verify it offline."
      }
    })
    |> halt()
  end
end
