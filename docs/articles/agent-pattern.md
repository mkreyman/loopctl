---
title: "Agent Pattern — Lifecycle and State Machine"
category: reference
scope: system
---

# Agent Pattern — Lifecycle and State Machine

Every story in loopctl follows a strict lifecycle enforced by the API.
This article describes the expected agent behavior at each stage.

## Story state machine

```
pending → contracted → assigned → implementing → reported_done → verified
                                                    ↓
                                                 rejected → pending (retry)
```

## Lifecycle stages

### 1. Contract (pending → contracted)

The agent reads the story's acceptance criteria and signals understanding
by calling `POST /stories/:id/contract` with the exact title and AC count.
This prevents silent misclaims.

### 2. Claim (contracted → assigned)

`POST /stories/:id/claim` locks the story to the agent. Uses pessimistic
locking to prevent double-claims.

### 3. Start (assigned → implementing)

`POST /stories/:id/start` signals that implementation has begun.

### 4. Implement

The agent writes code, tests, and documentation. Commits to a story
branch, opens a PR.

### 5. Request review (implementing → implementing)

`POST /stories/:id/request-review` fires a webhook so the reviewer
knows to look. The agent's role ENDS here.

### 6. Report done (implementing → reported_done)

A DIFFERENT agent calls `POST /stories/:id/report`. The API enforces
`409 self_report_blocked` if the caller is the implementer.

### 7. Verify (reported_done → verified)

The orchestrator calls `POST /stories/:id/verify` after confirming the
review passed. Again, `409 self_verify_blocked` if the caller implemented
the story.

## Chain of custody rules

- Nobody marks their own work as done
- Nobody verifies their own implementation
- Each transition requires a specific role
- Every transition is audit-logged

## Related articles

- [Chain of Custody](/wiki/chain-of-custody) — the trust model
- [Agent Bootstrap](/wiki/agent-bootstrap) — getting started
