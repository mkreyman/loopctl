# Epic 29 — Agent Memory (Part 2: auto-promotion / session-memory compiler)

Decomposition of GitHub issue **#308** (Agent Memory — Part 2: auto-promotion / session-memory
compiler). This is the **writer half** of the agent-memory pillar: it fills the Part 1 store
automatically, so an agent never has to say "remember this."

> **Status: authored with `user-story-writer` (current schema, `estimated_tokens`).**
> Pending the three-lens enhanced review (analyst / architect / adversarial) before
> `/implement-plan`, same as epic_28.

## Prerequisite

**Depends on epic_28 (#307) being implemented and merged** — it reuses `Loopctl.Memory`
(`session_history/2`, `remember`, `supersede/2`, `list`), the `memories` schema
(`source: :promoted`, `superseded_by`, `embedding_content_hash`), the `MemoryEmbeddingWorker`,
and the superadmin memory API. This epic adds only the promotion/compile layer on top.

## Scope boundary

- **In scope (Part 2):** the compile core (`Loopctl.Memory.Promoter`), the promotion Oban
  worker (explicit + scheduled triggers, dedupe/supersede, idempotency), the
  `POST /api/v1/memory/promote` API + superadmin promoted-vs-explicit oversight, the
  `memory_promote` MCP tool, a promotion-quality eval hook, and docs.
- **No web UI.** loopctl is agent-native. #308 originally named a LiveView for promoted-vs-explicit
  oversight; that is delivered instead as a **superadmin API** (source filter + reject), per the
  epic_28 decision.
- **Consumer (elsewhere):** the Claude Code Stop-hook + skills that call `memory_promote` live in
  **mkreyman/claude-config#85** — documented here as a seam, not implemented.

## Story map

| Story | Title | Surface | Depends on |
|-------|-------|---------|-----------|
| US-29.1 | Promotion compiler core: session turns → LLM nuggets, confidence-gated | domain | — |
| US-29.2 | Promotion worker: triggers (explicit + cron sweep), dedupe/supersede, idempotency | domain | 29.1 |
| US-29.3 | API `POST /api/v1/memory/promote` + superadmin promoted-vs-explicit oversight | api | 29.2 |
| US-29.4 | MCP `memory_promote` tool | mcp | 29.3 |
| US-29.5 | Promotion-quality eval hook (compile precision, calibrates the gate) | domain | 29.2 |
| US-29.6 | Docs + terminal e2e / idempotency / scope-isolation verification (runs last) | docs/verify | all |

## Key design decisions (pre-baked from epic_28's review)

- **Idempotency is load-bearing:** promotion runs unattended (cron + Stop-hook), so re-running a
  session must be a true no-op via dedupe/supersede (exact = `embedding_content_hash`, near =
  cosine over the epic_28 vector path within `(tenant_id, subject_id)`), guarded by Oban `unique`.
- **Scope safety:** promoted memories inherit the session's `(tenant_id, subject_id)`; nothing is
  ever widened. Cross-scope isolation is proven end-to-end in US-29.6.
- **Brittleness is measured, not assumed:** the confidence gate (US-29.1) + eval hook (US-29.5)
  are the mitigation that overturns the prior "kill" verdict on this idea.
- **Reconcile the kill:** US-29.2 updates the stale "killed session compiler" comment in
  `lib/loopctl/workers/knowledge_moc_worker.ex:9`.

## Provenance

Second Brain: `02f2d048` (Self-Evolving Session Memory Compiler), `3ee5f890` (Cole Medin),
`227dda43` (confidence bouncer), `1622a142` (synthetic eval), `c4936e11`/`33214eba` (dedup),
`2b548cc3` (Stop-hook capture). GitHub #308.
