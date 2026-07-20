# Epic 41 — Private/Local Knowledge Tier (Draft, Needs Review)

**Status:** Draft in PR #410; awaiting enhanced review before implementation
**Filed:** GH issue #409 (a loopctl user's self-host blocker + privacy concern)
**Companion:** GH issue #331 (agent-usable KB curation) — SHIPPED. Together the two
define the real gap: agent-native curation of PRIVATE data.
**Renumbered:** epic 39 -> 41 on 2026-07-20; epic 39 was reused by the shipped
repo-coordination-bus epic, and 40 is the coordination-bus v2 epic.

## Why This Epic
- A loopctl user wanted to self-host with local embeddings (Ollama) but couldn't:
  migrations pin `vector(1536)`, breaking 768/1024-dim local models
- Larger issue: content egresses at extraction (-> Anthropic) and embedding
  (-> OpenAI), and rests in plaintext — not suitable for health/DNA/financial data
- Ordering hazard: #331 shipped MORE agent autonomy over KB content while egress
  stayed uncontrolled AND undiscoverable

## Re-scope (2026-07-20) — what changed from the epic 39 draft
1. **Per-tenant, not deployment-level.** The 2026-07-15 "one dimension per
   deployment" decision is REVERSED. Vectors move to a dimension-tagged side table,
   so local models work on the HOSTED multi-tenant instance. The user who filed
   #409 is a hosted tenant; the old decision would have forced them off the service.
2. **Split the conflated axis.** Axis A (where inference happens: 41.2/41.3/41.4/
   41.5) is all per-tenant and ships on hosted. Axis B (where data rests: 41.1/41.6)
   is also per-tenant once the dimension moves.
3. **US-41.3 un-deferred.** The six task-level behaviours are already a
   config-swappable seam (Mox-mapped in config/test.exs), so an OpenAI-compatible
   path is sibling modules, not an LLM-layer refactor.
4. **US-41.5 added** — webhook delivery bypasses Admission entirely
   (`webhooks/req_delivery.ex:43`) and can carry tenant content off-box. The 39
   draft missed it; a local_only guarantee without it is not a guarantee.
5. **US-41.7 added** — bind egress posture into the Epic 26 audit chain / STH so
   "zero third-party egress" becomes a witnessed, verifiable claim. This is what
   makes hosted strictly better than a self-hosted fork.
6. **No-UI audit is now a first-class section of the README** — every knob is
   classified agent-write / agent-read / operator-only, which produced two new
   requirements: publish capabilities on `.well-known/loopctl`, and probe the
   endpoint at CONFIG time (an agent gets no settings screen to notice a mistake in).

## Key grounded facts (re-verified against master 2026-07-20, ~240 commits after the draft)
- Dimension pinned in exactly TWO `ALTER TABLE`s; HNSW indexes inherit the column
  type (`repo/hnsw_index.ex:125`) — smaller than the draft claimed
- Embedding KEY is already per-tenant and MANDATORY (`runtime.exs:375-381`) — so
  the per-tenant plumbing and its MCP surface already exist
- `Provider.Admission` gates all three provider `Req.post`s but is **FAIL-OPEN by
  design** (`admission.ex:81-97`, `fail_open/2:183`) — the egress guard must be a
  SEPARATE fail-closed decision that cannot inherit that path
- `private`/`owner` visibility is a metadata string filtered ONLY for agent-role
  callers (`coordination.ex:1021-1022`); memories have no visibility field at all

## Next Steps
1. `/review:enhanced-review-workflow` on PR #410 (README + 7 stories)
2. Fix confirmed findings — no deferrals
3. Implement 41.1 -> 41.2 -> 41.3 -> 41.4 -> 41.5, then 41.6 / 41.7
4. Update GH #409 with the re-scope (held for owner review, not yet posted)

## Breadcrumbs
- PR: https://github.com/mkreyman/loopctl/pull/410
- Issues: https://github.com/mkreyman/loopctl/issues/409 (problem),
  https://github.com/mkreyman/loopctl/issues/331 (companion, shipped)
- Session: beelink-loopctl (2026-07-20)
- Dev machines: pick up from any (repo at ~/workspace/loopctl)
