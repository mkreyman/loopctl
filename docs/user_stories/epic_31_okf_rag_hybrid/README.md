# Epic 31 — OKF-curated + RAG Hybrid Knowledge Interface

Decomposition of GitHub issues **#305 and #306** (the **same feature** — recommend closing one as a
duplicate). A single hybrid retrieval interface for the knowledge layer that **prefers a curated OKF
answer** and falls back to semantic retrieval for the long tail, with **provenance** and
**progressive disclosure** via index files — so callers never get a confidently-wrong fuzzy chunk
when a canonical answer exists, and never have to choose "RAG or curated."

> **Status: authored with `user-story-writer` (current schema, `estimated_tokens`).**
> Pending the three-lens enhanced review (analyst / architect / adversarial) before
> `/implement-plan`, same as epics 28–30.

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

## Provenance

Second Brain hub `820602df` (Cloud Codes — "Google OKF + RAG: The Ultimate AI Agent Architecture",
15 atomic notes + 4 actionables), `okf-open-knowledge-format` memory, shipped
`knowledge_okf_export/import`. GitHub #305 / #306.
