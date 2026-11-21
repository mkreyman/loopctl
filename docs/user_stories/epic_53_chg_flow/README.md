# Epic 53: loopctl adopts the chg flow

The request is mkreyman/loopctl#985 (Mark, 2026-10-16: "I would love loopctl and claude-config to
be transitioned to the new flow as well!"); delivery-loop triage escalated it as too large, and
this epic is the split. The design is chg's own: `chg/docs/design.md` §3.7-§3.8 and S8
(`design.md:167-185`, `:417-422`), the commands in `chg/docs/verify.md` and the gate switch in
`chg/docs/shadow.md`. Epic 47's PRD assigns post-merge verification, `verified/master`, bisect
and revert to chg (`docs/user_stories/epic_47_change_protocol/PRD.md:56`). So this epic
ADOPTS chg's commands in loopctl's own CI and hooks; it rebuilds none of them. This file fixes
the story order, the names every story shares, what "done" means and which test layer proves
what. Stories are numbered in build order.

Already in place, cited and not re-specified: `.chg/adapter.toml` (the Elixir adapter manifest,
`always_all` at `:396-420`); the chg shadow check in `.githooks/pre-push` (`:83-94`, `:215-251`);
merging the base only on a textual conflict (`CLAUDE.md:491-530`); ci.yml's master
concurrency, which already keeps one pending master run and never cancels a started one
(`.github/workflows/ci.yml:42-49`); and `factory-release.yml`, the repo's one `workflow_run`
consumer of CI on master today (`factory-release.yml:14-30`). home_care_billing did the same
move first (mkreyman/home_care_billing#2472) with its own Elixir script in place of `chg
verify`; its workflow is prior art for the token rules below (HCB
`.github/workflows/verify-master.yml:63`, `:516-517`).

## Stories, in build order

| # | story | depends on |
|---|---|---|
| 53.1 | Verify master: advance `verified/master` forward-only from each green master CI run | — |
| 53.2 | Deploy only `verified/master`, from its own workflow | 53.1 |
| 53.3 | Red master: `chg culprit`, `chg revert` armed to auto-merge with a reland issue, and `chg flaky` | 53.1 |
| 53.4 | Branch CI runs only what the diff can affect; journeys, retrieval eval and scale tests by area | — |
| 53.5 | The commit hook checks format and compile only; CI takes over what `mix precommit` drops | — |
| 53.6 | Cut the push gate over from shadow to `chg check` once S10 holds; `CHG_GATE=off` runs `mix precommit` | 53.5 |
| 53.7 | The week's measurement: PR CI median, catch-up merges, deploy provenance, red time, reverts | 53.2, 53.3, 53.4 |

Each story's `dependencies` field is the authority; this table mirrors it. A dependency is a
story whose code this one calls; 53.6 also waits on 53.5 because its evidence filter is written
for the state 53.5 leaves (no local full-gate verdict on a live push). Nothing waits on another
epic's unmerged code. Epic 52 release 9 (US-52.56-52.59, unbuilt on 2026-11-20: no
`US-52.5[6-9]` commit on master, no `epic/*` branch on origin) also edits `ci.yml`; see Hub
files.

**Merge order** (safety, not code). Two stories may be BUILT at any time but MERGE only after
others are live on master, and each says so in its `definition_of_done`:

- 53.4 merges after 53.3: a branch CI that runs a subset is safe only once a miss on master is
  found and reverted automatically.
- 53.5 merges after 53.1-53.4: #985 allows the fast commit hook only once the verifier, the
  verified-only deploy, the red-master hunt and selective branch CI all hold.

**Releases.** Every story is its own release, because each one changes what master or
production does and the next is judged against it running (53.2 cannot be shown working until
53.1 has advanced `verified/master` on master). A release is built on its own epic branch,
`epic/chg-flow-<n>` for US-53.<n>, cut from master, and reaches master through that branch's
one epic PR (the staging flow, `~/workspace/claude-config/docs/harness/staging-flow.md`). A
session holds one such release open at a time, and the repo at most three.

**Hub files**:

| hub file | owner story | other stories that edit it |
|---|---|---|
| `.github/workflows/ci.yml` | 53.2 (removes `deploy`, `smoke`) | 53.4 (Test job, areas), 53.5 (Lint steps); Epic 52 US-52.58 owns it in its own release 9 |
| `test/loopctl/factory_ci_workflows_test.exs` | 53.2 | 53.4 |
| `test/loopctl/verify_master_workflow_test.exs` | 53.1 (creates it) | 53.3 |
| `docs/runbooks/chg-flow.md` | 53.1 (creates it) | every later story adds its section |
| `CHANGELOG.md` | 53.2 | 53.6 |
| `.github/scripts/areas-output.sh` | 53.4 | none (Epic 52 may read it) |

## Lanes

From `scripts/lane_plan.py <this folder>`: 4 lanes reach the critical path (53.1, 53.3,
53.7); a fifth shortens nothing. Serial 2.14M tokens, 4 lanes 0.87M, 3 lanes 0.88M. Three lanes
lose almost nothing, so run three if a fourth machine is busy (lane B's 53.4 then goes first on
lane C).

| lane | stories, in order | waits on another lane for |
|---|---|---|
| A: trunk and deploy | 53.1, 53.2 | — |
| B: branch CI | 53.4 | merge only: 53.3 (Merge order) |
| C: hooks | 53.5, 53.6 | merge only: 53.5 after 53.1-53.4 (Merge order) |
| D: red master and report | 53.3, 53.7 | 53.3 on 53.1; 53.7 on 53.2, 53.4 |

The waits that cost time: lane D waits about 0.22M for 53.1 to merge before 53.3 can start;
it reads chg's `culprit`/`revert` code paths and drafts the hunt's stub tests meanwhile.
Lanes B and C finish building before they may merge and hold a green, reviewed PR until the
Merge order allows it; CLAUDE.md's Merging rule 1 means such a PR merges as it is when master
moved under it, unless it conflicts. Lane A owns the watch on Epic 52 release 9 (US-52.58 edits
`ci.yml`'s Test job, which 53.4 also edits); lane B owns resolving that conflict if 52.58 lands
first.

How the lanes share master (each story is its own release branch, so no two lanes share one):

1. A story starts only when every story in its `dependencies` is merged to master, and
   merges only when its Merge order holds (`git fetch origin`, then `git log --oneline
   origin/master | grep -F "US-53.<n>: "`; the colon keeps US-53.1 from matching US-53.12).
2. Cut the story's `epic/chg-flow-<n>` branch from master as it is now (`CLAUDE.md`, Merging
   rule 3). A hub-file
   conflict keeps both sides' additions; resolve it by merging master INTO the branch, never a
   rebase (`CLAUDE.md:523-525`).
3. After each merge, post the story id and the merge SHA on the loopctl channel under key
   `lane:loopctl:epic53-<lane>`; a waiting lane reads that slot instead of polling git.
4. A red master run after a story's merge is that story's to fix at once; from 53.3 on, the
   hunt job may already have opened its revert.

## Names every story uses

| thing | name |
|---|---|
| trunk verifier workflow | `.github/workflows/verify-master.yml`, `name: Verify master`, job `advance` (53.1), job `hunt` (53.3) |
| its scripts | `.github/scripts/verify-master-advance.sh` (53.1), `.github/scripts/verify-master-hunt.sh` (53.3) |
| verified ref | `refs/heads/verified/master`, pushed only by `chg verify`, forward only |
| deploy workflow | `.github/workflows/deploy.yml`, `name: Deploy`, jobs `deploy` and `smoke` (53.2), script `.github/scripts/deploy-verified.sh` |
| Fly image label | `verified-<40-hex sha>` (53.2) |
| GitHub deployment environment | `production`, the name post-deploy verification reads (`lib/loopctl/delivery/post_deploy_verification.ex:189`) |
| labels | `auto-revert`, `reland`, `flaky` (chg's defaults, `chg/cli/src/main.rs:253,277,279`), `master-red` (53.3) |
| revert credential | repository secret `CHG_REVERT_TOKEN` (53.3; does not exist yet, owner question) |
| branch CI suite areas | `.github/scripts/suite-areas.sh <base> <head>` printing `retrieval` / `scale`; changes-job outputs `retrieval`, `scale` (53.4) |
| branch CI test selection | `.github/scripts/select-tests.sh`, writing `$RUNNER_TEMP/selection.json` (53.4) |
| commit gate switch | `LOOPCTL_COMMIT_GATE=fast|full` in the environment, default `fast` (53.5) |
| push gate policy | `.chg/policy.toml` `[gate] mode` (53.6; does not exist yet) |
| cutover evidence | `scripts/chg/cutover-evidence.sh` and `scripts/chg/replay-master.sh` (53.6) |
| measurement | `mix loopctl.chg_flow.report`, `Loopctl.ChgFlow.Report`, inputs from `scripts/chg/flow-inputs.sh` (53.7), artifacts `docs/measurements/chg_flow_<date>.{json,md}` |
| runbook | `docs/runbooks/chg-flow.md` (53.1) |
| guard tests | `test/loopctl/verify_master_workflow_test.exs` (53.1, 53.3), `test/loopctl/deploy_workflow_test.exs` (53.2), `test/loopctl/branch_ci_selection_test.exs` (53.4), `test/loopctl/githooks_fast_commit_test.exs` (53.5) |

## Failure design

1. **Partition.** The work spans GitHub (refs, runs, issues, PRs), the fleet-ci runner pool
   (beelink, minis, x1), GitHub-hosted runners (deploy, which holds the Fly token by design,
   `ci.yml:83-92`) and Fly. A runner that cannot reach GitHub cannot push `verified/master`:
   `chg verify` exits 2 (no verdict) and the ref stays, which only delays deploy. Fly
   unreachable fails the deploy job; the ref is unchanged and the next deploy run (a later
   verify, or a manual dispatch) reads it again. Nothing in this epic writes loopctl's database.
2. **State.** `verified/master` lives on GitHub and moves forward only, by a non-forced push
   that GitHub refuses unless it fast-forwards (`verify.md:10`). What production runs is the
   Fly image label; the GitHub deployment record carries the same sha for post-deploy
   verification. Reverts, reland issues and flaky issues live on GitHub, each carrying chg's
   culprit or test marker (`verify.md:42-43`). Shadow verdicts live per host in
   `~/.chg/shadow/loopctl.jsonl`. No workflow keeps state in a runner's workspace.
3. **Retry.** `chg verify` is idempotent (`already`, `superseded`); `chg revert` is idempotent
   on the culprit (`auto-revert/<sha12>` plus markers, under a revert lock); `chg flaky` keeps
   one issue per test; a deploy whose sha is already the running image label does nothing.
   A re-run of any of these workflows therefore repeats nothing.
4. **Slow.** Every job has `timeout-minutes`; `chg verify` caps the suite at
   `--tests-timeout-secs` (default 2700, `verify.md:9`); every `gh` and `flyctl` call in the
   scripts runs under `timeout`. A slow verifier queues behind ci.yml's master concurrency:
   one pending run, replaced by a newer tip, a started one never cancelled.
5. **Reach.** Verify and hunt jobs run on any fleet-ci slot; deploy runs on ubuntu-latest.
   Nothing addresses a host: every job is found as a workflow run of its sha, every artifact
   by its ref, label or marker.

## User journey

The user is an implementing session (and Mark reading what it reports). No screen.

1. **Start and end.** A session holds a green branch; it ends holding a merged PR, a
   `verified/master` that contains it, and a deploy of that sha, or a revert PR and a reland
   issue that name its failing tests.
2. **Old way vs new way.** Today ci.yml's `deploy` job ships every green master push
   (`ci.yml:1705-1729`); 53.2 removes it, so `Deploy` (deploy.yml) is the one way production
   changes. Today the commit hook runs `mix precommit`; after 53.5 it runs format and compile,
   and `LOOPCTL_COMMIT_GATE=full` restores the old hook per commit.
3. **Inputs mapped to the source.** CI conclusions come from the CI workflow run of the sha;
   failing tests from `chg verify --failures-out`; the culprit from `chg culprit`.
4. **Precision.** Durations in seconds; medians over the runs a report names.
5. **Next step.** A reland issue names the tests to fix; a `master-red` issue says what failed
   and that a person decides.
6. **Their words.** Issue titles and job summaries use chg's terms: verified, held,
   superseded, culprit, flaky, reland.
7. **Numbers side by side.** 53.7's report shows each metric beside its target.
8. **Warnings they can act on.** Every `::warning::` or `::error::` these workflows print names
   the next action (the missing secret, the command to run).
9. **Phone width.** n/a: no screen.

**API parity.** No screen action and no new `/api/v1` endpoint, so no MCP tool is owed
(`CLAUDE.md`, "An operator-facing endpoint is NOT DONE until an MCP tool calls it").

## Design coverage

No screen.

## What "done" means, for every story

1. Every acceptance criterion is named by a test case's `verifies`, and that test passes.
2. Every new test file is `use ExUnit.Case, async: true` (or DataCase/ConnCase), never calls
   `Application.put_env`, and takes paths, binaries and environment as inputs (CLAUDE.md,
   Dependency Injection). A script under test runs with stub `chg`, `gh`, `git` remote and
   `flyctl` binaries on a PATH the test builds in its own `tmp_dir`, as
   `test/loopctl/githooks_pre_commit_routing_test.exs:6` does.
3. A workflow change is pinned by a YAML guard test that parses the file with YamlElixir, as
   `test/loopctl/factory_ci_workflows_test.exs:326-327` does; a guard that matches nothing
   fails (assert the matched set is non-empty).
4. Every new guard is mutation-checked once: delete what it guards, watch it fail, and say so
   in the PR body.
5. No story adds a context module or a table, so no tenant-isolation case applies; a story
   that finds it must add one stops and says so.
6. A changed operator-facing behaviour (deploy ordering, a new secret, a hook switch) is in
   `CHANGELOG.md` and in `docs/runbooks/chg-flow.md`; a new env var read by `config/runtime.exs`
   or `lib/**` gets its `deploy/FLY_SECRETS.md` row (none is planned).
7. No inventory counts in any doc (CLAUDE.md, Doc hygiene).
8. Workflow and hook paths are `human_paths` for chg's sweep (Epic 51 README:62): these PRs are
   reviewed and merged by the session, never by an automated sweep.

## Which layer proves what

| what | layer |
|---|---|
| a workflow's triggers, needs, conditions, concurrency, permissions | unit: YAML guard test |
| a script's decisions (which chg command, which exit path, which issue) | integration: the script run against stub binaries in `tmp_dir` |
| pure report arithmetic (53.7) | unit |
| that it works on GitHub and Fly | definition of done: `gh run view` / `gh api` evidence named in the PR body |
| external services | stubs, never the network |
