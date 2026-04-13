---
title: "Verification Runs — Independent Re-Execution"
category: reference
scope: system
---

# Verification Runs

Verification runs provide SWE-bench-style independent re-execution
of a story's acceptance criteria. Instead of trusting the implementer's
self-report, loopctl re-checks each AC against the committed code.

## How it works

1. A verification run is enqueued when verify_story is called
2. The runner fetches the commit SHA and computes a content hash
3. For each AC, the runner checks the verification_criterion:
   - **test**: runs the named test and checks it passes
   - **code**: greps for the pattern in the file
   - **route**: checks the router for the endpoint
   - **migration**: checks the migration for the column
   - **manual**: flags for operator review
4. Results are stored per-AC in the verification_run record

See [Acceptance Criteria Bindings](/wiki/acceptance-criteria-bindings)
for criterion format details.
