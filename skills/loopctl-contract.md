---
name: loopctl:contract
description: Sprint contract step — implementation agent reads the story, confirms understanding of acceptance criteria, and commits to delivering them before claiming the story. Prevents blind implementations.
---

# loopctl:contract — Sprint Contract

You are an implementation agent about to begin work on a story. Before you can claim it, you must demonstrate that you've read and understood the acceptance criteria.

## Process

### 1. Fetch the Story

```bash
loopctl status $STORY_NUM --format json
```

### 2. Read and Understand

Read every field:
- **Title**: What is being built?
- **Description**: The full context.
- **Acceptance Criteria**: Each AC is a specific, testable requirement. Count them.
- **Technical Notes**: Implementation guidance, patterns to follow, constraints.
- **Dependencies**: What must be complete before this story. Verify they ARE complete:
  ```bash
  loopctl status $DEP_STORY_NUM
  ```

### 3. Confirm Understanding

Post the contract:
```bash
loopctl contract $STORY_NUM
```

This automatically:
1. Fetches the story
2. Displays the title and all ACs
3. Posts the contract acknowledgment with the correct title and AC count

If the AC count or title doesn't match, the contract is rejected. This proves you read the current version of the story, not a stale copy.

### 4. Plan Before Claiming

Before calling `loopctl claim`, create a brief implementation plan:

- Which files will you create/modify?
- Which migrations are needed?
- Which tests will you write?
- Are there any ACs you're uncertain about?

If anything is unclear, ask the orchestrator BEFORE claiming. Once you claim, the clock starts.

### 5. Claim and Implement

```bash
loopctl claim $STORY_NUM
loopctl start $STORY_NUM
```

Now implement. Refer back to the ACs throughout — they are your checklist.

## Rules

1. **Read every AC** — don't skim. Each one becomes a test case.
2. **Check dependencies are actually done** — don't assume. Query loopctl.
3. **Ask before claiming if uncertain** — it's cheaper to clarify than to rework.
4. **One commit per story** — clean, atomic commits.
5. **Run the full test suite before reporting** — `mix precommit` must pass.
