---
name: loopctl:verify-artifacts
description: Verify that a story's implementation actually produced the expected code artifacts. Checks that files, modules, functions, routes, tests, and migrations exist in the codebase. READ-ONLY — only reads code, writes results to loopctl.
---

# loopctl:verify-artifacts — Artifact Verification

You verify that a story's implementation actually produced real code artifacts. Agents claim to have created files — you check if those files exist and contain what they should.

## Inputs

- Story ID
- Project directory (git repo path)
- Artifact report from the implementing agent (optional)

## Process

### 1. Read the Story

```bash
loopctl status $STORY_NUM --format json
```

Extract: acceptance_criteria, technical_notes (for module paths, table names).

### 2. Read Agent's Artifact Report (if available)

```bash
# List what the agent claims it created
loopctl status $STORY_NUM --format json | jq '.artifacts'
```

### 3. Derive Expected Artifacts

From the ACs and technical notes, determine what MUST exist:

| AC mentions... | Expect... |
|---|---|
| Schema module | `lib/loopctl/<context>/<schema>.ex` with `use Loopctl.Schema` |
| Context function | `lib/loopctl/<context>.ex` with the named function |
| API endpoint | Route in `lib/loopctl_web/router.ex` |
| Controller | `lib/loopctl_web/controllers/<name>_controller.ex` |
| Migration | `priv/repo/migrations/*_<name>.exs` |
| Test file | `test/loopctl/<context>_test.exs` or `test/loopctl_web/controllers/*_test.exs` |
| RLS policy | In migration file: `execute "CREATE POLICY..."` |
| Oban worker | `lib/loopctl/workers/<name>.ex` with `use Oban.Worker` |
| Behaviour | `lib/loopctl/<context>/<name>_behaviour.ex` with `@callback` |

### 4. Check Each Artifact

For each expected artifact:

**File exists?**
```
Glob for the expected path pattern
```

**Contains expected content?**
```
Grep for key identifiers:
- Schema: "use Loopctl.Schema", "schema \"table_name\""
- Context: "def function_name(", "@spec function_name"
- Controller: "action_fallback", "def create(", "def index("
- Migration: "create table(:table_name)", "CREATE POLICY"
- Test: "use Loopctl.DataCase, async: true", "describe \"function_name\""
- Route: "post \"/path\"", "get \"/path\""
```

**Test coverage?**
For each context function mentioned in the ACs, check that a corresponding test exists:
```
Grep test files for the function name or related describe block
```

### 5. Report Results

For each artifact, report to loopctl:

```bash
loopctl report $STORY_NUM --artifact '{
  "artifact_type": "schema",
  "path": "lib/loopctl/work_breakdown/story.ex",
  "exists": true,
  "details": {"has_base_schema": true, "has_tenant_field": true, "fields_count": 15}
}'
```

### 6. Summary

Produce a summary:

```json
{
  "story_id": "US-6.2",
  "total_expected": 8,
  "found": 7,
  "missing": 1,
  "missing_details": [
    {"type": "test", "expected_path": "test/loopctl_web/controllers/story_controller_test.exs", "note": "Controller test file does not exist"}
  ]
}
```

## What to Flag

- **CRITICAL**: Schema exists but missing `tenant_field()` — tenant isolation broken
- **CRITICAL**: Migration exists but no RLS policy — data leakage risk
- **HIGH**: Context module exists but function is missing or has wrong arity
- **HIGH**: Controller exists but not in router — endpoint unreachable
- **HIGH**: Test file exists but no test cases inside (empty describe blocks)
- **MEDIUM**: Test exists but missing tenant isolation test case
- **LOW**: Module exists but missing @doc or @spec

## Rules

1. **READ-ONLY** — never create, modify, or delete any file
2. **Check actual files, not agent claims** — the filesystem is truth
3. **Grep for content, not just existence** — an empty file is not an artifact
4. **Report everything to loopctl** — the orchestrator decides pass/fail based on your data
