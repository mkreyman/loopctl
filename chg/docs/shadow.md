# Shadow phase and the gate switch (S10)

A repo moves its push gate to `chg check` in three modes, chosen by `chg gate`:

| Mode | Who judges a push | chg's part |
|---|---|---|
| `shadow` (default) | the repo's existing gate | `chg check --shadow` runs beside it, never blocking, and logs its verdict |
| `on` | `chg check` | the gate itself |
| `off` | the repo's existing gate | nothing, shadow included |

`CHG_GATE=on|shadow|off` in the environment beats `[gate] mode` in `.chg/policy.toml`. An unknown value, a `CHG_GATE` that is not Unicode, or a policy file that exists but cannot be read or parsed resolves to `off`, so a hook that cannot tell what was asked runs the old gate. `chg gate` prints the mode on stdout (and its source on stderr) and always exits 0.

## Commands

- `chg check [--sha S] [--base B] [--all]`: static checks, then the affected tests of commit `S` (default HEAD) against `B` (default: the merge-base of `S` with origin's default branch). Prints the verdict as one JSON line. Exit 0 pass, 1 fail, 2 no verdict, 3 the gate is `off`. It checks `S` out at the repo's snapshot build path, hydrated from the nearest-ancestor snapshot, under the build lock, so only the delta compiles. When that snapshot is older than `B` across an `always_all` path (the build file, the dependency lock, config), the check would rebuild everything inside static's 15-minute budget, so it first builds `B`'s snapshot from it under the snapshot budget (30 min), saying so on stderr, and then hydrates from that; a busy build path or a failed build leaves the check to run as before. Uncommitted changes in the live tree are not judged. Afterwards it starts a detached refresh of `B`'s snapshot, logged to `~/.chg/shadow/logs/<repo>-refresh-<base12>.log`. When that path cannot be used, it runs in the live tree as before and says why on stderr. That happens with no store, a busy path (a snapshot build or another worktree's check: the gate never waits for it), no snapshot, or a failed worktree or hydrate. With `--sha`, the live tree must then be exactly `S` (HEAD is `S`, nothing uncommitted or untracked) before the run, or it exits 2 without running anything. If the tree changed by the end of the run, the verdict is `error`, so a gate never passes a commit it did not test. When chg is the gate (`chg gate` says `on`), it also appends its verdict to `~/.chg/shadow/<repo>.jsonl` as a `chg` row with `"source":"gate"`: the verdict, `ms` (what the push waited for), `mode`, `selection` (why it selected what it did, so for `all` the widening reason), the host and the sha. No other gate runs then, so nothing else would record the push. A log that cannot be written is reported on stderr and never changes the verdict.
- `chg check --shadow [--sha S] [--base B]`: resolves `S` (default HEAD) and `B` now, starts a detached copy of itself in a new session, and exits 0 at once, whatever happens. The copy:
  1. runs at `nice 10`, waits up to 95 min for the repo's build lock (a refresh may be building there), then up to 30 min for this machine's shadow lock, so a burst of pushes queues instead of running several suites beside the real gate;
  2. checks `S` out, with no hooks, at the repo's snapshot build path (one fixed path per repo, where snapshots are built, cleared first of anything a killed check left there), and hydrates it from the nearest-ancestor snapshot. With no snapshot it records `skipped` instead of cold-building, which would compete with the real gate for the machine;
  3. runs `chg check` there. The fixed path gives every shadow check of the repo the same workspace slot, so one test database of its own, reused run after run; the live tree is never read, because the real gate may be compiling and testing it at that moment;
  4. appends a `chg` row to `~/.chg/shadow/<repo>.jsonl` and removes the worktree.

  The detached copy works through the repo's shared git dir, not the pushing worktree, which may be removed before the check is done.

  Its output goes to `~/.chg/shadow/logs/<repo>-<sha12>.log` (kept 14 days). `CHG_HOME` moves `~/.chg`.

  `--foreground` runs the same check in this process instead and prints its verdict. `--replay` (with `--foreground`) marks the row `"source":"replay"`: a check of a past commit, not a push, which does not refresh `B`'s snapshot afterwards (see Replays).
