---
title: "Acceptance Criteria Bindings — Machine-Checkable Verification"
category: reference
scope: system
---

# Acceptance Criteria Bindings

Each acceptance criterion on a story can have a machine-checkable
`verification_criterion` that tells the verification runner exactly
what to check.

## Criterion types

### test
```json
{"type": "test", "path": "test/my_module_test.exs", "test_name": "creates a record"}
```
The runner executes the specific test and checks it passes.

### code
```json
{"type": "code", "path": "lib/my_module.ex", "line_range": [10, 50], "pattern": "def create"}
```
The runner checks that the specified pattern exists in the file.

### route
```json
{"type": "route", "method": "POST", "path": "/api/v1/stories/:id/verify"}
```
The runner checks that the route exists in the router.

### migration
```json
{"type": "migration", "table": "dispatches", "column": "lineage_path"}
```
The runner checks that the column exists on the table.

### manual
```json
{"type": "manual", "description": "Operator must visually inspect the UI"}
```
Requires human approval via the manual review dashboard.

See [Verify Story](/wiki/verify-story) for how verification works end-to-end.
