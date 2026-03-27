---
name: loopctl:plan
description: Analyze a project's dependency graph, determine epic implementation order, identify parallelization opportunities, and create the orchestration plan. READ-ONLY — does not write code or modify stories.
---

# loopctl:plan — Project Planning

You analyze a loopctl project and produce an orchestration plan. You read the dependency graph, identify the critical path, determine which epics/stories can run in parallel, and output a structured plan the orchestrator will follow.

## Inputs

- Project name or ID
- Max concurrent agents (from tenant settings)

## Process

### 1. Load Project State

```bash
loopctl status --project $PROJECT --format json
loopctl export --project $PROJECT > /tmp/project.json
```

### 2. Analyze Dependency Graph

From the export, build the dependency graph:

- **Epic dependencies**: Which epics must complete before others start?
- **Story dependencies**: Within and across epics, which stories block which?
- **Critical path**: The longest chain of dependent stories — this determines minimum project duration.

### 3. Identify Parallelism

Given N max concurrent agents:

- Find stories with no unverified dependencies (the "frontier")
- Group frontier stories by epic (prefer same-epic batches for cohesion)
- Identify independent epic chains that can run fully in parallel

Example for N=2:
```
Agent 1: Epic 1 → Epic 3 → Epic 5 (sequential chain)
Agent 2: Epic 2 → Epic 4 (independent chain)
```

### 4. Detect Risks

Flag:
- **Cross-level deadlocks**: Epic A depends on Epic B, but a story in B depends on a story in A
- **Bottleneck stories**: Stories with many dependents (high fan-out)
- **Long stories**: Stories with >8h estimate that might stall the pipeline
- **Circular dependency warnings**: Should not exist (import validates), but verify

### 5. Output Plan

```json
{
  "project": "freight-pilot",
  "total_stories": 60,
  "total_estimated_hours": 270,
  "max_concurrent_agents": 2,
  "phases": [
    {
      "phase": 1,
      "epics": [1, 2],
      "stories": ["US-1.1", "US-1.2", "..."],
      "parallelism": "Epic 1 and Epic 2 are independent, can run in parallel"
    },
    {
      "phase": 2,
      "epics": [3, 4, 5],
      "stories": ["US-3.1", "US-4.1", "US-5.1", "..."],
      "parallelism": "Epic 3 depends on Epic 1. Epics 4+5 depend on Epic 2. Two parallel chains."
    }
  ],
  "critical_path": ["US-1.1", "US-2.1", "US-2.3", "US-6.2", "US-7.1", "US-12.1"],
  "critical_path_hours": 42,
  "risks": [
    {"type": "bottleneck", "story": "US-2.4", "dependents": 12, "note": "All auth-dependent stories block on this"}
  ]
}
```

### 6. Save Plan to loopctl

```bash
loopctl state save --project $PROJECT --data '<plan_json>'
```

The orchestrator reads this plan to determine what to assign next.

## Rules

1. **READ-ONLY** — do not modify stories, create stories, or write code
2. **Respect dependencies** — never suggest parallelizing dependent stories
3. **Be conservative with parallelism** — 2 concurrent agents is better than 5 if the dependency graph is tight
4. **Flag risks, don't hide them** — if the plan has weak points, say so
