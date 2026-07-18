defmodule LoopctlWeb.ChannelPostController do
  @moduledoc """
  Write endpoint for the repo coordination bus (Epic 39, the third memory plane).

  - `POST /api/v1/channel/posts` — agent+, posts one short coordination message
    to a project's channel (a channel IS a `project_id`), optionally under a
    `key` that upserts the caller's own per-session working-state slot.

  ## Trust posture (owner decision #331, design brief §4)

  This is a COORDINATION surface, NOT chain-of-custody: posting to your own
  tenant's channel is the same content class as the KB surface #331 made fully
  agent-usable. So the route is `role: :agent` and is deliberately NOT behind
  `RequireHumanAnchor`. Authorship is stamped server-side from the verified key
  identity (`tenant_id`/`agent_id`) — never from the request body — so no caller
  can forge authorship or post into another tenant's channel.

  ## Security signals (AC-39.2.9)

  Every abuse-relevant outcome emits a `[:loopctl, :coordination, event]`
  telemetry event + a structured warning so exfil attempts and enumeration scans
  are observable: `:agent_identity_required` (403 — the key carries no agent
  identity, OR its agent belongs to another tenant), `:ownership_rejected` (422,
  cross-tenant/not-found project — no existence oracle), and `:rate_limited`
  (429). The denylist rejection (422) signal is emitted from `Loopctl.Coordination`
  at the point the write is rejected. A rate-limiter fault degrades to "no gate"
  but is logged via the shared throttled `FailOpenLog`, never swallowed silently.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Coordination
  alias Loopctl.RateLimiter.FailOpenLog
  alias Loopctl.Tenants
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  # Coordination surface (#331): agent role, NO RequireHumanAnchor. See the
  # coordination-surface allowlist entry in require_human_anchor_default_deny_test.
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:create]

  # Per-write rate limit (AC-39.2.8): a TIGHTER, config-driven cap on top of the
  # generic per-key/per-tenant pipeline RateLimiter, reusing the same
  # `Loopctl.RateLimiter` behaviour seam. Bounds post spam / upsert thrash.
  plug :rate_limit_write when action in [:create]

  tags(["Coordination"])

  # A missing project and a cross-tenant project return this ONE message — no
  # existence oracle distinguishing "not yours" from "does not exist" (AC-39.2.3).
  @ownership_error_message "project_id does not exist or does not belong to your tenant"

  # 60s fixed window, matching the ETS/Hammer contract the pipeline limiter uses.
  @write_window_ms 60_000

  # Config-default per-minute write cap; a tenant may override via the
  # `channel_post_write_limit_per_minute` setting (mirrors the pipeline limiter's
  # `rate_limit_requests_per_minute`). Not hardcoded at the call site.
  @default_write_limit 120

  # Fallback for the generic per-key pipeline limit, kept in sync with
  # LoopctlWeb.Plugs.RateLimiter's @default_per_key_limit. Used to clamp the
  # coordination cap so it stays the binding (and observable) constraint.
  @pipeline_per_key_limit_default 300

  operation(:create,
    summary: "Post to a repo coordination channel",
    description:
      "Posts one short, attributed coordination message to a project's channel (a channel IS a " <>
        "project_id). Agent+ role, NOT behind the human-anchor tier (coordination surface, owner " <>
        "decision #331). tenant_id and agent_id are stamped server-side from the verified key — " <>
        "any agent_id/tenant_id in the body is ignored. With a `key` the write upserts the " <>
        "caller's own per-session working-state slot (200); without a key it is a new " <>
        "append-only row (201). expires_at is set server-side to now + 30 days.",
    request_body: {"Channel post params", "application/json", Schemas.ChannelPostRequest},
    responses: %{
      201 => {"Post created", "application/json", Schemas.ChannelPostResponse},
      200 => {"Session slot upserted in place", "application/json", Schemas.ChannelPostResponse},
      403 => {"Agent identity required", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Validation error or unknown/cross-tenant project", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/channel/posts

  Writes a coordination post. Requires agent+ role and a key that carries an
  agent identity (403 `agent_identity_required` otherwise).
  """
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case api_key.agent_id do
      nil ->
        # AC-39.2.2: agent_id is required UNCONDITIONALLY (channel_posts.agent_id
        # is NOT NULL). Unlike article_controller's conditional memory-metadata
        # gate, coordination authorship is always required — no row is persisted.
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
              "This API key has no agent identity; it cannot post an attributed channel message"
          }
        })

      agent_id ->
        write_post(conn, tenant_id, agent_id, params)
    end
  end

  defp write_post(conn, tenant_id, agent_id, params) do
    # Only caller-supplied fields are threaded through; project_id is validated
    # for ownership in the context, and audit carries the verified actor context.
    # agent_id/tenant_id in the body are never read.
    attrs = %{
      project_id: params["project_id"],
      body: params["body"],
      key: params["key"],
      refs: params["refs"],
      session_id: params["session_id"],
      host: params["host"],
      audit: AuditContext.from_conn(conn)
    }

    case Coordination.post(tenant_id, agent_id, attrs) do
      {:ok, post, :created} ->
        conn
        |> put_status(:created)
        |> json(%{post: post})

      {:ok, post, :updated} ->
        conn
        |> put_status(:ok)
        |> json(%{post: post})

      {:error, :not_found} ->
        # AC-39.2.3: missing AND cross-tenant collapse to one byte-identical 422.
        emit_security_event(:ownership_rejected, %{
          tenant_id: tenant_id,
          agent_id: agent_id,
          project_id: params["project_id"]
        })

        {:error, :unprocessable_entity, @ownership_error_message}

      {:error, :agent_not_found} ->
        # Defense-in-depth: the key's server-stamped agent_id does not belong to
        # this tenant (a misconfigured key — the agent FKs are non-composite, so
        # the DB alone would accept the mis-attributed row). This is an IDENTITY
        # fault, not a project probe, so it emits the :agent_identity_required
        # signal + a 403 — never the :ownership_rejected project signal — keeping
        # the two failure modes correctly attributed.
        emit_security_event(:agent_identity_required, %{
          tenant_id: tenant_id,
          agent_id: agent_id,
          project_id: params["project_id"]
        })

        conn
        |> put_status(:forbidden)
        |> json(%{
          error: %{
            status: 403,
            code: "agent_identity_required",
            message:
              "This API key's agent identity is not valid for this tenant; it cannot post an attributed channel message"
          }
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # --- Rate limiting (function plug) ---

  defp rate_limit_write(conn, _opts) do
    api_key = conn.assigns.current_api_key
    tenant = conn.assigns[:current_tenant]
    limit = write_limit(tenant)
    identifier = "channel_post_write:key:#{api_key.id}"

    case check_rate(identifier, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        reset_at = window_reset_at()
        retry_after = max(1, reset_at - System.system_time(:second))

        emit_security_event(:rate_limited, %{
          tenant_id: api_key.tenant_id,
          api_key_id: api_key.id
        })

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{error: %{status: 429, message: "Rate limit exceeded"}})
        |> halt()
    end
  end

  # Reuse the RateLimiter behaviour seam (config-based DI). Fail OPEN on any
  # limiter fault — a limiter outage must degrade to "no gate", never block
  # writes — but route every fail-open through the SHARED throttled, PII-safe
  # `FailOpenLog` (full parity with LoopctlWeb.Plugs.RateLimiter) so a sustained
  # write-cap limiter outage stays observable (AC-39.2.9) instead of being
  # silently swallowed.
  defp check_rate(identifier, limit) do
    case Loopctl.RateLimiter.impl().check_rate(identifier, @write_window_ms, limit) do
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

  # Degrade to "no gate" on a limiter fault, but emit a throttled, PII-safe warning
  # (the bucket family reduces to `channel_post_write:key`, UUID suffix stripped)
  # so the outage is not invisible.
  defp fail_open(identifier, detail) do
    FailOpenLog.warn(:coordination, identifier, detail)
    {:allow, 0}
  end

  defp write_limit(nil), do: default_write_limit()

  defp write_limit(tenant) do
    configured =
      tenant
      |> Tenants.get_tenant_settings("channel_post_write_limit_per_minute", default_write_limit())
      |> coerce_positive_int(default_write_limit())

    # AC-39.2.8/9: the coordination write cap must remain a TIGHTER constraint than
    # the generic per-key pipeline limiter (LoopctlWeb.Plugs.RateLimiter), which
    # runs FIRST in the pipeline and emits no coordination-specific security signal.
    # If a tenant set this above the pipeline limit, every coordination rate-limit
    # trip would be shadowed by an anonymous pipeline 429 — blinding the AC-39.2.9
    # abuse detectors. Clamp so the coordination cap can never exceed (and thus be
    # shadowed by) the pipeline cap.
    min(configured, pipeline_per_key_limit(tenant))
  end

  defp default_write_limit do
    Application.get_env(:loopctl, :channel_post_write_limit_per_minute, @default_write_limit)
  end

  # The generic per-key pipeline limit that runs before this controller plug. Read
  # from the SAME tenant setting the pipeline limiter uses; default kept in sync
  # with LoopctlWeb.Plugs.RateLimiter's @default_per_key_limit.
  defp pipeline_per_key_limit(tenant) do
    tenant
    |> Tenants.get_tenant_settings(
      "rate_limit_requests_per_minute",
      @pipeline_per_key_limit_default
    )
    |> coerce_positive_int(@pipeline_per_key_limit_default)
  end

  # A tenant setting stored as a non-integer (e.g. the JSON string "3") would
  # silently NEUTER the cap: `get_tenant_settings/3` is a bare Map.get on raw jsonb,
  # so the Hammer limiter would then compare via Elixir term ordering (every integer
  # < every binary → never denies) and the Postgres limiter's `is_integer` guard
  # would raise (swallowed to fail-open). Coerce an integer or an integer STRING to
  # a positive integer; a zero/negative/garbage value falls back to `default`.
  defp coerce_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp coerce_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp coerce_positive_int(_value, default), do: default

  defp window_reset_at do
    now = System.system_time(:second)
    (div(now, 60) + 1) * 60
  end

  # --- Security telemetry (AC-39.2.9) ---

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
