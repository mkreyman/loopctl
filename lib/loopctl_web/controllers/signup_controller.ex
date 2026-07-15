defmodule LoopctlWeb.SignupController do
  @moduledoc """
  US-26.7.1 — public (no-auth) JSON self-signup endpoint for agent-rooted
  (KB-tier) tenants.

  Distinct from the `/signup` WebAuthn LiveView (different pipeline, path,
  and method — no route collision): this endpoint lets a stranger agent
  create its own tenant and obtain a working key entirely through an API
  call or an MCP tool, with no human operator and no hardware authenticator.

  This route sits OUTSIDE the `:authenticated` pipeline (it must — there is
  no key yet), so it never runs `LoopctlWeb.Plugs.RateLimiter`. It is
  rate-limited independently, per client IP, via the config-resolved
  `Loopctl.RateLimiter` behaviour (the same one `LoopctlWeb.SignupLive`
  uses for the WebAuthn ceremony).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.RemoteIp
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  # Conservative cap: <= 5 tenants per IP per hour (AC-26.7.1.5).
  @max_signups_per_ip 5
  @rate_window_ms 60_000 * 60
  @max_field_bytes 512

  tags(["Tenants"])

  operation(:create,
    summary: "Self-signup (agent-rooted, KB tier)",
    description:
      "Creates an agent-rooted tenant and mints a one-time role:user root API key, " <>
        "entirely through this API call — no WebAuthn ceremony. The resulting tenant " <>
        "has full knowledge-wiki access but NOT the work-breakdown / chain-of-custody " <>
        "surface (see the RequireHumanAnchor gate). Public — no authentication " <>
        "required. Rate-limited per client IP (<= 5 signups/hour).",
    request_body: {"Signup params", "application/json", Schemas.SelfSignupRequest},
    security: [],
    responses: %{
      201 => {"Tenant created", "application/json", Schemas.SelfSignupResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/signup

  Public agent-rooted self-signup. See moduledoc.
  """
  def create(conn, params) do
    # US-26.7.1 (#6a) — the rate-limit check runs FIRST, so an oversized-field
    # request still consumes the per-IP budget. Otherwise a flood of oversized
    # payloads would 422 without ever counting against the cap, defeating it.
    bucket = "api_signup:ip:#{client_ip(conn)}"

    case Loopctl.RateLimiter.impl().check_rate(bucket, @rate_window_ms, @max_signups_per_ip) do
      {:allow, _count} -> validate_and_signup(conn, params)
      {:deny, _limit} -> rate_limited(conn)
    end
  end

  defp validate_and_signup(conn, params) do
    case validate_field_sizes(params) do
      :ok -> do_signup(conn, params)
      {:error, message} -> unprocessable(conn, message)
    end
  end

  defp do_signup(conn, params) do
    case Tenants.self_signup(params) do
      {:ok, %{tenant: tenant, raw_key: raw_key}} ->
        conn
        |> put_status(:created)
        |> json(%{data: signup_response(tenant, raw_key)})

      {:error, :slug_taken} ->
        unprocessable(conn, "That slug is already in use", %{slug: ["has already been taken"]})

      {:error, :email_taken} ->
        unprocessable(
          conn,
          "That email is already associated with a tenant",
          %{email: ["has already been taken"]}
        )

      {:error, %Ecto.Changeset{}} = error ->
        error

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{status: 500, message: "Signup failed. Please retry."}})
    end
  end

  defp signup_response(tenant, raw_key) do
    %{
      tenant: tenant_json(tenant),
      raw_key: raw_key,
      next_action: %{
        message:
          "Configure your BYO LLM keys, then register an agent identity and start " <>
            "ingesting/searching the knowledge wiki.",
        configure_llm: "PATCH /api/v1/tenants/me/llm-config",
        register_agent: "POST /api/v1/agents/register",
        ingest: "POST /api/v1/knowledge/ingest",
        search: "GET /api/v1/knowledge/search"
      }
    }
  end

  defp tenant_json(tenant) do
    %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      email: tenant.email,
      trust_tier: tenant.trust_tier,
      status: tenant.status,
      inserted_at: tenant.inserted_at
    }
  end

  defp validate_field_sizes(params) do
    ok? =
      Enum.all?(["name", "slug", "email"], fn key -> within_size?(Map.get(params, key)) end)

    if ok?, do: :ok, else: {:error, "One or more fields exceed the maximum length"}
  end

  defp within_size?(value) when is_binary(value), do: byte_size(value) <= @max_field_bytes
  defp within_size?(_value), do: true

  # US-26.7.1 (#6b) — proxy-aware per-IP bucket key, mirroring
  # SignupLive.peer_identity/1. `conn.remote_ip` was resolved by the
  # `LoopctlWeb.Plugs.ClientIp` endpoint plug (shared `Loopctl.RemoteIp`
  # resolver, preferring the unspoofable `fly-client-ip`). If it still resolves
  # to one of our configured PROXIES (e.g. Fly's 6PN when no forwarded header
  # was present) we could NOT determine the real client — keying on the proxy
  # IP would collapse EVERY visitor onto ONE shared bucket, so a single
  # proxy-fronted flood would fill it and block legitimate signups. In that
  # case we fall back to a per-request key (never a shared bucket): it forgoes
  # limiting on this unresolved path rather than punishing everyone. On Fly the
  # path is unreachable (fly-client-ip is always present and unspoofable).
  defp client_ip(conn) do
    ip = conn.remote_ip

    cond do
      not is_tuple(ip) -> "req:#{System.unique_integer([:positive])}"
      RemoteIp.proxy?(ip) -> "req:#{System.unique_integer([:positive])}"
      true -> RemoteIp.to_string_ip(ip) || "req:#{System.unique_integer([:positive])}"
    end
  end

  defp unprocessable(conn, message, details \\ nil) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: unprocessable_error(message, details)})
  end

  defp unprocessable_error(message, nil), do: %{status: 422, message: message}

  defp unprocessable_error(message, details),
    do: %{status: 422, message: message, details: details}

  defp rate_limited(conn) do
    conn
    |> put_resp_header("retry-after", "3600")
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        status: 429,
        message: "Too many signup attempts from this IP. Please try again in an hour."
      }
    })
  end
end
