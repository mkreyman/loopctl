# Epic 29 — Agent Memory (Part 2: auto-promotion / session-memory compiler)

Decomposition of GitHub issue **#308** (Agent Memory — Part 2: auto-promotion / session-memory
compiler). This is the **writer half** of the agent-memory pillar: it fills the Part 1 store
automatically, so an agent never has to say "remember this."

> **Status: authored with `user-story-writer`, hardened through one enhanced-review round.**
> Three-lens review (analyst / architect / adversarial), each verified against the live code,
> found no blockers but a broken idempotency spine and an absent unattended-safety story — all
> applied (see "Review changes"). A confirm-pass before `/implement-plan` is still worthwhile.

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

## Key design decisions (hardened by review)

- **Idempotency spine = a promotion watermark + a synchronous exact-dedupe key.** A new
  `session_promotions` table stores a `session_content_hash` per `(tenant, subject, session)`,
  written on *every* run including zero-survivor ones; both triggers skip an unchanged session, so
  it is never re-compiled (kills re-LLM-every-tick and paraphrase drift). Exact dedupe computes
  `embedding_content_hash` *synchronously at write* (decoupled from epic_28's async embedding) with a
  **partial unique index** on `(tenant_id, subject_id, embedding_content_hash) WHERE source=:promoted`
  + `on_conflict`, so concurrent explicit+sweep promotion can't double-insert. Compile is
  deterministic (temperature 0). Idempotency is measured as *total rows incl. superseded*.
- **Near-dedupe fails safe:** the epic_28 cosine recall path degrades to ILIKE under an embedding
  outage; "no near-dup" is then non-authoritative, so the job snoozes/retries rather than inserting.
- **Unattended safety (new):** session content is untrusted → prompt-injection hardening + in-tenant
  `cross_link` validation (US-29.1); a per-tenant compiles/hour **budget** + a per-sweep-tick cap
  (US-29.2); a **TTL invariant** (`sweep window < session TTL`) so prune never beats promotion.
- **Two workers:** a per-session `MemoryPromotionWorker` and a separate cron `MemoryPromotionSweepWorker`
  (all-tenants, scope-correct per row — a per-session worker can't be a cron target).
- **LLM integration (corrected):** real module is `Loopctl.Llm` (`Anthropic.message/5`, operation
  `:extraction` — the enum is closed); a **new** `Promoter.LLMBehaviour` + config-swapped `MockPromoterLLM`
  (no generic LLM behaviour exists). Text→JSON, fail-closed (no tool-use blocks).
- **Eval scores against ground truth, not a circular LLM judge:** `PromotionEval` models the real
  `Loopctl.Knowledge.RetrievalMetrics` snapshot+worker+telemetry pattern over a labeled dataset
  (a same-class judge is fooled by the same injection as the compiler). Plus promotion-worker
  telemetry (swept/compiled/gated/superseded/**failed**) — SOUL rule 7.
- **Reconcile the kill:** US-29.2 updates the "killed session compiler" comment in
  `knowledge_moc_worker.ex:9`, preserving its intentional no-LLM-narrative rationale.

## Review changes (enhanced-review round 1, applied)

Rebuilt the idempotency spine (watermark, sync content-hash + partial unique index, deterministic
compile, fail-safe near-dedupe, idempotency measured incl. superseded); added the unattended-safety
story (prompt-injection + cross_link validation, per-tenant budget + sweep cap, TTL-vs-window
invariant); corrected the LLM integration (`Loopctl.Llm`, `:extraction`, new behaviour + config mock,
text-JSON fail-closed); split out a dedicated all-tenants sweep worker with per-row scope attribution;
retargeted the eval from a nonexistent synthetic-eval module to the `RetrievalMetrics` pattern with a
labeled ground-truth set; added promotion telemetry; dropped `project_id` as an isolation key; fixed
test types (session_history reads Postgres → integration).

## Provenance

Second Brain: `02f2d048` (Self-Evolving Session Memory Compiler), `3ee5f890` (Cole Medin),
`227dda43` (confidence bouncer), `1622a142` (synthetic eval), `c4936e11`/`33214eba` (dedup),
`2b548cc3` (Stop-hook capture). GitHub #308.
