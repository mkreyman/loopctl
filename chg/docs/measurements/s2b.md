# S2b measurement: xref and coverage selection replayed over 200 HCB PRs

Measured 2026-10-16/17, on the 200 most recent merged home_care_billing PRs
(2026-09-29 `2191c698` through 2026-10-16 `3b2fcddf`). Suite: 1619 test files,
full-suite wall 1959.9 s on nuc (`max_cases: 8`), per-file ms from the traced
record (sum 14 024 001 ms). Raw rows: `per_pr.csv` (xref) and `coverage.csv`
(coverage) alongside this file; the scripts are `scripts/s2b/graph_replay.exs`
and `scripts/s2b/coverage_replay.exs`.

Replay approximations (deliberate, from the script header): the coverage map is
HEAD's, the record is at each PR's parent (0 commits behind), and test files and
paths are HEAD's.

## Verdict against issue #24's done-when

- Median selected time at most 25% of the full suite: **not met.** xref median is
  98.4% of suite time; coverage median is 100% as measured.
- Sharded wall at most 3 min: **not met.** Time-balanced (LPT) sharding of the
  *full suite alone* is 490.0 s at 4 shards and 245.0 s at 8 shards on nuc
  timings, so even perfect sharding of everything misses 3 min; selection has to
  do most of the work.
- The issue's median rule ("if the median is already below ~30%, the single-file
  case was unrepresentative; stop"): the xref median is 98.4%, so the dense
  single-file measurement was representative and the coverage half was correct
  to attempt. It cannot be closed as working and cannot be closed as
  unrepresentative: the coverage replay is **blocked on digest instability**
  (below). It stays open, on a new digest-normalization story.

## xref selection (baseline, graph_replay.exs)

Distribution over all 200 PRs (fractions of 1619 files / 14 024 001 ms):

| metric | p10 | p25 | p50 | p75 | p90 |
|---|---|---|---|---|---|
| files fraction | 0.002 | 0.900 | 0.901 | 1.000 | 1.000 |
| time fraction | 0.013 | 0.984 | 0.984 | 1.000 | 1.000 |
| est. seconds | 4.2 | 1929.1 | 1929.1 | 1959.9 | 1959.9 |
| est. 4-shard s | 3.7 | 482.3 | 482.3 | 490.0 | 490.0 |
| est. 8-shard s | 3.7 | 241.1 | 241.1 | 245.0 | 245.0 |

88 of 200 PRs select everything up front (always_all): 38 migrations, 24
config, 21 test/support, 4 mix.exs, 1 .tool-versions. The 112 that reach the
graph selector still select a median of 90.1% of files and 98.4% of time — the
compile graph is dense in practice, not just in the single-file case.

## Coverage selection (coverage_replay.exs)

| metric | p10 | p25 | p50 | p75 | p90 |
|---|---|---|---|---|---|
| files fraction | 0.002 | 0.999 | 1.000 | 1.000 | 1.000 |
| time fraction | 0.013 | 1.000 | 1.000 | 1.000 | 1.000 |
| altered modules (subset PRs) | 0 | 192 | 212 | 255 | 279 |

