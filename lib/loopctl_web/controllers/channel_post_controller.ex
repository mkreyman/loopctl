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
    regretted post, letting the AUTHOR pull it back before its 30-day TTL.
    Author-only (or elevated role) — the redact path is for self-leak-pullback,
    NOT fleet-wide cleanup (US-40.D2): the caller must be the post's own author
    (server-stamped `agent_id`) OR hold an elevated role (`>= :user`, the
    operator escape hatch). A non-author agent gets a byte-identical 404 (no
    existence oracle) — same as a foreign or nonexistent id. Coordination trust
    posture: `role: :agent` at the route (the elevated bypass is checked inside
    the action against the verified key), deliberately NOT behind
    `RequireHumanAnchor`.

  - `GET /api/v1/channel/posts/quarantined` — role `:user` + human-anchored, the
    OPERATOR review read for issue #499: the only path that resolves posts the
    retroactive secret rescan quarantined (every agent-facing read hides them),
    returning full bodies so a human can judge true vs false positive. Anchored for
    the same reason as `:release` — it is the one endpoint that hands back the FULL
    body of a post confirmed to carry a credential shape.
  - `POST /api/v1/channel/posts/:id/release` — role `:user` + human-anchored, clears
    a quarantine (false-positive exoneration) and removes the row from the rescan
    candidate set for the current denylist revision. The non-destructive counterpart
    to DELETE.

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
  alias Loopctl.Coordination.ChannelCursor
  alias Loopctl.RateLimiter.FailOpenLog
  alias Loopctl.Tenants
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  # SINGLE SOURCE OF TRUTH for the agent-facing READ actions, shared by BOTH the
  # agent-role gate and the per-read rate cap below so the two can NEVER drift
  # apart: every read action is role-gated AND read-capped in lockstep, never a
  # body-returning read that is rate-limited but escapes controller-level role
  # enforcement (or vice versa). `:handoffs` (GET /channel/handoffs, 40.C1
  # directed discovery) is listed PROACTIVELY (AC-40.D5.1): when 40.C1 lands that
  # action ON THIS controller both guards attach automatically; until then the
  # guards simply never match the nonexistent action. If 40.C1 instead implements
  # handoffs in a SEPARATE controller, neither guard applies and 40.C1 MUST
  # re-apply the read cap there (cross-story invariant — see the 40.C1 review
  # note / wiki finding).
  @read_actions [:index, :show, :handoffs]

  # Coordination surface (#331): agent role, NO RequireHumanAnchor. See the
  # coordination-surface allowlist entry in require_human_anchor_default_deny_test.
  # The reads are the same agent-role, tenant-scoped coordination surface as the
  # write — never human-anchor gated (the human-anchor default-deny test only
  # walks POST/PUT/PATCH/DELETE, so these GETs need no allowlist entry).
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [:create, :delete, :graduate] or action in @read_actions

  # Per-write rate limit (AC-39.2.8): a TIGHTER, config-driven cap on top of the
  # generic per-key/per-tenant pipeline RateLimiter, reusing the same
  # `Loopctl.RateLimiter` behaviour seam. Bounds post spam / upsert thrash.
  # `:graduate` (US-40.E1) is a WRITE into the durable Knowledge plane — it reuses
  # the SAME per-write cap as `:create` (AC-40.E1.4: rate-bounded so it cannot
  # bulk-flood Knowledge from the channel). Per-api_key + per-tenant buckets only —
  # deliberately NO per-agent bucket (none exists). The generic pipeline per-key /
  # per-tenant limiter still runs first.
  plug :rate_limit_write when action in [:create, :graduate]

  # Per-read rate limit (AC-40.D5.1): a PARALLEL, config-driven cap on the
  # agent-facing read path — `:index` (channel_recent), `:show` (GET /:id, the
  # full-body fetch), and `:handoffs` (GET /channel/handoffs, 40.C1 directed
  # discovery — a body-returning read that must NOT escape the read limiter). It
  # reuses the SAME `Loopctl.RateLimiter` behaviour seam and the fail-open +
  # throttled FailOpenLog discipline as `rate_limit_write`, but on its own bucket
  # family (`channel_post_read:key`) so read and write abuse are independently
  # observable. The read is no longer covered ONLY by the generic pipeline
  # per-key/per-tenant limiter: this dedicated cap trips FIRST (clamped below the
  # pipeline cap) so a read burst emits the coordination `:rate_limited` signal
  # instead of being shadowed by an anonymous pipeline 429. Uses the SAME
  # `@read_actions` list as the RequireRole gate above — structural symmetry, so a
  # read action can never be role-gated without also being read-capped.
  plug :rate_limit_read when action in @read_actions

  # Issue #499 — the OPERATOR quarantine-review surface. Deliberately NOT part of
  # `@read_actions`: `:quarantined` returns the FULL bodies of posts the security
  # rescan flagged as carrying a credential shape, and `:release` un-hides such a
  # post. Both are human/operator judgement calls on a security finding, so they sit
  # at `role: :user` (an agent must never be able to read back — or resurrect — a
  # quarantined credential) and behind `RequireHumanAnchor`, matching the sibling
  # operator surface `LoopctlWeb.IngestionAnomalyController.update/2` where the
  # `:secret_detected` anomaly these posts raise is resolved.
  # The anchor covers BOTH actions, not just the state change: `:quarantined` is the one
  # endpoint that returns the FULL bodies of posts the rescan confirmed carry a credential
  # shape, so anchoring only the (less sensitive) `:release` would leave the credential
  # READ reachable by a `:user`-or-higher key in a tenant with no WebAuthn anchor.
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:quarantined, :release]
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:quarantined, :release]

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

  # Config-default per-minute READ cap (AC-40.D5.1); a tenant may override via the
  # `channel_post_read_limit_per_minute` setting, mirroring the write cap. Set
  # ABOVE the write default (reads are cheaper and more frequent) but still BELOW
  # the pipeline per-key default (@pipeline_per_key_limit_default 300) so the
  # coordination read cap stays the binding, observable constraint by default —
  # `read_limit/1` additionally clamps it below the tenant's live pipeline cap.
  @default_read_limit 240

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
        "append-only row (201). On the keyless path an OPTIONAL idempotency_key makes a " <>
        "retried append idempotent: a repeat write with the same (tenant, project, agent, " <>
        "idempotency_key) returns the EXISTING post (200, created:false) instead of " <>
        "appending a duplicate. expires_at is set server-side to now + 30 days.",
    request_body: {"Channel post params", "application/json", Schemas.ChannelPostRequest},
    responses: %{
      201 => {"Post created", "application/json", Schemas.ChannelPostResponse},
      200 =>
        {"Session slot upserted in place, or a keyless idempotent write deduplicated to " <>
           "the existing post (created:false)", "application/json", Schemas.ChannelPostResponse},
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
        "newest-first (inserted_at DESC, seq DESC). Agent+ role, tenant-scoped from the verified " <>
        "key — project_id is a query param but the tenant is NEVER taken from params. ORACLE-SAFE: " <>
        "a project_id belonging to another tenant, or a nonexistent one, returns 200 with an empty " <>
        "list — identical to an owned-but-empty channel, never a 404. Only non-expired posts are " <>
        "returned (expires_at > now, independent of the TTL sweep). Bodies are BOUNDED previews " <>
        "(body_preview + truncated), never full bodies — fetch a full body via GET " <>
        "/channel/posts/:id. `since` (ISO8601) returns only posts touched after that instant " <>
        "(delta read, with a bounded commit-lag look-back so a late-committing earlier row is " <>
        "re-delivered — AT-LEAST-ONCE with a small overlap the consumer dedups). `cursor` pages " <>
        "older history via the keyset `(inserted_at, seq)`: follow `meta.next_cursor` verbatim " <>
        "until it is null (exhausted). A cursor takes precedence over `since`. A tampered or " <>
        "cross-tenant cursor is rejected with 400. `limit` defaults to 25 and is clamped to 100.",
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
      cursor: [
        in: :query,
        type: :string,
        description:
          "Opaque keyset paging token. Omit for the newest page, then follow " <>
            "meta.next_cursor verbatim to page OLDER history by (inserted_at, seq). " <>
            "Tenant-bound and integrity-signed; a tampered or cross-tenant cursor " <>
            "returns 400. Takes precedence over `since`."
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
                 },
                 next_cursor: %OpenApiSpex.Schema{
                   type: :string,
                   nullable: true,
                   description:
                     "Opaque keyset paging token for the next OLDER page; null when history is " <>
                       "exhausted or in delta (`since`) mode. Follow it verbatim as `?cursor=`."
                 }
               }
             }
           }
         }},
      400 => {"Invalid or tampered cursor", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:handoffs,
    summary: "Discover directed, open, unclaimed handoffs (pinned)",
    description:
      "Returns DIRECTED, OPEN, UNCLAIMED handoffs for the caller (US-40.C1). A handoff is a post " <>
        "carrying a stable handoff:<anchor> key; this read surfaces EVERY open, unclaimed handoff " <>
        "on the channel by default — NOT filtered to the caller's host/capabilities. Each row carries " <>
        "a `directed_to_me` boolean so the caller can sort/surface relevant ones locally. An explicit " <>
        "`only_mine=true` opt-in narrows to handoffs addressed to the caller's host/capabilities (or " <>
        "unaddressed BROADCAST handoffs). It is a SEPARATE, PINNED set — NOT interleaved into and NOT " <>
        "subject to the newest-N recency truncation of channel_recent (GET /channel/posts), so a directed " <>
        "handoff is ALWAYS returned even when 100 newer status posts exist. Ordered newest-unclaimed-" <>
        "first so a refreshed handoff (corrected instructions from a new session) wins over the stale one. " <>
        "A claim that is DONE keeps the handoff EXCLUDED (done is terminal); only a RELEASED claim or a " <>
        "lease expired WITHOUT completion reopens it. Agent+ role, tenant-scoped from the verified key — " <>
        "project_id is a query param but the tenant is NEVER taken from params. ORACLE-SAFE: a project_id " <>
        "belonging to another tenant, a nonexistent one, or a malformed one all return 200 with an empty " <>
        "list, never a 404. Bodies are BOUNDED previews (body_preview + truncated) framed as UNTRUSTED " <>
        "DATA authored by another agent — never full bodies; fetch a full body via GET /channel/posts/:id. " <>
        "One row per LOGICAL handoff: duplicate pointers for the same key from different sessions are deduped, " <>
        "so meta.count counts logical handoffs. meta.overflow is true only on a pathological channel " <>
        "that hit the hard safety cap (the oldest directed handoffs are dropped newest-first) — " <>
        "read the channel directly when it is set.",
    parameters: [
      project_id: [
        in: :query,
        type: :string,
        description: "The channel — a project the caller's tenant owns"
      ],
      host: [
        in: :query,
        type: :string,
        description:
          "The caller's host (advisory hint). Surfaces handoffs directed to this host. " <>
            "Filters WHAT is shown, never WHO may read."
      ],
      capabilities: [
        in: :query,
        type: :string,
        description:
          "The caller's capabilities as a comma-separated list (e.g. fly-auth,windows-signing), " <>
            "or repeated capabilities[] params. Surfaces handoffs directed to any of these " <>
            "capabilities. Advisory — filters WHAT is shown, never WHO may read."
      ],
      only_mine: [
        in: :query,
        type: :boolean,
        description:
          "When true, narrow the results to handoffs directed to the caller's host/capabilities " <>
            "or unaddressed BROADCAST handoffs. Default is false (see-everything)."
      ]
    ],
    responses: %{
      200 =>
        {"Directed handoffs (pinned, not truncated)", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.ChannelPostListItem},
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 count: %OpenApiSpex.Schema{type: :integer},
                 overflow: %OpenApiSpex.Schema{
                   type: :boolean,
                   description:
                     "True when the pinned set hit the hard safety cap and the OLDEST " <>
                       "directed handoffs were dropped (newest-first) — read the channel directly."
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
        "backstop for a leaked/regretted post: the AUTHOR can pull it back before its 30-day TTL. " <>
        "Agent+ role, NOT behind the human-anchor tier (coordination surface, owner decision " <>
        "#331). Author-only (or elevated role) — the redact path is for self-leak-pullback, NOT " <>
        "fleet-wide cleanup (US-40.D2): the caller must be the post's own author (server-stamped " <>
        "agent_id) OR hold an elevated role (>= user). A non-author agent gets a byte-identical " <>
        "404 (no existence oracle) — same as a foreign or nonexistent id. The delete is audited " <>
        "(action \"deleted\", actor = the deleting agent) in the same transaction, so the removal " <>
        "stays accountable even though the row is gone.",
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

  operation(:quarantined,
    summary: "List QUARANTINED coordination posts (operator review)",
    description:
      "Lists the tenant's quarantined posts — rows the retroactive secret rescan " <>
        "(Loopctl.Workers.ChannelPostRescanWorker, issue #499) flagged as carrying a " <>
        "credential shape under the CURRENT denylist, typically written before that pattern " <>
        "existed. A quarantined post is hidden from EVERY other read (list, by-id, directed " <>
        "handoffs) so it stops being injected into new sessions, and the matching " <>
        "secret_detected ingestion anomaly carries FIELD NAMES only — this endpoint is the " <>
        "ONLY way an operator can see the actual rows the alert's post_ids point at, judge " <>
        "true vs false positive, and then either redact them (DELETE /channel/posts/:id) or " <>
        "exonerate them (POST /channel/posts/:id/release). It therefore returns FULL bodies " <>
        "and is role :user + human-anchored — never the agent-role coordination surface. It " <>
        "returns every field the rescan scans (body, key, session_id, host, to_host, " <>
        "to_capability, idempotency_key, refs), so a quarantine_reason naming any of them is " <>
        "reviewable. Newest quarantine first; optional project_id filter; limit defaults to " <>
        "25 and is clamped to 100 — meta.limit reports the CLAMPED value actually applied.",
    parameters: [
      project_id: [
        in: :query,
        type: :string,
        description: "Optional: restrict to one project channel"
      ],
      limit: [in: :query, type: :integer, description: "Max rows (default 25, clamped to 100)"]
    ],
    responses: %{
      200 =>
        {"Quarantined posts", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      403 => {"Requires user role / human anchor", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:release,
    summary: "RELEASE a quarantined coordination post (false-positive exoneration)",
    description:
      "Clears the quarantine on a post the secret rescan flagged (issue #499), making it " <>
        "readable on the channel again. The counterpart to the redact path: DELETE when the " <>
        "flag was right, release when it was WRONG — the denylist is a prefix HEURISTIC, and " <>
        "without this the only remedy for a false positive is the destructive one quarantine " <>
        "exists to avoid. The release is durable but revision-SCOPED: the post leaves the " <>
        "rescan candidate set for the CURRENT denylist revision, so the next hourly run " <>
        "cannot re-flag it under the same patterns, while a later revision (a new credential " <>
        "shape) re-examines it. It also rolls back the quarantine review TTL extension, so an " <>
        "exonerated post does not outlive normal retention. Role :user + human-anchored (an agent must never be able to un-hide a post " <>
        "the security rescan quarantined). Audited in-transaction (action " <>
        "\"quarantine_released\", carrying the cleared field-name reason). A nonexistent, " <>
        "foreign-tenant, malformed, or NOT-currently-quarantined id all return a " <>
        "byte-identical 404.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        required: true,
        description: "The quarantined post id — must belong to the caller's tenant"
      ]
    ],
    responses: %{
      200 => {"The released post", "application/json", Schemas.ChannelPostFull},
      403 => {"Requires user role / human anchor", "application/json", Schemas.ErrorResponse},
      404 =>
        {"No such quarantined post (nonexistent, malformed, another tenant, or not quarantined)",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      500 =>
        {"The release could not be recorded in the audit trail and was rolled back; the post " <>
           "is still quarantined. Retry the request.", "application/json", Schemas.ErrorResponse}
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
        "behind the dedicated per-read coordination rate cap (channel_post_read_limit_per_minute, " <>
        "US-40.D5), on its own bucket separate from the write cap, like the list read.",
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

  operation(:graduate,
    summary: "Graduate a coordination post into the durable Knowledge wiki",
    description:
      "Promotes ONE coordination post into the durable Knowledge wiki (US-40.E1). CONTENT-SELECTIVE: " <>
        "this is for a genuinely REUSABLE finding that has no external tracker — NOT the general " <>
        "handoff-durability answer. A transient directive (e.g. 'run this SQL') should be LEFT TO " <>
        "EXPIRE (posts auto-expire in 30 days); a reusable lesson graduates. There is NO automatic " <>
        "graduation — this is always an explicit, deliberate agent call. `title` is REQUIRED; the " <>
        "body is carried from the post, project_id is carried over, `tags` are optional. Agent+ " <>
        "role, project-scoped by membership (US-40.D3), NOT human-anchor gated (coordination surface, " <>
        "owner decision #331). Reuses Knowledge's EXISTING guardrails — the SEMANTIC NOVELTY gate " <>
        "(a near-duplicate returns 200 deduplicated and creates nothing) plus an explicit secret " <>
        "scan over the body (a denylisted credential shape returns 422 and nothing lands) — never a " <>
        "bypass. The article carries source_type 'channel_graduation' + source_id = the post id, " <>
        "attributed to the graduating agent. The source post is KEPT (the 30-day TTL sweep reclaims " <>
        "it); it is NOT marked graduated. Rate-bounded by the per-write cap so it cannot bulk-flood " <>
        "Knowledge from the channel.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        required: true,
        description: "The post id — must belong to the caller's tenant"
      ]
    ],
    request_body:
      {"Graduation params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:title],
         properties: %{
           title: %OpenApiSpex.Schema{
             type: :string,
             description: "The Knowledge article title (required)"
           },
           category: %OpenApiSpex.Schema{
             type: :string,
             description:
               "Optional article category; defaults to 'finding' (a reusable lesson) when omitted",
             default: "finding"
           },
           tags: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string},
             description: "Optional topical tags for the article"
           }
         }
       }},
    responses: %{
      201 =>
        {"Article created from the post", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      200 =>
        {"A near-duplicate already exists; nothing created (deduplicated)", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      403 => {"Agent identity required", "application/json", Schemas.ErrorResponse},
      404 =>
        {"Post not found (nonexistent, malformed id, in another tenant, or not a project member)",
         "application/json", Schemas.ErrorResponse},
      409 =>
        {"Title conflicts with an existing active article that has different content",
         "application/json", Schemas.ErrorResponse},
      422 =>
        {"Validation error, or the title/tags/body carry a denylisted secret", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"Novelty gate temporarily unavailable (embedding backend down); nothing graduated, retry",
         "application/json", Schemas.ErrorResponse}
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

    case resolve_cursor(tenant_id, params) do
      {:ok, cursor} ->
        # `has_more` is an HONEST truncation signal: `recent_page/3` fetches
        # `limit + 1` and reports whether a matching post exists beyond the applied
        # limit. `next_cursor` (US-40.C2) is the keyset paging token — the
        # `(inserted_at, seq)` of the last row when more HISTORY remains (null when
        # exhausted, or in delta/`since` mode). A consumer follows it verbatim to
        # walk the full live channel without gaps or dups.
        {posts, has_more, next_cursor} =
          Coordination.recent_page(tenant_id, params["project_id"],
            limit: applied_limit,
            since: params["since"],
            cursor: cursor
          )

        json(conn, %{
          data: Enum.map(posts, &channel_post_json/1),
          meta: %{
            limit: applied_limit,
            count: length(posts),
            has_more: has_more,
            next_cursor: encode_cursor(tenant_id, next_cursor)
          }
        })

      :error ->
        # A tampered, cross-tenant, or malformed cursor decodes to {:error, :invalid}
        # (TC-5). Reject with a 400 rather than silently resetting to the newest page,
        # so a forged cursor never surfaces cross-tenant rows and the client learns to
        # follow `next_cursor` verbatim. Uniform for any bad cursor — no oracle.
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            code: "invalid_cursor",
            message:
              "Invalid or tampered cursor. Omit `cursor` for the newest page, then " <>
                "follow `meta.next_cursor` verbatim to page older history."
          }
        })
    end
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
    base = %{
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
      # US-454 (defect 3): supersession marker — non-null = retired, value is
      # the successor's id.
      superseded_by: row.superseded_by,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }

    # US-454 (defect 2): the advisory discovery label rides ONLY on the
    # handoffs read (the context puts it on those rows); the history read's
    # field set stays exactly as narrow as before.
    if Map.has_key?(row, :directed_to_me) do
      Map.put(base, :directed_to_me, row.directed_to_me)
    else
      base
    end
  end

  # Resolve the `?cursor=` param (US-40.C2) to a `{:ok, position_or_nil}` for
  # `recent_page/3`, or `:error` for a bad cursor (→ 400). Mirrors the change-feed
  # `resolve_seek/2` convention:
  #   - cursor ABSENT    → {:ok, nil} (newest page / delta by `since`)
  #   - cursor EMPTY ""  → {:ok, nil} (treat `cursor=` like "start")
  #   - cursor a token   → decode + verify with the CALLER's tenant key; a
  #                        forged/tampered/cross-tenant/cross-namespace token fails
  #                        verification → :error (TC-5), never a silent reset
  #   - cursor non-string → :error
  defp resolve_cursor(tenant_id, params) do
    case Map.fetch(params, "cursor") do
      :error ->
        {:ok, nil}

      {:ok, ""} ->
        {:ok, nil}

      {:ok, raw} when is_binary(raw) ->
        case ChannelCursor.decode(tenant_id, raw) do
          {:ok, position} -> {:ok, position}
          {:error, :invalid} -> :error
        end

      {:ok, _non_string} ->
        :error
    end
  end

  defp encode_cursor(_tenant_id, nil), do: nil

  defp encode_cursor(tenant_id, {%DateTime{}, seq} = position) when is_integer(seq),
    do: ChannelCursor.encode(tenant_id, position)

  @doc """
  GET /api/v1/channel/handoffs

  Directed-handoff discovery read (US-40.C1): surfaces DIRECTED, OPEN, UNCLAIMED
  handoffs for the caller as a SEPARATE, PINNED set — never interleaved into or
  truncated by the newest-N `channel_recent` recency preview. Requires agent+ role
  (same coordination posture as the other reads, NOT human-anchor gated) and is
  behind the dedicated per-read rate cap (`rate_limit_read`, shared with `:index`/
  `:show`) — see `@read_actions`.

  The channel is a `project_id` query param; the tenant is ALWAYS derived from the
  verified key. `host` and `capabilities` are ADVISORY filters (spoofable surfacing
  hints — see the `ChannelPost` trust boundary): they shape WHAT is shown, NEVER
  WHO may read. `capabilities` is accepted either as a comma-joined string
  (`?capabilities=fly-auth,windows-signing`) or as a repeated/array param, and is
  normalized by the context.

  ORACLE-SAFE: `Coordination.directed_handoffs/3` returns `[]` for a cross-tenant,
  nonexistent, OR malformed `project_id` — so this action never 404s and has no
  ownership pre-check, uniform with `:index`. Renders the SAME bounded-preview
  `channel_post_json/1` shape (body_preview + truncated, includes to_host/
  to_capability). The set is pinned, so there is no `limit`/`next_cursor` — it is
  NEVER truncated by the newest-N recency cutoff. `meta` carries `count` plus an
  `overflow` boolean: on a pathological channel the set is bounded by a large hard
  safety cap (`Coordination.max_directed_handoffs/0`), and because it is ordered
  newest-first that cap drops the OLDEST directed handoffs — `overflow: true` tells
  the caller the pinned set was truncated and it should read the channel directly.
  Multiple pointer rows for the same logical handoff (same key from different
  sessions) are deduped to one row by the context, so `count` reflects LOGICAL
  handoffs.
  """
  def handoffs(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    {handoffs, overflowed?} =
      Coordination.directed_handoffs_page(tenant_id, params["project_id"], %{
        host: params["host"],
        capabilities: params["capabilities"],
        # US-454 (defect 2): DEFAULT is every open, unclaimed handoff on the
        # channel, each labelled `directed_to_me`. `only_mine=true` is the
        # explicit opt-in narrow view (addressed to me / broadcast only).
        only_mine: params["only_mine"] in ["true", "1", true]
      })

    json(conn, %{
      data: Enum.map(handoffs, &channel_post_json/1),
      meta: %{count: length(handoffs), overflow: overflowed?}
    })
  rescue
    e ->
      # Parity with the :index action's read-error telemetry (AC-40.D5).
      # `directed_handoffs_page/3` is total for well-formed input, so the only
      # path here is a genuine server-side fault (e.g. DB outage).
      api_key = conn.assigns.current_api_key

      emit_security_event(:read_error, %{
        tenant_id: api_key.tenant_id,
        api_key_id: api_key.id,
        project_id: params["project_id"]
      })

      reraise e, __STACKTRACE__
  end

  # US-454 (defect 1 fix 3): write-path provenance the sender MUST see. When the
  # server rescued the write — derived the handoff key from the body because no
  # `key` was sent, and/or minted a surrogate session_id because the proxy
  # supplied none (no CLAUDE_SESSION_ID) — the markers say so LOUDLY in the
  # response instead of letting the sender believe it made a fully-keyed,
  # session-deduped post. Both nil on a normal client-driven write.
  defp post_write_meta(post) do
    %{
      key_source: Map.get(post, :key_source),
      session_id_source: Map.get(post, :session_id_source)
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

  Rate limiting: the read is behind the dedicated per-read coordination cap
  (`rate_limit_read`, US-40.D5) exactly like `:index` — a config-driven,
  tenant-overridable per-minute cap on its OWN `channel_post_read:key` bucket,
  clamped below the generic pipeline per-key limiter so a read burst trips the
  coordination `:rate_limited` signal first. It is deliberately NOT on the write
  bucket (`:rate_limit_write` guards writes only) — read and write abuse are
  independently observable. Response bytes are bounded by construction: this read
  returns exactly one post whose `body` is <= @body_max_length (16KB).

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
      superseded_by: post.superseded_by,
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
        write_post(conn, tenant_id, agent_id, api_key.role, params)
    end
  end

  defp write_post(conn, tenant_id, agent_id, role, params) do
    # Only caller-supplied fields are threaded through; project_id is validated
    # for ownership in the context, and audit carries the verified actor context.
    # agent_id/tenant_id in the body are never read.
    attrs = %{
      project_id: params["project_id"],
      body: params["body"],
      key: params["key"],
      # OPTIONAL client idempotency token for the KEYLESS write path (US-40.B2):
      # when supplied without a `key`, a repeat write with the same
      # (tenant, project, agent, idempotency_key) returns the existing post
      # (created:false) instead of appending a duplicate.
      idempotency_key: params["idempotency_key"],
      refs: params["refs"],
      session_id: params["session_id"],
      host: params["host"],
      # Advisory, spoofable, surfacing-only addressing (US-40.A5) — NEVER authz.
      to_host: params["to_host"],
      to_capability: params["to_capability"],
      # US-454 (defect 3): OPTIONAL id of a post this one retires. The context
      # scope-checks (same tenant+project) and authorizes (author or role >=
      # :user) the target, then marks it superseded_by in the same transaction.
      supersedes: params["supersedes"],
      audit: AuditContext.from_conn(conn)
    }

    render_write(
      conn,
      Coordination.post(tenant_id, agent_id, role, attrs),
      tenant_id,
      agent_id,
      params
    )
  end

  # The write outcome → HTTP mapping, split out of `write_post/5` so the param
  # marshalling and the (long, deliberately explicit) result mapping stay separately
  # readable — and under the complexity gate.
  defp render_write(conn, {:ok, post, :created}, _tenant_id, _agent_id, _params) do
    conn
    |> put_status(:created)
    |> json(%{post: post, created: true, meta: post_write_meta(post)})
  end

  defp render_write(conn, {:ok, post, :updated}, _tenant_id, _agent_id, _params) do
    conn
    |> put_status(:ok)
    |> json(%{post: post, created: true, meta: post_write_meta(post)})
  end

  defp render_write(conn, {:ok, post, :deduplicated}, _tenant_id, _agent_id, _params) do
    # US-40.B2: a KEYLESS write whose client idempotency_key already exists
    # for this (tenant, project, agent) — the EXISTING post is returned and
    # nothing new was appended. 200 with `created: false` so the caller can
    # tell a dedup from a fresh 201 append (TC-40.B2.2).
    # Include meta for shape parity with created/updated responses.
    conn
    |> put_status(:ok)
    |> json(%{post: post, created: false, meta: post_write_meta(post)})
  end

  defp render_write(_conn, {:error, :supersede_target_not_found}, _tenant_id, _agent_id, _params) do
    # US-454 (defect 3): the supersedes target does not exist, is cross-project,
    # not owned by the caller, or is malformed. Same byte-identical 422 body as
    # a missing project, but WITHOUT the :ownership_rejected security signal —
    # preserving honest attribution (a bad supersedes target is NOT a project
    # ownership probe).
    {:error, :unprocessable_entity, @ownership_error_message}
  end

  defp render_write(_conn, {:error, :not_found}, tenant_id, agent_id, params) do
    # AC-39.2.3 + AC-40.D3.1/D3.4: missing, cross-tenant, AND cross-PROJECT
    # (a non-member agent posting to a sibling project in its own tenant)
    # ALL collapse to one byte-identical 422 — no oracle distinguishing them.
    # The :ownership_rejected signal fires on every case, so a cross-project
    # injection attempt is observable exactly like a cross-tenant probe.
    emit_security_event(:ownership_rejected, %{
      tenant_id: tenant_id,
      agent_id: agent_id,
      project_id: params["project_id"]
    })

    {:error, :unprocessable_entity, @ownership_error_message}
  end

  defp render_write(conn, {:error, :agent_not_found}, tenant_id, agent_id, params) do
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
  end

  defp render_write(_conn, {:error, :unprocessable_entity, _message} = err, _t, _a, _p) do
    # Issue #499 quarantine outcomes, both surfaced as an explicit 422 rather than
    # a false success: (a) the idempotency token belongs to a QUARANTINED row, so
    # reporting `deduplicated` would claim a hidden post is on the channel; (b) the
    # keyed slot still carries a credential in a field a re-post cannot overwrite,
    # so the write was rolled back. Also the pre-existing supersede-target case
    # above, which returns the same shape with its own message.
    err
  end

  defp render_write(_conn, {:error, :conflict} = err, _tenant_id, _agent_id, _params) do
    # US-40.B2 rare double race: a keyless idempotent write's winning row was
    # hard-deleted (US-39.7) between the failed insert and BOTH the recovery
    # SELECT and the bounded re-append. The slot kept churning, so `post/4`
    # returns a RETRYABLE 409 (not a misleading 422) — `action_fallback` maps
    # `{:error, :conflict}` to a 409 the client can safely re-fire.
    err
  end

  defp render_write(_conn, {:error, %Ecto.Changeset{} = changeset}, _t, _a, _p) do
    {:error, changeset}
  end

  @doc """
  POST /api/v1/channel/posts/:id/graduate

  Graduates a coordination post into the durable Knowledge wiki (US-40.E1).
  Requires agent+ role and a key that carries an agent identity (403
  `agent_identity_required` otherwise — mirrors `create/2`).

  CONTENT-SELECTIVE: for a genuinely REUSABLE finding with no external tracker,
  NOT routine handoffs (a transient directive is left to expire). The orchestration
  — tenant-scoped fetch, project-membership gate, secret scan, and the semantic
  novelty gate — lives in `Coordination.graduate_post/5`, keeping the controller
  thin. `{:error, :not_found}` (nonexistent / cross-tenant / non-member) and
  `{:error, :unprocessable_entity, msg}` (denylisted secret) fall through to
  `action_fallback`.
  """
  def graduate(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case api_key.agent_id do
      nil ->
        # Parity with create/2: an attributed durable article requires a verified
        # agent identity — no article is created without one.
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
              "This API key has no agent identity; it cannot graduate a channel post to Knowledge"
          }
        })

      agent_id ->
        graduate_params = %{
          title: params["title"],
          tags: params["tags"],
          # Optional — the context defaults to :finding (a reusable lesson).
          category: params["category"],
          audit: AuditContext.from_conn(conn)
        }

        conn
        |> render_graduation(
          Coordination.graduate_post(
            tenant_id,
            agent_id,
            api_key.role,
            params["id"],
            graduate_params
          )
        )
    end
  end

  # Render the `Coordination.graduate_post/5` outcome, mirroring
  # `LoopctlWeb.ArticleController.render_proposal/4`:
  #   * :duplicate    → 200, nothing created, point at the canonical article
  #     (so a single-use/duplicate finding does NOT pollute the wiki — AC-40.E1.2)
  #   * :created / :gated_to_draft → 201, the created article
  #   * :deduplicated (idempotency_key no-op) → 200 reference
  # `{:error, :not_found}`, `{:error, :unprocessable_entity, msg}` (secret),
  # `{:error, :duplicate_title, _}`, and `{:error, %Ecto.Changeset{}}` all fall
  # through to `action_fallback` (404 / 422).
  defp render_graduation(conn, {:ok, %{verdict: :duplicate, article: existing}}) do
    conn
    |> put_status(:ok)
    |> json(%{
      deduplicated: true,
      data: %{id: existing.id, title: existing.title, status: to_string(existing.status)},
      note:
        "A near-duplicate already exists (id #{existing.id}). Nothing was graduated — read or " <>
          "update the existing article instead."
    })
  end

  defp render_graduation(conn, {:ok, %{verdict: :deduplicated, article: existing}}) do
    conn
    |> put_status(:ok)
    |> json(%{
      deduplicated: true,
      data: %{id: existing.id, status: to_string(existing.status)},
      note: "An article with this identity already exists. Nothing was graduated."
    })
  end

  defp render_graduation(conn, {:ok, %{article: article}}) do
    conn
    |> put_status(:created)
    |> json(%{
      data: %{
        id: article.id,
        title: article.title,
        status: to_string(article.status),
        source_type: article.source_type,
        source_id: article.source_id,
        project_id: article.project_id
      },
      note:
        "Graduated the coordination post into Knowledge (id #{article.id}). The source post is " <>
          "kept and will expire on its 30-day TTL; redact it via DELETE if it must be removed sooner."
    })
  end

  # Exact-title collision with a DIFFERENT-bodied active article (distinct from the
  # semantic novelty gate — the title unique guard). Mirror article_controller's
  # 409 title_conflict; the FallbackController has no clause for this 3-tuple.
  defp render_graduation(conn, {:error, :duplicate_title, existing}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "title_conflict",
        message:
          "An article with this title already exists with different content. Choose a different " <>
            "title or update the existing article.",
        details: %{existing_article_id: existing.id}
      }
    })
  end

  # The novelty gate FELL OPEN (embedding backend down) and `on_gate_unavailable: :skip`
  # short-circuited WITHOUT creating — automated graduation must not inject an
  # un-deduplicated article during an outage. Transient server-side dependency outage →
  # 503 so the caller retries once embeddings recover (mirrors MemoryController's
  # graduation posture); the source post is kept and stays eligible.
  defp render_graduation(conn, {:error, :gate_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        status: 503,
        code: "gate_unavailable",
        message:
          "The novelty gate is temporarily unavailable (the embedding backend could not " <>
            "assess this post), so nothing was graduated. The source post is kept — retry " <>
            "once embeddings recover."
      }
    })
  end

  # {:error, :not_found} | {:error, :unprocessable_entity, msg} |
  # {:error, %Ecto.Changeset{}} → FallbackController (404 / 422).
  defp render_graduation(conn, error), do: LoopctlWeb.FallbackController.call(conn, error)

  @doc """
  DELETE /api/v1/channel/posts/:id

  HARD-deletes a coordination post in the caller's tenant — the redact path
  (US-39.7). Requires agent+ role (NOT human-anchor gated). Author-only (or
  elevated role, US-40.D2): the caller must be the post's own author OR hold an
  elevated role (`>= :user`). A non-author agent — like a foreign or nonexistent
  id — returns a byte-identical 404 via the shared `FallbackController` (no
  existence oracle). The deleting agent is the audit actor.
  """
  def delete(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Coordination.delete_post(
           tenant_id,
           api_key.agent_id,
           api_key.role,
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

  @doc """
  GET /api/v1/channel/posts/quarantined

  The OPERATOR review read for issue #499: lists the tenant's quarantined posts with
  FULL bodies, so a human can judge whether the secret rescan's heuristic flag was a
  true or false positive. Role `:user` — every agent-facing read hides these rows, and
  the operator alert names FIELD names only, so this is the one path that resolves the
  `post_ids` an open `secret_detected` anomaly points at.
  """
  def quarantined(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    limit = parse_limit(params["limit"])

    posts =
      Coordination.list_quarantined_posts(tenant_id,
        project_id: params["project_id"],
        limit: limit
      )

    json(conn, %{
      data: Enum.map(posts, &quarantined_json/1),
      # The CLAMPED bound the context actually applied — never the requested value.
      # `?limit=1000` returns at most 100 rows and `?limit=0` / `?limit=-5` return the
      # default 25, so echoing the request here would report a page size that never
      # existed.
      meta: %{count: length(posts), limit: Coordination.quarantined_limit(limit)}
    })
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(limit) when is_integer(limit), do: limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value
      # A malformed ?limit falls back to the context default rather than 400ing an
      # operator mid-incident; the context clamps the effective bound either way.
      _ -> nil
    end
  end

  defp parse_limit(_), do: nil

  # The review payload: the FULL body (that is the artifact under review) plus the
  # quarantine bookkeeping an operator needs to act — never a matched value, which the
  # `quarantine_reason` deliberately never carries either.
  #
  # It carries EVERY field `ChannelPost.secret_fields/1` can flag (`@scanned_text_fields`
  # + `refs`). A `quarantine_reason` naming e.g. `to_capability` on an endpoint that never
  # returns `to_capability` is unreviewable — the operator would be left with direct DB
  # access or a blind release/delete. The endpoint is already `role: :user`,
  # human-anchored, and already returns full bodies, so the extra fields add no exposure.
  defp quarantined_json(post) do
    %{
      id: post.id,
      project_id: post.project_id,
      agent_id: post.agent_id,
      session_id: post.session_id,
      host: post.host,
      to_host: post.to_host,
      to_capability: post.to_capability,
      idempotency_key: post.idempotency_key,
      key: post.key,
      body: post.body,
      refs: post.refs,
      quarantined_at: post.quarantined_at,
      quarantine_reason: post.quarantine_reason,
      inserted_at: post.inserted_at,
      expires_at: post.expires_at
    }
  end

  @doc """
  POST /api/v1/channel/posts/:id/release

  Exonerates a quarantined post (issue #499) — the non-destructive counterpart to the
  redact path. Role `:user` + human-anchored. A nonexistent, foreign-tenant, malformed,
  or not-currently-quarantined id all return the same 404 via `FallbackController`.
  """
  def release(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    api_key = conn.assigns.current_api_key

    case Coordination.release_post(
           tenant_id,
           api_key.agent_id,
           api_key.role,
           params["id"],
           AuditContext.from_conn(conn)
         ) do
      {:ok, post} ->
        json(conn, %{post: quarantined_json(post), released: true})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :audit_write_failed} = err ->
        # The release could not be durably audited, so it rolled back and the post is
        # STILL quarantined. Never report success — the FallbackController maps this to
        # a 5xx so the operator retries instead of trusting a false exoneration.
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
          api_key_id: api_key.id,
          limit_kind: :write
        })

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{error: %{status: 429, message: "Rate limit exceeded"}})
        |> halt()
    end
  end

  # Per-read rate limit (AC-40.D5.1/3/4): the read-path counterpart to
  # `rate_limit_write`, on a SEPARATE bucket family (`channel_post_read:key`) so
  # read and write abuse are counted and observed independently. Reuses the SAME
  # `check_rate/2` (fail-open + throttled FailOpenLog), `window_reset_at/0`, and
  # `emit_security_event/2` helpers — no duplication. On a trip it emits the
  # coordination `:rate_limited` signal and returns 429 with a `retry-after`
  # header, then `halt()`s. On a limiter fault `check_rate/2` fails OPEN so a
  # limiter outage never blocks reads (the outage stays observable via FailOpenLog).
  defp rate_limit_read(conn, _opts) do
    api_key = conn.assigns.current_api_key
    tenant = conn.assigns[:current_tenant]
    limit = read_limit(tenant)
    identifier = "channel_post_read:key:#{api_key.id}"

    case check_rate(identifier, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        reset_at = window_reset_at()
        retry_after = max(1, reset_at - System.system_time(:second))

        emit_security_event(:rate_limited, %{
          tenant_id: api_key.tenant_id,
          api_key_id: api_key.id,
          limit_kind: :read
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

  defp read_limit(nil), do: default_read_limit()

  defp read_limit(tenant) do
    configured =
      tenant
      |> Tenants.get_tenant_settings("channel_post_read_limit_per_minute", default_read_limit())
      |> coerce_positive_int(default_read_limit())

    # AC-40.D5.3: the coordination read cap must remain a TIGHTER constraint than
    # the generic per-key pipeline limiter (LoopctlWeb.Plugs.RateLimiter), which
    # runs FIRST in the pipeline and emits no coordination-specific security signal.
    # If a tenant set this above the pipeline limit, every coordination read-rate
    # trip would be shadowed by an anonymous pipeline 429 — blinding the read-abuse
    # detectors. Clamp so the read cap can never exceed (and thus be shadowed by)
    # the pipeline cap, full parity with write_limit/1's clamp.
    min(configured, pipeline_per_key_limit(tenant))
  end

  defp default_read_limit do
    Application.get_env(:loopctl, :channel_post_read_limit_per_minute, @default_read_limit)
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

    # `limit_kind` (:write / :read) is the rate-cap discriminator and is carried
    # ONLY by the two :rate_limited callers. Render it solely when present so the
    # four non-rate-limit events (:read_error, :agent_identity_required,
    # :ownership_rejected) don't emit a dangling `limit_kind=` (nil) token — the
    # full telemetry map still carries whatever keys each caller passed.
    limit_kind_token =
      case Map.fetch(metadata, :limit_kind) do
        {:ok, kind} -> " limit_kind=#{kind}"
        :error -> ""
      end

    Logger.warning(
      "coordination security event: #{event} " <>
        "(tenant=#{Map.get(metadata, :tenant_id)} " <>
        "api_key=#{Map.get(metadata, :api_key_id)} " <>
        "agent=#{Map.get(metadata, :agent_id)} " <>
        "project=#{Map.get(metadata, :project_id)}" <>
        limit_kind_token <> ")"
    )

    :ok
  end
end
