# Epic 39 — Private / Local-Only Knowledge & Memory (data sovereignty)

**Status: DRAFT — PARKED 2026-07-15. Scope confirmed (single-tenant / deployment-level).
NOT scheduled. Every story MUST go through the enhanced-review workflow (against the
story text AND the diff) before/at implementation — these are un-reviewed drafts.
Resume breadcrumbs: GH issue #409 (problem), PR #410 (this draft), and the
`project_epic_39_private_tier` memory. Pick up on any session/machine.**

Make loopctl a genuine home for **private** data (health, DNA, financial) by letting a
**self-hosted** instance run the entire knowledge + memory pipeline against **local,
OpenAI-compatible models with zero third-party egress** — and *enforce* that guarantee
rather than hope for it.

## Motivation

A loopctl user wanted to harvest personal documents into their second brain; their agent
warned that harvesting sends data to third-party model providers. The concern is valid, and
**broader than embeddings** — a private doc is exposed at three points today:

1. **Extraction (the biggest leak).** Turning a doc into articles sends its full content to
   Anthropic — endpoint **hardcoded** (`lib/loopctl/llm/anthropic.ex:37`).
2. **Embedding.** Article/chunk text goes to the embedding provider — default OpenAI
   (`lib/loopctl/knowledge/embedding_client.ex:41`).
3. **At rest.** Article/memory **bodies are stored plaintext** (they back full-text search);
   only BYO API keys are Cloak-encrypted (`Loopctl.Vault.Binary`).

**The actual blocker for self-hosting a local stack** (per the user's agent): the embedding
**vector dimension is hardcoded `vector(1536)`** in the migrations, so a local embedding model
with a different dimension (e.g. nomic-embed 768, bge 1024) won't fit — even though the Elixir
validation layer *already* reads a configurable `Application.get_env(:loopctl, :embedding_dimensions, 1536)`
(`config/config.exs:16`, `article.ex:490`, `memory.ex:266`). The config knob exists; the schema
doesn't honor it.

## Design principle (non-negotiable)

loopctl is **agent-native and self-discoverable — there is NO human UI, by design.** Every
capability here ships as **MCP tools + JSON API + self-describing responses**, never a UI.
An agent must be able to *discover the instance's egress posture* and *verify locality* before
harvesting sensitive data.

## Grounded current state

| Capability | Today | Gap |
|---|---|---|
| Embedding **dimension** | `:embedding_dimensions` config exists + validated, but migrations hardcode `vector(1536)` | schema/index must honor the config → **US-39.1** |
| Embedding **endpoint** | `base_url` is a **server-wide** runtime default; tenant BYO **key+model** only (`tenant_llm_settings.ex`) | per-tenant/deployment `embedding_base_url` → **US-39.2** |
| Extraction/classification **endpoint** | Anthropic base_url **hardcoded** | pluggable OpenAI-compatible endpoint → **US-39.3** |
| Egress **enforcement** | none — provider calls fire if configured | fail-closed no-egress guard at the epic-37 `Provider.Admission` chokepoint + posture self-report → **US-39.4** |
| Data **at rest** | bodies plaintext (for FTS) | encrypt private-tier bodies, vector-only search → **US-39.5** |

## Stories (draft)

| Story | Title | Depends |
|-------|-------|---------|
| US-39.1 | Configurable embedding dimension end-to-end (migrations/HNSW honor `:embedding_dimensions`) — **the self-host blocker** | — |
| US-39.2 | Per-tenant / per-deployment embedding **endpoint** (`embedding_base_url`) → point embeddings at a local OpenAI-compatible server | — |
| US-39.3 | Pluggable extraction/classification/merge **endpoint** (OpenAI-compatible local chat) → run harvesting fully local | — |
| US-39.4 | Fail-closed **no-egress guard** (per-scope `local_only`, enforced at `Provider.Admission`) + agent-discoverable **egress-posture** MCP tool/endpoint | US-39.2, US-39.3 |
| US-39.5 | Encrypt **private-tier bodies at rest** + vector-only recall (drop plaintext FTS for that tier) | — |

## Constraints / decisions to confirm with Mark

- **Scope of "configurable dimension": DECIDED (Mark, 2026-07-15) — deployment-level /
  single-tenant** ("hosted local should mean single tenant, for now"). One dimension per
  self-hosted instance. Per-tenant (dim-partitioned tables) is explicitly deferred.
- **Everything agent-native, no UI** (design principle above) — the egress-posture surface is
  an MCP tool + endpoint, not a dashboard.
- **Embedding-inversion caveat:** stored vectors can partially leak content, so the private
  tier is meaningful **only on a self-hosted instance** (don't put sensitive vectors in a
  shared/hosted DB). Docs must say this plainly.
- Default behavior is **unchanged for the hosted instance** (dim 1536, OpenAI/Anthropic, no
  local_only) — every new capability is opt-in/flag-gated.
- Changing the embedding dimension on an **existing** instance requires a reindex/re-embed —
  documented as a one-time setup step, not an online migration.

## Related (second brain)

The user's own KB already captures the local-first playbooks this epic operationalizes:
`Privacy pillars of a self-hosted AI setup`, `DIY Privacy-Preserving Local AI Stack (Ollama +
Open WebUI)`, `Self-hosting ML models is a practical GDPR/Schrems strategy`, `Privacy-First
Architecture for Medical AI Apps: De-identification`.
