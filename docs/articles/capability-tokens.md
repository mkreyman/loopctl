---
title: "Capability Tokens — Signed Authorization for Custody Operations"
category: reference
scope: system
---

# Capability Tokens

Capability tokens are signed, scoped, non-replayable authorization tokens
that gate custody-critical operations in loopctl. Without a valid cap,
the forbidden operation is structurally unreachable.

## Token types

| Type | Minted at | Consumed by | Gates |
|------|-----------|-------------|-------|
| `start_cap` | claim_story | start_story | Starting implementation |

`start_cap` is the only capability minted today. `claim_story` returns it in the
response body; present it as `capability` on `start_story`.

### Why the others were retired

`report_cap`, `verify_cap` and `review_complete_cap` are no longer minted. A
capability is bound to one dispatch lineage and verified with an EXACT match, so
it can only gate a transition whose legitimate actor is known when the token is
minted. The other three gates are precisely the ones whose actor must DIFFER from
the implementer, and is not yet known:

- `report_cap` was minted to the implementer's lineage but `report_story` must be
  called by a different principal — so the only holder was the one principal
  forbidden to use it.
- `verify_cap` was minted to the lineage `select_verifier/3` picked, which is
  routinely not the caller: the pool includes `agent`-role dispatches while the
  endpoint is orchestrator-only, a legacy key has no lineage to match, and a
  single-root tenant yields no eligible verifier at all.
- `review_complete_cap` was never minted or consumed by any code path.

Those transitions are gated by structural lineage separation instead — see
[Chain of Custody](/wiki/chain-of-custody).

## Token structure

Each token contains:
- `typ` — the operation type
- `story_id` — the story this cap authorizes
- `issued_to_lineage` — exact dispatch lineage path of the recipient
- `nonce` — 32 random bytes (replay protection)
- `signature` — ed25519 signature by the tenant's audit key
- `expires_at` — TTL (default 1 hour)

## Presenting a cap

Include the `cap_id` in your request body. The server verifies:
1. Signature matches the tenant's public key
2. Type matches the endpoint
3. Story matches the URL parameter
4. Lineage exactly matches the caller's current lineage
5. Not expired
6. Not already consumed (replay protection)

## Why caps matter

A capability makes a forbidden step unreachable rather than merely refused: the
token is signed, single-use, story-bound, lineage-bound and expiring, so a caller
outside the lineage it was issued to cannot construct a valid request at all.

That is why `start_cap` survives and the others did not. It is issued to the
principal that will spend it — the agent that just claimed the story. Where the
actor must instead DIFFER from the minter, no token can express the rule, and the
separation is enforced structurally by comparing the caller's server-resolved
dispatch lineage against the implementer's.

See [Chain of Custody](/wiki/chain-of-custody) for the full trust model.
See [Dispatch Lineage](/wiki/dispatch-lineage) for how lineages work.
