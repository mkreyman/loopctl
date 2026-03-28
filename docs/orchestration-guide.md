# loopctl Orchestration Guide

How to use loopctl to manage AI-driven software development projects.

## Overview

loopctl is a state store. It tracks what work exists, who's doing it, and whether it's been verified. The actual orchestration logic — deciding what to assign, when to review, how to verify — lives in **skills**: instruction sets that AI orchestrators follow.

This guide explains the methodology and the skills that drive the development loop.

## The Development Loop

```
          ┌─────────────────────────────────────────────┐
          │                                             │
          ▼                                             │
    ┌──────────┐     ┌───────────┐     ┌──────────┐    │
    │   PLAN   │────▶│ IMPLEMENT │────▶│  REVIEW  │────┤
    └──────────┘     └───────────┘     └──────────┘    │
          │                                  │          │
          │                            ┌─────┴─────┐   │
          │                            │  VERIFIED? │   │
          │                            └─────┬─────┘   │
          │                              yes │ no      │
          │                                  │ └───────┘
          │                                  ▼
          │                           ┌────────────┐
          └──────────────────────────▶│    DONE    │
                                      └────────────┘
```

### Roles

| Role | What They Do | loopctl Role |
|------|-------------|--------------|
| **Orchestrator** | Plans work, dispatches agents, reviews results, verifies deliverables | `orchestrator` |
| **Implementation Agent** | Reads stories, writes code, commits, reports completion | `agent` |
| **Human** | Imports stories, monitors progress, reviews at milestones | `user` |

### The Trust Model

The orchestrator and implementation agents are **different processes with different API keys**. An implementation agent cannot mark its own work as verified. This prevents the pattern where agents fabricate review results.

```
Implementation Agent (agent key):
  contract → claim → start → report

Orchestrator (orchestrator key):
  verify OR reject → (rejected stories auto-reset to pending)
```

## Skills

Skills are instruction sets stored as markdown files in the `skills/` directory. The orchestrator reads a skill before performing the corresponding action. Skills are versioned — when you improve a prompt, you create a new version and can compare performance.

### Available Skills

| Skill | File | Purpose |
|-------|------|---------|
| `loopctl:orchestrate` | [loopctl-orchestrate.md](../skills/loopctl-orchestrate.md) | Main loop: poll → dispatch → review → verify → iterate |
| `loopctl:review` | [loopctl-review.md](../skills/loopctl-review.md) | Independent code review calibrated for skepticism |
| `loopctl:contract` | [loopctl-contract.md](../skills/loopctl-contract.md) | Agent reads story and confirms understanding before claiming |
| `loopctl:plan` | [loopctl-plan.md](../skills/loopctl-plan.md) | Analyze dependency graph, determine implementation order |
| `loopctl:verify-artifacts` | [loopctl-verify-artifacts.md](../skills/loopctl-verify-artifacts.md) | Check that expected files/modules/tests actually exist |
| `loopctl:status` | [loopctl-status.md](../skills/loopctl-status.md) | Query project progress and display summary |

### How Skills Are Used

1. The orchestrator fetches a skill (reads the markdown file or queries the loopctl Skills API)
2. The skill text becomes the system prompt or instruction set for the action
3. After the action, the orchestrator records which skill version was used alongside the verification result
4. Over time, you compare skill versions to see which prompts produce better reviews

## Step-by-Step: Running a Project

### 1. Setup

```bash
# Register your organization
curl -X POST https://loopctl.local:8443/api/v1/tenants/register \
  -H "Content-Type: application/json" \
  -d '{"name": "My Team", "slug": "my-team", "email": "admin@example.com"}'
# Save the returned API key (user role)

# Create agent and orchestrator keys (see README Authentication Flow)
```

### 2. Import Your Stories

