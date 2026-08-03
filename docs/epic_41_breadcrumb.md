# Epic 41 — Private/Local Knowledge Tier

**Status:** PARTLY SHIPPED — 5 of 7 stories merged. See the story table in
[`docs/user_stories/epic_41_private_local_tier/README.md`](user_stories/epic_41_private_local_tier/README.md)
for the per-story state and merge PR; this file records the DESIGN decisions that got
the epic here and is not re-verified per merge.

Everything below the "Re-scope" heading is the 2026-07-20 draft's reasoning, preserved
as written. It describes what was TRUE THEN — treat its present tense as historical.
**Grounded current state** in particular was verified against master 2026-07-20 and has
since been overtaken by the merges the story table lists.

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
- Dimension pinned in exactly TWO `ALTER TABLE`s. **CORRECTION (round 2):** the
  earlier "HNSW indexes inherit the column type (`repo/hnsw_index.ex:125`) — smaller
  than the draft claimed" bullet was WRONG and is retracted. pgvector refuses to
  build an hnsw/ivfflat index on a `vector` column with no dimension modifier, and a
  `WHERE dim = N` partial predicate supplies no typmod, so a mixed-dimension side
  table needs a typed column/partition per dimension **or** an expression index over
  an explicit cast. Single source of truth: the "Grounded current state" table in
  `docs/user_stories/epic_41_private_local_tier/README.md` and US-41.1 AC-41.1.2 —
  do not re-derive the cost from this file.
- Embedding KEY is already per-tenant and MANDATORY (`runtime.exs:385-390` carries
  the comment recording the deliberate removal of the global operator key) — so
  the per-tenant plumbing and its MCP surface already exist
- `Provider.Admission` gates all three provider `Req.post`s but is **FAIL-OPEN by
  design** (`admission.ex:81-97`, `fail_open/2:183`) — the egress guard must be a
  SEPARATE fail-closed decision that cannot inherit that path
- `private`/`owner` visibility is a metadata string filtered ONLY for agent-role
  callers (`coordination.ex:1021-1022`); memories have no visibility field at all

## Next Steps (as planned on 2026-07-20 — steps 1-2 and most of 3 are DONE)
1. `/review:enhanced-review-workflow` on PR #410 (README + 7 stories)
2. Fix confirmed findings — no deferrals
3. Implement **41.4 first** -> 41.1 -> 41.2 -> 41.3 -> 41.5, then 41.6 / 41.7.
   41.4 leads because AC-41.2.7 and AC-41.3.3 both REQUIRE the single egress policy
   module introduced in AC-41.4.9 and forbid a second, divergent URL policy — the
   old 41.1-first ordering forced exactly the duplicate policy those ACs call a
   review failure. US-41.2 and US-41.3 now declare US-41.4 as a dependency.
4. Update GH #409 with the re-scope (held for owner review, not yet posted)

## Breadcrumbs
- PR: https://github.com/mkreyman/loopctl/pull/410
- Issues: https://github.com/mkreyman/loopctl/issues/409 (problem),
  https://github.com/mkreyman/loopctl/issues/331 (companion, shipped)
- Session: beelink-loopctl (2026-07-20)
- Dev machines: pick up from any (repo at ~/workspace/loopctl)
