defmodule LoopctlWeb.ChannelLockController do
  @moduledoc """
  ADVISORY file soft-lock endpoints for the Repo Coordination Bus (Epic 40,
  US-40.4) — collision avoidance on FILE targets.

  - `POST /api/v1/channel/locks` — agent+, take (or refresh) an advisory soft-lock
    on a file target. 201 on a fresh lock, 200 when the caller's own slot is
    refreshed in place.
  - `POST /api/v1/channel/locks/release` — agent+, release the caller's OWN lock.
  - `GET /api/v1/channel/locks` — agent+, the PINNED list of a channel's live
    advisory locks, so a session can see "claimed: <file> by <agent/host>" BEFORE
    it edits.

  ## Advisory — never a mutex

  A soft-lock NEVER blocks anybody. Two sessions may hold a lock on the same file
  and both are surfaced; the reading agent decides. There is no server-side edit
  prevention, and a lock request is never rejected because a peer holds one.

  ## NOT the handoff claim

  `/api/v1/channel/claims` (`LoopctlWeb.ChannelClaimController`, US-40.B1) is the
  EXACTLY-ONCE handoff claim, backed by the `channel_claims` unique index. This
  controller is the advisory, non-exclusive soft-lock stored in `channel_locks`
  (`Loopctl.Coordination.ChannelLock`, US-52.21). Do not conflate them, and never
  cite this surface as the handoff-claim primitive.

  ## Response shape

  The JSON fields are the ones these endpoints answered with while a lock was a
  `channel_posts` row: `key` (`"claim:" <> target`), `refs` (one file ref) and
  `body_preview` are derived from the lock row by `ChannelLock.key/1`,
  `ChannelLock.refs/1` and `ChannelLock.body/1`.

  ## Trust posture (owner decision #331 — same as channel posts and claims)

  A COORDINATION surface, NOT chain-of-custody: `role: :agent`, deliberately NOT
  behind `RequireHumanAnchor`. `tenant_id`, `agent_id` and `role` are stamped
  server-side from the verified key identity — NEVER from the request body — so no
  caller can lock as another agent, in another tenant, or in a project it is not a
  writable member of (the shared US-40.D3 `project_writable_by_agent/4` gate).

  ## What the release scope actually enforces (review #451)

  A release is addressed by `(tenant_id, project_id, agent_id, session_id, target)`.
  `tenant_id` and `agent_id` are server-stamped and are real trust boundaries;
  **`session_id` is caller-supplied and is NOT**, and `GET /channel/locks` publishes
  every live lock's `session_id`. Two sessions sharing ONE agent key are therefore
  not isolated from each other — either can release or overwrite the other's lock.
  The enforced guarantee is "scoped to your AGENT, not to your session" (the same
  author-scoped model `DELETE /channel/posts/:id` uses). That is acceptable for
  advisory hint data; do not cite it as per-session isolation.

  ## Oracle-safety

  A missing / cross-tenant / cross-PROJECT (non-member) project collapses to one
  byte-identical 422 on the lock path. A release of a nonexistent lock, another
  AGENT's lock, a lock held under a different session id than the one supplied, or a
  cross-tenant lock all collapse to one byte-identical 404 — no existence oracle.

  ## The READ is tenant-scoped, not membership-gated

  `index/2` is deliberately uniform with `channel_recent`: it filters on the
  key-derived `tenant_id` + the requested `project_id` only, so any agent in the
  tenant may read any of that tenant's channels' locks (an oracle-safe empty list
  for a nonexistent/cross-tenant project, never a 404). The US-40.D3 membership gate
  applies to the WRITE path (`Coordination.lock_file/5`), not to this read.
  """

  use LoopctlWeb, :controller

  require Logger

  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelLock
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:create, :release, :index]

  # No coordination rate cap here (US-52.26): the only request bounds are the
  # pipeline's, in `LoopctlWeb.Plugs.RateLimiter`.

  # A missing / cross-tenant / cross-project project returns this ONE message — no
  # existence oracle (mirrors ChannelPostController and ChannelClaimController).
  @ownership_error_message "project_id does not exist or does not belong to your tenant"

  @invalid_target_message "target must be a non-blank file path of at most 194 bytes"

  # A lock write with no client session id is REJECTED rather than rescued with a
  # server surrogate (review #451): a surrogate is minted fresh per write, so such a
  # lock can never be refreshed in place nor released by slot — every attempt would
  # leak another unreleasable row into the pinned read until its TTL expired.
  @missing_session_message "session_id is required to take an advisory soft-lock: it is what makes the lock refreshable in place and releasable by slot"

  @doc """
  POST /api/v1/channel/locks

  Takes or refreshes an ADVISORY soft-lock on `target`. NEVER blocks: a peer
  holding a lock on the same target does not make this fail.

  `session_id` is REQUIRED (422 otherwise) — it is what makes the lock refreshable
  in place and releasable by slot.
  """
  def create(conn, params) do
    with_agent(conn, fn tenant_id, agent_id, role ->
      opts = [
        role: role,
        ttl_seconds: params["ttl_seconds"],
        session_id: params["session_id"],
        host: params["host"],
        body: params["body"],
        audit: AuditContext.from_conn(conn)
      ]

      render_lock(
        conn,
        Coordination.lock_file(tenant_id, agent_id, params["project_id"], params["target"], opts),
        tenant_id,
        agent_id,
        params
      )
    end)
  end

  @doc """
  POST /api/v1/channel/locks/release

  Releases the caller's OWN advisory soft-lock on `target`. Oracle-safe 404 for a
  lock that is not yours / not there.
  """
  def release(conn, params) do
    with_agent(conn, fn tenant_id, agent_id, _role ->
      case Coordination.unlock_file(tenant_id, agent_id, params["project_id"], params["target"],
             session_id: params["session_id"],
             audit: AuditContext.from_conn(conn)
           ) do
        {:ok, lock} ->
          json(conn, %{released: true, lock: %{id: lock.id, key: ChannelLock.key(lock)}})

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :audit_write_failed} ->
          {:error, :audit_write_failed}
      end
    end)
  end

  @doc """
  GET /api/v1/channel/locks?project_id=...

  The PINNED live advisory-lock set for a channel — read this BEFORE editing a
  file. Advisory: a returned lock is a hint, never a prohibition.
  """
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    limit = Coordination.clamp_active_locks_limit(params["limit"])

    {locks, overflow?, holders_truncated?} =
      Coordination.active_locks_page(tenant_id, params["project_id"], limit: limit)

    json(conn, %{
      locks: Enum.map(locks, &lock_json/1),
      meta: %{
        count: length(locks),
        limit: limit,
        # TWO distinct truncation signals (review #451). `overflow` is the PAGE cap;
        # `holders_truncated` is the per-agent FAIRNESS cap, which filters inside the
        # scope and is therefore structurally invisible to `overflow` — reporting only
        # the latter would answer `overflow: false` on a page that had silently dropped
        # live locks. EITHER flag means "this is not the complete live set".
        overflow: overflow?,
        holders_truncated: holders_truncated?,
        advisory: true
      }
    })
  end

  # The note rides as `body_preview`, bounded by the same 512-byte preview rule a
  # channel post's body uses (`Coordination.finalize_preview/1`), so a peer session
  # never reads more of it than it read before.
  defp lock_json(%ChannelLock{} = lock) do
    %{body_preview: body_preview, truncated: truncated} =
      Coordination.finalize_preview(%{body_preview: ChannelLock.body(lock)})

    lock
    |> lock_write_json()
    |> Map.merge(%{body_preview: body_preview, truncated: truncated})
  end

  # --- write outcome → HTTP ---

  defp render_lock(conn, {:ok, lock, :created}, _tenant_id, _agent_id, _params) do
    conn
    |> put_status(:created)
    |> json(%{lock: lock_write_json(lock), created: true, meta: lock_meta(lock)})
  end

  defp render_lock(conn, {:ok, lock, :updated}, _tenant_id, _agent_id, _params) do
    conn
    |> put_status(:ok)
    |> json(%{lock: lock_write_json(lock), created: false, meta: lock_meta(lock)})
  end

  defp render_lock(_conn, {:error, :invalid_target}, _tenant_id, _agent_id, _params) do
    {:error, :unprocessable_entity, @invalid_target_message}
  end

  defp render_lock(_conn, {:error, :missing_session}, _tenant_id, _agent_id, _params) do
    {:error, :unprocessable_entity, @missing_session_message}
  end

  defp render_lock(_conn, {:error, :not_found}, tenant_id, agent_id, params) do
    emit_security_event(:ownership_rejected, %{
      tenant_id: tenant_id,
      agent_id: agent_id,
      project_id: params["project_id"]
    })

    {:error, :unprocessable_entity, @ownership_error_message}
  end

  defp render_lock(conn, {:error, :agent_not_found}, tenant_id, agent_id, params) do
    agent_identity_fault(conn, tenant_id, agent_id, params["project_id"])
  end

  defp render_lock(_conn, {:error, %Ecto.Changeset{} = changeset}, _t, _a, _p) do
    {:error, changeset}
  end

  defp lock_write_json(%ChannelLock{} = lock) do
    %{
      id: lock.id,
      target: lock.target,
      key: ChannelLock.key(lock),
      agent_id: lock.agent_id,
      session_id: lock.session_id,
      host: lock.host,
      refs: ChannelLock.refs(lock),
      expires_at: lock.expires_at,
      inserted_at: lock.inserted_at,
      updated_at: lock.updated_at
    }
  end

  defp lock_meta(lock) do
    %{
      # ADVISORY is part of the contract, not a docstring: a client must never
      # infer exclusivity from a 201.
      advisory: true,
      blocking: false,
      expires_at: lock.expires_at
    }
  end

  # A lock always requires an attributed agent identity (channel_locks.agent_id is
  # NOT NULL). A key with no agent identity gets a 403 before any row is touched —
  # mirrors ChannelPostController.create/2 and ChannelClaimController.
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
            message:
              "This API key has no agent identity; it cannot take an advisory file soft-lock"
          }
        })

      agent_id ->
        fun.(tenant_id, agent_id, api_key.role)
    end
  end

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
          "This API key's agent identity is not valid for this tenant; it cannot take an advisory file soft-lock"
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
        "project=#{log_safe_id(Map.get(metadata, :project_id))})"
    )

    :ok
  end

  # LOG-FORGING guard (review #451). `tenant_id`/`agent_id`/`api_key_id` are
  # server-derived, but `project_id` comes STRAIGHT FROM THE REQUEST BODY and is
  # never format-checked on these paths (the 422 comes from the context's ownership
  # lookup, not a UUID parse). Interpolated raw into a one-line log record, a value
  # carrying CR/LF lets an authenticated agent forge additional log lines —
  # including fake "coordination security event:" records with attacker-chosen
  # tenant/agent ids — in whatever aggregator consumes these. The RAW value still
  # rides the structured telemetry metadata above (where it is a field, not a line),
  # so nothing is lost for debugging.
  defp log_safe_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> "<invalid>"
    end
  end

  defp log_safe_id(nil), do: ""
  defp log_safe_id(_value), do: "<invalid>"
end
