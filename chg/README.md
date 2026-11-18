# chg

The agent fleet's change system: Scion's coordination model (server-side landing with no global
lock, affected-only checks before merge, batched verification after merge, auto-revert, Claude
resolving conflicts, intent review) on git storage. Elixir and TypeScript repos are first-class.

- Design and phases: [docs/design.md](docs/design.md)
- Sources: [docs/sources.md](docs/sources.md)
- Shadow phase and the gate switch (`chg check`, `chg gate`, `chg shadow`): [docs/shadow.md](docs/shadow.md)
- Trunk verification, culprits and auto-revert (`chg verify`, `chg culprit`, `chg revert`, `chg flaky`): [docs/verify.md](docs/verify.md)
- The outbox to loopctl's ledger, change events and review keys (`chg outbox`, `chg event`, `chg review-dispatch`): [docs/outbox.md](docs/outbox.md)

Layout as it lands: `cli/` (Rust: `chg` and `chgd`), `adapters/` (Elixir, TypeScript, and generic for a repo with no build),
`server/` (Elixir/Phoenix control plane, phase 2).

## Install

    scripts/install.sh                     # build this checkout, install ~/.local/bin/chg
    scripts/install.sh --release vX.Y.Z    # Linux x86_64 only: the release's static binary

A Mac has no release binary, so it always builds from source: check out the commit to install
(`git -C ~/workspace/chg pull` on master, with a clean tree) and run `scripts/install.sh`. The
build uses the Rust that `.tool-versions` names, and `chg --version` ends with
`commit <sha12>` (`-dirty` when the tree had uncommitted changes), so every machine says which
commit it runs. CI runners also need `scripts/install-system.sh` (docs/verify.md).

## KB write-back (S13, phase-1 form)

`bin/chg-kb-sync.py --repo owner/name --project-id <loopctl project>` writes each lesson the master verifier recorded on GitHub (merged `auto-revert` PRs, `test-flakiness` issues) to the loopctl KB as one `finding`, tagged `chg`, the repo and the kind. It runs from cron (minis: daily 06:17 for home_care_billing), never on the merge path, and a rerun writes nothing twice. It needs claude-config's `skills/_shared/loopctl_client_core.py`, and makes its own venv for `requests` under `~/.chg/kb-venv` on first use. Test: `python3 tests/kb-sync-test.py`.

`bin/chg-kb-digest.py --repo owner/name --project-id <loopctl project>` writes one daily digest per repo to the KB, the `/debrief` analogue: the day's merged PRs, auto-reverts and flaky-test issues, the `## Review findings` sections of those PRs (counts by disposition and severity, the wrong + didnt-matter share, sections that did not parse), and recurring review patterns, meaning a file flagged in 2+ PRs or a directory flagged in 3+ within the last 7 days (`--lookback`). It parses the sections with claude-config's `bin/review-dispositions.py`. `~/.chg/kb-digest/<repo>.json` holds the last day written; a run writes every day since, up to yesterday and at most 7 days back (`--catch-up`), and a day's idempotency tag makes a rerun write nothing twice. It runs from cron (minis: daily 06:27 for home_care_billing). Test: `python3 tests/kb-digest-test.py`.