112 PRs passed the always_all check and ran `ChgAdapter.Select.by_coverage`:
95 returned a subset verdict and 17 failed closed to select-all (14 new
`Jason.Encoder` implementations, 2 test-data changes, 1 altered module in the
record's global set). The 95 subset outcomes are bimodal: 21 PRs with zero
altered modules (docs, scripts, CI and spec changes; 11 of them flagged
docs_only in the xref replay) select 0-3 files — 14 select none, and the rest
select only the change's own test files. The 74 code PRs select a median of
1617 of 1619 files. Only 2 code PRs selected ≤25% of suite time — the only two
with exactly 1 altered module (`4babacfb37`: 31 files, 17.9% of time;
`2ad8ae29d2`: 32 files, 14.2%). In those two the selector did exactly what it
was built to do; everywhere else it degenerated.

## Root cause: digest v3 is not stable across compilations

The selection is only as good as the "altered modules" set, which is the
digest-diff of the PR against its parent. The digest was verified deterministic
as a *function* (same beam in, same digest out, across machines, PR #29) but not
across *compilations*:

- Same commit compiled twice (`mix compile --force`, same machine, same
  toolchain): **266 of 2408 modules (11.0%) change digest.**
- Same commit compiled on nuc and on mac-mini: **288 of 1560 modules (18.5%)
  change digest.**
- Across the 200 replays, 164 PRs "alter" the same fixed set of LiveView
  modules (DashboardLive, HomeLive, PlanOfCareFormLive, ...). No real history
  looks like that.

Chunk-level forensics on one flapping module (`HealthCheckLogLive`, identical
source, two compiles): AtU8/StrT/ImpT/ExpT/LitT identical; Code, FunT, Attr,
Dbgi differ. Inside Code, the differences are exactly two volatile constructs:

1. `Phoenix.LiveView.Rendered` **`fingerprint` literals** (2 sites here).
   Phoenix computes the fingerprint at compile time
   (`engine.ex: md5(term_to_binary([block | static]))`); the template AST that
   feeds it is not stable across compilations, so the literal flips.
2. `make_fun3` **embedded fun-uniq operands** (26 sites here). Digest v3 strips
   `old_uniq` from the FunT table but the same value is also an immediate in
   the Code chunk, and it flips per compilation. (Attr `vsn` and part of Dbgi
   differ downstream of these.)

Two compounding facts make the flap dominate the replay:

- HCB's compile graph is dense at the *byte* level too: checking out the
  overtime PR (`7101445e`, 2 changed files) after its parent rewrote **429**
  app beams. That is Mix's own incremental cascade — the same density that made
  `mix test --stale` select 90% in S2's original measurement.
- The rewrite set is exactly the flap-prone population (macro- and
  Heex-coupled modules): of the 429 rewritten beams, 217 changed digest. A
  typical PR therefore reports ~200 "altered" modules scattered across the app,
  and the tests covering at least one of them are ~all 1619 files. The reported
  altered count is the noise floor, not the change.

With a stable digest the same PR (a function-body fix, no interface change)
would report ~1 altered module and select ~30 files, like `4babacfb37` and
`2ad8ae29d2` did when the flap happened not to fire. The selector is not the
problem; the digest is.

## Follow-up: digest v4

Done in the adapter as digest form 4 (chg#78, chg#31). The two constructs above
were only part of it: OTP 26+ orders a map's atom keys by atom index, so code a
macro generates from a map differs between builds too. `mix chg.compile` now
starts every compiling VM with the project's atoms made in sorted order
(`ChgAdapter.Atoms`), and the digest canonicalises labels, generated function
names, map instruction pairs and LiveView fingerprints, and leaves out
`__mix_recompile__?/0`. Two clean builds of HCB 52a7d2088b at two paths on
minis: 6 of 2849 modules differ (v3: 467 of 2995 at e2b7741e). The 6 are maps
of more than 32 keys, which OTP orders by a hash that differs from one VM run to
the next: the same 40 standard atoms in one map give two key orders in two
identical `elixir` runs, and preloading the atoms from a boot script, before the
kernel starts, left the same 6 differing.

## Follow-up: deterministic boot

The 6 were not a per-run hash. They were the atoms the VM makes while booting,
made in a different order on every multi-scheduler boot. The compiling VM now
boots on one scheduler of each kind (`+S N:1 +SDcpu N:1 +SDio 1`), and
`ChgAdapter.Atoms.preload` brings the schedulers back before compiling (chg#90).
Two clean builds now give one digest on all 9 bases of an 11-PR HCB replay on
minis (2026-10-29), with HCB's compile-time random `CLOAK_KEY` fixed; clean
compiles take ~1 s longer (72.5 s against 71.5 s median).

## The digest walk itself

204 of 204 commits digested (`/tmp/chg-digests` on mac-mini, ~35 s/commit
including deps). The first walk's log shows 199 `OK` lines and 0 failures for
204 shas: the run's first five iterations' output was lost, and because
`walk.sh` never checks dig.exs's exit status (it echoes `OK` after compile
success regardless), four of those five — the four newest commits `3b2fcddf`,
`6c836aa2`, `c98e11df`, `19b2fb6e` — had no etf either; the fifth (`61aa6ebe`)
wrote its etf but its log line was lost with the rest. All four missing commits
compiled and digested cleanly on the re-run (3-70 s each); **no commit was
skipped** as uncompilable, and the replay had digests for every PR and every
parent.
