# Epic 41 — Private / Local-Only Knowledge & Memory (data sovereignty)

**Status: PARTLY SHIPPED. US-41.1, 41.3, 41.4, 41.5 and 41.7 are merged; US-41.2 and
US-41.6 are not started.** The per-story state and its merge PR live in the Stories
table below — that table is the single source of truth for what is done, and this
header is the only place that summarises it. Everything in the prose below (the
motivation, the audit table, the "Grounded current state" table, the decisions) was
written against master 2026-07-20 and is the epic's DESIGN record: read its present
tense as "at design time", not as a claim about master today.

Recording this mattered enough to fix: GH #551 was filed against a stale reading of
this header and asserted that five stories were open when three of those five had
already merged. A status line nobody updates is worse than no status line, because it
gets cited.

**Re-scoped 2026-07-20 from the parked epic 39 draft (2026-07-15).
Renumbered 39 -> 41 because epic 39 was reused by the shipped repo-coordination-bus
epic. Every story MUST go through the enhanced-review workflow (against the story
text AND the diff) before/at implementation.
Breadcrumbs: GH issue #409 (problem), GH issue #331 (the companion half, shipped),
PR #410 (this draft), `docs/epic_41_breadcrumb.md`.**

Let a tenant run the entire knowledge + memory pipeline against **local or
self-chosen OpenAI-compatible models with zero third-party egress** — and *enforce*
that guarantee rather than hope for it. **On the hosted service as well as a
self-hosted instance.**

**Precision about what "enforce" means, stated up front.** loopctl enforces, in
code and fail-closed, that it will only call endpoints classified as local for a
`local_only` scope. Two of the three inputs to that classification are
operator-controlled facts (network locality, the deployment allowlist); the third —
a **tenant-declared trusted endpoint** — is an **unverified tenant attestation**,
not a verified control. loopctl does not and cannot prove that a declared host is
owned by the declaring tenant. Everywhere a declared endpoint appears (posture
report, custody claim, tool descriptions, this README) it MUST be labelled
*"tenant-declared (unverified attestation), not network-local"*. A claim built on a
declared endpoint is only as strong as the declaration.

## Motivation — two users, one platform gap

Two independent requests converge here:

- **#331 (shipped).** "The KB should be fully agent-usable" — agents got in-place
  edit plus archive/supersede/merge, because those operations are reversible and
  audited, so the human gate bought nothing. Agent autonomy over KB *content* went
  up.
- **#409 (this epic).** A loopctl user wanted to harvest **personal documents**
  into their second brain. Their agent correctly warned that harvesting ships the
  content to third-party model providers, and the fallback — self-hosting with
  local models — was blocked by a hardcoded vector dimension.

Read together they define the actual gap: **agent-native curation of private
data.** Note the ordering hazard — #331 shipped *more agent autonomy over content*
while egress stayed uncontrolled **and undiscoverable**. An agent today can harvest
a DNA file and ship its full text to two vendors, with no supported way to check
first. That makes the egress-posture surface (US-41.4) the highest-value story
here, not the dimension fix.

## Design principle (non-negotiable)

loopctl is **agent-native and self-discoverable — there is NO human UI, by design.**
Every capability here must therefore *work with no UI at all*: an agent must be
able to **discover** the instance's constraints, **configure** what is
tenant-scoped, **verify** the posture, and **get a legible remediation** when it
gets it wrong — all through MCP tools with matching JSON API endpoints.

This has teeth. The following table is the agent-manageability audit for this
epic; anything that fails it is a design bug, not a docs gap:

| Knob | Scope | Agent-manageable? | Surface |
|---|---|---|---|
| `embedding_base_url` | tenant | **NO — role `:user`** (corrected) | `set_llm_config` MCP tool + PATCH API, which is `role: :user` (`router.ex:185-189`) because the same PATCH stores tenant secrets |
| extraction/classification/merge endpoint | tenant | **NO — role `:user`** (corrected) | same tool, same route, same reason |
| `local_only`, `encrypt_body` scope marking | tenant/project | **asymmetric**: enabling (tightening) at `:orchestrator`+, clearing at `:user` | new MCP tool + endpoint (US-41.4) |
| tenant-declared **trusted endpoints** | tenant | **NO — role `:user`**; public addresses only, purpose-scoped (`inference`/`webhook`) | new MCP tool + endpoint (US-41.4); reported by `egress_posture` |
| `LOCAL_ENDPOINT_ALLOWLIST` | deployment | **read-only at every role** — it is the trust root; nobody widens it through the API. Its CONTENTS are operator-plane infrastructure state and are **not** disclosed to `:agent` | `egress_posture` shows contents at `:user`+; at `:agent` it shows only the caller's own endpoints and their verdicts |
| `egress_posture` (read) | tenant | **read at `:agent`** — verify-before-harvest must work with the key an agent already holds | new MCP tool + endpoint (US-41.4) |
| embedding **dimension** | tenant (US-41.1) | **NO — follows the endpoint write at `:user`**; the DDL is never writable from the request path at any role | published on `.well-known/loopctl`; validated by a config-time probe |

