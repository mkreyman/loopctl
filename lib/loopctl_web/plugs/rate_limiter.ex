defmodule LoopctlWeb.Plugs.RateLimiter do
  @moduledoc """
  Per-API-key and per-tenant rate limiting plug.

  Checks both per-key and per-tenant aggregate limits. Superadmin keys
  are exempt. Rate limit headers are added to every response.

  Must be placed AFTER RequireAuth in the pipeline so unauthenticated
  requests don't consume rate limit budget.

  ## Headers

  - `X-RateLimit-Limit` — requests allowed per minute
  - `X-RateLimit-Remaining` — requests remaining in current window
  - `X-RateLimit-Reset` — Unix timestamp when the window resets
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.RateLimiter.Server, as: RateLimitServer
  alias Loopctl.Tenants

  @default_per_key_limit 300

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

    window_info = RateLimitServer.window_info()

    case RateLimitServer.check_rate(key_id, per_key_limit) do
      {:allow, key_count} ->
        case RateLimitServer.check_rate(tenant_id, per_tenant_limit) do
          {:allow, _tenant_count} ->
            remaining = max(per_key_limit - key_count, 0)
            put_rate_limit_headers(conn, per_key_limit, remaining, window_info.reset_at)

          {:deny, _limit} ->
            deny_response(conn, per_key_limit, window_info.reset_at)
        end

      {:deny, _limit} ->
        deny_response(conn, per_key_limit, window_info.reset_at)
    end
  end

  # No api_key assigned — pass through (RequireAuth handles this)
  def call(conn, _opts), do: conn

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
    conn
    |> put_rate_limit_headers(limit, 0, reset_at)
    |> put_resp_header("retry-after", to_string(reset_at - System.system_time(:second)))
    |> put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{
      error: %{status: 429, message: "Rate limit exceeded"}
    })
    |> halt()
  end
end
