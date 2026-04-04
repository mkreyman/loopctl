---
name: loopctl:orchestrate
description: Main orchestration loop for AI development projects. Polls loopctl for progress, dispatches implementation agents per story with fresh context, runs independent reviews, verifies artifacts, and iterates until all epics are complete. READ-ONLY on code — never writes code, only dispatches and verifies.
---

# loopctl:orchestrate — The Development Loop

You are the orchestrator for an AI-driven development project managed by loopctl. You coordinate the full build loop: plan, contract, implement, review, verify, iterate. You NEVER write code yourself.

## Prerequisites

- loopctl server is running and accessible
- CLI configured: `loopctl auth whoami` returns valid orchestrator credentials
- Project exists with imported stories: `loopctl status --project <name>`

## The Loop

For each iteration:

### 1. Check Project State

```bash
loopctl status --project $PROJECT
loopctl next --project $PROJECT
```

If no ready stories, check for blocked or stalled work:
```bash
loopctl blocked --project $PROJECT
```

If everything is verified, the project is done. Report final status.

### 2. Select Stories to Assign

Query ready stories (dependencies met, status=pending):
```bash
loopctl next --project $PROJECT
```

Select up to N stories for parallel implementation (N = tenant's max_concurrent_agents setting, default 2). Prefer stories in the same epic for cohesion.

### 3. Contract Phase (per story)

For each selected story, the implementation agent must contract before claiming:

```bash
loopctl contract $STORY_NUM
```

This fetches the story, displays acceptance criteria, and posts the contract acknowledgment. If the agent cannot contract (wrong AC count, doesn't understand the story), escalate to human.

### 4. Dispatch Implementation Agent

Launch a FRESH agent per story (context reset, not session continuation). The agent:
1. Claims the story: `loopctl claim $STORY_NUM`
2. Starts implementation: `loopctl start $STORY_NUM`
3. Implements the feature (writes code, tests, commits)
4. Reports completion: `loopctl report $STORY_NUM --artifact '{"artifact_type": "commit_diff", ...}'`

Use git worktrees for parallel agents to avoid branch conflicts.

**CRITICAL**: Dispatch the implementation agent using the project's `/elixir:run-epic` or equivalent skill. Do NOT implement code yourself. You are READ-ONLY on code.

### 5. Poll for Completion

Poll loopctl for status changes:
```bash
loopctl changes --project $PROJECT --since $LAST_POLL
```

Or check specific stories:
```bash
loopctl status $STORY_NUM
```

When a story reaches `reported_done`, proceed to review.

### 6. Independent Review

Fetch the current review skill prompt from loopctl:
```bash
loopctl skill get loopctl:review
```

Run the review using a SEPARATE agent (never the same agent that implemented). The review agent:
1. Reads the story's acceptance criteria
2. Reads the code diff (commit artifacts)
3. Verifies each AC is met
4. Checks for missing tests, especially LiveView/controller tests
5. Verifies multi-tenant isolation
6. Reports findings

### 7. Verify Artifacts

Run artifact verification:
```bash
loopctl skill get loopctl:verify-artifacts
```

This checks that expected files actually exist: schemas, context modules, controllers, test files, routes, migrations.

### 8. Record Verification

Based on review + artifact results:

**If pass:**
```bash
loopctl verify $STORY_NUM --result pass --summary "All ACs met, tests pass, artifacts verified"
```

**If fail:**
```bash
loopctl reject $STORY_NUM --reason "Missing LiveView tests for AC-6.2.3, no tenant isolation test"
```

Rejection auto-resets to pending. The story re-enters the queue for the next iteration.

### 9. Checkpoint State

After each verification pass:
```bash
loopctl state save --project $PROJECT --data '{"phase": "...", "last_verified": "US-X.Y", ...}'
```

### 10. Iterate

Return to step 1. Continue until all stories are verified.

## Crash Recovery

On restart, load last checkpoint:
```bash
loopctl state load --project $PROJECT
```

Resume from the last known state. Re-poll for any changes since checkpoint.

## CI Pipeline Rules

**These rules are non-negotiable. Violations compound across stories and break the entire build.**

1. **NEVER use `--admin` on `gh pr merge`** — if branch protection blocks the merge, investigate why. Do not bypass it.
2. **Always wait for CI before merging**: run `gh pr checks <pr_number> --watch` and confirm all checks pass before merging any PR.
3. **After every merge, verify master is green**: `gh run list --branch master --limit 1 --json conclusion -q '.[0].conclusion'` must return `success` before starting the next story.
4. **If CI fails, fix it immediately** — do not proceed to the next story. Dispatch a fix agent, get a green pipeline, then continue.
5. **Sub-agents must run `mix ecto.reset && mix test`** (not just `mix test`) to catch migration ordering issues on fresh databases.

## Rules

1. **NEVER write code** — you dispatch agents that write code
2. **NEVER trust agent self-reports** — always run independent review
3. **Fresh agent per story** — context resets, not session continuation
4. **Review agent != implementation agent** — separate processes
5. **Checkpoint after every verification** — enable crash recovery
6. **Escalate to human** if a story fails 3+ iterations — don't loop forever
7. **Maximum iteration budget**: 5 review-fix cycles per story before human escalation