**Correction to the 39 draft (and to an earlier version of this table).** The draft
asserted that `embedding_base_url` and the chat endpoint were *agent*-writable "via the
existing `set_llm_config` tool". That is false and was never true: `PATCH
/tenants/me/llm-config` sits in the `role: :user` scope (`router.ex:185-189`) precisely
because it stores tenant secrets, and `mcp-server/index.js:1836-1843` sends the exact
`LOOPCTL_USER_KEY` with the global-key override deliberately bypassed (reviews #12/#13).
Lowering that route to `:agent` would be a trust-boundary change requiring the CLAUDE.md
role-hierarchy argument, and this epic does **not** make it. Endpoint configuration is a
**human/user-role** act; everything an agent needs at run time — discovery
(`.well-known`), verification (`egress_posture`), and tightening (`local_only` at
orchestrator+) — stays agent-reachable. The no-UI principle is preserved by making
configuration *scriptable through the API by the tenant's user key*, not by widening what
an agent key may do with secrets.

Three consequences fall out of that audit, and all three are new relative to the 39 draft:

1. **Publish instance capabilities on `.well-known/loopctl`** (the US-26.0.4
   discovery endpoint): supported embedding dimensions, whether non-default
   endpoints are permitted, which tiers exist. An agent can then discover the
   constraint *before* it authenticates, let alone harvests.
2. **Probe at config time, not at write time.** Without this, an agent points
   `embedding_base_url` at a local Ollama, vectors come back 768-dim, and the
   failure surfaces much later as an opaque changeset error at
   `article.ex:490`. `set_llm_config` must issue one test embedding against the
   supplied endpoint, check the dimension, and fail fast with a `meta.remediation`
   payload — the same ACTION-REQUIRED shape `knowledge_search` already returns for
   a missing embedding key.
3. **"Local" is two concepts, not one.** *Network* locality (loopback / private
   ranges / the deployment allowlist) and *non-third-party-ness* (an endpoint the
   tenant owns and attests to) are different things, and conflating them breaks the
   hosted case outright: on the hosted instance the server's loopback and private
   ranges are the **operator's** network, so a hosted tenant's own Ollama/TEI box is
   reachable only via a public hostname (VPS, tailscale funnel, their own domain).
   A network-locality-only definition would classify every real hosted `local_only`
   tenant as non-local and hard-block them, with the only escape hatch being an
   allowlist no tenant may touch. US-41.4 therefore adds a **per-tenant declared
   trusted-endpoint list** (role `:user`), and the posture report and custody claim
   label the two distinctly: *network-local* vs *tenant-declared (unverified
   attestation), not network-local*.

   Two hard limits on that list, both enforced (US-41.4 AC-41.4.5 / AC-41.4.9):
   **(i)** a tenant declaration may only name endpoints that still pass UrlGuard's
   full denylist *after DNS resolution* — public addresses only. Private,
   loopback, CGNAT, link-local (incl. `169.254.169.254`) and Fly-6PN carve-outs are
   available ONLY through the operator-controlled deployment allowlist. This follows
   directly from the paragraph above: a hosted tenant's box is public-hostname
   reachable, so the private-range carve-out is not needed for the case that
   justifies the list, and granting it would re-open GHSA-jh42-wf7g-f5rg as a
   self-service feature. **(ii)** each declaration is **purpose-scoped**
   (`inference` and/or `webhook`); a host declared for an Ollama box does not
   silently authorize webhook POSTs of tenant content to it.

## Grounded current state (re-verified against master 2026-07-20)

Every claim below was checked against the code, not carried over from the 39 draft.
Three of them changed.

| Capability | Today | Gap |
|---|---|---|
| Embedding **dimension** | `:embedding_dimensions` (`config/config.exs:16`) is a **changeset validation only** (`article.ex:490,506`, `memory.ex:281`); the column type is pinned by **two** `ALTER TABLE`s (`20260410022854:25`, `20260709000000:101`). `repo/hnsw_index.ex:125` emits `USING hnsw (embedding vector_cosine_ops)` — which works *only because the column is `vector(1536)` today*. pgvector **refuses** to index an unconstrained `vector` column, and a `WHERE dim = N` predicate supplies no typmod, so a mixed-dimension side table needs a typed column/partition per dimension **or** an expression index over an explicit cast. | per-tenant dimension -> **US-41.1** |
| Embedding **endpoint** | server-wide `runtime.exs:391-394`, read at `embedding_client.ex:194` | per-tenant `embedding_base_url` -> **US-41.2** |
| Embedding **key** | **already per-tenant and MANDATORY** — no tenant key, no call (`embedding_client.ex:58-60,75-77`); the global operator key was deliberately removed (comment at `runtime.exs:385-390`) | none — this is why US-41.2 is one field, not a subsystem |
| Extraction **endpoint** | `@base_url` hardcoded (`anthropic.ex:37`, used `:139`). No provider behaviour — but six **task-level** behaviours exist and are config-swappable (already Mox-mapped in `config/test.exs`) | 4 sibling impls, not a refactor -> **US-41.3** |
| Egress **enforcement** | `Provider.Admission` sits before all three provider `Req.post`s (`anthropic.ex:118`, `embedding_client.ex:91,101`) — but it is **FAIL-OPEN by design** (`admission.ex:81-97`, `fail_open/2:183`), a burst shedder, not a deny-gate | fail-CLOSED guard + posture surface -> **US-41.4** |
| Non-provider **egress** | webhook delivery posts tenant-supplied URLs and **bypasses Admission entirely** (`webhooks/req_delivery.ex:43`) — but *not* unguarded: `:20` calls `UrlGuard.pin/1` and `:31` uses `pinned_request_opts` (`redirect: false`), which blocks loopback, private, CGNAT, link-local and Fly 6PN to close GHSA-jh42-wf7g-f5rg. So a `local_only` destination is blocked today by the **SSRF** guard, not the locality guard | one shared egress policy module -> **US-41.5** (missed by the 39 draft) |
| Data **at rest** | `articles.body` and `memories.text` are plaintext `:string`; Cloak covers exactly 4 fields (2 BYO keys, `webhook.signing_secret_encrypted`, `idempotency_cache.response_data`); `articles.search_vector` is generated from title+body | encrypted tier -> **US-41.6** |
| Egress **provenance** | none — posture is config, not a recorded fact | witnessed custody claim -> **US-41.7** |

## The re-scope: split the axis the 39 draft conflated

The parked draft asserted the private tier "is only meaningful on a self-hosted
instance" and decided a deployment-level dimension. That forks the product, and it
blocks the very user who filed #409 — who is a **hosted** tenant. Two independent
axes were merged:

- **Axis A — where inference happens.** US-41.2, 41.3, 41.4, 41.5. All per-tenant.
  These ship on the hosted service unchanged. A hosted tenant points inference at
  their own endpoint — declared as a trusted endpoint per consequence 3 above, since
  a hosted tenant's box is public-hostname-reachable, not network-local — and their
  content never touches Anthropic/OpenAI, while keeping every hosted advantage:
  managed DB, RLS, hash-chained audit, STH witness, verification runs, zero ops
  burden.
- **Axis B — where data rests.** US-41.1 and US-41.6. Also per-tenant, once the
  dimension moves to a side table.

**Superseded decision.** The 2026-07-15 call ("deployment-level dimension,
per-tenant deferred") is reversed: it is the only version that serves a hosted tenant
running a 768-dim local model. It is **not** as cheap as the draft claimed — the
"HNSW inherits the column type, so only two column definitions move" framing was wrong
(see the dimension row above and US-41.1 AC-41.1.2). The reversal and its corrected cost
analysis are recorded in the second brain as the decision article *"Decision: per-tenant
embedding dimension (supersedes the 2026-07-15 deployment-level call) — loopctl epic 41"*
(`ae9a1719-e368-4175-8218-fa6e878cb277`), so the call is retrievable by agents rather
than living only in this README. See US-41.1.

## Stories

Dependency note: **US-41.4 no longer depends on 41.2/41.3, and now leads the epic.**
The classifier, fail-closed guard, egress policy module and `egress_posture` surface are
implementable against today's hardcoded vendor endpoints, and posture reporting is
strictly more truthful early — blocking the epic's highest-value safety control behind
~1.25M tokens of data-model prerequisites was a sequencing bug, not a real dependency.
The reverse edges are real, though: AC-41.2.7 and AC-41.3.3 both require the SINGLE
egress policy module from AC-41.4.9 and forbid a second URL policy, and AC-41.1.3
requires the `.well-known` capability publication from AC-41.4.10 — so 41.2, 41.3 and
41.1 all depend on 41.4. **Implementation order: 41.4 -> 41.1 -> 41.2 -> 41.3 -> 41.5,
then 41.6 / 41.7.**

| Story | Title | Axis | Depends | State |
|-------|-------|------|---------|-------|
| US-41.1 | Per-tenant embedding dimension via an `article_embeddings` / `memory_embeddings` side table | B | US-41.4 (`.well-known` capability publication, AC-41.4.10) | SHIPPED (PR #482) |
| US-41.2 | Per-tenant embedding **endpoint** + config-time dimension probe with legible remediation | A | US-41.1, US-41.4 (egress policy module, AC-41.4.9) | NOT STARTED |
| US-41.3 | Pluggable extraction/classification/merge endpoint (OpenAI-compatible local chat) | A | US-41.4 (egress policy module, AC-41.4.9) | SHIPPED (PR #472) |
| US-41.4 | **Fail-closed** no-egress guard + `local_only` scope marking + tenant-declared trusted endpoints + `egress_posture` MCP tool + `.well-known` capability publication | A | — | SHIPPED (PR #457) |
| US-41.5 | Extend the egress guard to non-provider egress (webhook delivery) | A | US-41.4 | SHIPPED (PR #477) |
| US-41.6 | Encrypted private-tier bodies at rest + vector-only recall + honest threat model | B | US-41.1, US-41.4 | NOT STARTED |
| US-41.7 | Egress posture as a **witnessed custody claim** in the audit chain / STH | A | US-41.4, US-41.5 | SHIPPED (PR #481) |

The two open stories are load-bearing on OTHER work and are cheap to re-verify in code
rather than by trusting this table: US-41.2 is unstarted iff `tenant_llm_settings` has
no `embedding_base_url` field (`lib/loopctl/llm/tenant_llm_settings.ex`) and
`EmbeddingClient` still resolves `base_url` from runtime config
(`lib/loopctl/knowledge/embedding_client.ex`); US-41.6 is unstarted iff
`Loopctl.Egress` still hardcodes `encrypt_body: false` with a "ships in US-41.6"
comment (`lib/loopctl/egress.ex`). Both hold as of 2026-08-02.

## Decisions

- **Per-tenant dimension: YES** (supersedes the 2026-07-15 deployment-level call).
- **Private tier is solved with crypto, not a visibility flag.** Today's
  `private`/`owner` visibility is a metadata string filtered query-side **only for
  agent-role callers** (`coordination.ex:1021-1022`) — user/orchestrator/superadmin
  keys see private articles. The `memories` **table** has no visibility column;
  graduated memory *articles* do carry `metadata.visibility = "owner"`
  (`memory.ex:1907-1912`), also enforced only for agent-role callers (#163), and
  memories themselves are scoped by explicit `(tenant_id, subject_id)` predicates.
  Either way, hardening that flag is the wrong lever for health/DNA data; encryption
  is the right one — and encryption is **tenant/subject isolation at rest, not
  intra-tenant role separation** (US-41.6 AC-41.6.6).
- **Honest threat model, stated in the docs and the tool descriptions.** US-41.6 v1
  uses a per-tenant DEK **held server-side**, wrapped by a KEK that MUST live
  outside the database and outside every database backup (US-41.6 AC-41.6.2) — if
  the KEK were dumped alongside the wrapped DEKs the protection would be nil. That
  protects against a **database dump / stolen database backup**, and against a disk
  image **of the database volume only**; it does NOT protect against an image or
  memory capture of the *application* host, which holds the KEK — nor against a
  compromised app server or the operator. A tenant-held KEK is a genuine upgrade and
  a separate story; nothing in this epic may imply we already have it.
- **`encrypt_body` is at-rest only — it does NOT stop egress.** The two flags are
  independent by design, but the combination `encrypt_body` **without** `local_only`
  is a *posture defect*, not a neutral configuration: every body is still shipped in
  full plaintext to Anthropic (extraction) and OpenAI (embedding) before it is
  encrypted at rest. That is the exact leak the epic exists to close, and "encrypted"
  is precisely the word a user storing health/DNA/financial data will read as
  end-to-end. US-41.6 AC-41.6.13 therefore requires enabling `encrypt_body` on a
  non-`local_only` scope to return an explicit warning with remediation, and
  `egress_posture` to report the combination as the named posture defect
  `encrypted_at_rest_plaintext_in_flight`.
- **Embedding-inversion caveat** stays: stored vectors can partially leak content.
  With US-41.6 the vectors are the residual exposure, so the docs must say so
  plainly rather than implying encryption closes it.
- **Default-off everywhere.** No scope is `local_only` or encrypted by default; the
  hosted instance behaves exactly as today until a tenant opts in.
- **Changing a tenant's embedding model/dimension requires a re-embed** — a
  one-time, agent-triggerable backfill, not an online migration.

## Related (second brain)

`Privacy pillars of a self-hosted AI setup`, `DIY Privacy-Preserving Local AI Stack
(Ollama + Open WebUI)`, `Self-hosting ML models is a practical GDPR/Schrems
strategy`, `On-Premise Deployment Option for Data-Sensitive Firms`,
`Privacy-First Architecture for Medical AI Apps: De-identification`.
