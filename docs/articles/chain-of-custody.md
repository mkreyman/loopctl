---
title: "Chain of Custody — Trust Model Overview"
category: reference
scope: system
---

# Chain of Custody — Trust Model Overview

loopctl's chain of custody prevents two failure modes in AI-agent-driven
development: **sneaky agents** that bypass review to self-approve their own
work, and **lazy agents** that declare incomplete work done.

## The two threat profiles

### The sneaky adversary

An agent that appears to follow the process but exploits structural gaps to
mark its own work as reviewed and verified. Examples: minting a second API
key and using it as its own reviewer, passing nil identity to bypass
comparison checks, or manipulating dispatch lineage so the verifier shares
an ancestor with the implementer.

### The lazy adversary

An agent that genuinely performs incomplete work — skipping tests, writing
stub implementations, or declaring done without verifying acceptance
criteria — then self-reports success. The work looks complete on paper but
fails in production.

## The six-layer enforcement stack

loopctl addresses both threats via six complementary layers:

```
L0  Human + hardware anchor (WebAuthn at signup)
L1  Capability tokens (signed, scoped, non-replayable)
L2  Database invariants (FK, CHECK, triggers, partial indexes)
L3  Independent re-execution (SWE-bench-style verification)
L4  Structural role separation (dispatch lineage, rotating verifier)
L5  Behavioral detection (lazy-bastard score, CoT sanity monitor)
L6  Halt on byzantine conditions (divergent STH, custody halt)
```

Each layer is independently useful and fails safe — if one layer is
bypassed, the next catches the violation.

## Design principles

- **Structural over policy**: Enforcement is in the database, not in code
  comments or documentation. A constraint violation crashes the transaction,
  not a log entry.
- **Nil is never permissive**: Unknown identity is treated as untrusted, not
  as "no identity to compare."
- **Independent re-execution beats self-reporting**: The system verifies work
  by re-running tests, not by trusting the agent's claim.
- **Honest work is the path of least resistance**: The happy path (do real
  work, report it, get verified) is easier than any bypass attempt.

## Related articles

- [Agent Bootstrap](/wiki/agent-bootstrap) — getting started from zero
- [Agent Pattern](/wiki/agent-pattern) — the full agent lifecycle
- [Tenant Signup](/wiki/tenant-signup) — the human root of trust
- [Discovery](/wiki/discovery) — the `.well-known/loopctl` contract
