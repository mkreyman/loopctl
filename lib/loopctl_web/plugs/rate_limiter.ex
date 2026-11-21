defmodule LoopctlWeb.Plugs.RateLimiter do
  @moduledoc """
  The API pipeline's request rate limit: one tenant-wide bucket, plus a per-key
  bucket for keys that are not holder credentials (US-52.26).

  - **Holder credential** (`api_key.holder_id` set, US-52.13): NO per-key check. A
    holder credential is one session, and a busy session coordinating with others
    must never be refused because its own key hit a cap. It meets only the
    tenant-wide bucket, and the `X-RateLimit-*` headers report that bucket.
  - **Any other key**: the per-key check against the tenant setting
    `rate_limit_requests_per_minute` (default 300), then the tenant-wide bucket.
    The headers report the per-key bucket.
  - **Superadmin key**: exempt from both.

  The tenant-wide limit is the tenant setting `rate_limit_tenant_requests_per_minute`
  (default 900); it is independent of the per-key setting.

  Must be placed AFTER RequireAuth in the pipeline so unauthenticated requests don't
  consume rate limit budget.

  ## Where each bucket is counted

  The tenant bucket is counted on `Loopctl.RateLimiter.tenant_impl/0` (default
  `Loopctl.RateLimiter.Postgres`) whatever `RATE_LIMITER` selects, so every node draws
  on one budget instead of `limit × node_count`. The per-key bucket stays on
  `Loopctl.RateLimiter.impl/0`. Both are resolved at call time and may be overridden
  by the `:tenant_limiter` / `:key_limiter` plug options (a test passes its own).

  Every limiter fault (raise, exit, throw, or an unexpected return) FAILS OPEN with
  one throttled `Loopctl.RateLimiter.FailOpenLog` line per bucket family per window:
  a limiter outage must never block all API traffic.

  ## Headers

  - `X-RateLimit-Limit` — requests allowed per minute in the reported bucket
  - `X-RateLimit-Remaining` — requests remaining in the current window
  - `X-RateLimit-Reset` — Unix timestamp when the window resets
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.RateLimiter.FailOpenLog
  alias Loopctl.Tenants

  @default_per_key_limit 300
  @default_tenant_limit 900

  # Fixed 60s window, matching the ETS/Hammer contract the headers rely on. The
  # limit is the requests-per-minute ceiling.
  @window_ms 60_000

  @doc "Default of the tenant setting `rate_limit_tenant_requests_per_minute`."
  @spec default_tenant_limit() :: pos_integer()
  def default_tenant_limit, do: @default_tenant_limit

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_api_key: %{role: :superadmin}}} = conn, _opts) do
    # Superadmin keys are exempt from rate limiting
    conn
  end

  def call(%{assigns: %{current_api_key: api_key, current_tenant: tenant}} = conn, opts) do
    tenant_limiter = Keyword.get_lazy(opts, :tenant_limiter, &Loopctl.RateLimiter.tenant_impl/0)
    tenant_limit = get_tenant_limit(tenant)
    tenant_bucket = "tenant:#{api_key.tenant_id}"
    reset_at = window_reset_at()

    if holder_credential?(api_key) do
      case check_rate(tenant_limiter, tenant_bucket, tenant_limit) do
        {:allow, count} ->
          put_rate_limit_headers(conn, tenant_limit, max(tenant_limit - count, 0), reset_at)

        {:deny, _limit} ->
          deny_response(conn, tenant_limit, reset_at)
      end
    else
      key_limiter = Keyword.get_lazy(opts, :key_limiter, &Loopctl.RateLimiter.impl/0)
      per_key_limit = get_per_key_limit(tenant)

      with {:allow, key_count} <- check_rate(key_limiter, "key:#{api_key.id}", per_key_limit),
           {:allow, _tenant_count} <- check_rate(tenant_limiter, tenant_bucket, tenant_limit) do
        put_rate_limit_headers(conn, per_key_limit, max(per_key_limit - key_count, 0), reset_at)
      else
        {:deny, _limit} -> deny_response(conn, per_key_limit, reset_at)
      end
    end
  end

  # No api_key assigned — pass through (RequireAuth handles this)
  def call(conn, _opts), do: conn

  defp holder_credential?(%{holder_id: holder_id}) when is_binary(holder_id), do: true
  defp holder_credential?(_api_key), do: false

  # FAILS OPEN on any limiter fault (parity with Loopctl.Provider.Admission and
  # US-37.1): a limiter outage must never block ALL API traffic, only degrade to "no
  # gate". An unexpected `{:error, _}` (or any non allow/deny shape) is also allow.
  defp check_rate(limiter, identifier, limit) do
    case limiter.check_rate(identifier, @window_ms, limit) do
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
    # Throttled + PII-safe (bounded per bucket-family per window; UUID suffix
    # stripped) so a sustained limiter outage — when every request fails here —
    # can't flood the logs.
    FailOpenLog.warn(:plug, identifier, detail)

    {:allow, 0}
  end

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

  # Settings are raw jsonb, so a value stored as a string ("900") or a non-positive
  # number would otherwise reach the limiter as a non-integer limit, raise, and fail
  # open — silently removing the tenant bound. Coerce, falling back to the default.
  defp get_tenant_limit(nil), do: @default_tenant_limit

  defp get_tenant_limit(tenant) do
    tenant
    |> Tenants.get_tenant_settings("rate_limit_tenant_requests_per_minute", @default_tenant_limit)
    |> positive_int(@default_tenant_limit)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

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
