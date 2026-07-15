defmodule LoopctlWeb.Plugs.RateLimiter do
  @moduledoc """
  Per-API-key and per-tenant rate limiting plug.

  Checks both per-key and per-tenant aggregate limits. Superadmin keys
  are exempt. Rate limit headers are added to every response.

  Must be placed AFTER RequireAuth in the pipeline so unauthenticated
  requests don't consume rate limit budget.

  ## Cluster-global capability (US-38.2)

  The per-key/per-tenant RPM check resolves through the `:rate_limiter`
  behaviour (`Loopctl.RateLimiter.Behaviour`) via config-based DI — the SAME
  seam `Loopctl.Provider.Admission` and the signup/enroll gates use — instead of
  calling the node-local ETS `Loopctl.RateLimiter.Server` directly. With the
  DEFAULT config (`Loopctl.RateLimiter.Hammer`, node-local ETS) this behaves
  exactly as before: a fixed 60s window `{:allow, count}` / `{:deny, limit}`
  counter. When an operator selects `Loopctl.RateLimiter.Postgres`, this plug
  becomes cluster-global with NO further change — the shared counter store
  enforces one global budget instead of `limit × node_count`.

  ## Headers

  - `X-RateLimit-Limit` — requests allowed per minute
  - `X-RateLimit-Remaining` — requests remaining in current window
  - `X-RateLimit-Reset` — Unix timestamp when the window resets
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Loopctl.Tenants

  @default_per_key_limit 300

  # Fixed 60s window, matching the ETS/Hammer contract the headers rely on. The
  # limit is the requests-per-minute ceiling.
  @window_ms 60_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_api_key: %{role: :superadmin}}} = conn, _opts) do
    # Superadmin keys are exempt from rate limiting
    conn
  end

  def call(%{assigns: %{current_api_key: api_key, current_tenant: tenant}} = conn, _opts) do
    per_key_limit = get_per_key_limit(tenant)
    per_tenant_limit = per_key_limit * 3

    key_id = "key:#{api_key.id}"
    tenant_id = "tenant:#{api_key.tenant_id}"

    reset_at = window_reset_at()

    case check_rate(key_id, per_key_limit) do
      {:allow, key_count} ->
        case check_rate(tenant_id, per_tenant_limit) do
          {:allow, _tenant_count} ->
            remaining = max(per_key_limit - key_count, 0)
            put_rate_limit_headers(conn, per_key_limit, remaining, reset_at)

          {:deny, _limit} ->
            deny_response(conn, per_key_limit, reset_at)
        end

      {:deny, _limit} ->
        deny_response(conn, per_key_limit, reset_at)
    end
  end

  # No api_key assigned — pass through (RequireAuth handles this)
  def call(conn, _opts), do: conn

  # Resolve the limiter through config-based DI so the plug becomes cluster-global
  # when the Postgres impl is selected, with no call-site change. FAILS OPEN on any
  # limiter fault (parity with Loopctl.Provider.Admission and US-37.1): a limiter
  # outage must never block ALL API traffic, only degrade to "no gate". An
  # unexpected `{:error, _}` (or any non allow/deny shape) is also treated as allow.
  defp check_rate(identifier, limit) do
    case rate_limiter().check_rate(identifier, @window_ms, limit) do
      {:allow, count} when is_integer(count) -> {:allow, count}
      {:deny, denied_limit} when is_integer(denied_limit) -> {:deny, denied_limit}
      other -> fail_open(identifier, "limiter returned #{inspect(other)}")
    end
  rescue
    e -> fail_open(identifier, Exception.message(e))
  catch
    :exit, reason -> fail_open(identifier, "limiter exit: #{inspect(reason)}")
    :throw, value -> fail_open(identifier, "limiter throw: #{inspect(value)}")
  end

  defp fail_open(identifier, detail) do
    Logger.warning(
      "LoopctlWeb.Plugs.RateLimiter: limiter error for #{identifier}; " <>
        "failing OPEN (allowing request): #{detail}"
    )

    {:allow, 0}
  end

  # Config-based DI (project convention): resolve at call time so config/test.exs
  # can swap in Loopctl.MockRateLimiter. NEVER passed as an opt. Default is the
  # node-local ETS impl (today's behaviour).
  defp rate_limiter,
    do: Application.get_env(:loopctl, :rate_limiter, Loopctl.RateLimiter.Hammer)

  # Unix timestamp (seconds) when the current fixed 60s window rolls over.
  # Computed purely from the wall clock — window boundaries align to unix-minute
  # marks, matching the ETS/Hammer fixed-window semantics — so the header value
  # is independent of which limiter impl is selected.
  defp window_reset_at do
    now = System.system_time(:second)
    (div(now, 60) + 1) * 60
  end

  defp get_per_key_limit(nil), do: @default_per_key_limit

  defp get_per_key_limit(tenant) do
    Tenants.get_tenant_settings(tenant, "rate_limit_requests_per_minute", @default_per_key_limit)
  end

  defp put_rate_limit_headers(conn, limit, remaining, reset_at) do
    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset_at))
  end

  defp deny_response(conn, limit, reset_at) do
    # Seconds until the window resets; always >= 1 so a client at the window
    # boundary still backs off rather than hot-looping on a 0/negative value.
    retry_after = max(1, reset_at - System.system_time(:second))

    conn
    |> put_rate_limit_headers(limit, 0, reset_at)
    |> put_resp_header("retry-after", to_string(retry_after))
    |> put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{
      error: %{status: 429, message: "Rate limit exceeded"}
    })
    |> halt()
  end
end
