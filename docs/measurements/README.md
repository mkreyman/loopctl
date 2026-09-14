# Delivery-gate measurements

Build order steps 2 and 3 of the agent delivery loop design (`mkreyman/loopctl-runner`,
`docs/agent-delivery-loop.md` §12) require Gate B's false-negative rate and Gate A's escalation
rate to be measured before step 7 — auto-merge — may run. Issue #828 is the tracking issue.

This directory holds the results. The harness that produced them is
`mix loopctl.gates.measure_b` and `mix loopctl.gates.measure_a`
(`lib/mix/tasks/loopctl.gates.measure_*.ex`), over
`Loopctl.DeliveryGates.Measurement.*`.

Neither task gates anything, changes any gate, or writes to the database. They replay the
SHIPPED gate code over history and count.

## The files

| file | what it is |
|---|---|
| `gate_b_<date>.json` | the machine-readable Gate B result: outcome counts, three strata with their rates, the false-negative rows |
| `gate_b_<date>.md` | the same run's human summary, including every bias |
| `gate_a_<date>.json` | the Gate A result: two strata, the sensitivity run, the escalated issue numbers |
| `gate_a_<date>.md` | that run's human summary |

Add a new dated pair per run rather than overwriting: the point of these is a TRACK RECORD, and
a rate with nothing to compare it against is one number.

**The INTERPRETATION of a run does not live here.** What the numbers mean, which false negatives
survived a hand review and which configuration defect caused them, names paths in a private
repository — see the redaction rule below. It goes in the run's pull request body and in a
knowledge-wiki article; the numbers here are what a later run compares against.

## Re-running

Gate B reads a git checkout READ-ONLY (`log`, `diff`, `ls-tree` — no fetch, no checkout), so it
is safe to point at a checkout somebody is working in. It does not fetch, so the window's upper
end is whatever that checkout's HEAD holds; the artifact records that sha.

```bash
mix loopctl.gates.measure_b \
  --repo /path/to/target/checkout \
  --repo-name owner/repo \
  --triggers /path/to/triggers.json \
  --out docs/measurements/gate_b_<date>.json \
  --summary docs/measurements/gate_b_<date>.md
```

Gate A takes a ticket corpus as a FILE, so the run is offline and repeatable. The one networked
step is deliberately outside the task:

```bash
gh issue list -R owner/repo --state all --limit 1000 \
  --json number,title,body,labels,state,stateReason,createdAt > tickets.json

mix loopctl.gates.measure_a \
  --tickets tickets.json \
  --corpus owner/repo \
  --out docs/measurements/gate_a_<date>.json \
  --summary docs/measurements/gate_a_<date>.md
```

### The trigger document is NOT in this repository

`--triggers` takes the Gate B trigger JSON, which is the live `DELIVERY_GATES_CONFIG` secret.
Design §13 keeps it in configuration rather than source because loopctl is public and the
document is a map of which paths skip human review. It is not committed here and the harness
never prints it. `deploy/FLY_SECRETS.md` documents the secret; the document itself lives with
the operator.

## What is redacted, and why the artifacts here are safe to publish

loopctl is public. The target repository measured to date is private. Two things therefore never
reach a committed artifact:

- **File paths.** Publishing `(files, verdict)` pairs for hundreds of changes RECONSTRUCTS the
  guard set — the map §13 keeps out of source. The cleared changes are the worst case: each one
  is a proof that none of its paths is guarded, which is a better attack map than the trigger
  list itself.
- **Pull request titles, issue titles, and matched trigger patterns.**

A redacted row keeps the pull request or issue NUMBER, the sha, the date, the diffstat, the file
COUNT and the oracle's families. Anyone who can judge "should a human have seen this?" can
already read the pull request, so the redaction costs a reader with access nothing.

Each task also writes an UNREDACTED artifact — paths, titles, matched patterns — to
`tmp/gate_measurement/` by default, which is gitignored. That is the file to read when
spot-checking; do not commit it to a public repository.

**One residual, stated rather than hidden:** `meta.trigger_fingerprint` is the first 12
characters of the document's SHA-256. It is there so two runs can say whether they measured the
same configuration, and it is a truncated commitment — somebody who can guess the document
byte-for-byte can confirm the guess against it. That was judged worth the comparability, given
that the document's schema is public and a reader with repository access can infer most of its
content anyway. `meta.trigger_shape` carries pattern COUNTS for the same purpose without being a
commitment at all.

## Reading a Gate B result

Three strata, and the one to read is usually not the first:

- **all readable** — every change in the window that could be read.
- **production files** — the subset touching at least one file outside `test/`, `docs/`,
  `.github/`, `priv/repo/` and `assets/`. A corpus stratification only: the oracle stays
  path-blind and this decides nothing about a verdict.
- **configuration applied** — the subset where every configured pattern matched a file at BOTH
  refs. The trigger document is TODAY's; replayed over a tree from before a guarded path
  existed, a pattern that matches nothing escalates as a stale trigger. That is the gate working
  as designed, on a question the replay invented, so a rate over the full window is dominated by
  a replay artifact. **This stratum is the honest corpus**, and it carries its own date range,
  which is not the run's window.

`false_negative_rate` is over the SCORED clears, never over all of them: a clear whose oracle
could not run is neither a false negative nor a true one.

## Reading a Gate A result

Two strata plus a sensitivity run:

- **intake** — the tickets Gate A is actually for: the ones the in-app chat filed with a
  `[Bug] <agency>: ` / `[Feature] <agency>: ` prefix. The headline, because that split was
  decided at FILING time and carries no hindsight.
- **all** — every issue in the repository, classified by label. Wider, and biased by labels
  applied after the outcome was known.
- **sensitivity** — the same corpus with `workflow_change_not_defect_fix` suppressed. Gate A's
  rate turns almost entirely on whether a feature request counts as a workflow change, so the
  result is a RANGE and the report says so rather than picking one end.

Every bias each harness carries is printed on the summary and stored on the artifact. Read the
rate with them or not at all.
