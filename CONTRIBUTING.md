# Contributing to loopctl

Thank you for your interest in contributing to loopctl.

## Getting Started

1. Check [GitHub Issues](https://github.com/mkreyman/loopctl/issues) for open items
2. Fork the repository and create a feature branch
3. Follow the setup instructions in [README.md](README.md#local-development)
4. Run the full quality gate before submitting: `mix precommit`

## Quality Standards

All contributions must pass:

- `mix compile --warnings-as-errors` -- Zero compiler warnings
- `mix format --check-formatted` -- Consistent formatting
- `mix credo --strict` -- Static analysis
- `mix dialyzer` -- Type checking
- `mix test` -- Full test suite with 100% pass rate
- `mix loopctl.check_env_docs` -- Every env var read in `runtime.exs` or `lib/` has a doc table row
- `mix loopctl.check_skill_citations` -- `file:line` citations in skills/CLAUDE.md still resolve

The last two run inside `mix precommit`. They exist because both failures are
SILENT: nothing else in the pipeline notices an undocumented knob or a citation
that rotted after a refactor.

## Documenting Operator-Facing Changes

Two things are easy to ship and impossible for a user to discover, so both are
required in the same PR that introduces them:

**1. A new environment variable.** Give it a row in the appropriate table in
[`deploy/FLY_SECRETS.md`](deploy/FLY_SECRETS.md) with its **default** and **what
breaks if it is wrong**. `mix loopctl.check_env_docs` fails the build otherwise.
An operator cannot read our source tree; a knob that lives only in our source
effectively does not exist for them.

The guard scans `config/runtime.exs` **and** `lib/**/*.ex`, and it wants a table
**row** with a real default and description — not a passing mention. Both bounds were
bought the hard way: the whole `OBAN_*` family stayed invisible for months because
`runtime.exs` reads it through `Loopctl.ObanConfig` rather than by literal name, and
`STH_SWEEP_CRON` counted as documented on the strength of one aside about a different
decision (#566).

A name the code BUILDS at runtime (`"OBAN_QUEUE_" <> queue`) is not resolvable by a
textual scan, and is still an operator knob. So the guard FAILS on a dynamic read
unless its file is listed in the task's `@dynamic_read_sources` with a reason — and
then you document the family (`OBAN_QUEUE_<QUEUE>`) by hand.

**2. A new or changed API constraint.** Size caps, new `4xx` conditions, changed
field semantics, and what is or is not encrypted at rest all belong in the
endpoint's `operation/2` OpenAPI spec — not only in the controller guard. Where a
limit is both enforced and documented, reference ONE module attribute from both
sites so they cannot drift.

## Changelog

`CHANGELOG.md` records **operator-facing** changes only — things that alter how
someone runs, upgrades, or calls loopctl:

- a new or changed environment variable, or a change to required deploy ordering
- a migration with an ordering requirement or a manual step
- a breaking or behaviour-changing API change (new limits, changed field meaning)
- a security-relevant change in how data is stored or protected

Everything else — refactors, test de-flaking, internal hardening, dependency
bumps — is deliberately **out of scope**. `git log --first-parent` is the complete
history and needs no duplication. This narrow trigger is the point: a changelog
that tries to record every merge is the kind that stops being written at all,
which is exactly what happened to this one before the boundary was drawn.

## Reporting Issues

Please use [GitHub Issues](https://github.com/mkreyman/loopctl/issues) to report bugs or request features. Include reproduction steps and relevant error output when possible.
