# Gate B trigger drift

Design §5 says Gate B's path set is "read literally off the repo and asserted by a test that
fails when one stops existing". This is that assertion.

A configured pattern that matches nothing in the target repository has stopped guarding the path
it names — most often because the path was renamed. `Loopctl.DeliveryGates.GateB` already
escalates on it at runtime, as `{:stale_trigger, pattern}`; that is fail-closed but it announces
itself as one more escalation among many, and the first Gate B measurement (#828, PR #830) found
712 of 830 replayed changes escalating that way with nobody having noticed. Checked ahead of
time it is what it actually is: a configuration alarm.

`Loopctl.DeliveryGates.TriggerDrift` is the check, extracted from `GateB`'s own private
stale-trigger logic rather than written beside it. A drift checker that can disagree with the
gate is worse than none — it would clear a configuration the gate escalates on, or the reverse.

## Running it

```bash
mix loopctl.gates.check_drift \
  --repo /path/to/target/checkout \
  --repo-name owner/repo \
  --triggers /path/to/triggers.json
```

It reads the checkout READ-ONLY (`rev-parse` and `ls-tree` only — no fetch, no checkout), writes
nothing to the database, changes no gate, and exits non-zero on any unmatched pattern.

`--triggers` takes the live `DELIVERY_GATES_CONFIG` document, which is NOT in this repository:
design §13 keeps it in configuration because loopctl is public and the document is a map of
which paths skip human review.

## Where the assertion actually runs, and the bound on that

Both of its inputs are deliberately unavailable in loopctl's own CI. The target repository is
private and the trigger document is a secret, so `test/loopctl/delivery_gates/trigger_drift_live_test.exs`
runs in whichever of two modes its inputs allow:

| mode | when | what it asserts |
|---|---|---|
| live | `LOOPCTL_TRIGGER_DRIFT_REPO`, `LOOPCTL_TRIGGER_DRIFT_DOCUMENT` and `LOOPCTL_TRIGGER_DRIFT_REPO_NAME` are set | reads the tree, runs the same checker the gate runs, fails on any unmatched pattern |
| artifact | none of them is set | `trigger_drift.json` is present, well-formed, redacted, and reports zero unmatched patterns |

Half-configured is a failure, not a fall-back: one variable set and the others absent means
somebody meant to run the real assertion and it silently did not. So is an unreadable tree, an
empty file list, and a document that does not parse — a checker that cannot read the tree has
proved nothing, and "no patterns drifted" over no files is a vacuous pass.

These three variables are read only by that test. They are not application configuration and do
not belong in `deploy/FLY_SECRETS.md`.

**The bound, stated rather than left to be discovered:** artifact mode cannot see a rename that
happened after the artifact was written. It makes a committed drifted artifact red and a missing
one red; it does not make a STALE one red, because a staleness deadline would fail builds on
quiet weeks for a reason unrelated to drift. Closing that gap needs the check to run where the
tree is — the target repository's own CI, or a scheduled check reading the tree through the
GitHub API. Both are named as follow-on work in the pull request that added this.

## The artifact

`trigger_drift.json` carries, per pattern: its kind, its configuration index, and whether it
matched anything. A BOOLEAN, not the match count — the assertion needs only "at least one", and
a count would publish how broadly each guard reaches for no gain. The unredacted artifact
(`tmp/gate_measurement/trigger_drift.full.json`, gitignored) carries the patterns and the counts.

`meta.trigger_fingerprint` is the first 12 characters of the document's SHA-256, the same
truncated commitment the measurement artifacts use and for the same reason: two runs can say
whether they checked the same configuration, and a reader who can guess the document
byte-for-byte can confirm the guess. Regenerate the artifact whenever the document changes, so
the fingerprint on it names the configuration that is live.
