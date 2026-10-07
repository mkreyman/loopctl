# Epic 46: async test suite through dependency injection

Mark, 2026-10-07: refactor all code that manipulates global state to take that state as an
input (dependency injection), so every test that can run async does. The rule is CLAUDE.md,
Dependency Injection; the method and its guard come from home_care_billing PR #2272.

Each story lists its files with the cause the module states. Order: US-46.1 first (cheap,
proves the method), then the two auth and runner boundaries, then the rest, then the guard
(US-46.6), whose allow-list is whatever remains legitimately sync.

Measure the gate's sync phase (`Finished in ... (Ns async, Ms sync)`) before and after each
story and put both figures in its PR.
