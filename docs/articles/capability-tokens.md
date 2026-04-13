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
| `report_cap` | start_story | report_story | Reporting work as done |
| `review_complete_cap` | request_review | review_complete | Recording review |
| `verify_cap` | request_review | verify_story | Verifying work |

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

Without caps, an implementer could forge a verify request. With caps,
the verify_cap is never minted to the implementer's lineage — they
literally cannot construct a valid verify request.

See [Chain of Custody](/wiki/chain-of-custody) for the full trust model.
See [Dispatch Lineage](/wiki/dispatch-lineage) for how lineages work.
