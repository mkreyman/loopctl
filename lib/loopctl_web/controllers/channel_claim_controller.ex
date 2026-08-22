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
  - `GET /api/v1/channel/claims` — agent+, the channel's UNSWEPT claims, so a session
    can see "this ref is taken, by this agent, until this time" WITHOUT writing.

  ## Read to find out whether a ref is claimed. NEVER probe by claiming. (#707)

  `create` is IDEMPOTENT FOR THE OWNING AGENT: re-claiming your own still-active ref
  returns the existing claim rather than a 409. Combined with a fleet whose sessions
  all authenticate as ONE `agent_id` — which is this deployment's actual shape — that
  makes "claim it and see what happens" a destructive probe. A probe issued while a
  PEER SESSION holds the ref hands back that peer's claim as though it were the
  prober's own, and the `release` that tidies the probe up DELETES it. The peer keeps
  working a handoff the bus has already reopened, and a second machine picks it up.
  #707 recorded exactly that sequence.

  `GET /channel/claims` exists so nobody has to. It answers the same question a `409`
  does and writes nothing.

  ## What the owner scope actually enforces

  `done` and `release` are scoped to `(tenant_id, project_id, claimant_agent_id, ref)`.
  `tenant_id` and `claimant_agent_id` are server-stamped and are real trust boundaries;
  **there is no session dimension**, so two sessions sharing one agent key are NOT
  isolated from each other — either can `done` or `release` the other's claim, and the
  server cannot tell them apart. The enforced guarantee is "scoped to your AGENT, not
  to your session" — the same posture `ChannelLockController` documents for soft-locks
  and `DELETE /channel/posts/:id` uses for posts. Do not cite it as per-session
  isolation. The abandoned-lease sweep, not the release path, is what protects a claim
  whose session died.

  ## The READ is tenant-scoped, not membership-gated

  `index/2` is deliberately uniform with `GET /channel/locks` and `channel_recent`: it
  filters on the key-derived `tenant_id` plus the requested `project_id` only, so any
  agent in the tenant may read any of that tenant's channels' claims. The US-40.D3
  membership gate applies to the WRITE path (`Coordination.claim/5`), NOT to this read.
  A missing or non-UUID `project_id` is refused (422) rather than answered with an empty
  page, because an empty page here MEANS "that ref is claimable" and a caller that
  simply forgot the parameter must not be told every ref is free.

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
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Projects
  alias Loopctl.RateLimiter.FailOpenLog
  alias Loopctl.Tenants
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:create, :done, :release, :index]

  # Per-claim rate limit (review finding): a dedicated cap on the claim write path,
  # mirroring the ChannelPostController's per-write cap. Reuses the same RateLimiter
  # behaviour seam, fail-open discipline, and security telemetry. The claim surface
  # is high-value (24h leases, no operator force-release) so a dedicated cap is
  # warranted even though the generic pipeline limiter also runs first.
  plug :rate_limit_claim when action in [:create]

  # The read gets its OWN bucket, not a share of the write cap (#707). This endpoint
  # exists to replace a destructive probe, so polling it must not spend the CLAIM write
  # budget. A separate bucket alone does NOT deliver that, though: the generic per-key
  # pipeline limiter (LoopctlWeb.Plugs.RateLimiter) counts EVERY authenticated request,
  # reads included, so a read cap merely bounded BY the pipeline budget could still
  # exhaust it and 429 the caller out of claiming. `claim_read_limit/1` therefore clamps
  # the read to a SHARE (a quarter) of that budget — but never BELOW the claim write
  # cap, which would invert the guarantee and 429 the caller out of the very read that
  # replaces the probe.
  plug :rate_limit_claim_read when action in [:index]

  # 60s fixed window, matching the ETS/Hammer contract the pipeline limiter uses.
  @claim_window_ms 60_000

  # Config-default per-minute claim cap; a tenant may override via the
  # `channel_claim_limit_per_minute` setting.
  @default_claim_limit 60

  # Config-default per-minute cap for the claim READ; a tenant may override via the
  # `channel_claim_read_limit_per_minute` setting. Set above the write cap because a
  # read is cheap, idempotent, and is the behaviour we are trying to make the easy one.
  @default_claim_read_limit 120

  # The read's share of the per-key PIPELINE budget (see the `:rate_limit_claim_read`
  # plug note). A quarter, FLOORED at the claim write cap by `claim_read_limit/1`: the
  # share bounds an unbounded poll rate aimed at AdminRepo's small pool, and the floor
  # keeps the read at least as available as the write it precedes. On the default
  # 300/min pipeline budget the effective read cap is therefore 75, not the 120 above —
  # the 120 is the cap this endpoint asks for, the pipeline share is what it gets.
  @claim_read_pipeline_share 4

  # Fallback for the generic per-key pipeline limit, kept in sync with
  # LoopctlWeb.Plugs.RateLimiter's @default_per_key_limit.
  @pipeline_per_key_limit_default 300

  # A missing/cross-tenant/cross-project project returns this ONE message on the
  # claim path — no existence oracle (mirrors ChannelPostController).
  @ownership_error_message "project_id does not exist or does not belong to your tenant"

  # The READ refuses a missing/non-UUID project_id rather than answering an empty page,
  # which it documents as "these refs are claimable". Says nothing about existence.
  @missing_project_message "project_id is required and must be a UUID"

  # Mirrors `Coordination.valid_ref?/1`, which mirrors the claim changeset. Says nothing
  # about whether the ref is claimed.
  @invalid_ref_message "ref must be a non-blank string with no NUL bytes, at most " <>
                         "#{ChannelClaim.ref_max_length()} bytes"

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

  @doc """
  The channel's unswept claims — a read, so nobody has to probe by claiming (#707).

  `GET /api/v1/channel/claims?project_id=<uuid>[&ref=<anchor>][&limit=<n>]`

  A ref is listed while a row HOLDS its `(tenant, project, ref)` slot: DONE, still within
  its lease, or expired and not yet swept. So an empty `claims` array means no row holds
  that ref, and `ref` is the point lookup a session about to claim actually wants. It is
  not a promise the claim will succeed: `claim` also refuses a superseded ref, a caller
  over its concurrent-claim budget, and a non-member — and it returns the CALLER's own
  listed open claim idempotently rather than refusing it. Each row carries `done` and
  `expired` for the handoffs question: `done`, or an unexpired lease, is what keeps the
  ref out of `GET /channel/handoffs`; `expired: true` means the handoff has already
  reopened and the row is merely awaiting the sweeper — retry shortly, do not move on.

  Tenant-scoped from the verified key and NOT membership-gated (see the moduledoc). A
  cross-tenant or nonexistent `project_id` returns an empty page, never a 404 — the same
  no-oracle posture as `GET /channel/locks`. A MISSING or non-UUID `project_id`, and a
  malformed `ref`, are 422 instead: both are client faults decidable without touching a
  row, and answering either with an empty page would tell the caller the ref is free.

  DONE rows are ordered LAST, so a truncated page drops finished rows before it drops
  one that still holds a ref — but `meta.overflow: true` still invalidates an
  "absent = free" conclusion.
  """
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, project_id} <- Ecto.UUID.cast(params["project_id"]),
         :ok <- validate_ref_filter(params["ref"]) do
      render_claims(conn, tenant_id, project_id, params)
    else
      :error -> {:error, :unprocessable_entity, @missing_project_message}
      {:error, _status, _message} = refusal -> refusal
    end
  end

  # A malformed `ref` gets the same 422 a malformed `project_id` does, for the same
  # reason: an empty page means "no row holds it", and a ref the WRITE would refuse with
  # a 422 must never read back that way. `nil` is LIST mode, not a malformed filter.
  defp validate_ref_filter(nil), do: :ok

  defp validate_ref_filter(ref) do
    if Coordination.valid_ref?(ref),
      do: :ok,
      else: {:error, :unprocessable_entity, @invalid_ref_message}
  end

  defp render_claims(conn, tenant_id, project_id, params) do
    limit = Coordination.clamp_claims_limit(params["limit"])

    # A well-formed but foreign/nonexistent project still gets the oracle-safe empty
    # page — but it is RECORDED, so enumerating projects through this read leaves the
    # same trail the write path already leaves as :ownership_rejected. Without it the
    # highest-frequency call on this surface is the one probe with no audit signal.
    case Projects.get_project(tenant_id, project_id) do
      {:ok, _project} ->
        :ok

      {:error, :not_found} ->
        emit_security_event(:ownership_rejected, %{
          tenant_id: tenant_id,
          api_key_id: conn.assigns.current_api_key.id,
          project_id: project_id
        })
    end

    {claims, overflow?} =
      Coordination.claims_page(tenant_id, project_id, limit: limit, ref: params["ref"])

    now = DateTime.utc_now()

    json(conn, %{
      claims: Enum.map(claims, &claim_json(&1, now)),
      meta: %{
        count: length(claims),
        limit: limit,
        overflow: overflow?
      }
    })
  end

  # The read model is the claim's own `@derive {Jason.Encoder}` field set MINUS nothing
  # — every field on it is already coordination-visible (the write paths return the bare
  # struct). Projected explicitly anyway so a future column added to the schema is not
  # silently published by a LIST read, which is a much wider audience than the
  # single-row write responses.
  defp claim_json(claim, now) do
    %{
      id: claim.id,
      ref: claim.ref,
      claimant_agent_id: claim.claimant_agent_id,
      claimed_at: claim.claimed_at,
      lease_expires_at: claim.lease_expires_at,
      done_at: claim.done_at,
      # Derived so a caller never has to re-implement the lifecycle predicates and get
      # them subtly different from the ones the server enforces. `done` (terminal) or a
      # future lease is what EXCLUDES the handoff; `expired` is the row that no longer
      # excludes it but still holds the unique slot, so a claim on it is refused until
      # the ChannelClaimSweeper reaps it.
      done: not is_nil(claim.done_at),
      expired: is_nil(claim.done_at) and DateTime.compare(claim.lease_expires_at, now) != :gt
    }
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

  defp rate_limit_claim_read(conn, _opts) do
    api_key = conn.assigns.current_api_key
    tenant = conn.assigns[:current_tenant]
    limit = claim_read_limit(tenant)
    identifier = "channel_claim_read:key:#{api_key.id}"

    case check_rate(identifier, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        reset_at = window_reset_at()
        retry_after = max(1, reset_at - System.system_time(:second))

        emit_security_event(:rate_limited, %{
          tenant_id: api_key.tenant_id,
          api_key_id: api_key.id,
          limit_kind: :claim_read
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

  defp claim_read_limit(nil), do: default_claim_read_limit()

  defp claim_read_limit(tenant) do
    configured =
      tenant
      |> Tenants.get_tenant_settings(
        "channel_claim_read_limit_per_minute",
        default_claim_read_limit()
      )
      |> coerce_positive_int(default_claim_read_limit())

    # NEVER below `claim_limit/1`: a read cap tighter than the write cap 429s the caller
    # out of reading while it can still claim, which is the destructive probe again.
    min(
      configured,
      max(claim_limit(tenant), div(pipeline_per_key_limit(tenant), @claim_read_pipeline_share))
    )
  end

  defp default_claim_read_limit do
    Application.get_env(:loopctl, :channel_claim_read_limit_per_minute, @default_claim_read_limit)
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