- `chg shadow record --verdict pass|fail [--sha S] [--ms N] [--gate NAME] [--failures-file F] [--source local|ci]`: appends the authoritative gate's verdict for `S` as a `gate` row. `--source ci` (default `local`) marks a CI verdict recorded by hand, as a replay with enrollment overlaid does for its synthetic commit (see Replays); a CI row has no gate time, so `--ms` is refused with it, and stays out of the gate-time figures. `F` lists failing test ids, one per line; the report uses them to tell a missed test from a flake.
- `chg shadow report [--file F]... [--hosts a,b,c] [--ci-check NAME] [--json]`: pairs each push (one commit on one machine, however many `chg` runs judged it there; the extra runs are counted as reruns) with the gate's verdict for its commit, prints the disagreements and the cutover criteria, and exits 0 only when every criterion is met. `--hosts` reads each machine's log over ssh. `--ci-check NAME` fills in a commit no local gate judged from GitHub check runs named `NAME` on that commit: every completed run that passed or failed becomes a `gate` row, so a failed run and its passing rerun make the commit gate-flaky. A CI row has no gate time, since one check's duration is not the gate's: such a push shows `ci` in the gate-time column and stays out of the gate and saved figures, whose line says how many local gates they cover. A commit is asked about again until its newest CI verdict is 72 hours old. Gate-mode rows (`"source":"gate"`) are never paired: the report summarises them per host, and for all hosts together, as the check count, pass, fail and error, how many ran a subset, the median and p90 time, and the five most frequent reasons the whole suite ran (an `always_all` hit counts by its glob, not its path).

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
- at least 200 paired pushes, replays included;
- on at least 3 machines;
- zero MISS.

The report also prints the median `chg check` time (`ms`, the check without its hydrate) against the gate's. It is not a criterion: Mark dropped the 3-minute median on 2026-10-19. On HCB, about 40% of master commits change a path in `always_all` (migrations, config, `test/support`), so their checks run the whole suite and held the median near 4m45s, while the median gate took 10m41s.

## Replays

A replay judges a past commit the way a push would have been judged, and the report counts it like one: `pushes N (M replayed, K distinct commits)`. A push counts as replayed only when no push judged that commit on that machine. Mark allowed replays to count on 2026-10-19 so cutover need not wait for organic pushes. Master commits are nearly all green, so replays test agreement and chg-red more than they test MISS; live pushes keep testing both. One commit judged on three machines is three pushes and one commit, which is why the report prints both.

A check starts from a snapshot that is an ancestor of the commit, and a replay does not refresh its base (history no push starts from; one build per replay would also push the live bases out of GC's keep set). So build one snapshot of the oldest commit's parent first, then walk forward; each check hydrates from it and compiles the difference.

A commit that carries the repo's enrollment (`.chg/adapter.toml`, plus whatever the adapter needs, `elixirc_options: [check_cwd: false]` for Elixir) is replayed as committed, and its gate verdict is CI's check run on that commit, recorded by `--ci-check`:

```bash
# On each machine, in a clone whose origin is the repo, with its own slice of commits:
first=$(head -1 slice); chg snapshot build . "$first^1"
while read -r sha; do
  chg check --shadow --foreground --replay --sha "$sha" --base "$sha^1"
done < slice
# Once, anywhere: record CI's verdict for every commit no local gate judged.
chg shadow report --hosts <hosts> --ci-check Tests
```

A commit from before enrollment is replayed with the enrollment overlaid. In a clone of its own (the machine's working checkout stays untouched), build a chain of synthetic commits: synthetic `i` is original `i`'s tree with today's manifest and the adapter's needs added, parented on synthetic `i-1`, so each synthetic diff is the original diff. Snapshot the synthetic parent of the oldest commit, judge each synthetic commit against the one before it, and record the original's CI verdict for the synthetic sha by hand:

```bash
chg check --shadow --foreground --replay --sha "$synthetic" --base "$previous_synthetic"
chg shadow record --repo . --sha "$synthetic" --verdict pass --source ci --gate "Tests (CI on ${original:0:12})"
```

`--sha` is the synthetic commit, the one chg judged; the original is named only in `--gate`. GitHub has never seen a synthetic commit, so `--ci-check` would find nothing for it: a commit only replays judged is asked about until it has a CI verdict and never after, because a past commit's CI runs are finished. Record one row per CI conclusion, a failure and its passing rerun both, so the report sees gate-flaky as it would from `--ci-check`.

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
      # verdict; or, when chg had to check the live tree, that tree is not exactly
      # $GATE_SHA) blocks the push like a failure.
      [ "$status" -eq 3 ] && { run_the_existing_gate; status=$?; } ;;
  *)  run_the_existing_gate; status=$? ;;
esac
```

Rollback is `CHG_GATE=off git push` for one push, or `mode = "off"` in the policy for everyone. Neither needs a code change.
