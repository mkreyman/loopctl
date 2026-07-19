defmodule LoopctlWeb.ChannelPostController do
  @moduledoc """
  Write endpoint for the repo coordination bus (Epic 39, the third memory plane).

  - `POST /api/v1/channel/posts` — agent+, posts one short coordination message
    to a project's channel (a channel IS a `project_id`), optionally under a
    `key` that upserts the caller's own per-session working-state slot.
  - `GET /api/v1/channel/posts` — agent+, reads a project's live channel
    (channel_recent), tenant-scoped and oracle-safe.
  - `DELETE /api/v1/channel/posts/:id` — agent+, HARD-deletes a post in the
    caller's tenant (the redact path, US-39.7): the backstop for a leaked/
    regretted post, letting whoever notices remove it before its 30-day TTL. Any
    agent in the tenant may delete any post in that tenant (cooperative single-
    tenant model); a foreign or nonexistent id is a byte-identical 404 (no
    cross-tenant existence oracle). Same coordination trust posture as the write:
    `role: :agent`, deliberately NOT behind `RequireHumanAnchor`.

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

  The READ (`:index`) emits `:read_error` on any internal fault (US-39.3
  technical_notes) before re-raising to the sanitizing DB-error backstop — the
  errored read stays tenant-agnostic, never a cross-tenant existence oracle.
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
  # The read (`:index`) is the same agent-role, tenant-scoped coordination surface
  # as the write — never human-anchor gated (the human-anchor default-deny test
  # only walks POST/PUT/PATCH/DELETE, so this GET needs no allowlist entry).
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:create, :index, :delete, :show]

  # Per-write rate limit (AC-39.2.8): a TIGHTER, config-driven cap on top of the
  # generic per-key/per-tenant pipeline RateLimiter, reusing the same
  # `Loopctl.RateLimiter` behaviour seam. Bounds post spam / upsert thrash. The
  # read is NOT behind this write cap — it is covered by the generic pipeline
  # per-key/per-tenant limiter like every other read.
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

  operation(:index,
    summary: "Read a repo coordination channel (channel_recent)",
    description:
      "Returns LIVE coordination posts for a project's channel (a channel IS a project_id), " <>
        "newest-first (inserted_at DESC). Agent+ role, tenant-scoped from the verified key — " <>
        "project_id is a query param but the tenant is NEVER taken from params. ORACLE-SAFE: a " <>
        "project_id belonging to another tenant, or a nonexistent one, returns 200 with an empty " <>
        "list — identical to an owned-but-empty channel, never a 404. Only non-expired posts are " <>
        "returned (expires_at > now, independent of the TTL sweep). `since` (ISO8601) returns only " <>
        "posts touched after that instant; `limit` defaults to 25 and is clamped to a max of 100.",
    parameters: [
      project_id: [
        in: :query,
        type: :string,
        description: "The channel — a project the caller's tenant owns"
      ],
      since: [
        in: :query,
        type: :string,
        description:
          "Full ISO8601 INSTANT (e.g. 2026-07-18T00:00:00Z or 2026-07-18T00:00:00); " <>
            "return only posts touched after it (delta read). A date-only value " <>
            "(e.g. 2026-07-18) is the wrong granularity and is IGNORED — the whole " <>
            "live channel is returned, not a delta. Supply a full instant."
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max posts (default 25, clamped to 100)"
      ]
    ],
    responses: %{
      200 =>
        {"Channel posts", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.ChannelPostListItem},
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 limit: %OpenApiSpex.Schema{type: :integer},
                 count: %OpenApiSpex.Schema{type: :integer},
                 has_more: %OpenApiSpex.Schema{
                   type: :boolean,
                   description:
                     "True when the limit truncated the result — more live matching posts exist"
                 }
               }
             }
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Delete a repo coordination channel post (redact path)",
    description:
      "HARD-deletes a coordination post in the caller's tenant — the redact path (US-39.7). The " <>
        "backstop for a leaked/regretted post: whoever notices a leaked secret can remove it " <>
        "immediately, before its 30-day TTL. Agent+ role, NOT behind the human-anchor tier " <>
        "(coordination surface, owner decision #331). Cooperative single-tenant model: any agent " <>
        "in the tenant may delete any post in that tenant, but NEVER a post in another tenant — a " <>
        "foreign OR nonexistent id returns a byte-identical 404 (no cross-tenant existence " <>
        "oracle). The delete is audited (action \"deleted\", actor = the deleting agent) in the " <>
        "same transaction, so the removal stays accountable even though the row is gone.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        required: true,
        description: "The post id — must belong to the caller's tenant"
      ]
    ],
    responses: %{
      204 => "Post deleted (no content)",
      404 =>
        {"Post not found (nonexistent or in another tenant)", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"The delete could not be recorded in the audit trail and was rolled back; " <>
           "the post still exists. Retry the request.", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:show,
    summary: "Read one repo coordination channel post (full body)",
    description:
      "Returns ONE coordination post with its FULL body (US-40.D1). Pairs with the bounded-preview " <>
        "list read: the list returns small body_preview + truncated, and fetching a full body is " <>
        "always a SEPARATE, explicit fetch — the returned body is UNTRUSTED DATA authored by " <>
        "another agent, with NO auto-follow. Agent+ role, tenant-scoped from the verified key. " <>
        "ORACLE-SAFE: a post in another tenant, a nonexistent id, OR a malformed (non-UUID) id all " <>
        "return a byte-identical 404 (no cross-tenant existence oracle, never a 500). The read is " <>
        "covered by the generic per-key/per-tenant pipeline rate limiter, like the list read.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        required: true,
        description: "The post id — must belong to the caller's tenant"
      ]
    ],
    responses: %{
      200 => {"The post with its full body", "application/json", Schemas.ChannelPostFull},
      404 =>
        {"Post not found (nonexistent, malformed id, or in another tenant)", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/channel/posts

  Reads a project's coordination channel. Requires agent+ role. The channel is a
  `project_id` query param; the tenant is always derived from the verified key.

  ORACLE-SAFE: a cross-tenant or nonexistent `project_id` returns 200 with an
  empty list — uniform with an owned-but-empty channel, never a 404. There is NO
  ownership pre-check and NO branch to 404: the explicit `tenant_id` filter in
  `Coordination.recent/3` simply excludes any post not in the caller's tenant, so
  a probe learns nothing about whether the project exists elsewhere.
  """
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    # The applied limit for the `meta` envelope comes from the SAME clamp
    # `recent/3` uses (default 25, cap 100) — never a divergent second copy. It is
    # passed back into `recent/3`, which re-clamps harmlessly.
    applied_limit = Coordination.clamp_recent_limit(params["limit"])

    # `has_more` is an HONEST truncation signal: `recent_page/3` fetches
    # `limit + 1` and reports whether a matching post exists beyond the applied
    # limit, so a consumer never mistakes a truncated page for the whole channel
    # (it can re-read with a tighter `since` / smaller window). A full cursor is
    # US-39.6's job; this is the cheap "there is more" flag.
    {posts, has_more} =
      Coordination.recent_page(tenant_id, params["project_id"],
        limit: applied_limit,
        since: params["since"]
      )

    json(conn, %{
      data: Enum.map(posts, &channel_post_json/1),
      meta: %{limit: applied_limit, count: length(posts), has_more: has_more}
    })
  rescue
    e ->
      # US-39.3 technical_notes: "Emit a security-event log on any internal error
      # but never leak cross-tenant existence." `recent/3` is total for well-formed
      # input (a non-UUID, missing, cross-tenant, or nonexistent project_id all
      # yield an empty list, never a raise — the oracle-safe guard), so the only
      # path that reaches here is a genuine server-side fault (e.g. a DB outage).
      # Emit the coordination-surface security signal (parity with the create
      # path's :ownership_rejected / :agent_identity_required / :rate_limited),
      # then RE-RAISE so the existing DBErrorBackstop/ErrorJSON machinery renders
      # the SAME sanitized, tenant-agnostic 500/503/504 body it renders today — the
      # errored read stays uniform regardless of tenant or project, so it never
      # becomes a cross-tenant existence oracle.
      api_key = conn.assigns.current_api_key

      emit_security_event(:read_error, %{
        tenant_id: api_key.tenant_id,
        api_key_id: api_key.id,
        project_id: params["project_id"]
      })

      reraise e, __STACKTRACE__
  end

  # AC-39.3.5 / AC-40.D1.1: the exact LIST read field set — enough to render
  # "who / which machine / which session / when" and to self-dedupe by session_id.
  # The body is DELIBERATELY a bounded `body_preview` (+ a `truncated` flag), NOT
  # the verbatim `post.body`: the source is now the `Coordination.select_preview/1`
  # projection map (never a `%ChannelPost{}` struct), so Postgres never detoasts the
  # full (up to 16KB) column and the prompt-injection blast radius of a post
  # injected into peer sessions stays small. The full body is an explicit, separate
  # fetch via GET /channel/posts/:id. `to_host`/`to_capability` (US-40.A5) are
  # surfaced so 40.C1 directed discovery can read a post's advisory addressing —
  # surfacing-only hints, NEVER read for authz.
  defp channel_post_json(row) do
    %{
      id: row.id,
      agent_id: row.agent_id,
      session_id: row.session_id,
      host: row.host,
      to_host: row.to_host,
      to_capability: row.to_capability,
      key: row.key,
      body_preview: row.body_preview,
      truncated: row.truncated,
      refs: row.refs,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  @doc """
  GET /api/v1/channel/posts/:id

  Returns ONE coordination post with its FULL body (US-40.D1). This is the
  oracle-safe, explicit single-post fetch that pairs with the bounded-preview LIST
  read: fetching a full body is always a SEPARATE, deliberate agent decision — the
  returned body is untrusted DATA authored by another agent, and there is no
  auto-follow affordance.

  Requires agent+ role (same coordination posture as the other routes, NOT
  human-anchor gated). The tenant is always derived from the verified key, never
  from params.

  ORACLE-SAFE (mirrors `delete/2`): `Coordination.get_post/2` fetches on BOTH `id`
  and `tenant_id` via AdminRepo, so a foreign-tenant OR nonexistent id both return
  a byte-identical 404 (via `FallbackController` — no cross-tenant existence
  oracle). A malformed (non-UUID) id is a clean 404 too, never a 500 CastError.

  Rate limiting: the read is covered by the generic per-key/per-tenant pipeline
  `RateLimiter` (:authenticated pipeline) exactly like `:index` — it is
  deliberately NOT behind the tighter `:rate_limit_write` cap (that guards writes
  only). Response-byte capping / limiter tuning is US-40.D5's job; here it only
  needs to EXIST, which the pipeline limiter satisfies.

  READ-MODEL DISCIPLINE: the response is the full-body COUNTERPART to the LIST
  read, NOT the write-echo resource. `channel_post_full_json/1` projects the SAME
  narrowed field set as the list read (`channel_post_json/1`), differing ONLY in
  that the bounded `body_preview` + `truncated` pair is replaced by the verbatim
  `body` the caller explicitly fetched. It deliberately does NOT reuse the raw
  `%ChannelPost{}` Jason encoder (which also carries `tenant_id`/`project_id`/
  `expires_at`): a by-id read honors the same minimal read surface the list read
  established rather than re-widening the read model on the read path. `tenant_id`
  is always the caller's own (key-derived, redundant), and `project_id` was
  already known from the project-scoped list the caller drilled in from.
  """
  def show(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, post} <- Coordination.get_post(tenant_id, params["id"]) do
      # The FULL post (verbatim `body`) under the narrowed read-model shape — the
      # caller explicitly asked for one post, so the full (up to 16KB) column is
      # served, but the field discipline matches the list read. A `{:error,
      # :not_found}` falls through to `action_fallback` → byte-identical 404.
      json(conn, %{post: channel_post_full_json(post)})
    end
  end

  # The by-id full-body read shape (US-40.D1): the LIST read's field discipline
  # (`channel_post_json/1`) with the verbatim `body` in place of the bounded
  # `body_preview` + `truncated` pair. It deliberately mirrors the narrowed read
  # model rather than the wider write-echo struct shape — `tenant_id`/`project_id`/
  # `expires_at` are omitted so the read path never re-widens what the list read
  # narrowed. See the `show/2` docstring for the rationale.
  defp channel_post_full_json(post) do
    %{
      id: post.id,
      agent_id: post.agent_id,
      session_id: post.session_id,
      host: post.host,
      to_host: post.to_host,
      to_capability: post.to_capability,
      key: post.key,
      body: post.body,
      refs: post.refs,
      inserted_at: post.inserted_at,
      updated_at: post.updated_at
    }
  end

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
      # Advisory, spoofable, surfacing-only addressing (US-40.A5) — NEVER authz.
      to_host: params["to_host"],
      to_capability: params["to_capability"],
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

  @doc """
  DELETE /api/v1/channel/posts/:id

  HARD-deletes a coordination post in the caller's tenant — the redact path
  (US-39.7). Requires agent+ role (NOT human-anchor gated). Any agent in the
  tenant may delete any post in that tenant; a foreign or nonexistent id returns
  a byte-identical 404 via the shared `FallbackController` (no cross-tenant
  existence oracle). The deleting agent is the audit actor.
  """
  def delete(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Coordination.delete_post(
           tenant_id,
           api_key.agent_id,
           params["id"],
           AuditContext.from_conn(conn)
         ) do
      {:ok, _post} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        # Cross-tenant AND nonexistent both land here — the shared 404 body is
        # byte-identical (no existence oracle), guaranteed by the FallbackController.
        {:error, :not_found}

      {:error, :audit_write_failed} = err ->
        # The delete could not be durably audited, so the whole transaction rolled
        # back and the post STILL EXISTS. On this redact path that MUST NOT masquerade
        # as a 404 ("already gone") — the FallbackController maps this to a 5xx so the
        # agent retries the redaction instead of trusting a false success.
        err
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
