# Changelog

All notable changes to loopctl are documented here.

## [Unreleased] — 2026-07-24 — Self-hosting: fresh-install fixes, multilingual search, at-rest ingestion encryption

Operator-facing changes for deployments outside the hosted instance.

### Changed

- **`loopctl.oban.poll.error.count` label values changed — re-point any Prometheus selector
  or Grafana panel (#558).** The `error_class` label moved from a bare `exit` / `throw` to the
  kind-prefixed, closed set produced by `Loopctl.ExitClass` — `exit:noproc`, `exit:timeout`,
  `exit:Postgrex.Error`, `throw:other`, and so on. A selector matching the old bare values
  **silently stops firing** rather than erroring, which is the worst failure mode an alert
  has. The same vocabulary is now shared by the ingestion backlog-gate and vector-search
  under-fill counters, so one query shape works across all three.

- **`loopctl.ingestion.backlog_gate.failed_open.*` gained an `:outcome` label, and a `jobs`
  sum alongside the counter.** The event now fires on refusals as well as admissions, so a
  dashboard reading the counter alone over-reports admissions during exactly the sustained
  incident it is alerted on; slice by `outcome` (`admitted` / `unmetered` / `exhausted`). The
  `jobs` series is job-denominated — one 50-item batch is one check but fifty jobs.

- **A DB pool fault that arrives as an EXIT now renders the pinned 503/504 instead of a bare
  500, and counts in `loopctl.db.error.count`.** Crash propagation from a pooled process is an
  exit, not a raise, so it previously escaped the endpoint backstop untranslated: no
  structured SQLSTATE line, no counter increment (the aggregate under-counted DB faults during
  exactly the pool wedge it is read in), and the raw reason — the failing statement plus the
  call's bound parameters — reached the web-server crash log. Exits the backstop cannot place
  in the pool are still re-exited untouched.

- **The ingestion fail-open allowance is metered on the node-local limiter even under
  `RATE_LIMITER=postgres`.** The Postgres limiter store is `AdminRepo` — the same pool whose
  exhaustion makes the backlog unmeasurable — so the allowance was unconsultable for exactly
  the fault it bounds and admission stayed unbounded during a sustained wedge. Every other
  limiter bucket still follows `RATE_LIMITER`.

- **`POST /knowledge/ingest[/batch]` can now answer `503 ingestion_gate_unavailable` where it
  previously answered `429 ingestion_backlog_exceeded`.** Only for the refusals that are NOT
  backlog pressure: the gate could not MEASURE the backlog because of a driver/config fault or
  a defect in the counting code, and the bounded allowance for admitting unmeasured work is
  spent. The 429 asserted a backlog nobody counted and advised waiting for a drain that a
  deterministic fault never reaches. `Retry-After` is set on both; a client branching on
  `error.code` needs no change, one branching on the status does.

- **Tightening `OBAN_INGEST_BACKLOG_MAX` now tightens the ingest fail-open allowance with it
  (#564).** That allowance — how many jobs a tenant may have admitted while the gate cannot
  MEASURE its backlog — is `max(1, OBAN_INGEST_BACKLOG_MAX / 10)` per web node, sized so a
  10-node fleet stays at or under one threshold per hour. A floor at one full batch (50)
  previously took over for any threshold below 500, so lowering the knob to e.g. `100` left
  the allowance pinned at 50/node — a fleet admitting 500/hour against a threshold of 100,
  silently, and in the direction an operator assumes is the safer one. Effect at the default
  of 500 is unchanged. Below a threshold of 10 the allowance floors at 1 rather than 0, so a
  transient blip cannot refuse EVERY request — but a request asking for more items than one
  window's allowance still cannot fit it, and is refused after a single token rather than
  burning the remainder on jobs it will not enqueue. `OBAN_INGEST_BACKLOG_MAX` and
  `OBAN_INGEST_BACKLOG_RETRY_AFTER` are now documented in `deploy/FLY_SECRETS.md`, where
  they should have been all along.

- **`POST /knowledge/ingest[/batch]` can answer `503 ingestion_gate_unavailable` for a
  `db_error` too (#564).** It was the last unmeasurable-count class still admitting
  UNCONDITIONALLY — on the reasoning that a broken count query is our defect, not the
  tenant's backlog. That is a correct argument about the error CODE (and is kept: the refusal
  is the 503, never a backlog 429) but it left the class unbounded, and a deterministic
  query-shape fault recurs on every request — so the backpressure valve was simply OFF for as
  long as the bug existed. Every class is now metered. Operator-visible as ingest requests
  that previously succeeded during a counting-code fault now being refused once the hourly
  allowance is spent; the `loopctl.ingestion.backlog_gate.failed_open.*` series with
  `error_class="db_error"` is the signal to fix the query.

- **Which ingest fail-open refusals carry `429` vs `503` changed again, and the `Retry-After`
  on them is now window-scaled but capped (#565, #566).** `429 ingestion_backlog_exceeded` is
  now reserved for a fault that is demonstrable pool pressure: the SQLSTATE/exception classes
  `connection`, `timeout`, `db_pressure`, `guc_capture_abort`, plus any EXIT the driver's own
  pool raised. Pool-ness of an exit is decided from the raw exit reason
  (`ExitClass.pool_exit?/1`), not from its metric label, so a foreign `{:timeout, {GenServer,
  :call, _}}` escaping the counter takes the `503 ingestion_gate_unavailable` while a
  `{:noproc, {DBConnection, :execute, []}}` keeps the 429 — the label alone cannot tell them
  apart. A `throw:*` and every exit the gate cannot place at the pool answer the 503, like
  `db_error` and `driver_fault` already did, because none of them is evidence that the refused
  tenant has a backlog. In the other direction, the CONTENTION SQLSTATEs (40001, 40P01
  deadlock_detected, 55P03 lock_not_available) now classify as `db_pressure` rather than
  `db_error`, so heavy `oban_jobs` churn reads as load on the dashboard instead of as a defect
  in the counting query; the rest of classes 40 and 55 (55P02 cant_change_runtime_param and
  friends) stay `db_error`, since a deterministic config fault never drains. The `Retry-After`
  on an allowance-exhausted refusal now advises the time left in the hourly allowance window
  instead of `OBAN_INGEST_BACKLOG_RETRY_AFTER` (~60s) — which had a compliant client re-running
  the backlog count ~60 times per window against the pool the gate is protecting — capped at 5x
  that variable so a cleared blip cannot stall a client for a whole window. The fail-open
  allowance is also now metered in two per-tenant lanes (pressure vs non-pressure), so a
  counting-code defect can no longer spend the tokens a genuine pool fault is then refused on.
  The lanes SPLIT one threshold's worth rather than each getting one — the per-lane allowance
  is `max(1, OBAN_INGEST_BACKLOG_MAX / 20)` per web node (10 nodes x 2 lanes), so the total a
  tenant can have admitted while unmeasured stays at one `OBAN_INGEST_BACKLOG_MAX` per hour and
  there is **no multiplier to apply on top**. At the default of 500 the per-lane allowance is
  25/node.

- **`GET /api/v1/knowledge/heat_index` ranks by DISTINCT READERS, not by read count (#567).**
  Heat was `count(*)` over access-event rows, so any agent could pin its own article at rank 1 by
  calling `knowledge_get` on it in a loop — and because this index is meant to be pasted into a
  cached prefix, that ranking then propagated into every other agent's context. A signal the
  ranked party controls is not a signal. A reader is `coalesce(agent_id, api_key_id)` of the key
  that read — NOT the key row, since v2 mints a fresh ephemeral key per dispatch and counting
  keys would count dispatches — so one agent now contributes at most 1 however many times, and
  from however many dispatches, it reads; raw read count breaks ties before the article id does.
  Existing `heat` values will DROP (they become readership size, not traffic) and the
  ordering will change wherever traffic and readership disagreed. Two further contract fixes on
  the same route: `meta.heat_window` is snapped to a UTC day boundary in the NARROWING direction
  (an explicit `since` is never widened, and the 365-day ceiling is never exceeded), so two calls with no intervening
  read return a byte-identical payload (it previously carried a microsecond timestamp, making the
  "cacheable prefix" a guaranteed cache miss); and a FUTURE `since` is clamped to now instead of
  returning 200 with an empty list and a window that has not happened yet. `meta.chars` is now
  measured off the ENCODED stub, so escape-heavy titles no longer under-report the wire size a
  caller budgets against. No migration and no index change: the route's published-id subquery
  was suspected of scanning the corpus, and `EXPLAIN (ANALYZE, BUFFERS)` on production
  disproved it — the planner drives from the windowed event index and probes `articles_pkey`
  per distinct article read, 11 ms against a 79,025-article corpus.

### Added

- **A retirement trigger for the US-41.1 legacy embedding columns (#551).** New migration
  (`embedding_retirement_observations`, a global non-tenant table) and a new daily job at
  03:40 UTC. It records one observation per UTC day — the read flag, which legacy columns
  survive, and the cumulative `idx_scan` of every index over them — and once retirement is
  owed it logs at `error` every run and enqueues an operator alert
  (`embeddings.legacy_retirement_due`) through the existing `SCALE_ALERT_WEBHOOK_URL`
  channel, which stays a no-op when that is unset. A passed deadline that a revert in
  progress is BLOCKING alerts on the same channel under `embeddings.legacy_retirement_blocked`
  — it names a condition to resolve, not a column to drop.

  **It drops nothing.** Dropping `articles.embedding` / `memories.embedding` remains a
  deliberate, reviewed migration; this only decides when the system starts asking for one.
  Two triggers, both requiring the columns to still exist: 30 consecutive clear days
  (`embedding_side_table_reads = 1`, no movement on any legacy index), or the `review_by`
  date passing — `2027-01-22`, six months after the cutover. The deadline is what keeps
  the check honest: a probe that errors forever looks exactly like a probe that keeps
  finding nothing. Both values are `config :loopctl, :embedding_legacy_retirement` — no
  new environment variable, and moving the date out is a supported operator decision.

- **`GET /enroll` — a browser page that anchors an EXISTING tenant (#541).** The API
  advertised an `enrollment_upgrade` path out of `agent_rooted`, but nobody could walk it:
  `navigator.credentials.create()` needs a browser, and the only page running a WebAuthn
  ceremony was `/signup`, which creates a NEW tenant. Every tenant predating the signup
  ceremony was therefore permanently locked out of chain-of-custody, work-breakdown,
  dispatch, and token-budget writes. Paste a `user`-role API key, touch an authenticator,
  and the tier flips in place. The key is sent only as a bearer token from your browser to
  the same API you would curl — the page holds no server-side state and enforces nothing;
  every gate stays in `TenantAuthenticatorController`. `GET /api/v1/tenants/me` now names
  the page in `remediation.enrollment_upgrade.enrollment_page` (relative, since a
  self-hosted instance serves its own).

### Fixed

- **WebAuthn registration rejected hardware security keys.** Both browser hooks requested
  `attestation: "direct"` while the server built its challenge with Wax's default of
  `"none"`, so `Wax.register/3` refused any real attestation statement with
  `:invalid_attestation_conveyance_preference`. This was invisible on laptops — Touch ID
  and Windows Hello return `fmt: "none"` regardless — and broke exactly the roaming keys
  (YubiKey and similar) that the signup page recommends. Affects `/signup` as well as the
  new `/enroll`. No configuration change is needed; existing enrolled authenticators are
  unaffected.

- **`WEBAUTHN_RP_ID` / `WEBAUTHN_ORIGIN` / `WEBAUTHN_RP_NAME` — WebAuthn on a self-hosted
  domain (#511, contributed by @FinanceAlex; refs #494).** `config.exs` hardcoded the
  relying party to `loopctl.com`, and the WebAuthn spec requires `rp_id` to be a
  registrable domain suffix of the page's origin — so on any other domain the browser
  refused the enrollment ceremony. Since enrollment is the only way a tenant becomes
  `human_anchored`, a self-hosted deployment could never reach the chain-of-custody
  surface at all. `dev.exs`/`test.exs` already overrode this for localhost; only a prod
  release had no way to. Unset, the hosted deployment is byte-for-byte unchanged.
  Each var applies independently. `WEBAUTHN_ORIGIN` defaults to `https://$PHX_HOST` whenever
  `PHX_HOST` is set — the page host, not the `rp_id`, since `rp_id` may legally be a
  registrable parent domain of it — and must be set explicitly for localhost or a
  non-standard port, since WebAuthn runs only in a secure context (localhost being the one
  `http://` exception). A blank, non-host-shaped `WEBAUTHN_RP_ID` or a `WEBAUTHN_ORIGIN`
  that is not `scheme://host[:port]` is named in the boot log and ignored rather than
  applied; an `rp_id` that is not a registrable suffix of the origin is warned about too.
  Set `WEBAUTHN_RP_ID`
  before the first enrollment: credentials are bound to it, so changing it later
  invalidates every enrolled authenticator.
- **`SCALE_ALERTS_ENABLED` — off switch for a deployment with no alert receiver (#376).**
  Defaults to `true`, so an existing deployment is unchanged. The parse is deliberately
  opt-OUT and asymmetric with loopctl's other boolean env vars: only `false` or `0`
  disable (trimmed, case-insensitive), so a typo leaves alerting **on**, where its guard
  is still watching, rather than silently off. **Disabled stops the whole checker** — the
  supervised `ScaleAlerts` child is not started, so nothing is evaluated, logged *or*
  POSTed; the Prometheus series on `METRICS_PORT` are unaffected and remain the
  degradation signal. Enabling alerting is now a two-part change (`SCALE_ALERT_WEBHOOK_URL`
  **and** this flag) and `/health/ready` reports `checks.scale_alerts: "error"` for either
  half-done direction, naming the setting to fix. The hosted deployment ships this `false`
  via `fly.toml` until an operator webhook receiver exists.
- **`FTS_REGCONFIG` — per-deployment keyword-search language (#492).** Keyword FTS
  was hardwired to the `english` stemmer, so a non-English corpus silently degraded
  (Russian «отчёты» never matched «отчёт»). `Loopctl.Search.Regconfig` is now the
  single source of truth, set from `FTS_REGCONFIG` (default `english`, so the hosted
  instance is unchanged). **Set it before the first `migrate`** — the
  `apply_fts_regconfig` migration bakes the value into the stored `search_vector`s
  and is a no-op on the default. A well-formed but uninstalled config (e.g.
  `ukrainian`) fails the migration loudly rather than building an unusable index.
- **`SECRETS_ADAPTER=local_file` + `SECRETS_FILE` — signup off Fly (#496).** Tenant
  signup stores a per-tenant Ed25519 audit key via `Loopctl.Secrets`, which defaulted
  to the Fly secrets API — so signup was impossible on any other host. The local
  adapter writes `0600` with fsync and atomic tmp+rename under a write lock. Put
  `SECRETS_FILE` on a persistent volume and back it up with the database.
- **Browser signup mints a usable root API key (#500).** The HTML signup ceremony
  previously completed without issuing credentials, leaving a browser-onboarded
  tenant with no authenticated path forward. The key is surfaced exactly once, in
  LiveView memory only — never in a URL, session, or persisted record.

### Changed

- **`GET /api/v1/articles/:id` link payload trimmed, ranked and capped (#538) — BREAKING
  for anything reading `source_article` / `target_article`.** Each link object now carries
  only its FAR side, as `article: {id, title}`. The near side was a constant echo of the
  id already in the request URL, and — because only the far side is preloaded — its
  `title` was always `null`; it cost 14% of a typical response and carried nothing.
  Direction is unchanged and still given by which array the link is in. Links now also
  carry `similarity` when the auto-linker recorded one.
  Both arrays are **ranked** (open `potential_conflict` first, then descending similarity,
  then oldest-first for links with no recorded score — only the auto-linker records one,
  so a hand-created or imported corpus ranks entirely on that fallback) and **capped at 25
  per direction**, with new `links_total` and `links_truncated` fields
  reporting the true size. Use `knowledge_graph` to traverse the whole graph.
  A new `links` query parameter selects the detail level — `full` (default, so an
  untouched caller keeps working), `count` (`links_total` + `links_truncated`, so one
  cheap call answers whether the full fetch is capped), `none` (no link fields).
  An unrecognized value degrades to `full` rather than 422-ing a read.
  `potential_conflicts` is returned in **all three** modes, so a cheaper read never
  silently turns off conflict discovery; it is itself capped at 25 (highest similarity
  first) with `conflicts_total` / `conflicts_truncated`, so a conflict-heavy hub cannot
  make a cheap mode expensive.
  `GET /articles/:id` now also reads the `project_id` / `story_id` query params the MCP
  tool has always advertised, so article-access events are attributed instead of nil.
  As on every sibling knowledge read, a malformed `project_id` there returns **422**
  rather than silently discarding the attribution, and an empty one counts as absent.
  Why: agents are instructed to open every search hit with `knowledge_get`, so this
  response is paid on essentially every wiki read in every session. On a measured hub
  article the links were 12,564 of 16,189 bytes — about 4,000 tokens to read 735 tokens
  of body.
- **Ingestion document content is encrypted at rest (#493).** Raw `content` posted to
  `POST /api/v1/knowledge/ingest` was persisted as plaintext JSON in `oban_jobs.args`
  (including `retryable`/`discarded` rows) until pruning — the one at-rest exposure
  Epic 41 did not cover. It is now Cloak AES-256-GCM encrypted via
  `Loopctl.Ingestion.ContentEnvelope`. `url`, `source_type`, and `metadata` are **not**
  encrypted. Inline `content` is capped at 1,000,000 bytes (`422` over cap).
  `content_hash` changed from `sha256(plaintext)` to a per-tenant HMAC blind index —
  still an opaque deterministic string (dedup unaffected), but no longer an offline
  confirmation oracle for a DB-read attacker.
  **Operational:** when rotating `CLOAK_KEY`, keep the outgoing cipher in
  `retired_ciphers` until the `:ingestion` queue drains, or in-flight jobs discard.

### Fixed

- **Fresh installs no longer break in the Epic-41 migrations (#495).** The pgvector
  guard silently skipped embedding columns that a later migration then required. The
  migration now tolerates and heals the skipped state (idempotent, `IF NOT EXISTS`).
- **`/signup` rendered unstyled and non-functional on a fresh self-hosted install
  (#494)** — the browser pipeline was missing `put_root_layout`. Fixed at the
  `live_session` level so the `layout: false` marketing pages do not double-wrap.

> **Scope of this file.** loopctl's changelog records **operator-facing** changes
> only: environment variables, deploy ordering, migrations with manual steps,
> breaking or behaviour-changing API changes, and security-relevant changes to how
> data is stored. Refactors, test fixes, internal hardening, and dependency bumps
> are deliberately out of scope — `git log --first-parent` is the complete history.
> The trigger is narrow on purpose: a changelog that tries to record every merge
> is the kind that stops being written, which is what happened to the stretch of
> entries between this line and the one below it. See `CONTRIBUTING.md`.

## [Earlier] — 2026-07-16 — Agent-memory substrate: project scope, merged recall, graduation (#411)

### Added

- **Gap 1 — cheap repo → `project_id` resolution.**
  `Loopctl.Projects.resolve_project/2` (`GET /api/v1/projects/resolve`, MCP tool
  `resolve_project`) maps a `repo_url` / `slug` / `name` to a project in one call
  (precedence `slug > repo_url > name`; `repo_url` accepts SSH, HTTPS, and bare
  `owner/repo`). `404` `not_found`, `422` `no_identifier`, `409`
  `ambiguous_resolution` (a fuzzy identifier matched >1 active project).
- **Gap 2 — the `project_id` partition key + merged recall.** Long-term memories
  carry an optional `project_id` that PARTITIONS a subject's memories into a
  `global` (NULL) bucket and one per project — a partition key, NOT the isolation
  boundary (`(tenant_id, subject_id)` remains that, always key-derived). Write
  tenant-validates `project_id` (`422 invalid_project_id`); recall merges
  `global ∪ active-project` and treats an unowned id as an empty partition
  (global-only, no error). `Loopctl.Memory.recall_context/2`
  (`POST /api/v1/recall`, MCP tool `recall_context`) returns ONE re-ranked
  `global ∪ active-project` union of long-term MEMORY *and* KNOWLEDGE (combined
  search summaries), each result tagged `source: memory|knowledge`, plus the
  untouched per-source envelopes. A blank/over-500-char query is a `422` up front;
  a one-sided degrade returns the other side with `meta.degraded?: true` (never a
  500). Agent role is forced to published articles + own/`shared` memories (#163).
- **Gap 3 — recall-count graduation (HOT memory → durable knowledge).** Recall now
  bumps a `recall_count`/`last_recalled_at` hotness signal off the hot path
  (relevance floor `memory_recall_bump_min_score` = 0.6, cooldown
  `memory_recall_bump_cooldown_seconds` = 3600 s, fan-out cap
  `memory_recall_bump_max_tasks` = 200). The hourly
  `Loopctl.Workers.MemoryGraduationSweepWorker` graduates not-yet-graduated
  memories at/above `memory_graduation_recall_threshold` = 3 recalls into curated
  knowledge articles via the novelty gate (per-run budget
  `memory_graduation_max_per_run` = 50, scan fan-out
  `memory_graduation_scan_limit` = 500), stamping `graduated_at` on any durable
  verdict (a fell-open gate is not stamped — it re-graduates once embeddings
  recover).
- **Gap 3 surface — explicit, on-demand graduation.**
  `Loopctl.Memory.graduate_memory/3` is now reachable over HTTP + MCP:
  `POST /api/v1/memory/graduate` `{memory_id, re_scope?}` (MCP tool
  `memory_graduate`). Scope is key-derived (a foreign/unknown `memory_id` → `404`,
  no cross-subject oracle; malformed → `422 invalid_memory_id`). The novelty-gate
  verdict drives the status: `created`/`gated_to_draft` → `201` with a new
  article, `duplicate`/`deduplicated` → `200` (canonical article, nothing
  created). `re_scope: "global"` promotes a PROJECT memory to a tenant-wide
  article on its FIRST graduation only (`409 already_graduated` otherwise); a
  fell-open gate returns `503 gate_unavailable`. Allowlisted as an agent-reachable
  write in the default-deny custody classification (alongside `memory_promote` /
  `knowledge_create`).
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md) extended with the
  project-scope partition model, `resolve_project`, merged `recall_context`, the
  recall-count graduation cadence, and `memory_graduate` + local→global re-scope;
  `mcp-server/README.md`, `AGENTS.md`, and both changelogs updated. The
  MCP server publishes these three new tools at `loopctl-mcp-server` **2.42.0**.

## [Unreleased] — 2026-07-11 — OKF-curated + RAG Hybrid Knowledge Retrieval (Epic 31)

### Added

- **Hybrid knowledge retrieval** — `Loopctl.Knowledge.hybrid_search/3`
  (`POST /api/v1/knowledge/hybrid_search`, MCP tool `knowledge_hybrid_search`)
  composes the already-shipped retrieval (`search_combined/3`) and curated-source
  identification (`list_curated_sources/2`, US-31.1) subsystems into a single
  resolution layer: `:curated` wins ONLY when a governed curated source's
  ABSOLUTE (never pool-relative, min-max-normalized) confidence score clears a
  scale-matched threshold AND beats the best retrieved candidate by a margin AND
  is authoritative (published, not superseded, not in an open
  `:potential_conflict`); otherwise `:retrieved`. Both branches return an
  identical `results`/`meta` key shape carrying `meta.provenance`
  (`:curated`/`:retrieved`), `meta.confidence`, and `meta.curated_article_id` — a
  caller branches on `meta.provenance` alone, never on which subsystem answered.
  See [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md).
  - **Curated-source identification** (US-31.1) — a GOVERNED, non-self-assignable
    `articles.curated_at`/`curated_by` marker (excluded from `@cast_fields`),
    written only by `Knowledge.mark_curated/3` / `unmark_curated/3` (audited).
    Content edits (title/body/publish) invalidate the marker, forcing
    re-curation. `list_curated_sources/2` applies system-scope precedence (a
    tenant's own curated answer always wins over a `scope: :system` canonical on
    the same topic) and excludes superseded/conflicted articles.
  - **Progressive disclosure** (US-31.3) — `Knowledge.progressive_index/3` /
    `progressive_drill/3` (`GET /api/v1/knowledge/progressive_index` /
    `GET /api/v1/knowledge/progressive/:id`, MCP tools
    `knowledge_progressive_index` / `knowledge_progressive_drill`): a bounded,
    top-K-capped topic index of compact stubs (curated-preferred, one hop of
    `:relates_to` hub enrichment), then a full-body drill.
- **Docs** — new
  [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md) (the
  resolution rule, provenance contract, progressive disclosure, and the
  three-layer model positioning hybrid retrieval within the Knowledge Wiki
  alongside Agent Memory and the Context Retriever); README/CLAUDE.md/AGENTS.md
  extended. **#305 and #306 describe the same feature** — recommend closing one
  as a duplicate rather than tracking separately; the "#305 reconcile
  `docs/cole-medin-self-evolving-wiki.md`" item is already satisfied by the
  epics 28–30 reconciliation (KB hub `fb9abd73`/`3ee5f890`).

### Verification

- **Terminal e2e + negative control** (US-31.5,
  `test/loopctl/knowledge/hybrid_e2e_test.exs`) — a governed curated
  refund-policy article suppresses an unrelated fuzzy chunk (`:curated`, hoisted
  first); archiving that curated article (removed from the published search
  pool, unrelated chunk unchanged) flips the result to `:retrieved` and surfaces
  the previously-suppressed chunk, proving causation; a niche non-curated topic
  falls to `:retrieved`; a near-but-wrong curated doc is never mislabeled
  `:curated`; `:curated`/`:retrieved` meta share an identical key shape. Tenant isolation is proven across the resolver, progressive index/drill,
  and the HTTP API; a system-scoped curated article participates without
  overriding a tenant's own; a superseded/conflicted curated article is never
  authoritative without the conflict surfaced.

## [Unreleased] — 2026-07-10 — Context Retriever (Epic 30)

### Added

- **Context Retriever** — a governed, auto-generated agent query surface over
  loopctl's own STRUCTURED records (`projects`/`stories`/`epics`), the third of
  loopctl's three agent information layers (Knowledge Wiki / Agent Memory /
  Context Retriever). See [`docs/context-retriever.md`](docs/context-retriever.md).
  - **Entity registry** (`Loopctl.ContextRetriever.Entity`/`Registry`, table
    `entity_definitions`) — a tenant admin declares a named **entity** (typed
    `fields` + a backing source) over `POST/PATCH/DELETE /api/v1/entities`. The
    definition IS the executor's field allowlist, bounded by a SERVER per-source
    column allowlist that excludes `tenant_id`/`metadata`/custody columns. Defining
    requires role ≥ `user` + a human-anchored tenant; per-tenant entity count and
    fields-per-entity are capped. Relationships/joins are out of scope for v1.
  - **Tool generator** (`ToolGenerator`) — emits per-entity `cr_filter_<entity>_by_<field>`
    tools (one per filterable field) and a `cr_search_<entity>` tool when a declared
    searchable TEXT field is covered by the source's `search_vector`; served at
    `GET /api/v1/retrieve/tools`.
  - **Executor** (`Executor.run/3`, the security boundary) — `POST /api/v1/retrieve/:entity`
    runs a filter/search parameterized (Ecto-pinned values / `websearch_to_tsquery`
    — never model SQL), dual tenant-scoped (RLS `loopctl_app` role + explicit
    predicate), execute-time allowlist-rechecked, shaped to declared columns only,
    audited fail-closed (`audit_log` `entity_type: "context_retrieval"`; no rows
    without a persisted audit trail), and per-tenant rate-limited (429 over-limit,
    unexecuted). Injection payloads match literally; pagination size + offset are
    capped.
- **MCP dynamic tool listing** — `mcp-server/lib/generated-tools.js` fetches the
  tenant's `cr_*` specs, appends them to ListTools (TTL-cached, negative-cached on
  outage, non-`cr_`/static-colliding specs dropped), and dispatches a `cr_*` call
  to `POST /api/v1/retrieve/:entity` under the same agent key as static reads.
- **Docs** — new [`docs/context-retriever.md`](docs/context-retriever.md) (the
  three-layer model, architecture, security model, surfaces); README/CLAUDE.md/AGENTS.md
  extended to a three-way `retrieve_*` vs `knowledge_*` vs `memory_*` decision
  guide. The #309 "reconcile `docs/cole-medin-self-evolving-wiki.md`" item was
  already satisfied (removed PR #310; content in KB hub `fb9abd73`); the epic folder
  is `epic_30`.

### Verification

- **Terminal e2e + security** (US-30.7) — `Loopctl.E2E.ContextRetrieverJourneyTest`
  (define → ListTools → filter + search via API and the MCP-derived body agree,
  tenant-scoped) and `Loopctl.E2E.ContextRetrieverSecurityTest` (injection in
  filter + search match literally; non-allowlist rejected on every surface;
  cross-tenant define/list/query isolation via context/API/MCP with a positive
  control; no undeclared-column leak; an audit record per execution; `/retrieve`
  429 over-limit) — both run under the non-owner app role. All Context Retriever
  endpoints render at `/swaggerui`.

## [Unreleased] — 2026-07-10 — Agent Memory auto-promotion (Epic 29, Part 2)

### Added

- **Memory promotion pipeline** — compiles a session's short-term turns into durable
  long-term `:promoted` memories without an explicit agent write. Triggered explicitly
  (`POST /api/v1/memory/promote {session_id}` → `Loopctl.Memory.promote_session/1`) or
  by the all-tenants cron `Loopctl.Workers.MemoryPromotionSweepWorker`; both enqueue the
  per-session `Loopctl.Workers.MemoryPromotionWorker` (unique per
  `(tenant_id, subject_id, session_id)`).
  - **Idempotency spine** — a `session_promotions` watermark (session content hash) skips
    an unchanged session WITHOUT an LLM call; re-running promotion adds no net rows
    (measured including superseded).
  - **Confidence gate + hash dedupe/supersede** — survivors above the confidence
    threshold are written with their `confidence`, embedded synchronously at write time,
    exact-deduped on `embedding_content_hash`, and near-dup superseded (source-scoped to
    `:promoted`, never clobbering an `:explicit` memory).
  - **Per-tenant budget** — a compiles/hour cap (atomic reservation incl. in-flight jobs)
    returns HTTP 429 with NO LLM call when exceeded.
  - **TTL-window invariant** — `sweep_interval < sweep_window < session_ttl`, sweep
    promotes oldest-active-first to bound the golden-nugget-loss window.
  - **Prompt-injection resistance** — session content is scope-enforced (the LLM never
    sees foreign turns) and `cross_links` are tenant + visibility validated, so a
    compromised model's foreign/fabricated article link is stripped before write.
- **MCP tool** — `memory_promote` (compile a session; caller's own sessions only; scope
  key-derived). The `/api/v1/memory/promote` endpoint renders at `/swaggerui`.
- **Promotion-quality eval (US-29.5)** — `Loopctl.Memory.PromotionEval` scores the
  compiler's precision/recall against a committed labeled dataset under a reserved,
  structurally-excluded eval subject; calibration only, never gates promotion.
- **Telemetry** — `[:loopctl, :memory_promotion, *]` events (`:swept` `:skipped`
  `:compiled` `:gated_out` `:promoted` `:superseded` `:degraded` `:quota_exceeded`
  `:budget_exceeded` `:failed` `:eval`) so a failing/budget-walled/degraded sweep is
  observable, not silent.
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md) extended with the full
  promotion lifecycle, the watermark/budget/TTL invariants, the confidence + eval story,
  the prompt-injection stance, and the Claude Code Stop-hook recipe (cross-ref
  `mkreyman/claude-config#85`, not implemented here);
  [`docs/observability/promotion.md`](docs/observability/promotion.md) documents the
  pipeline metrics.

### Verified (US-29.6, terminal)

- **Promotion e2e** (`Loopctl.Memory.PromotionE2ETest`) — a session promoted via
  `POST /api/v1/memory/promote` is recall-able through BOTH the context and the API with
  `source: :promoted`, `source_session_id`, and `confidence`.
- **Idempotency + cross-scope** (`Loopctl.Memory.PromotionIsolationTest`) — re-promotion
  (explicit + sweep) adds no net rows counting superseded (watermark skip); a promoted
  `(tenant T, subject A)` memory is invisible to tenant U AND subject B via context, API
  (recall / index / forget), with MCP scope-blindness proven in
  `mcp-server/test/memory_tools.test.js`.
- **Unattended safety** (`Loopctl.Memory.PromotionSafetyTest`) — injection produces no
  cross-tenant-linked memory; an over-budget promote is 429 with no LLM call; a compile
  failure emits `:failed` telemetry.

## [Unreleased] — 2026-07-09 — Agent Memory (Epic 28, Part 1)

### Added

- **Agent memory subsystem** — a per-agent PRIVATE working memory, isolated per
  `(tenant_id, subject_id)` and kept strictly separate from the shared Knowledge
  Wiki. Two tiers:
  - **Session memory** (`session_memories`) — short-term, append-only, chronological
    turns/facts with a required `expires_at`, pruned by
    `Loopctl.Workers.SessionMemoryPruneWorker`. No embedding.
  - **Long-term memory** (`memories`) — durable facts embedded as `vector(1536)`
    (populated asynchronously by `Loopctl.Workers.MemoryEmbeddingWorker`) and
    recalled by HNSW cosine similarity, with a supersede/forget lifecycle and a
    per-`(tenant, subject)` live-row quota.
- **HTTP API** — `POST /api/v1/memory` (remember), `POST /api/v1/memory/recall`
  (semantic recall; degrades to a scoped text match, never a silent empty),
  `GET /api/v1/memory` (list; superadmin `?all_subjects=true` oversight), and
  `DELETE /api/v1/memory/:id` (forget). Scope is derived from the API key, never the
  body; the endpoints render at `/swaggerui`.
- **MCP tools** — `memory_remember`, `memory_recall`, `memory_list`, `memory_forget`
  (four tools; scope key-derived, no `tenant_id`/`subject_id` surface).
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md): architecture, the two
  tiers + session TTL/pruning, the `subject_id` derivation + BYPASSRLS heavy-read
  structural guard, when to use memory vs knowledge (vs the future context
  retriever), the PII/secret (BYO-embedding) stance, and the auto-promotion (#308) /
  skills-consumer (`claude-config#85`) seams.

### Verified (US-28.5, terminal)

- End-to-end (write via API → recall via context AND API), cross-surface isolation
  (cross-tenant AND cross-subject invisible/immutable across context, API, and MCP,
  on both the semantic and fallback paths), and an `@tag :scale` recall gate proving
  a needle subject recalls its own top-k among an ~80k multi-subject corpus (the
  over-fetch pool + outer subject filter does not starve a subject at scale).

## [Unreleased] — 2026-07-03 — per-tenant BYO Anthropic LLM config + usage (Epic 28, #179)

### Added

- **Per-tenant BYO Anthropic config** — `GET` / `PATCH /api/v1/tenants/me/llm-config`
  (role `:user`): each tenant supplies its OWN Anthropic API key (encrypted at rest,
  never returned — only `has_api_key` + a last-4 hint) and picks a model per operation
  (`extraction_model` / `classification_model` / `merge_model`). loopctl fronts no LLM
  cost. Setting/rotating a key writes an audit event (without the value).
- **Per-tenant LLM usage tracking** — `GET /api/v1/knowledge/llm-usage`
  (role `:orchestrator`): token usage grouped by operation + model + source_type + day
  over an optional date range, with offset/limit pagination (default 90-day lookback).
  Record-only — no budget enforcement.

### Changed — BREAKING (mandatory BYO)

- **Tenant knowledge-LLM work now REQUIRES a per-tenant Anthropic key.** Content
  ingestion, category classification, article merge, and review-finding extraction all
  resolve the tenant's OWN key via `Loopctl.Llm.resolve/2` — there is **no**
  global-system-key fallback. The global `ANTHROPIC_API_KEY` / `:anthropic_provider`
  config path was removed.
- With no key configured, `POST /knowledge/ingest[/batch]` returns **422** with
  `code: "no_api_key"` and a remediation hint; the Oban workers `{:discard}` cleanly
  (no crash, no retry loop). A `[:loopctl, :llm, :blocked]` telemetry event and an
  `llm.blocked_no_api_key` audit entry are emitted when a tenant is blocked.
  (Single-tenant today; no grace period — the operator sets a key.)

## [Unreleased] — 2026-06-30 — docs sync + agents'-KB endpoints backfill

### Added

- **KB conflict resolution API** — `GET /api/v1/knowledge/conflicts` (list potential-conflict
  article pairs the auto-linker/nightly lint flagged as too-similar-to-coexist) and
  `POST /api/v1/knowledge/conflicts/resolve` (record a `dismiss`/`supersede`/`merge` verdict;
  the nightly executor acts on `supersede`/`merge` only at `confidence: high`, and `merge`
  LLM-synthesizes both sources into one new draft, never auto-published). Role: agent.
  MCP tools `knowledge_conflicts`, `knowledge_resolve_conflict` (MCP 2.26–2.28).
- **`GET /api/v1/knowledge/analytics/retrieval-metrics`** — daily retrieval-precision time
  series (share of search results the agent then opened). Role: orchestrator. MCP tool
  `knowledge_retrieval_metrics` (MCP 2.29).
- **`GET /api/v1/knowledge/curation-log`** — human-readable feed of KB curation adjustments
  (novelty-gate `gate_duplicate`/`gate_draft`; conflict `supersede`/`merge`/`dismiss`),
  recorded only while a tenant has `settings.kb_curation_log` enabled (default off).
  Role: orchestrator. MCP tool `knowledge_curation_log` (MCP 2.30).
- **Creativity primitives** — `POST /api/v1/knowledge/novelty`, distant-pairs, random-walk,
  and suggested-links endpoints (MCP `knowledge_novelty`, `knowledge_distant_pairs`,
  `knowledge_random_walk`, `knowledge_suggest_links`).
- **API root discovery links** — `GET /api/v1/` now also returns `discovery`, `routes`, `wiki`,
  and `mcp_server` pointers so agents hitting the root have a path to the MCP server and
  discovery documents instead of dead-ending.

### Docs

- Corrected the MCP tool count to **69** (was 57/65) across the README, `mcp-server/README.md`,
  the landing/docs pages, and `CLAUDE.md`, and documented the 4 previously-undocumented tools.
- Fixed drifted docs: UI-test endpoints are nested under `/projects/:project_id/ui-tests`
  (README); `verified_status` values are `unverified`/`verified`/`rejected` (not `pass`/`fail`),
  and `initial_verified_status` on import is honored only for a superadmin caller
  (orchestration guide); `knowledge_export` has no `obsidian` format and its download needs a
  user key (`mcp-server/README.md`); `GET /` serves the HTML landing page (it does not redirect).
- `GET /api/v1/routes` is now described as a curated index (not the exhaustive surface), points
  to the OpenAPI spec, and lists the CoC v2 dispatch routes, `recover-cap`, `acceptance_criteria`,
  and the new knowledge endpoints.
- Refreshed `model_name` examples (OpenAPI schema, MCP tool descriptions, PRD) to the current
  `claude-sonnet-5` id. `model_name` remains a free-form string and cost is caller-reported, so
  no code change is needed to record a new model.

## [Unreleased] — 2026-06-25 — heavy-read pgbouncer outage fix (US-27.13)

### Fixed

- **HeavyReadRepo pgbouncer `08P01` outage (US-27.13):** the dedicated heavy-read pool
  carried a `statement_timeout` connection STARTUP parameter (`parameters:` in
  `config/runtime.exs`), which Fly MPG's pgbouncer rejects with
  `FATAL 08P01 unsupported startup parameter`, crash-looping the pool so it never
  established a connection — every heavy vector/enumeration endpoint (`suggested_links`,
  semantic search, `distant_pairs`, `novelty`, heavy enumeration) hung then `503/504`'d.
  It was invisible to CI because the suite connects to direct Postgres (which accepts the
  startup param) and aliases heavy reads to `AdminRepo`. The server-side `statement_timeout`
  is now applied per-read via `SET LOCAL` inside a transaction (the pgbouncer-safe mechanism).

### Changed

- **Heavy-read `statement_timeout` configuration:** set via `HEAVY_READ_STATEMENT_TIMEOUT_MS`
  (default 10s) and the per-endpoint `:heavy_read_statement_timeout_overrides` map, applied
  per-read via `SET LOCAL` — **NOT** a connection startup `:parameters` value
  (pgbouncer-incompatible). A server GUC that must persist at connect is set via `ALTER ROLE`
  (the documented `hnsw.ef_search` lever), never a startup parameter.

### Added

- **Recurrence guards:** `config_pgbouncer_safe_parameters_test.exs` (scans the config
  source — incl. `runtime.exs` — and fails on any pgbouncer-incompatible repo `:parameters`)
  and a pgbouncer-layer e2e (`pgbouncer_startup_params_test.exs` + a CI `pgbouncer-e2e` job
  that gates deploy) which reproduces the `08P01` rejection and proves `SET LOCAL` enforces
  through the proxy.

## [Unreleased] — 2026-06-22 — knowledge wiki harvest-hardening (#132–#138)

A batch of Knowledge Wiki API changes for reliable agent/harvest workflows.
(Supersedes the #120 draft-by-default + orchestrator-publish-gate notes below.)

### Added

- **Idempotency_key (#137):** `POST /api/v1/articles` accepts `idempotency_key`
  (per-article, max 255). Re-creating with the same key is a no-op that returns
  a reference to the existing article (`deduplicated: true`, id only — no body),
  preventing partial duplicates on re-capture. Distinct from
  `source_type`/`source_id` (a shared source identifier).
- **Lag-free enumeration (#134/#135):** `GET /api/v1/articles` filters by
  `source_type`, `source_id`, and `idempotency_key`; new MCP `knowledge_list`
  wraps it. This is the lag-free, all-status read of record for
  dedup/idempotency/repair — vs `knowledge_search`, which is ranked,
  published-only, and lags writes.
- **Bulk delete (#136):** `POST /api/v1/knowledge/bulk-delete` (role user) —
  partial-success soft-delete by `article_ids`, `source_type`+`source_id`, or
  `tag`+`confirm:true` (exactly one selector). MCP `knowledge_bulk_delete`.
- **Ingest publish opt-in (#133):** `POST /api/v1/knowledge/ingest` + `/batch`
  accept `publish: true`; extracted articles stay **draft by default**
  (lower-trust LLM output) but can be published in one step.

### Changed

- **Publish-on-create is the default for every role, including agent (#133)** —
  `POST /api/v1/articles` publishes immediately; draft is now the opt-in
  (`draft: true` / `status: "draft"`). The orchestrator-only publish gate is
  removed on the create path (publishing a wiki article is neither destructive
  nor story chain-of-custody); the standalone publish endpoint and system-scope
  gate are unchanged.
- **Bulk-publish is partial-success + uncapped (#132, #138.3):** publishes every
  valid draft and returns per-id outcomes (published/skipped/not_found/errored)
  in `meta.results` instead of failing the whole call; already-published ids are
  skipped (idempotent); the 100-id cap is gone (auto-chunked, ≤5000).
- **Tag cap raised 20 → 50 (#138.2).**

### Fixed

- **Invalid `?status=`/`?category=` → 400 with allowed values (#138.1)** on
  `GET /api/v1/articles` (was a 404/500 from an `Ecto.Enum` cast); malformed
  list/map query params no longer 500.
- **429 `Retry-After` is always ≥ 1s (#136)** (was `reset_at - now`, which could
  be ≤ 0 at a window boundary); rate limits documented on `RateLimitError`.

### Docs

- Documented the witness/STH request-header workflow for non-MCP clients (#138.4)
  and the search-vs-list distinction.

## [Unreleased] — 2026-06-19 — create-and-publish + draft note (#120)

### Added

- `POST /api/v1/articles` accepts `publish: true` to create-and-publish in one
  call. This is gated at **orchestrator+** (mirrors `POST /articles/:id/publish`);
  an agent requesting publish gets `403 publish_requires_orchestrator`.

### Changed

- The create response now carries a `note` making the lifecycle explicit —
  articles are created as **draft** (not visible in search/index/context) unless
  published, which the two-step flow made easy to miss (#120).

### Security

- The initial article status is now set **server-side** on create; a
  caller-supplied `status` is ignored except that `status: "published"` is
  treated as `publish: true` (and gated the same way). This closes a gap where
  an agent could self-publish — or set `archived`/`superseded` — by passing
  `status` directly in the create payload, bypassing the orchestrator publish
  gate.

## [Unreleased] — 2026-06-19 — search total_count semantics (#119)

### Changed

- `GET /api/v1/knowledge/search` now returns `meta.total_count_scope` (and
  `meta.search_mode`) so callers can tell what `meta.total_count` counts in the
  active mode: `keyword_matches` (stop-word-filtered tsquery matches),
  `ranked_corpus` (semantic ranks all embedded published articles — that
  embedded set's size, not a match count, and ≤ the published count),
  `merged_candidates` (combined: deduped union of a keyword and a semantic
  sub-search, each capped at 50, so up to ~100), or `filtered_set` (list mode:
  complete set). The
  OpenAPI description and MCP tool docs now spell out the per-mode semantics and
  stop-word behavior, and direct corpus-sizing to list mode or
  `GET /knowledge/stats` (#119). No value changed — `total_count` was already
  uncapped per mode; this makes its meaning explicit.

## [Unreleased] — 2026-06-19 — knowledge stats endpoint (#118)

### Added

- `GET /api/v1/knowledge/stats` (and `GET /api/v1/projects/:project_id/knowledge/stats`)
  — aggregate article counts (`total`, `by_category`, `by_status`) via cheap
  `COUNT(*) GROUP BY` with no article metadata loaded. Answers "how many
  articles are here?" without paging the index. Counts span all statuses;
  `by_status` shows the published/draft/archived/superseded split. Role: agent+.
  Exposed via the MCP `knowledge_stats` tool.

## [Unreleased] — 2026-06-19 — knowledge_index field projection (PR #126)

### Added

- `GET /api/v1/knowledge/index` accepts a `fields` query param — a
  comma-separated projection of `id, title, category, tags, status,
  updated_at`. `id` and `category` (the grouping key) are always included;
  unknown fields return `400` (matching the existing `category` validation).
  `meta` now echoes the applied `fields` and adds `has_more` (a synonym for the
  existing `truncated`). The MCP `knowledge_index` tool gains a matching
  `fields` parameter (array or csv). Non-string `fields`/`category`/`tags`/
  `limit`/`offset` params now return `400`/are ignored rather than raising a
  `500`.

### Changed

- **Default response shape changed** (intentional): without `fields`, each
  article object now includes only `id, title, category` instead of all six
  metadata fields. This shrinks the catalog payload dramatically — previously
  the index serialized every field (including the full `tags` array) for up to
  1000 articles per page, producing ~545 KB responses that overflowed MCP
  clients' token limits (#117). Callers that need `tags`/`status`/`updated_at`
  must now request them explicitly via `fields`.

## [Unreleased] — 2026-06-18 — Concurrent article create (PR #116)

### Changed

- `POST /api/v1/articles` (and MCP `knowledge_create`) is now concurrency-safe.
  A create that races/retries into the `(tenant_id, title)` active unique index
  no longer returns a spurious `422 "tenant_id has already been taken"`: an
  **identical-body** collision returns the existing article idempotently as
  **HTTP 200**, and a **different-body** collision returns **`409 title_conflict`**
  (with `existing_article_id`) instead of a 422 the client retries into. The
  unique-violation is attributed to `title` rather than the misleading
  `tenant_id`. Fixes #113/#114.

## [Unreleased] — 2026-04-17 — Import merge + agent ergonomics (PR #105)

### Added

- `POST /api/v1/projects/:project_id/stories` — create a single story by
  epic number (agent-friendly alternative to the UUID-based
  `POST /epics/:epic_id/stories`). Role: `:orchestrator`.
- `POST /api/v1/stories/:id/backfill` — mark a story as verified when the
  work was completed outside loopctl. Records provenance in
  `metadata.backfill` plus an `action: "backfilled"` audit entry and a
  `story.backfilled` webhook. Refused for any story with dispatch lineage
  (non-pending `agent_status`, `assigned_agent_id`,
  `implementer_dispatch_id`, or `verifier_dispatch_id` set) — this is the
  structural guard that makes backfill safe regardless of role. Role:
  `:orchestrator`.
- `story.backfilled` added to the webhook event allowlist.

### Fixed

- `POST /api/v1/projects/:id/import?merge=true` no longer returns
  `epics[0].tenant_id: has already been taken for this project` when
  clients serialize epic numbers as strings. Epic numbers are normalized
  to integers (and story numbers to strings) before validation and DB
  lookups.
- Fallback changeset rendering translates Epic/Story unique-number
  violations into `"Epic 72 already exists in this project. Use
  merge=true..."` regardless of which controller surfaced the error.

### Changed

- Data-op roles: create/update for epics, stories, and dependencies
  lowered from `:user` to `:orchestrator`. DELETE stays at `:user` per
  the destructive-op rule. CLAUDE.md Security section clarified.
- `/loopctl:orchestrate` skill carves out "data operations" (imports,
  creates, backfills, dispatches, reads) as operations the orchestrator
  can perform directly without dispatching a sub-agent. Sub-agents are
  only required for editing application code.

### Security

- `unique_constraint` error translation now scopes to the `_number_`
  index specifically, so future unique constraints (external_id, slug,
  etc.) on Epic/Story schemas won't be mis-reported as "X already
  exists."

## [1.0.0] — 2026-04-12 — Chain of Custody v2

27 stories across 7 phases implementing a six-layer trust model for
AI agent development loops. Full spec: `docs/chain-of-custody-v2.md`.

### Added — Chain of Custody v2 / US-26.0.1

- **Tenant signup ceremony with WebAuthn enrollment**.
  - New public LiveView at `/signup` that collects tenant metadata and
    initiates a FIDO2 registration ceremony via `navigator.credentials.create()`.
    Supports both cross-platform authenticators (YubiKey, etc.) and platform
    authenticators (Touch ID, Windows Hello).
  - `tenant_root_authenticators` table storing `credential_id`, COSE public
    key, attestation format, sign counter, and friendly label per enrolled
    key. One-to-many from tenant to authenticator, unique on
    `(tenant_id, credential_id)`, RLS-enabled.
  - `tenants.status` gains a `:pending_enrollment` value; an Oban cron
    worker (`PendingEnrollmentCleanupWorker`, every 5 minutes) deletes
    tenants stuck in that state past the 15-minute TTL.
  - `Loopctl.WebAuthn.Behaviour` + `Loopctl.WebAuthn.Wax` adapter, wired
    via config-based DI so tests can swap in `Loopctl.MockWebAuthn`.
  - `Loopctl.Tenants.signup/1` atomically creates the tenant, persists
    every verified authenticator, flips the status to `:active`, and
    writes the audit log genesis entry in a single `Ecto.Multi`.
  - OpenAPI schemas: `TenantSignupRequest`, `WebAuthnChallenge`,
    `WebAuthnAttestation`; `TenantResponse` updated to surface the new
    `pending_enrollment` status.
  - New post-signup onboarding LiveView at `/tenants/:id/onboarding`
    that scaffolds the four-step operator checklist (audit key
    generation, system article tour, first project, first agent).
  - JavaScript `WebAuthn` hook in `assets/js/hooks/webauthn.js`.
  - `CoreComponents` module providing `<.input>`, `<.icon>`, and
    `<.flash_group>` in the design-system palette.

### Removed

- `POST /api/v1/tenants/register` and the `Loopctl.Auth.register_tenant/1`
  helper it called. Chain of Custody v2 requires a WebAuthn-gated signup
  ceremony; the legacy unauthenticated tenant creation path has no
  replacement and any request to it now 404s. This enforces AC-26.0.1.7.
