# Trunk verification, culprits and auto-revert (S8)

A merge is judged twice: by its PR's checks before, and by the whole suite on trunk after. `verified/master` is the newest trunk commit the whole suite passed on. Deploys run from it, and new worktrees are cut from it. When trunk goes red, chg finds the merge that broke it, opens a revert PR that merges itself once its checks pass, and files the story to re-land the change.

Every command works through the repo's adapter (`.chg/adapter.toml`), so it serves any product with an adapter. Each prints one JSON document on stdout.

## Commands

- `chg verify [--sha S] [--ref verified/master] [--remote origin] [--no-run] [--no-push] [--failures-out F]` runs `static` and then the whole suite (`shard 1/1`) on `S` (default HEAD) in this tree, which must be exactly `S`. On green it pushes `S` to `refs/heads/<ref>` on the remote:
  - **Forward only.** The ref moves only to a commit that descends from where it is. The push is never forced, so the remote refuses anything else.
  - **Already there:** nothing runs (`already`).
  - **A newer commit is already verified:** nothing runs (`superseded`). The same applies when a racing verifier moved the ref first.
  - **Red:** the ref stays (`held`), and `F` gets the failing test ids, one per line. When static checks failed, `F` is empty: a lint or compile failure is not a test that can be searched with, so it is left to a person.
  - **`--no-run`:** advances only. Use it for a CI job whose suite already passed on `S`.

  Exit 0 green or nothing to do, 1 red, 2 no verdict.
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
