# Epic 39 — Repo Coordination Bus (v1)

Design source of truth: **`docs/repo-coordination-bus.md`**.

## The problem (measured)

When the same repo is worked from **more than one machine and/or more than one session**, the sessions can't talk to each other — coordination happens by hand (copy-pasting one session's finding into another). The stopgap, memory-keeper, is **local SQLite, one DB per machine**, so it structurally can't bridge machines. Fleet audit (2026-07-17) quantified the fragmentation: `home_care_billing` memory is **4,286 items split 444 / 3163 / 679 across three machines, none shared**.

This epic adds the missing **third memory plane**: a project-scoped, append-only, short-lived coordination channel — hosted on loopctl so it is multi-machine by construction.

## The model (v1, deliberately minimal)

A **channel = a `project_id`** (including `:kb` scopes). A **post** is one attributed message: `agent_id` (server-stamped from the key), `host`, `session_id`, `body`, an optional `key` (upsert), optional structured `refs`. **No message-type taxonomy; uniform 30-day retention** (owner decision — the fleet audit showed the category taxonomy was barely used). Durable keepers **graduate to Knowledge** (#411); the rest expires. Sessions read the channel at **SessionStart** (a new TEAM CHANNEL block) and on demand. Realtime/websockets are deliberately excluded — agents consume at turn boundaries (see the design brief §5).

## Decomposition

| Story | Title | Repo | Risk | Depends |
|-------|-------|------|------|---------|
| US-39.1 | `channel_posts` schema + migration (RLS, indexes, 30d `expires_at`, optional-key upsert) | loopctl | Low-Med (migration + RLS) | — |
| US-39.2 | `channel_post` write endpoint + context (agent role, upsert, `agent_id` stamped, ownership) | loopctl | **Med — auth boundary** | US-39.1 |
| US-39.3 | `channel_recent` read endpoint + context (tenant+project scoped, `since`/`limit`) | loopctl | Low-Med | US-39.1 |
| US-39.4 | MCP tools `channel_post` + `channel_recent` (Node proxy, agent key) + publish | loopctl | Low | US-39.2, US-39.3 |
| US-39.5 | 30-day Oban TTL sweep worker | loopctl | Low | US-39.1 |
| US-39.6 | SessionStart **TEAM CHANNEL** injection (default-on, injection-safe, fail-open) | **claude-config** | Med (hook; untrusted-content injection) | US-39.3 |
| US-39.7 | Delete/redact a channel post (remove a leaked post before its 30-day expiry) | loopctl | Med (secret backstop) | US-39.2, US-39.4 |

US-39.6 lives in the **claude-config** repo (the SessionStart hook), not loopctl — it is the consumer of the loopctl API and ships/reviews on its own delivery loop; it is listed here for epic completeness.

Total: 7 stories, ~1.5M estimated tokens. Both a technical-accuracy review (grounding every assumption against loopctl code) and a completeness/security review were run over these stories before this epic was committed; their findings are folded in (see the constraints below).

## Non-negotiable constraints (release gates)

- **Tenant isolation = AdminRepo + explicit `tenant_id` filter (RLS is defense-in-depth).** Runtime isolation is the loopctl content pattern: query via `AdminRepo` (BYPASSRLS) with an explicit `tenant_id` filter in EVERY query — exactly like Knowledge/Projects — with RLS ENABLED on `channel_posts` as a second layer. A query missing the tenant filter is a bug even though RLS would also stop it. Isolation is tested on BOTH paths.
- **`agent_id` is server-stamped from the verified key identity, ALWAYS and NEVER from the body** — a caller cannot post as another agent; a key without an agent identity is 403 (channel posts require identity unconditionally, unlike the conditional memory-metadata gate). `host`/`session_id` are client-supplied, informational, and spoofable — never used as authorization or as authoritative attribution.
- **Project ownership validated on write** via `Projects.get_project/2` (public; `validate_project_ownership` is private) — a missing OR cross-tenant `project_id` returns a **byte-identical 422** (no existence oracle).
- **No cross-tenant existence oracle anywhere:** read of an unowned/nonexistent project → uniform **200 empty**; delete of one → uniform **404**; write → uniform **422**. Same status AND body for "not yours" and "does not exist".
- **Body, `refs`, and `key` are all secret-scanned and bounded:** `body` ≤16KB; `refs` constrained to `{file,pr,branch,commit}` string values with per-value + total-size caps; `key` ≤200. The knowledge secret-denylist runs over `body` AND `refs` values AND `key`; a hit is an explicit **422 rejection** (never a silent drop).
  - **Best-effort, NOT a DLP boundary.** The denylist matches ~11 high-confidence, *prefixed* credential shapes (Bearer, `sk-`, `lc_`, `ghp_`, `AKIA`, JWT, `user:pass@` URLs, etc.) to keep false positives near zero. It is deliberately NOT a comprehensive credential filter: a plaintext DB password, an unprefixed high-entropy token, a base64 blob, or `PGPASSWORD=hunter2` pass straight through. The channel is cross-session/cross-machine readable for 30 days — operators MUST NOT treat this scan as a guarantee that no credential can land, and MUST rely on the US-39.7 delete/redact path as the real backstop for anything the denylist misses. (Scanning is over a bounded prefix per field, so a credential padded past the byte cap is rejected on **length** but may not fire the `secret_blocked` signal.)
- **Write is rate-limited** (per `(tenant, agent)`, 429 + Retry-After) so an agent cannot spam posts, thrash a key, or inflate the audit chain.
- **A delete/redact path exists (US-39.7)** so a leaked/regretted post — including one the denylist missed — is removable immediately, not stuck (and auto-injected) for 30 days.
- **Agent-role, no human-anchor:** coordination/content surface (owner decision #331). Exposes NO work-breakdown surface. The default-deny guard test allowlists the mutating routes (`POST /channel/posts`, `DELETE /channel/posts/:id`); the GET is not walked by that test.
- **Security events are logged:** denylist hits, ownership/tenant rejections, `agent_identity_required`, and rate-limit trips are emitted as structured telemetry.
- **Retention enforced:** `expires_at = now + 30d`; reads filter `expires_at > now()` defensively; the sweep (US-39.5, template `SessionMemoryPruneWorker`) is idempotent, batch-bounded, and only deletes expired rows.
- **The claude-config injection (US-39.6) treats post bodies as UNTRUSTED, agent-authored content rendered into a bash hook + a new session's context:** every field injected as JSON-encoded data (`jq --arg`, never shell-interpolated → no command injection), truncated + fenced (no prompt-injection breakout, bounded volume), fail-open + latency-bounded, and off-switch-aware (`CLAUDE_MEMORY`, `.claude/memory-off`, and a dedicated `CLAUDE_TEAM_CHANNEL=0`).
- **OpenAPI:** each new endpoint declares an `operation/1` spec (loopctl maintains OpenAPI; `openapi_test.exs` must pass).
- Every loopctl merge auto-deploys behind the smoke gate; no schema change here is destructive (new table + online indexes).

## Out of scope for v1 (deliberate)

- **Knowledge-graduation bridge** (`channel_post → knowledge_create` for a keeper): deferred per design §6 sequencing. The "30-day hard delete loses nothing" claim rests on this existing as a *manual* path today; a first-class bridge is a follow-up.
- **Presence, turn-boundary freshness pull, advisory soft-locks, realtime/SSE** (design §5): later — v1 is post + read + inject + delete.
