---
name: loopctl:status
description: Query loopctl for project progress and display a human-readable summary. Shows epic completion, story status breakdown, active agents, blocked stories, and skill performance.
---

# loopctl:status — Project Status Dashboard

You query loopctl and produce a clear status report for the human developer.

## Usage

When invoked, gather and display the following:

### 1. Project Overview

```bash
loopctl status --project $PROJECT --format json
```

Display as:
```
Project: freight-pilot (active)
Progress: 42/60 stories verified (70%)
Phase: Epic 10 — Webhooks

Stories by status:
  pending:       8
  contracted:    0
  assigned:      2  (worker-1: US-10.3, worker-2: US-10.4)
  implementing:  0
  reported_done: 3  (awaiting review)
  verified:     42
  rejected:      5  (back in queue)
```

### 2. Epic Progress

```bash
loopctl status --project $PROJECT --format json
```

Display as:
```
Epic Progress:
  1. Foundation         7/7  [====================] 100%
  2. Auth               7/7  [====================] 100%
  3. Audit              3/3  [====================] 100%
  4. Agents             2/2  [====================] 100%
  5. Projects           2/2  [====================] 100%
  6. Work Breakdown     5/5  [====================] 100%
  7. Progress Tracking  4/5  [================----]  80%  ← current
  8. Artifacts          0/2  [--------------------]   0%  (blocked)
  ...
```

### 3. Active Agents

```bash
# From the status response
```

Display which agents are working on what, and for how long.

### 4. Blocked Stories

```bash
loopctl blocked --project $PROJECT --format json
```

Show which stories are blocked and what they're waiting on.

### 5. Recent Activity

```bash
loopctl changes --project $PROJECT --since <1_hour_ago> --format json
```

Show recent status changes, verifications, rejections.

### 6. Iteration Health

For stories that have been rejected and re-submitted:
- Average iterations to pass
- Stories with 3+ iterations (potential problem stories)
- Current skill versions in use

### 7. Recommendations

Based on the data:
- "US-10.3 has been implementing for 45 min — consider checking on worker-1"
- "Epic 8 is blocked on US-7.2 — prioritize its review"
- "5 stories rejected — loopctl:review v2 has 30% false positive rate, consider updating"

## Output Formats

- Default: Human-readable tables and progress bars (for developer)
- `--format json`: Machine-readable (for other skills/agents)
