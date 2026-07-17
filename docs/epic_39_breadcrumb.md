# Epic 39 — Private/Local Knowledge Tier (Draft, Needs Review)

**Status:** Draft in PR #410; awaiting enhanced review before implementation
**Filed:** GH issue #409 (context: friend's self-host blocker + privacy concern)
**Decision:** single-tenant/deployment-level embedding dimension (per-tenant deferred)

## Why This Epic
- User friend wanted to self-host loopctl with local embeddings (Ollama) but couldn't: migrations hardcode `vector(1536)`, breaking with local 768/1024-dim models
- Larger issue: three egress points (extraction→Anthropic, embedding→OpenAI, plaintext at rest) not suitable for health/DNA/financial data
- Solution: configurable embedding dimension + per-tenant endpoints + fail-closed no-egress guard

## Five Stories (All Draft, Needs Enhanced Review)
1. **US-39.1** — Configurable embedding dimension (migrations + HNSW indexes honor `:embedding_dimensions`)
2. **US-39.2** — Per-tenant embedding_base_url (Ollama/TEI compatible)
3. **US-39.3** — *Deferred* — Pluggable extraction endpoint (OpenAI-compatible local chat, bigger scope)
4. **US-39.4** — No-egress guard at Provider.Admission + egress-posture MCP tool (agent-discoverable)
5. **US-39.5** — Encrypt private bodies + vector-only recall

## Next Steps
1. `/review:enhanced-review-workflow` on PR #410 (whole epic + 5 stories)
2. Fix confirmed findings
3. Implement US-39.1→2→4→5 in order (US-39.3 deferred to next epic)
4. Deploy + verify (singleton local-embedding stack, no egress)

## Breadcrumbs
- PR: https://github.com/mkreyman/loopctl/pull/410
- Issue: https://github.com/mkreyman/loopctl/issues/409
- RFC: see epic README + this file
- Session: mac-mini-loopctl (2026-07-15)
- Dev machines: pick up from any (repo at ~/workspace/loopctl, master clean, PR ready)
