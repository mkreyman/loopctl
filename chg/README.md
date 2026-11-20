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
(`git -C ~/workspace/loopctl pull` on master, with a clean tree) and run `chg/scripts/install.sh`.
On a factory machine `release/install-machine.sh` does this for the release set's commit. The
build uses the Rust that `.tool-versions` names, and `chg --version` ends with
`commit <sha12>` (`-dirty` when the tree had uncommitted changes), so every machine says which
commit it runs. CI runners also need `scripts/install-system.sh` (docs/verify.md).

## KB write-back (S13, phase-1 form)

`bin/chg-kb-sync.py --repo owner/name --project-id <loopctl project>` writes each lesson the master verifier recorded on GitHub (merged `auto-revert` PRs, `test-flakiness` issues) to the loopctl KB as one `finding`, tagged `chg`, the repo and the kind. It runs daily on nuc (infra `infra-chg-kb-sync` timer, runbooks/chg-jobs.md), never on the merge path, and a rerun writes nothing twice. It needs claude-config's `skills/_shared/loopctl_client_core.py`, and makes its own venv for `requests` under `~/.chg/kb-venv` on first use. Test: `python3 tests/kb-sync-test.py`.

`bin/chg-kb-digest.py --repo owner/name --project-id <loopctl project>` writes one daily digest per repo to the KB, the `/debrief` analogue: the day's merged PRs, auto-reverts and flaky-test issues, the `## Review findings` sections of those PRs (counts by disposition and severity, the wrong + didnt-matter share, sections that did not parse), and recurring review patterns, meaning a file flagged in 2+ PRs or a directory flagged in 3+ within the last 7 days (`--lookback`). It parses the sections with claude-config's `bin/review-dispositions.py`. `~/.chg/kb-digest/<repo>.json` holds the last day written; a run writes every day since, up to yesterday and at most 7 days back (`--catch-up`), and a day's idempotency tag makes a rerun write nothing twice. It runs daily on nuc (infra `infra-chg-kb-digest` timer). Test: `python3 tests/kb-digest-test.py`.

## Improvement loop (S14a, phase-1 form)

`bin/chg-loop.py --repo owner/name [--repo ...] [--harness-log ~/.chg/loop/harness.jsonl]` turns recurring failures into `chg-loop` GitHub issues (#97; the full design is #22). Its sensors read what is already recorded: merged `auto-revert` PRs (keyed by the directories the culprit touched), the runs in `test-flakiness` issues, files flagged in the `## Review findings` of merged PRs, and red harness checks, one JSON line each (`at`, `source`, `check`, `host`, `detail`) in the harness log. Each cause gets a fingerprint, sha256 of (sensor, owning repo, key), and one issue ever, in the repo that owns it: `hooks/`, `skills/`, `agents/` and `bin/` of claude-config go to claude-config, chg's paths to chg, the rest stay where they were seen. Thresholds and guards are in `.chg/loop.toml`: an issue is filed at 1 revert, 2 flaky runs, 4 PRs flagging a file within 14 days, or 1 red harness check; at most 3 new issues per repo per day; a new occurrence comments on the open issue; a recurrence within 14 days of a close reopens it; after two closes it is filed as `chg-loop-escalated`, for Mark. `~/.chg/loop/state.json` holds the fingerprints, and each issue carries `<!-- chg-loop:<fingerprint> -->`, so a lost state file finds the issues again. `--dry-run` prints the plan. It runs daily on nuc (infra `infra-chg-loop` timer). Test: `python3 tests/loop-test.py` (in CI).

## Selection replay (#104)

`bin/chg-replay-selection.py --chg <chg checkout> --base <sha> --head <sha> --repo <product checkout> [--corpus N] [--miss <sha> --failure <name> ...]` measures whether a change to chg's test selection only widens it. loopctl's verifier runs it for a chg story that touches selection code, and loopctl merges that story without a person only on this measurement (loopctl US-51.5). It builds chg and the Elixir adapter at both chg commits (cached in `~/.chg/replay/builds/`), then runs each build's `chg adapter exec affected` on the product's last N first-parent commits (default 5, at most 30), each build in its own throwaway worktree. It prints loopctl's `selection_replay` JSON: per commit `base_count`, `head_count` and up to 3 `dropped` test files, and for `--miss`, the `--failure` names (gate failures, `file:line`) whose file the head selects there. It is offline (`GIT_ALLOW_PROTOCOL=file`, so both builds select from the same local coverage records) and writes no ledger rows. The product checkout needs its deps fetched. Elixir adapters only. Test: `python3 tests/replay-selection-test.py` (in CI).
