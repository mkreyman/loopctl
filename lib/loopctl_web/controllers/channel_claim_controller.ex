defmodule LoopctlWeb.ChannelClaimController do
  @moduledoc """
  Exactly-once handoff CLAIM endpoints for the Repo Coordination Bus (Epic 40,
  US-40.B1) — the third memory plane's coordination surface.

  - `POST /api/v1/channel/claims` — agent+, INSERT-to-claim a handoff `ref` for
    exactly ONE agent. The FIRST inserter on the `(tenant_id, project_id, ref)`
    unique index wins (201); every concurrent loser gets a distinct
    `409 already_claimed` so it learns another agent owns the ref and moves on.
  - `POST /api/v1/channel/claims/done` — agent+, mark the caller's OWN claim done.
  - `POST /api/v1/channel/claims/release` — agent+, DELETE the caller's OWN claim so
    the ref reopens for the next racer.

  ## Trust posture (owner decision #331 — same as channel posts)

  A COORDINATION surface, NOT chain-of-custody: `role: :agent`, deliberately NOT
  behind `RequireHumanAnchor`. `tenant_id`, `agent_id`, and `role` are stamped
  server-side from the verified key identity (`conn.assigns.current_api_key`) —
  NEVER from the request body — so no caller can claim as another agent, in another
  tenant, or into a project it is not a writable member of (US-40.D3 gate). `ref`
  and the optional `lease_seconds` are the only caller-influenced fields.

  ## Oracle-safety

  A missing/cross-tenant/cross-project claim target collapses to a byte-identical
  error the `FallbackController` renders as one shared shape — no existence oracle.
  `claim` maps a missing/cross-tenant/cross-project project to a 422; `done`/
  `release` map a non-owner/cross-tenant/cross-project/missing claim to a 404.
  """

  use LoopctlWeb, :controller

  require Logger

  alias Loopctl.Coordination
  alias Loopctl.RateLimiter.FailOpenLog
  alias Loopctl.Tenants
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:create, :done, :release]

  # Per-claim rate limit (review finding): a dedicated cap on the claim write path,
  # mirroring the ChannelPostController's per-write cap. Reuses the same RateLimiter
  # behaviour seam, fail-open discipline, and security telemetry. The claim surface
  # is high-value (24h leases, no operator force-release) so a dedicated cap is
  # warranted even though the generic pipeline limiter also runs first.
  plug :rate_limit_claim when action in [:create]

  # 60s fixed window, matching the ETS/Hammer contract the pipeline limiter uses.
  @claim_window_ms 60_000

  # Config-default per-minute claim cap; a tenant may override via the
  # `channel_claim_limit_per_minute` setting.
  @default_claim_limit 60

  # Fallback for the generic per-key pipeline limit, kept in sync with
  # LoopctlWeb.Plugs.RateLimiter's @default_per_key_limit.
  @pipeline_per_key_limit_default 300

  # A missing/cross-tenant/cross-project project returns this ONE message on the
  # claim path — no existence oracle (mirrors ChannelPostController).
  @ownership_error_message "project_id does not exist or does not belong to your tenant"

  @doc """
  POST /api/v1/channel/claims

  INSERT-to-claim a handoff `ref`. Requires agent+ role and an agent identity.
  """
  def create(conn, params) do
    with_agent(conn, fn tenant_id, agent_id, role ->
      case Coordination.claim(tenant_id, agent_id, params["project_id"], params["ref"],
             role: role,
             lease_seconds: params["lease_seconds"],
             audit: AuditContext.from_conn(conn)
           ) do
        {:ok, claim} ->
          conn
          |> put_status(:created)
          |> json(%{claim: claim})

        {:error, :already_claimed} ->
          # The loser of the INSERT-to-claim race. A DISTINCT 409 (via the
          # FallbackController's :already_claimed clause) so the caller learns
          # another agent owns the ref — never confused with a validation 422.
          {:error, :already_claimed}

        {:error, :not_found} ->
          # Missing / cross-tenant / cross-PROJECT (non-member) all collapse to one
          # byte-identical 422 — no oracle distinguishing them.
          emit_security_event(:ownership_rejected, %{
            tenant_id: tenant_id,
            agent_id: agent_id,
            project_id: params["project_id"]
          })

          {:error, :unprocessable_entity, @ownership_error_message}

        {:error, :agent_not_found} ->
          agent_identity_fault(conn, tenant_id, agent_id, params["project_id"])

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end)
  end

  @doc """
  POST /api/v1/channel/claims/done

  Marks the caller's OWN claim on `ref` done. A non-owner / cross-tenant /
  cross-project / missing claim returns a byte-identical 404 (no oracle).
  """
  def done(conn, params) do
    with_agent(conn, fn tenant_id, agent_id, _role ->
      case Coordination.done(
             tenant_id,
             agent_id,
             params["project_id"],
             params["ref"],
             AuditContext.from_conn(conn)
           ) do
        {:ok, claim} -> json(conn, %{claim: claim})
        {:error, :not_found} -> {:error, :not_found}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      end
    end)
  end

  @doc """
  POST /api/v1/channel/claims/release

  DELETES the caller's OWN claim on `ref` so it reopens for the next racer. Same
  oracle-safe 404 as `done` for a non-owner / cross-tenant / missing claim.
  """
  def release(conn, params) do
    with_agent(conn, fn tenant_id, agent_id, _role ->
      case Coordination.release(
             tenant_id,
             agent_id,
             params["project_id"],
             params["ref"],
             AuditContext.from_conn(conn)
           ) do
        {:ok, claim} -> json(conn, %{claim: claim})
        {:error, :not_found} -> {:error, :not_found}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      end
    end)
  end

  # A claim always requires an attributed agent identity (channel_claims
  # .claimant_agent_id is NOT NULL). A key with no agent identity gets a 403 before
  # any row is touched — mirrors ChannelPostController.create/2.
  defp with_agent(conn, fun) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case api_key.agent_id do
      nil ->
        emit_security_event(:agent_identity_required, %{
          tenant_id: tenant_id,
          api_key_id: api_key.id
        })

        conn
        |> put_status(:forbidden)
        |> json(%{
          error: %{
            status: 403,
            code: "agent_identity_required",
            message: "This API key has no agent identity; it cannot claim a coordination handoff"
          }
        })

      agent_id ->
        fun.(tenant_id, agent_id, api_key.role)
    end
  end

  # Defense-in-depth: the key's server-stamped agent_id does not belong to this
  # tenant (a misconfigured key). An IDENTITY fault (403), not a project probe.
  defp agent_identity_fault(conn, tenant_id, agent_id, project_id) do
    emit_security_event(:agent_identity_required, %{
      tenant_id: tenant_id,
      agent_id: agent_id,
      project_id: project_id
    })

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "agent_identity_required",
        message:
          "This API key's agent identity is not valid for this tenant; it cannot claim a coordination handoff"
      }
    })
  end

  # --- Rate limiting (function plug) ---

  defp rate_limit_claim(conn, _opts) do
    api_key = conn.assigns.current_api_key
    tenant = conn.assigns[:current_tenant]
    limit = claim_limit(tenant)
    identifier = "channel_claim:key:#{api_key.id}"

    case check_rate(identifier, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        reset_at = window_reset_at()
        retry_after = max(1, reset_at - System.system_time(:second))

        emit_security_event(:rate_limited, %{
          tenant_id: api_key.tenant_id,
          api_key_id: api_key.id,
          limit_kind: :claim
        })

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{error: %{status: 429, message: "Rate limit exceeded"}})
        |> halt()
    end
  end

  defp check_rate(identifier, limit) do
    case Loopctl.RateLimiter.impl().check_rate(identifier, @claim_window_ms, limit) do
      {:allow, count} when is_integer(count) -> {:allow, count}
      {:deny, denied} when is_integer(denied) -> {:deny, denied}
      other -> fail_open(identifier, "limiter returned #{inspect(other)}")
    end
  rescue
    e -> fail_open(identifier, Exception.message(e))
  catch
    :exit, reason -> fail_open(identifier, "limiter exit: #{inspect(reason)}")
    :throw, value -> fail_open(identifier, "limiter throw: #{inspect(value)}")
  end

  defp fail_open(identifier, detail) do
    FailOpenLog.warn(:coordination, identifier, detail)
    {:allow, 0}
  end

  defp claim_limit(nil), do: default_claim_limit()

  defp claim_limit(tenant) do
    configured =
      tenant
      |> Tenants.get_tenant_settings("channel_claim_limit_per_minute", default_claim_limit())
      |> coerce_positive_int(default_claim_limit())

    min(configured, pipeline_per_key_limit(tenant))
  end

  defp default_claim_limit do
    Application.get_env(:loopctl, :channel_claim_limit_per_minute, @default_claim_limit)
  end

  defp pipeline_per_key_limit(tenant) do
    tenant
    |> Tenants.get_tenant_settings(
      "rate_limit_requests_per_minute",
      @pipeline_per_key_limit_default
    )
    |> coerce_positive_int(@pipeline_per_key_limit_default)
  end

  defp coerce_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp coerce_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp coerce_positive_int(_value, default), do: default

  defp window_reset_at do
    # Hammer uses millisecond windows aligned to epoch; the next reset is the
    # next multiple of the window size.
    now = System.system_time(:millisecond)
    ceil = div(now, @claim_window_ms) * @claim_window_ms + @claim_window_ms
    div(ceil, 1000)
  end

  # Coordination-surface security telemetry (parity with ChannelPostController).
  defp emit_security_event(event, metadata) do
    :telemetry.execute([:loopctl, :coordination, event], %{count: 1}, metadata)

    Logger.warning(
      "coordination security event: #{event} " <>
        "(tenant=#{Map.get(metadata, :tenant_id)} " <>
        "api_key=#{Map.get(metadata, :api_key_id)} " <>
        "agent=#{Map.get(metadata, :agent_id)} " <>
        "project=#{Map.get(metadata, :project_id)})"
    )

    :ok
  end
end
