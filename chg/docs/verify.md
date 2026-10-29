# Trunk verification, culprits and auto-revert (S8)

A merge is judged twice: by its PR's checks before, and by the whole suite on trunk after. `verified/master` is the newest trunk commit the whole suite passed on. Deploys run from it, and new worktrees are cut from it. When trunk goes red, chg finds the merge that broke it, opens a revert PR that merges itself once its checks pass, and files the story to re-land the change.

Every command works through the repo's adapter (`.chg/adapter.toml`), so it serves any product with an adapter. Each prints one JSON document on stdout.

## Commands

- `chg verify [--sha S] [--ref verified/master] [--remote origin] [--no-run] [--no-push] [--failures-out F] [--tests-timeout-secs N]` runs `static` and then the whole suite (`shard 1/1`) on `S` (default HEAD) in this tree, which must be exactly `S`. The whole-suite run is capped at `N` seconds (default `exec::SUITE_TIMEOUT_SECS`, 2700, above `chg check`'s 1200: a verifier shares a CI runner, where contention stretches a normal run past 20 minutes); a run that hits the cap is an `error` verdict and holds the ref. `chg culprit` takes the same flag for its whole-suite run on `<bad>`. On green it pushes `S` to `refs/heads/<ref>` on the remote:
  - **Forward only.** The ref moves only to a commit that descends from where it is. The push is never forced, so the remote refuses anything else.
  - **Already there:** nothing runs (`already`).
  - **A newer commit is already verified:** nothing runs (`superseded`). The same applies when a racing verifier moved the ref first.
  - **Red:** the ref stays (`held`), and `F` gets the failing test ids, one per line. When static checks failed, `F` is empty: a lint or compile failure is not a test that can be searched with, so it is left to a person.
  - **`--no-run`:** advances only. Use it for a CI job whose suite already passed on `S`.

  Exit 0 green or nothing to do, 1 red, 2 no verdict.

  A green whole-suite run also writes the commit's coverage record (`CHG_RECORD`, see the adapter contract) when the adapter supports it, and `chg verify` publishes it as `refs/chg/cover/<sha>` on the remote. A red run keeps none: coverage selection skips a test whose executed code is unchanged since the record, which is sound only if the test passed there. Publishing deletes the remote's records that are ancestors of the commit and more than 100 first-parent commits behind it, except those another verified line of the same family still reaches (`chg/verified/master` and `chg/verified/epic/<name>` are one family: an epic's publish never deletes the master records master still uses). Every line protects its own 100 first-parent commits for as long as its ref exists, whatever the ancestry: an epic that merges master in leaves master's records alone, and an epic merged into master keeps its records while its stories still use it. Deleting `chg/verified/epic/<name>` when the epic branch goes away is what releases them, and a publish that sees a line tip it has not fetched prunes nothing. A failure while pruning is printed and never changes `cover`: the record is already out. Another line's own records are left to that line. Verifying an epic line is `chg verify --sha <tip> --ref chg/verified/epic/<name>` on each push to the epic; a `chg check` whose base is on the epic then finds the epic's records on its first-parent line. The report's `cover` field says what happened: `published`, `recorded` (with `--no-push`), `recorded, not published: …`, or `no record: …`. Neither recording nor publishing changes the verdict.
- `chg cover fetch [--remote origin]` mirrors the remote's record refs and prints how many were new. Run it on a gate machine before `chg check`, so `affected` selects by coverage, and before a balanced shard. A record is unpacked into this machine's store when first used, and the store keeps the 30 most recently unpacked.

  `affected` judges by the nearest record on the base's first-parent line, at most `CHG_COVER_MAX_AGE` (default 100) commits behind, handed to the adapter as `CHG_COVER`. When a path changed since that record matches `always_all`, chg hands it none and says why on stderr, and the adapter selects from the base instead.
- `chg adapter exec shard --n N --i I --balance-by <rev>` splits the suite by the test times in `rev`'s record, so N machines finish together. Every machine in a pool must pass the same `rev` (the verified sha) and hold its record; a missing record is an error (exit 2), never a silent fall back to the stable split, because two machines splitting by different rules would skip tests.
- `chg culprit <good> <bad> [--tests F] [--reruns 2]` finds the merge that broke trunk:
  1. It takes the failing tests from `F`, or runs the whole suite on `bad` to find them.
  2. It reruns them `--reruns` times on `bad`. A test that passes on any rerun is `flaky` and leaves the search.
  3. It runs the rest at `good`. If they fail there too, nothing after `good` broke them, and there is no culprit.
  4. It binary-searches them over `bad`'s first-parent commits after `good`, so it names a merge, never a commit inside a merged branch. A test whose file does not exist at a commit passes there, because the commit that added it is where it starts to fail.

  A probe that cannot run stops the search with no culprit, because a guess here would revert somebody's merge. That covers a worktree, a hydrate or a snapshot that failed, and an adapter that broke the contract or timed out.

  Test ids are the adapter's own (`test/a_test.exs:3`, `packages/a.test.ts > name`). Each probe runs the entries the ids name: the id with any ` > name` dropped (see the adapter contract).

  Every probe runs in a throwaway worktree at one fixed path per repo, hydrated from a snapshot. With no snapshot, chg builds one of `good` once. The live tree is never touched, and the search has one test database of its own. Output: `culprit` (null when nothing fails for real), `subject`, `failing`, `flaky`, and every probe. Exit 0 with an answer, 2 when the search could not run.
- `chg revert <culprit> --run-id ID [--base master] [--tests F] [--label auto-revert] [--fix-label reland]` works in five steps:
  1. Builds the revert on top of the remote's `base` in a throwaway worktree, with `-m 1` for a merge, and pushes it as `auto-revert/<sha12>`.
  2. Opens a PR labelled `auto-revert`.
  3. Arms auto-merge, so it merges once the branch's required checks pass.
  4. Files a `reland` issue: the story to re-land the change with `F`'s tests passing.
  5. Comments on the culprit's PR, which is how its author's session hears of it.

  It is idempotent on the culprit. The branch is `auto-revert/<sha12>`, and the PR, the issue and the comment each carry a marker naming the culprit, so a retry, or a later red run that names the same culprit before the revert merges, finds them and does only what is missing. A lookup that fails is an error, never "none yet". Each attempt holds the repo's revert lock throughout. A revert that does not apply cleanly opens no PR, and the issue says so. Exit 0 with a revert PR, 1 without one, 2 on error.
- `chg flaky --tests F --run-id ID [--label flaky]` keeps one open issue per flaky test. A test that was already flaky gets one comment per run instead of a new issue.

`gh` must be authenticated for the repo. `CHG_GH` names another binary.

A CI runner that runs as its own user (`github-runner`) gets chg from `scripts/install-system.sh`, run once per host by an account that has the toolchains: `/usr/local/bin/chg`, the Elixir adapter archive and the TypeScript adapter at `/usr/local/share/chg/typescript/chg-adapter.mjs`. A TypeScript job sets `CHG_TS_ADAPTER_DIR=/usr/local/share/chg/typescript` so the manifest's commands run that copy (adapters/typescript/README.md). On Linux the binary is static (musl), so a job running in a container can mount and run it whatever the container's glibc.

## A trunk workflow

```yaml
on:
  push:
    branches: [master]
# A newer tip replaces a queued run; a started run is never cancelled.
concurrency: { group: verify-master, cancel-in-progress: false }
jobs:
  verify:
    runs-on: [self-hosted]
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - id: verify
        run: chg verify --failures-out failing.txt
      - if: failure() && steps.verify.outcome == 'failure'
        run: |
          [ -s failing.txt ] || exit 0  # static checks failed: no tests to search with
          good=$(git ls-remote origin refs/heads/verified/master | cut -f1)
          chg culprit "$good" HEAD --tests failing.txt > culprit.json
          jq -r '.flaky[]' culprit.json > flaky.txt
          [ -s flaky.txt ] && chg flaky --tests flaky.txt --run-id "$GITHUB_RUN_ID"
          culprit=$(jq -r '.culprit // empty' culprit.json)
          if [ -n "$culprit" ]; then
            jq -r '.failing[]' culprit.json > real.txt
            chg revert "$culprit" --run-id "$GITHUB_RUN_ID" --tests real.txt
          fi
```

A deploy job runs only from `verified/master`:

```bash
[ "$(git ls-remote origin refs/heads/verified/master | cut -f1)" = "$DEPLOY_SHA" ] || exit 1
```

These belong to the product, not to chg: the deploy guard, branch protection on `verified/master` (allow the verifier's push, refuse force pushes), and cutting new worktrees from `origin/verified/master`.
