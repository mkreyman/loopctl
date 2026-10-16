# Shadow phase and the gate switch (S10)

A repo moves its push gate to `chg check` in three modes, chosen by `chg gate`:

| Mode | Who judges a push | chg's part |
|---|---|---|
| `shadow` (default) | the repo's existing gate | `chg check --shadow` runs beside it, never blocking, and logs its verdict |
| `on` | `chg check` | the gate itself |
| `off` | the repo's existing gate | nothing, shadow included |

`CHG_GATE=on|shadow|off` in the environment beats `[gate] mode` in `.chg/policy.toml`. An unknown value, a `CHG_GATE` that is not Unicode, or a policy file that exists but cannot be read or parsed resolves to `off`, so a hook that cannot tell what was asked runs the old gate. `chg gate` prints the mode on stdout (and its source on stderr) and always exits 0.

## Commands

- `chg check [--sha S] [--base B] [--all]`: static checks, then the affected tests of the working tree against `B` (default: the merge-base of `S`, or HEAD, with origin's default branch). Prints the verdict as one JSON line. Exit 0 pass, 1 fail, 2 no verdict, 3 the gate is `off`. With `--sha`, the tree must be exactly `S` (HEAD is `S`, nothing uncommitted or untracked) before the run, or it exits 2 without running anything; if the tree changed by the end of the run, the verdict is `error`, so a gate never passes a commit it did not test.
- `chg check --shadow [--sha S] [--base B]`: resolves `S` (default HEAD) and `B` now, starts a detached copy of itself in a new session, and exits 0 at once, whatever happens. The copy:
  1. runs at `nice 10` and waits up to 30 min for this machine's shadow lock, so a burst of pushes queues instead of running several suites beside the real gate;
  2. checks `S` out, with no hooks, into the repo's shadow worktree inside the snapshot store (one fixed path per repo, cleared first of anything a killed check left there), and hydrates it from the nearest-ancestor snapshot. With no snapshot it records `skipped` instead of cold-building, which would compete with the real gate for the machine;
  3. runs `chg check` there. The fixed path gives every shadow check of the repo the same workspace slot, so one test database of its own, reused run after run; the live tree is never read, because the real gate may be compiling and testing it at that moment;
  4. appends a `chg` row to `~/.chg/shadow/<repo>.jsonl` and removes the worktree.

  The detached copy works through the repo's shared git dir, not the pushing worktree, which may be removed before the check is done.

  Its output goes to `~/.chg/shadow/logs/<repo>-<sha12>.log` (kept 14 days). `CHG_HOME` moves `~/.chg`.
- `chg shadow record --verdict pass|fail [--sha S] [--ms N] [--gate NAME] [--failures-file F]`: appends the authoritative gate's verdict for `S` as a `gate` row. `F` lists failing test ids, one per line; the report uses them to tell a missed test from a flake.
- `chg shadow report [--file F]... [--hosts a,b,c] [--ci-check NAME] [--json]`: pairs every `chg` row with the gate's verdict for its commit, prints the disagreements and the cutover criteria, and exits 0 only when every criterion is met. `--hosts` reads each machine's log over ssh. `--ci-check NAME` fills in a commit no local gate judged from GitHub check runs named `NAME` on that commit: every completed run that passed or failed becomes a `gate` row, so a failed run and its passing rerun make the commit gate-flaky. A commit is asked about again until its newest CI verdict is 72 hours old.

`<repo>` is the origin's repository name (`home_care_billing`), the same in every worktree.

## The report

| Class | chg | gate | Meaning |
|---|---|---|---|
| agree | pass | pass, or fail and fail | |
| **MISS** | pass | fail | a test chg did not select, or a flake chg's run did not hit. Blocks cutover. The report lists each gate failure as selected (chg ran it and it passed: likely a flake) or not selected (a real miss). |
| chg-red | fail | pass | a flake in chg's run, or an environment difference |
| gate-flaky | either | both | the gate gave both verdicts for this commit, so it cannot judge chg |

A `skipped` or `error` chg row, or one whose commit has no gate verdict yet, is counted but not paired.

Cutover criteria (issue #18), all required:
- at least 200 paired pushes;
- on at least 3 machines;
- zero MISS;
- median `chg check` time at most 3 min. This is the check alone (`ms`), not the hydrate (`hydrate_ms`): after cutover the check runs in the agent's own worktree, which is already hydrated.

## Wiring a pre-push hook

Shadow phase. After the hook has decided which commit its gate will judge (`$GATE_SHA`), and for pushes it leaves to CI:

```bash
# chg shadow (S10): never blocks the push and never changes this hook's verdict.
if command -v chg >/dev/null 2>&1; then
  chg check --shadow --sha "$GATE_SHA" --base "$BASE_SHA" </dev/null || true
fi
started=$SECONDS
status=0
run_the_existing_gate || status=$?
if command -v chg >/dev/null 2>&1; then
  verdict=pass; [ "$status" -ne 0 ] && verdict=fail
  chg shadow record --sha "$GATE_SHA" --verdict "$verdict" \
    --ms "$(( (SECONDS - started) * 1000 ))" --gate "mix precommit" </dev/null || true
fi
```

A push the hook does not gate locally, because CI judges it, gets only the `chg check --shadow` line. The report then takes its verdict with `--ci-check "<required check name>"`.

Cutover (one PR in the product repo, after the report says ready): set `[gate] mode = "on"` in `.chg/policy.toml`, and make the hook ask chg which gate to run:

```bash
case "$(chg gate 2>/dev/null || echo off)" in
  on) chg check --sha "$GATE_SHA" --base "$BASE_SHA"; status=$? ;
      # 3 = the gate was switched off between the two calls: run the old one. 2 (no
      # verdict, or the tree is not exactly $GATE_SHA) blocks the push like a failure.
      [ "$status" -eq 3 ] && { run_the_existing_gate; status=$?; } ;;
  *)  run_the_existing_gate; status=$? ;;
esac
```

Rollback is `CHG_GATE=off git push` for one push, or `mode = "off"` in the policy for everyone. Neither needs a code change.
