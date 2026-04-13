---
title: "Verify Story — The Verifier's Walkthrough"
category: reference
scope: system
---

# Verify Story

This guide walks a verifier through the complete verification flow.

## Prerequisites

- You hold a `verify_cap` for the story (issued by request_review)
- Your dispatch lineage does NOT share a prefix with the implementer's
- The story has a review_record confirming the review passed

## Step 1: Find stories awaiting verification

```bash
curl -H "Authorization: Bearer $VERIFY_KEY" \
  "https://loopctl.com/api/v1/stories?verified_status=unverified&agent_status=reported_done"
```

## Step 2: Review the acceptance criteria

```bash
curl -H "Authorization: Bearer $VERIFY_KEY" \
  "https://loopctl.com/api/v1/stories/STORY_ID/acceptance_criteria"
```

## Step 3: Re-execute verification

For each AC with a `test` or `code` criterion, the verification runner
checks the actual code/tests. For `manual` criteria, operator approval
is required.

## Step 4: Submit verification

```bash
curl -X POST -H "Authorization: Bearer $VERIFY_KEY" \
  -d '{"summary": "All ACs verified", "cap_id": "..."}' \
  "https://loopctl.com/api/v1/stories/STORY_ID/verify"
```

See [Agent Pattern](/wiki/agent-pattern) for the full lifecycle.
