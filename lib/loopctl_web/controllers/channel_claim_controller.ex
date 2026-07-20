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
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:create, :done, :release]

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
