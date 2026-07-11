# Epic 31 — OKF-curated + RAG Hybrid Knowledge Interface

Decomposition of GitHub issues **#305 and #306** (the **same feature** — recommend closing one as a
duplicate). A single hybrid retrieval interface for the knowledge layer that **prefers a curated OKF
answer** and falls back to semantic retrieval for the long tail, with **provenance** and
**progressive disclosure** via index files — so callers never get a confidently-wrong fuzzy chunk
when a canonical answer exists, and never have to choose "RAG or curated."

> **Status: authored with `user-story-writer`, hardened through one enhanced-review round.**
> Three-lens review (analyst / architect / adversarial), each verified against the live code,
> found a critical flaw (a near-but-wrong curated doc mislabeled `:curated` — worse than the RAG
> failure it replaces) plus governance/system-scope/staleness gaps and code-name errors — all
> applied (see "Review changes"). A confirm-pass before `/implement-plan` is still worthwhile.

## Composes an already-shipped subsystem (not greenfield)

Unlike epics 28–30, this is a **resolution layer on top of existing code**: `knowledge_search`
(semantic + `keyword_only` fallback + meta), `knowledge_context`, `knowledge_index`,
`knowledge_okf_export/import` (`lib/loopctl/knowledge/okf.ex`), hubs/links, and article
`category`/`status`/`scope`. Per #305 it explicitly **does NOT re-architect embeddings/vector store**
— it adds the curated-vs-retrieved resolution + provenance + progressive-disclosure on top.

## Story map

| Story | Title | Surface | Depends on |
|-------|-------|---------|-----------|
| US-31.1 | Curated-source identification (the "curated" rule the resolver needs) | domain | — |
| US-31.2 | Hybrid resolver: prefer curated, fall back to retrieval, return provenance | domain | 31.1 |
| US-31.3 | OKF index progressive disclosure (compact index → drill) | domain | 31.1 |
| US-31.4 | API + MCP: single hybrid entrypoint with provenance | api/mcp | 31.2, 31.3 |
| US-31.5 | Docs (three-layer model) + terminal verification (runs last) | docs/verify | all |

## Key design points

- **"Curated" needs a concrete rule** — the knowledge subsystem has category/hub/OKF structure but
  no explicit curated-answer marker (`canonical` is used for dedup, not provenance). US-31.1 defines
  it (curated category set + hub/OKF membership, published-only), preferring config over a migration.
- **Prefer curated over fuzzy** is the default resolution rule; **provenance** (`:curated` |
  `:retrieved`) + confidence + the underlying `knowledge_search` meta ride every response.
- **Progressive disclosure**: load a compact index (hub/OKF index stubs), then drill — reuse
  `knowledge_index` + hubs + OKF, don't build a new index store.
- **Additive**: existing `knowledge_*` tools/endpoints are unchanged; the hybrid path is a new
  entrypoint.
- **The headline proof** (US-31.5): the refund-policy-style hallucination (a confident answer from an
  unrelated chunk) is demonstrably avoided when a curated answer exists.

## Review changes (enhanced-review round 1, applied)

- **Critical — curated must actually answer:** `:curated` is returned only when a curated source
  clears an absolute threshold AND beats the best retrieved candidate by a margin AND is not
  conflicted/superseded — otherwise `:retrieved`. Added a near-but-wrong negative test. (A curated
  doc semantically near a query it doesn't answer, labeled authoritative, is worse than the RAG bug.)
- **Governance/poisoning:** "curated" is a **governed marker** (admin/`kb_curation`-gated), not an
  agent-settable `category` — the article changeset doesn't role-gate `:published`, so category-only
  would let any agent self-promote to authoritative.
- **System scope:** `@scope_values [:tenant, :system]` — system (public-wiki) canonical articles may
  participate but never override a tenant's own curated answer, and never leak cross-tenant.
- **Staleness/conflict:** a `:superseded` or open-`:potential_conflict` curated article is not
  returned as authoritative without surfacing the conflict.
- **Code-name corrections:** the Elixir fn is `search_combined/3` (not `knowledge_search`); the
  signature is `hybrid_search(tenant_id, query, opts)` (no scope-struct/map-query convention exists);
  hubs are **emergent** (`article_link` degree), not a modeled type; the OKF `index.md` is a private
  full-export artifact, so progressive disclosure is built on `knowledge_index` + link traversal +
  `derive_description/1` (made public), capped top-K.
- **Also:** provenance emitted to `RetrievalMetrics`; tenant isolation is explicit-predicate on
  AdminRepo/HeavyRead (BYPASSRLS, not RLS); the progressive index/drill MCP tool is required (not
  optional); shape-parity + unit tests added.
- **Deferred (v2, tracked):** #306's freshness/novelty index ranking is out of scope for v1 (noted
  here rather than silently dropped).

## US-31.1 implementation notes (shipped)

The "curated" marker was implemented as a **dedicated non-castable column**, not config.
Round-1 review concluded a governed marker is required and that `metadata` is unsafe (it is
cast freely by `Article.create_changeset/2`/`update_changeset/2`), so:

- **Marker:** `articles.curated_at :utc_datetime_usec` (+ advisory `curated_by :string`),
  added by `20260712010000_add_curated_marker_to_articles.exs`. Both are EXCLUDED from
  `Article`'s `@cast_fields` and writable ONLY via `Article.curation_changeset/3` — the same
  isolation technique as `:embedding`. An agent create/update that sets `curated_at`,
  `curated_by`, or `metadata["curated"]` cannot self-promote (proven by tests).
- **Governed writer:** `Loopctl.Knowledge.mark_curated/3` / `unmark_curated/3` — the ONLY
  writers, each audited (`article.curated`/`article.uncurated`) and logged to the
  `KbCuration` feed. Marking is a trust gate: any HTTP surface reaching it must be role-gated
  at `:user`+ (the domain fn is the non-castable half; the role check is the transport half).
  HTTP exposure is deferred to US-31.4.
- **Pure predicate:** `Knowledge.curated?/1` — `status == :published AND curated_at != nil`,
  no DB call (unit-testable on an in-memory struct). Category may be a filter, never
  sufficient alone.
- **Scoped listing:** `Knowledge.list_curated_sources/2` — tenant's own curated-published
  UNION system-scoped curated-published, via the explicit
  `where a.tenant_id == ^tenant_id or a.scope == :system` predicate on AdminRepo (never RLS).
- **System vs tenant precedence (AC-31.1.3):** a system canonical (`scope: :system`,
  `tenant_id` nil) MAY participate as curated, but a tenant's OWN curated article on the same
  topic (case-insensitive title) WINS — the system one is suppressed from that tenant's
  result and never overrides the tenant's fresher/own answer. System canonicals on topics the
  tenant has not curated still participate. System articles never leak as another tenant's
  private content (surfaced only via the explicit `or a.scope == :system` opt-in).
- **Conflict exclusion (AC-31.1.4):** `Knowledge.authoritative_curated?/1` and
  `list_curated_sources/2` exclude an article in an OPEN `:potential_conflict` (an
  auto-generated conflict link with no `conflict_resolutions` row) — the pure `curated?/1`
  stays marker+status only.

## Provenance

Second Brain hub `820602df` (Cloud Codes — "Google OKF + RAG: The Ultimate AI Agent Architecture",
15 atomic notes + 4 actionables), `okf-open-knowledge-format` memory, shipped
`knowledge_okf_export/import`. GitHub #305 / #306.
