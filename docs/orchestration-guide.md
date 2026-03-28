# loopctl Orchestration Guide

Methodology reference for running AI-driven development projects with loopctl.

---

## The Autonomous Loop

The orchestration loop repeats for every story until the project is complete:

```
find ready → contract → claim → implement → report → review → verify
                                                              │
                                              pass ──────────┤
                                              fail ──▶ reject ──▶ (back to pending)
```

**find ready** — Query `/stories/ready?project_id=...` to get stories whose dependencies are all
verified. A story is not ready if any predecessor has `verified_status != pass`.

**contract** — The agent POSTs to `/stories/:id/contract` with the story title and acceptance
criteria count. This proves the agent read the story before claiming it.

**claim / start** — Two separate transitions. Claim reserves the story; start signals active work.
A story can be claimed by only one agent at a time.

**implement** — The agent does the work: writes code, commits, runs tests. One commit per story.

**report** — The agent POSTs an artifact describing what was produced (commit hash, files created,
test results). This is the agent's self-report — it does not advance `verified_status`.

**review** — The orchestrator runs an independent review using a separate process that has not seen
the implementation. The review process reads the story's acceptance criteria and audits the artifact.

**verify / reject** — Only the orchestrator can set `verified_status`. A passing verification
unblocks dependent stories. A rejection resets the story to `pending` and increments the cycle count.

---

## The Two-Tier Trust Model

Every story carries two independent status fields:

| Field | Set by | Meaning |
|-------|--------|---------|
| `agent_status` | Implementation agent | Self-reported completion |
| `verified_status` | Orchestrator only | Independently confirmed |

These fields are never the same key. An agent reporting `completed` does not advance `verified_status`.
Stories surface in dependency resolution only when `verified_status = pass`.

**Why this matters:** Without separate fields, agents can and do fabricate review results. The trust
model makes fabrication structurally impossible — an agent's API key cannot write to `verified_status`.

The orchestrator API key is separate from the agent API key. The loopctl RBAC layer enforces the
boundary: verification endpoints reject requests from agent-role keys.

---

## Dependency Resolution

Stories carry a `depends_on` list of story IDs. The `/stories/ready` endpoint computes readiness by
walking the dependency graph and returning only stories where every predecessor has
`verified_status = pass`.

This means:

- Stories become available progressively as earlier work is verified, not merely reported.
- Parallel work is possible: stories with no shared dependencies can be dispatched simultaneously.
- Rejections have cascading effects — if a foundational story is rejected and re-verified after fixes,
  the orchestrator should re-check whether any story that was ready has become ready again.

The orchestrator should poll `/stories/ready` after every verification, not just after every report.

---

## Orchestrator State Checkpointing

Orchestrator sessions can run for hours. Process restarts, context compaction, and timeout evictions
all terminate the session mid-loop. Checkpointing enables recovery.

```
PUT /orchestrator/state/:project_id
{
  "state_key": "main",
  "state_data": {
    "phase": "epic_3",
    "last_verified": "US-3.4",
    "pending_review": "US-3.5",
    "cycle_counts": {"US-2.1": 1, "US-3.2": 2}
  },
  "version": 4
}
```

The `version` field is an optimistic lock. Concurrent writes fail if versions do not match,
preventing two orchestrator sessions from diverging silently.

On session start, the orchestrator loads its checkpoint:

```
GET /orchestrator/state/:project_id?state_key=main
```

If no checkpoint exists, the orchestrator starts from scratch. If a checkpoint exists, it resumes
from the recorded phase, re-validates the state against current story statuses, and continues the
loop.

**Checkpoint after every verification** — not just at phase boundaries. A crash between two verifications
costs at most one re-verification, not a full phase replay.

---

## Auditing Orchestrator Sessions

loopctl tracks every state transition in an immutable audit log. External observers can reconstruct
the decision chain for any story:

```
GET /stories/:id/history
```

Returns all transitions: who triggered them, when, and what was reported. Use this to audit whether
reviews were run, whether rejections were acted on, and whether verification came from a different
actor than the implementation.

The change feed provides project-wide observability:

```
GET /changes?since=2026-03-01T00:00:00Z&project_id=:id
```

Observer processes can tail this feed to detect anomalies: stories verified by their own agent,
stories with zero review cycles, or stories completed without artifact reports.

The `/loopctl:observe` pattern refers to the practice of POSTing structured orchestrator events
(session start, rule violations, agent dispatches) to loopctl as audit entries, then querying them
back via the history API. This decouples observability from any specific toolchain.

---

## Best Practices

**One commit per story.** Mixing multiple stories in a single commit breaks artifact traceability.
The artifact report references a commit; that commit should correspond to exactly one story.

**Always run independent review.** The review process must not be the same process that implemented
the story. Different context, different API key, same acceptance criteria. No exceptions.

**Never self-verify.** The orchestrator dispatches the implementation and runs the review, but
verification is the conclusion of the review — not a rubber stamp. If the review finds problems,
reject and cycle.

**Fresh agent per story.** Long agent contexts accumulate coherence degradation. Dispatching a fresh
agent per story keeps implementation quality consistent across a long project.

**Checkpoint after every verification.** If the session dies between verifications, the checkpoint
allows resumption without re-doing completed work.

**Maximum five cycles per story.** If a story fails review five times, escalate to a human. Automated
fix loops beyond this threshold indicate a design problem that agents cannot resolve alone.

**Treat agent reports as unverified input.** Read artifact reports to inform the review, not to
replace it. The orchestrator's job is to verify independently, not to confirm what the agent claimed.
