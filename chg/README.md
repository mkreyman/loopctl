# chg

The agent fleet's change system: Scion's coordination model (server-side landing with no global
lock, affected-only checks before merge, batched verification after merge, auto-revert, Claude
resolving conflicts, intent review) on git storage. Elixir and TypeScript repos are first-class.

- Design and phases: [docs/design.md](docs/design.md)
- Sources: [docs/sources.md](docs/sources.md)
- Shadow phase and the gate switch (`chg check`, `chg gate`, `chg shadow`): [docs/shadow.md](docs/shadow.md)
- Trunk verification, culprits and auto-revert (`chg verify`, `chg culprit`, `chg revert`, `chg flaky`): [docs/verify.md](docs/verify.md)

Layout as it lands: `cli/` (Rust: `chg` and `chgd`), `adapters/` (Elixir, TypeScript, and generic for a repo with no build),
`server/` (Elixir/Phoenix control plane, phase 2).

## KB write-back (S13, phase-1 form)

`bin/chg-kb-sync.py --repo owner/name --project-id <loopctl project>` writes each lesson the master verifier recorded on GitHub (merged `auto-revert` PRs, `test-flakiness` issues) to the loopctl KB as one `finding`, tagged `chg`, the repo and the kind. It runs from cron (minis: daily 06:17 for home_care_billing), never on the merge path, and a rerun writes nothing twice. It needs claude-config's `skills/_shared/loopctl_client_core.py`, and makes its own venv for `requests` under `~/.chg/kb-venv` on first use. Test: `python3 tests/kb-sync-test.py`.
