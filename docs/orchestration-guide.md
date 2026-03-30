# loopctl Orchestration Guide

Methodology reference for running AI-driven development projects with loopctl.

---

## The Autonomous Loop

The orchestration loop repeats for every story until the project is complete:

```
find ready → contract → claim → implement → request-review → [reviewer] report → review-complete → verify
                                                                                                    │
                                                                                    pass ───────────┤
                                                                                    fail ──▶ reject ──▶ (back to pending)
```

**find ready** — Query `/stories/ready?project_id=...` to get stories whose dependencies are all
verified. A story is not ready if any predecessor has `verified_status != pass`.

**contract** — The agent POSTs to `/stories/:id/contract` with the story title and acceptance
criteria count. This proves the agent read the story before claiming it.

**claim / start** — Two separate transitions. Claim reserves the story; start signals active work.
A story can be claimed by only one agent at a time.

**implement** — The agent does the work: writes code, commits, runs tests. One commit per story.

**request-review** — The implementer POSTs to `/stories/:id/request-review` to signal that the
work is ready for review. This is the implementer's final action on the story. It does NOT mark the
story as done — it fires a `story.review_requested` webhook and puts the story in a "awaiting
review" state. The implementer cannot call `/report` on their own story (409 self_report_blocked).

**report (reviewer)** — A DIFFERENT agent (the reviewer) calls `/stories/:id/report` to confirm
the implementation artifact. The API enforces that the caller is not the assigned implementer
(`reported_by_agent_id` must differ from `assigned_agent_id`). If they match, the response is
`409 self_report_blocked`.

**review** — The reviewer reads the acceptance criteria and audits the implementation. This is the
independent review step — a separate process that has not seen the implementation.

**review-complete (reviewer)** — The reviewer calls `/stories/:id/review-complete` to signal that
the review is finished and findings have been recorded. This fires a `story.review_completed`
webhook. The same identity gate applies: 409 if caller == implementer.

**verify / reject** — Only the orchestrator can set `verified_status`. A passing verification
unblocks dependent stories. A rejection resets the story to `pending` and increments the cycle
count. If the orchestrator was also the implementer, verify returns `409 self_verify_blocked`.

---

## Why the Chain-of-Custody Matters

In practice, orchestrators skipped reviews. A common failure mode was:

1. Orchestrator dispatches an implementer agent
2. Orchestrator receives the agent's self-report
3. Orchestrator calls `/verify` directly without running a review

The result: stories get verified with no independent check. This defeats the entire trust model.

The chain-of-custody pattern closes this gap structurally. The implementer **cannot** call `/report`
on their own story — the API returns 409. This means the orchestrator cannot skip the review step by
having the implementer self-report and then verifying. A genuinely different agent must confirm the
implementation before verification is possible.

The three identity gates are enforced at the API layer regardless of role:
- `POST /report` — 409 `self_report_blocked` if caller == assigned_agent_id
- `POST /review-complete` — 409 `self_review_blocked` if caller == assigned_agent_id
- `POST /verify` — 409 `self_verify_blocked` if caller == assigned_agent_id

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

## Bootstrapping Pre-existing Projects

When onboarding a project that already has completed work, three patterns are available:

### Pattern 1: Import with initial status

Set `initial_agent_status` and `initial_verified_status` on stories at import time. Stories
imported as `pass` are immediately treated as verified and unblock their dependents:

```bash
curl -X POST http://localhost:4000/api/v1/projects/:id/import \
  -H "Authorization: Bearer lc_user_key" \
  -H "Content-Type: application/json" \
  -d '{
    "epics": [{
      "number": 1,
      "title": "Foundation",
      "stories": [{
        "number": "1.1",
        "title": "Database schema",
        "acceptance_criteria": [{"criterion": "Migrations applied"}],
        "initial_agent_status": "reported_done",
        "initial_verified_status": "pass"
      }]
    }]
  }'
```

Use this pattern when you know the status of work at import time.

### Pattern 2: Bulk mark-complete after import

Import stories normally (they start as `pending`), then bulk-complete them in one call:

```bash
curl -X POST http://localhost:4000/api/v1/stories/bulk/mark-complete \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{
    "stories": [
      {"story_id": "<uuid>", "summary": "Pre-existing implementation", "review_type": "pre_existing"},
      {"story_id": "<uuid>", "summary": "Carried over from v1", "review_type": "pre_existing"}
    ]
  }'
```

Use this pattern when you need to import first and then batch-verify after reviewing what exists.

### Pattern 3: Epic-wide verification

After implementation agents have reported done on all stories in an epic, the orchestrator can
verify the entire epic in a single call instead of verifying each story individually:

```bash
curl -X POST http://localhost:4000/api/v1/epics/:id/verify-all \
  -H "Authorization: Bearer lc_orch_key" \
  -H "Content-Type: application/json" \
  -d '{"review_type": "enhanced", "summary": "Epic-wide review passed, all ACs met"}'
```

This verifies only stories in `reported_done` state. Stories still in progress are skipped.

### Querying Status During Bootstrap

Use `GET /stories?project_id=X` for comprehensive status queries during bootstrap. The endpoint
supports filtering by `agent_status`, `verified_status`, and `epic_id` with up to 500 results
per page:

```bash
# Find all stories still pending after bulk import
curl "http://localhost:4000/api/v1/stories?project_id=:id&verified_status=unverified&limit=500"

# Find reported_done stories awaiting orchestrator verification
curl "http://localhost:4000/api/v1/stories?project_id=:id&agent_status=reported_done&verified_status=unverified"
```

---

## Optional: UI Testing

UI test runs are a project-level QA step. They are not part of the per-story loop — they cover the
whole application from a user's perspective.

**When to run a UI test pass:**
- After a batch of stories from a major epic has been merged
- When the project has a user guide describing the expected UX flows
- When you want an end-to-end sanity check before a release

**How it works:**

1. **Start the run** via the loopctl API (orchestrator role):
   ```bash
   curl -sk -X POST https://192.168.86.55:8443/api/v1/projects/:id/ui_test_runs \
     -H "Authorization: Bearer ${LOOPCTL_API_KEY:-$LOOPCTL_ORCH_KEY}" \
     -H "Content-Type: application/json" \
     -d '{"notes": "Post-epic-37 QA pass"}'
   ```

2. **Dispatch a ui-tester agent** (foreground, not background) with the guide path and app URL:
   ```
   Agent(
     subagent_type: "elixir-engineer",
     description: "UI test pass — <project>",
     prompt: "You are a QA tester for the application at <app_url>.
              Read the user guide at <guide_path>.
              Walk through every flow described in the guide.
              Record each finding via the loopctl API at
              POST /api/v1/ui_test_runs/<run_id>/findings.
              You are READ-ONLY — do NOT edit any code.
              When done, call POST /api/v1/ui_test_runs/<run_id>/complete."
   )
   ```

3. **If findings exist**, dispatch a fix agent to address them, then re-dispatch the ui-tester
   agent with a new run to confirm the fixes.

4. **If no findings**, the run is complete. Continue with the normal story loop or mark the
   project phase as QA-passed.

**Important constraints:**
- The ui-tester agent is **READ-ONLY** — it records findings but never edits code.
- Fixes are handled by a separate fix agent dispatched by the orchestrator.
- There is no requirement to run UI tests on every story or every epic. It is a project-wide
  QA pass, not a per-story gate.
- A project without a user guide cannot run a UI test pass — the tester has no reference for
  expected behavior.

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