Write your user stories as JSON files (see [README Import Format](../README.md#import-json-format)), then import:

```bash
curl -X POST https://loopctl.local:8443/api/v1/projects/{id}/import \
  -H "Authorization: Bearer $USER_KEY" \
  -H "Content-Type: application/json" \
  -d @stories.json
```

### 3. Plan

The orchestrator reads `loopctl:plan` and analyzes the dependency graph:

```bash
# Get the dependency graph
curl https://loopctl.local:8443/api/v1/projects/{id}/dependency_graph \
  -H "Authorization: Bearer $ORCH_KEY"

# Get ready stories (all dependencies met)
curl https://loopctl.local:8443/api/v1/stories/ready?project_id={id} \
  -H "Authorization: Bearer $ORCH_KEY"
```

### 4. The Loop (per story)

```bash
# Agent: contract the story (proves you read the ACs)
curl -X POST .../stories/{id}/contract \
  -H "Authorization: Bearer $AGENT_KEY" \
  -d '{"story_title": "...", "ac_count": 8}'

# Agent: claim → start → implement → report
curl -X POST .../stories/{id}/claim -H "Authorization: Bearer $AGENT_KEY"
curl -X POST .../stories/{id}/start -H "Authorization: Bearer $AGENT_KEY"
# ... agent writes code, commits ...
curl -X POST .../stories/{id}/report -H "Authorization: Bearer $AGENT_KEY" \
  -d '{"artifact": {"artifact_type": "commit_diff", "path": "abc..def", "exists": true}}'

# Orchestrator: review independently (reads loopctl:review skill)
# Orchestrator: verify or reject
curl -X POST .../stories/{id}/verify \
  -H "Authorization: Bearer $ORCH_KEY" \
  -d '{"result": "pass", "summary": "All ACs met"}'
# OR
curl -X POST .../stories/{id}/reject \
  -H "Authorization: Bearer $ORCH_KEY" \
  -d '{"reason": "Missing controller tests"}'
# Rejected stories auto-reset to pending and re-enter the queue
```

### 5. Monitor Progress

```bash
# Project-wide progress
curl .../projects/{id}/progress -H "Authorization: Bearer $USER_KEY"

# Change feed (orchestrator polls this)
curl ".../changes?since=2026-03-27T00:00:00Z&project_id={id}" \
  -H "Authorization: Bearer $ORCH_KEY"

# Audit trail for a story
curl .../stories/{id}/history -H "Authorization: Bearer $ORCH_KEY"
```

### 6. Checkpoint

The orchestrator saves its state for crash recovery:

```bash
curl -X PUT .../orchestrator/state/{project_id} \
  -H "Authorization: Bearer $ORCH_KEY" \
  -d '{"state_key": "main", "state_data": {"phase": "epic_3", "last_verified": "US-2.1"}, "version": 0}'
```

On restart, the orchestrator loads its state and resumes from the checkpoint.

## Key Principles

1. **The orchestrator never writes code.** It dispatches agents and verifies their work.
2. **Never trust agent self-reports.** Always run an independent review.
3. **Fresh agent per story.** Context resets prevent coherence degradation over long sessions.
4. **One commit per story.** The precommit hook forces quality at every step.
5. **Review agent ≠ implementation agent.** Separate processes, separate keys.
6. **Checkpoint after every verification.** Enable crash recovery.
7. **Maximum 5 review-fix cycles per story.** Escalate to human if stuck.

## Skill Versioning (Future)

When running loopctl as a service, you can store skills in the database via the Skills API:

```bash
# Import skills from files
curl -X POST .../skills/import \
  -H "Authorization: Bearer $USER_KEY" \
  -d '[{"name": "loopctl:review", "description": "...", "prompt_text": "..."}]'

# Track which skill version produced which results
curl -X POST .../skill_results \
  -H "Authorization: Bearer $ORCH_KEY" \
  -d '{"skill_version_id": "...", "verification_result_id": "...", "story_id": "...", "metrics": {"findings_count": 5}}'

# Compare versions
curl .../skills/{id}/stats -H "Authorization: Bearer $USER_KEY"
```

This enables data-driven prompt optimization: see which review prompt version catches the most real bugs with the fewest false positives.
