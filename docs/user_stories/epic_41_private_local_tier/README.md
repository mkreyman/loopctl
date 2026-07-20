# Epic 41 — Private / Local-Only Knowledge & Memory (data sovereignty)

**Status: DRAFT — re-scoped 2026-07-20 from the parked epic 39 draft (2026-07-15).
Renumbered 39 -> 41 because epic 39 was reused by the shipped repo-coordination-bus
epic. Every story MUST go through the enhanced-review workflow (against the story
text AND the diff) before/at implementation.
Breadcrumbs: GH issue #409 (problem), GH issue #331 (the companion half, shipped),
PR #410 (this draft), `docs/epic_41_breadcrumb.md`.**

Let a tenant run the entire knowledge + memory pipeline against **local or
self-chosen OpenAI-compatible models with zero third-party egress** — and *enforce*
that guarantee rather than hope for it. **On the hosted service as well as a
self-hosted instance.**

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
| `embedding_base_url` | tenant | **write** | extend existing `set_llm_config` MCP tool + PATCH API |
| extraction/classification/merge endpoint | tenant | **write** | same tool, same pattern |
| `local_only`, `encrypt_body` scope marking | tenant/project | **write** | new MCP tool + endpoint (US-41.4) |
| `LOCAL_ENDPOINT_ALLOWLIST` | deployment | **read-only** — it is the trust root; an agent must never widen its own allowlist | reported by `egress_posture` |
| embedding **dimension** | tenant (US-41.1) | **write** (choice of model) — the DDL is never agent-writable | published on `.well-known/loopctl`; validated by a config-time probe |

Two consequences fall out of that audit, and both are new relative to the 39 draft:

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

## Grounded current state (re-verified against master 2026-07-20)

Every claim below was checked against the code, not carried over from the 39 draft.
Three of them changed.

| Capability | Today | Gap |
|---|---|---|
| Embedding **dimension** | `:embedding_dimensions` (`config/config.exs:16`) is a **changeset validation only** (`article.ex:490,506`, `memory.ex:281`); the column type is pinned by **two** `ALTER TABLE`s (`20260410022854:25`, `20260709000000:101`). **HNSW indexes do NOT pin a dimension** — they inherit the column type (`repo/hnsw_index.ex:125`). | per-tenant dimension -> **US-41.1** |
| Embedding **endpoint** | server-wide `runtime.exs:382-385`, read at `embedding_client.ex:194` | per-tenant `embedding_base_url` -> **US-41.2** |
| Embedding **key** | **already per-tenant and MANDATORY** — no tenant key, no call (`embedding_client.ex:58-60,75-77`); the global operator key was deliberately removed (`runtime.exs:375-381`) | none — this is why US-41.2 is one field, not a subsystem |
| Extraction **endpoint** | `@base_url` hardcoded (`anthropic.ex:37`, used `:139`). No provider behaviour — but six **task-level** behaviours exist and are config-swappable (already Mox-mapped in `config/test.exs`) | 4 sibling impls, not a refactor -> **US-41.3** |
| Egress **enforcement** | `Provider.Admission` sits before all three provider `Req.post`s (`anthropic.ex:118`, `embedding_client.ex:91,101`) — but it is **FAIL-OPEN by design** (`admission.ex:81-97`, `fail_open/2:183`), a burst shedder, not a deny-gate | fail-CLOSED guard + posture surface -> **US-41.4** |
| Non-provider **egress** | webhook delivery posts tenant-supplied URLs and **bypasses Admission entirely** (`webhooks/req_delivery.ex:43`) | -> **US-41.5** (missed by the 39 draft) |
| Data **at rest** | `articles.body` and `memories.text` are plaintext `:string`; Cloak covers exactly 4 fields (2 BYO keys, `webhook.signing_secret_encrypted`, `idempotency_cache.response_data`); `articles.search_vector` is generated from title+body | encrypted tier -> **US-41.6** |
| Egress **provenance** | none — posture is config, not a recorded fact | witnessed custody claim -> **US-41.7** |

## The re-scope: split the axis the 39 draft conflated

The parked draft asserted the private tier "is only meaningful on a self-hosted
instance" and decided a deployment-level dimension. That forks the product, and it
blocks the very user who filed #409 — who is a **hosted** tenant. Two independent
axes were merged:

- **Axis A — where inference happens.** US-41.2, 41.3, 41.4, 41.5. All per-tenant.
  These ship on the hosted service unchanged. A hosted tenant points inference at
  their own endpoint and their content never touches Anthropic/OpenAI, while
  keeping every hosted advantage: managed DB, RLS, hash-chained audit, STH witness,
  verification runs, zero ops burden.
- **Axis B — where data rests.** US-41.1 and US-41.6. Also per-tenant, once the
  dimension moves to a side table.

**Superseded decision.** The 2026-07-15 call ("deployment-level dimension,
per-tenant deferred") is reversed. It is now cheap (only two column definitions
move; HNSW inherits) and it is the only version that serves a hosted tenant running
a 768-dim local model. See US-41.1.

## Stories

| Story | Title | Axis | Depends |
|-------|-------|------|---------|
| US-41.1 | Per-tenant embedding dimension via an `article_embeddings` / `memory_embeddings` side table | B | — |
| US-41.2 | Per-tenant embedding **endpoint** + config-time dimension probe with legible remediation | A | US-41.1 |
| US-41.3 | Pluggable extraction/classification/merge endpoint (OpenAI-compatible local chat) | A | — |
| US-41.4 | **Fail-closed** no-egress guard + `local_only` scope marking + `egress_posture` MCP tool + `.well-known` capability publication | A | US-41.2, US-41.3 |
| US-41.5 | Extend the egress guard to non-provider egress (webhook delivery) | A | US-41.4 |
| US-41.6 | Encrypted private-tier bodies at rest + vector-only recall + honest threat model | B | US-41.1 |
| US-41.7 | Egress posture as a **witnessed custody claim** in the audit chain / STH | A | US-41.4 |

## Decisions

- **Per-tenant dimension: YES** (supersedes the 2026-07-15 deployment-level call).
- **Private tier is solved with crypto, not a visibility flag.** Today's
  `private`/`owner` visibility is a metadata string filtered query-side **only for
  agent-role callers** (`coordination.ex:1021-1022`) — user/orchestrator/superadmin
  keys see private articles, and memories have no visibility field at all.
  Hardening that flag is the wrong lever for health/DNA data; encryption is the
  right one.
- **Honest threat model, stated in the docs and the tool descriptions.** US-41.6 v1
  uses a per-tenant DEK **held server-side**. That protects against a DB dump or a
  disk image — exactly what the AC claims — and **NOT** against a compromised app
  server or the operator. A tenant-held KEK is a genuine upgrade and a separate
  story; nothing in this epic may imply we already have it.
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
