# chg: a change system for an agent fleet

Design, 2026-10-16; revised 2026-11-18. Phase 1 and the outbox to loopctl are built; sections 3-6 describe phases 2-3 as designed. Sources are in `notes.md` next to this file.

## 0. The answer

Build Scion's *coordination* model on git storage. Do not build Scion's *storage*.

Anthropic replaced git because of data volume: almost 100 GB of history, 25 million checkouts a day, and 600 PB a day of naive fetch traffic. We have none of that. HCB's whole working tree, deps and `_build` included, is about 1.5 GB, and fleet-holding is smaller. Volume is not what sinks a fleet at 10-100x; waiting is. The measured costs are a 9-minute gate that CI then runs again, catch-up merges done so a base-bound attestation stays valid, a cold `deps.get + compile` for every worktree, and a review that starts from 94k tokens of harness. Each of those has a Scion-shaped fix that needs no new VCS:

| Scion idea | What we take | What we leave |
|---|---|---|
| Server does commit, merge and rebase; nothing to push | Server-side landing with `git merge-tree --write-tree` + `commit-tree` + a fast-forward-only push (a compare-and-swap on one ref) | Scion's changeset log, Spanner, blob store |
| No global merge-queue lock; post-merge and pre-deploy testing | Pre-merge runs affected checks on the change's own base. Post-merge verifies trunk in batches, bisects and auto-reverts. Deploy takes only verified revisions | Anthropic's open question "what does CI mean"; we answer it below |
| Claude fixes conflicts | A conflict-resolver job on the runner pool | — |
| Antique: semantic approval rules, humans review intent | Server-dispatched review with a lean payload, plus policy classes (comment/doc/test-only auto-approve; sensitive paths always reviewed) | A new review UI; GitHub's UI stays the place to browse |
| scion-daemon per node, snapshot start, >99% cache hit | `chgd` per machine: a warm snapshot per verified trunk revision, cloned copy-on-write into a workspace in seconds | Virtualized FS (EdenFS-style); our repos are too small to need it |
| Source control as an API (bisect/revert pipelines) | Every operation is a CLI verb; bisect and revert are pool jobs | — |
| Superfan agents per component | One watcher agent per component (lander, verifier, pool), from phase 3 | — |

The stack: a Rust client (`chg` CLI plus the `chgd` node daemon) on every fleet machine, per-language adapters behind one contract (Elixir and TypeScript ship together), and **loopctl** as the place the record lives: the ledger, each change's event log, review custody and the dashboard (loopctl Epic 50). There is no chg control-plane app. Coordination that must not wait on a web service (landing, job leases) is a compare-and-swap on a git ref on GitHub, which every machine can reach and which already is the authority for trunk. GitHub stays the durable store for refs and objects, and the place to browse. It stops being the workflow: no PRs and no Actions in the gate path from phase 2.

## 1. What the Scion article says, and what it leaves out

**Said** (https://www.anthropic.com/engineering/redesigning-source-control):
- Load: merges went from about 2,500/day (May 2026) to over 30,000/day (September). Main history is almost 100 GB; a compressed working copy is over 25 GB; CI makes about 25M checkouts a day; naive fetching would be over 600 PB/day. Before Scion they ran several hundred git mirrors; seeds drifted from main, and diff/blame on partial clones degraded.
- Principles: clients are always online. The server does history, blame, commits, merges and rebases. The client keeps a bounded object cache, lays out files and watches the FS. Everything is an API, so many jobs need no local repo. It scales horizontally with no full copy anywhere and no packfiles. Commits are lock-free and cost scales with change size. Refs are discouraged except main and release, and moving a ref is a CAS on one Spanner row. Checkouts are sparse or virtualized.
- Data model: a changeset is a write-ahead-log entry listing the files changed relative to its first parent, with content-addressed pointers into blob storage. It is created server-side and visible everywhere at once. Derived data (blame, path history, commit-graph skip lists, copy detection, path search) is defined recursively from parents and computed eagerly or lazily.
- Serving: scion-servers on Spanner plus cloud storage. The client negotiates top-down for only the trees and blobs it wants; every request is for an immutable object; fetches are resumable. Tiers: scion-daemon (one per node, shared by every job there, starts from a periodically refreshed snapshot), then a regional scion-cache, then a server. All tiers have the same RPCs and strict tiering for failure isolation. Hit rate is over 99% per tier.
- Results: about 200x less CPU and memory than the git mirrors; CI checkouts went from minutes to seconds; a 25% CI CPU capacity win; no repo maintenance.
- Merge: *"A proper merge queue … doesn't make much sense at agent scale."* *"We haven't been able to effectively replicate the industry standard of a global repository lock on the merge queue, so instead, we've invested in post-merge and pre-deploy automated testing."* Concurrent changes can conflict; *"Claude can typically fix these conflicts faster than humans can even identify them."* A CI job can ask the server for the diff to its merge base without a checkout.
- Antique (code review): approval rules *"can express complex semantic constraints"* (comment-only versus sensitive logic). Humans *"examine the intent of the change as opposed to reading every line."*
- Migration: five months and seven people, while merges grew 10x. Scion first served only metadata queries for CI and tools, then contents and checkouts. Claude rewrote the git-to-Scion ingestion pipeline with 20x less memory, running 4x faster. Testing used hermetic simulations, fuzzing and rate limiting. Superfan Claude agents watch the daemon, the cache and the merge queue, alongside traditional alerts. Directory-level IAM.

**Not said**, which this design has to decide for itself:
- How an agent's edits reach the server (no client verbs are described) and whether a local commit exists.
- What runs pre-merge, if anything, and how affected tests are chosen.
- How long trunk can stay red, what is blocked while it is, how batches are formed, and how bisect and revert decide.
- Flaky tests.
- Deploy gating beyond the words "pre-deploy testing".
- Whether git or GitHub stayed as a mirror.
- Change ids, stacked changes, amend and evolve.
- Cost.
- How the conflict resolver is triggered or verified.
- Review latency.

## 2. Our waits, and the mechanism behind each

Baseline (HCB 2026-10-02..16, numbers as given, not re-measured):

| Measured | Mechanism that produces it | Removed by |
|---|---|---|
| 72% of PR lifetime is before the PR opens | Implementation plus a 9-minute full local gate (`.githooks/pre-push` runs `mix precommit`), repeated per push | Affected-only gate on a warm workspace (phase 1) |
| Local gate duplicated by CI; 64% full re-runs | `attest` in HCB `ci.yml` refuses any head with `behind_by > 0`. Once the base moves (always, at 30-120/day), the attestation is void and CI runs everything | The verdict is keyed to *change vs its merge base*, and full-suite truth moves to post-merge (phase 1) |
| 51% of PRs did catch-up base merges; only 6 of 449 were real conflicts | The same rule tells agents to "merge the base locally" to stay attested | Never require a current base; the lander merges in memory, and only conflicts need work (phase 1 policy, phase 2 mechanism) |
| CI wait 6.9 agent-hours/day; job queue median 20s | Every PR runs GitHub Actions on one host (beelink) after the gate already ran | No suite runs in PR CI (phase 1); a pull-based pool across every machine (phase 3) |
| `/code-review` round median 226s, 88% model time, 94k-token start, one tool call per turn | The review runs inside the harness context, after CI, sequentially | A pool-dispatched reviewer with a ~15k payload, running concurrently with checks (phase 2) |
| Every new worktree pays full `deps.get` + compile | Worktrees start empty | A warm snapshot per verified revision, cloned copy-on-write (phase 1) |

What 10-100x means: fleet-holding goes from 120 to 1,200-12,000 landings/day and HCB from 30 to 300-3,000, with a default of 20-50 concurrent agents. 12,000/day averages 0.14 landings/s, with peaks near 1/s. One ref CAS of about 1 s against GitHub, batched, handles that with about 10x headroom (section 3.6).

## 3. Target system

### 3.1 Components

```
 agent session (any machine)
 ┌──────────────────────────┐  git push (ff-only = CAS): revisions, event chains, trunk, leases
 │ chg CLI (Rust)           │──────────────────────────────────────────────┐
 │ workspace = CoW clone    │                                              ▼
 └──────────▲───────────────┘                         GitHub: durable refs + objects, browsing,
            │ unix socket                                     refs/chg/<id>/{<n>,events}, deploy trigger
 ┌──────────┴───────────────┐  git fetch / push (CAS)          ▲
 │ chgd (Rust), one per box │──────────────────────────────────┘
 │ bare mirror, snapshots,  │
 │ lander, verifier, job    │  outbox: signed HTTPS, off the push path
 │ executor, verdicts,      │─────────────────────────────▶ loopctl (Epic 47 + 50): ledger rows, change
 │ outbox                   │  review_dispatch (US-50.3)    events applied in seq order, story binding,
 └──────────────────────────┘◀───────────────────────────── review custody, dashboard, MCP read tool
```

loopctl receives and never calls: an outage there costs freshness of the record and new review keys, never a push, a landing or a check.

### 3.2 Unit of change

A **change** is a stable identity: a client-generated ULID, written as a `Change-Id:` trailer, the same idea as Gerrit and jj change ids. A change has an ordered list of **revisions**. Each revision is a single git commit whose parent is the change's base (a verified trunk revision), pushed by the client to a hidden ref, `refs/chg/<change-id>/<n>`, on GitHub. Hidden refs are not branches: nothing lists them, nothing protects them, and nobody deletes them by hand.

- Change: `id, repo, trunk, author_session, story_id (optional), intent (text: what and why), depends_on[] (stacks), state, policy_class`.
- Revision: `change_id, n, base_sha, commit_sha, tree_sha, input_fingerprint`. Unique on `(change_id, n)` and on `(change_id, tree_sha)`, so re-submitting identical content is a no-op.
- Events: an append-only per-change log (`submitted, check_passed, review_findings, conflict, landed, verified, reverted, …`). This is jj's operation log at change granularity. It is the agent's inbox and the audit trail. It lives as a commit chain at `refs/chg/<change-id>/events`, one commit per event holding the exact JSON loopctl receives, so `event_seq` is allocated by a fast-forward push and is gap-free across machines (`chg event emit`, docs/outbox.md). loopctl applies the same events in seq order and holds any that arrive ahead of a gap.
- Landing writes **one** first-parent commit on trunk per change (a squash of the change's latest revision onto the current tip). Trunk history stays linear; the revision history lives in `refs/chg/*` and the event log.
- Stacks: a change with `depends_on` lands only after its parents. Its revisions are replayed by the lander with `git replay` on its bare mirror when a parent changes, which never touches a workspace.

### 3.3 Where state lives

| State | Home | Authority | Rebuildable from |
|---|---|---|---|
| Trunk tip (`refs/heads/master`) | GitHub | **GitHub** (the ff-only push is the CAS) | — |
| Verified pointer (`refs/heads/verified/master`) | GitHub | GitHub (written by the verifier, ff-only) | Verification events |
| Revision objects | GitHub `refs/chg/<id>/<n>`, node mirrors | GitHub | — |
| Change events (submitted, review, landed, …) | GitHub `refs/chg/<id>/events` (one commit per event) | GitHub (the ff-only push allocates `event_seq`) | — |
| Job leases (phase 3) | GitHub `refs/chg/jobs/<job>` (a commit naming owner, epoch, expiry) | GitHub (the ff-only push is the lease CAS) | Expire and are re-leased |
| Ledger: shadow and gate verdicts, review rounds, flaky tests, runner samples; applied change events; story bindings; review custody | loopctl (Epic 47, Epic 50) | loopctl, as a record | Every row and event is resent from the fleet's files and chains (idempotent) |
| Unsent ledger rows and events | Each machine's outbox (`~/.chg/outbox`, the shadow log) | The machine's | — |
| Node bare mirror, snapshots, verdict cache | Each machine (`chgd`) | Cache | Snapshot rebuild |
| Workspaces | Each machine | The agent's | Any change's latest revision ref |

Two rules follow. **Landed means reachable from GitHub trunk**, and loopctl only remembers it. **Nothing on a dev machine is needed for correctness**: lose a machine and you lose only its unsubmitted edits and the ledger rows it had not sent.

### 3.4 Agent interface

The CLI is the only surface, because hooks, Bash-native sessions and the runner all use it. loopctl's MCP tools read the record (`chg_ledger_summary`, `change_binding_get`); they do not drive changes.

| Verb | Replaces | Exit codes / result |
|---|---|---|
| `chg ws new <name> [--repo R]` (phase 1 runs it from the `post-checkout` hook of `git worktree add`) | `git worktree add` + `deps.get` + compile/install + PLT build | 0 ready (prints path); 3 no snapshot (falls back to cold build and says so) |
| `chg check` (phase 1 runs it from `pre-push`) | `mix precommit` / `pnpm verify` before push; CI's suite on the PR | 0 pass (verdict recorded); 1 fail (failures inline) |
| `chg submit [--intent F] [--story ID] [--depends-on C] [--wait]` (phase 2) | push, `gh pr create`, `wait-for-checks.sh`, `/code-review` dispatch, `gh pr merge`, `delete-merged-branch.sh`, `worktree-remove.sh` | Returns a change id at once. With `--wait` (backgrounded): 0 landed; 1 checks failed; 2 review findings; 3 conflict the resolver could not fix; 4 landed then reverted; 5 budget elapsed; 6 GitHub unreachable, submission queued in the outbox |
| `chg revise` | Pushing a fix and re-requesting review | New revision of the workspace's change; re-review covers only the interdiff |
| `chg status [C]` / `chg wait C` | ci-status plugin polling | Event-log tail; a long-poll that ends on a terminal event |
| `chg log C` | Reading PR timelines | Full event log |

`chg wait` watches the change's event chain (`git ls-remote` on `refs/chg/<id>/events`, re-armed every 55 s). The ci-status plugin's push-a-prompt-on-settle behaviour is re-pointed at the same chain, so a session learns that its change landed, failed or was reverted without polling.

Built so far for phase 2's record: `chg event emit|sync` (the chain and its delivery), `chg review-dispatch` (a loopctl review key for one revision) and `chg outbox send|status` (docs/outbox.md).

### 3.5 Workspaces in seconds

On every machine, `chgd` keeps a **snapshot per verified trunk revision**, per repo: a source checkout plus the adapter's artifacts (Elixir: `deps`, `_build/{dev,test}` with the dialyzer PLT, and the adapter's test-reference cache; TS: `node_modules` across the workspace, built `packages/*/dist`, the Playwright browsers path). When the verifier advances `verified/master`:
1. CoW-clone the previous snapshot.
2. `git checkout` the new revision in the clone.
3. Run the adapter's `snapshot` command, which is incremental: only the delta recompiles or reinstalls.
4. Atomically rename it into place.
5. Keep the newest 3 snapshots and garbage-collect the rest once no lease holds them.

A new workspace is a `git worktree add` from the node's bare mirror at the verified revision, plus a CoW clone of the artifact paths from the matching snapshot. If HEAD is not exactly the snapshot revision, the nearest-ancestor snapshot is used and the adapter's incremental build covers the delta.

Mechanics, verified on the fleet:
- **macOS (APFS):** `clonefile(2)`, the same mechanism as `cp -c`. Workspaces and snapshots must sit on the same APFS volume, which `~/workspace` and `~/Library/Caches/chg` do.
- **Linux:** minis, x1, nuc and beelink are **ext4 on LVM with 0 free extents**, so there is no reflink and no room for a new logical volume. Use a sparse image file on the existing ext4 (`mkfs.xfs -m reflink=1`, loop-mounted at `/srv/chg` from fstab; 300 GB sparse on minis, x1 and beelink, 120 GB on nuc), cloned with `FICLONE` (`cp --reflink=always`). `.claude/worktrees` becomes a symlink into `/srv/chg/ws/<repo>`, so the worktree convention is unchanged. Overlayfs is rejected: each workspace would pin its lower snapshot (GC hazard), and its rename and inotify quirks hurt Vite/esbuild watchers.
- **Elixir relocation:** a clone at a new path normally forces a full rebuild, because `.beam` files hold absolute source paths and the manifest stores the cwd (`mix/compilers/elixir.ex:104`). Elixir **1.19.2+ has `mix compile --no-check-cwd`**, and HCB runs 1.20.4. Enrolled repos set it as `elixirc_options: [check_cwd: false]` in `mix.exs`, since `mix test` rejects the switch, and `mix chg.snapshot` refuses a project without it in dev or test. Cost: stack-trace source paths point at the snapshot until a module recompiles. Mix compares content digests when mtimes differ, so a fresh checkout of identical content recompiles nothing. Phase-1 story S4 measures exactly that. The cwd check is not the only path a build bakes in. Phoenix's `embed_templates` puts a hash of its absolute template paths into `__mix_recompile__?`, and config can expand paths (an esbuild `cd`, a test database named after the workspace slot). On HCB, a snapshot reused at a new path recompiled 933 of its 945 files (minis, 2026-10-18). So snapshots are built at the store's one build path, `<store>/<repo>/build`, and shadow checks and gate-mode `chg check` run at that same path under the build lock. The gate checks the pushed commit there, and falls back to the live tree only when there is no store or no snapshot to start from. Each snapshot records the resolved path it was built at (`built_in`). A build of a sha whose snapshot was built anywhere else replaces it rather than reporting it present, so snapshots from before the build path existed, or from a store that has moved, get rebuilt.
- **pnpm:** the snapshot installs with the product's own pnpm settings and clones `node_modules` like any artifact. pnpm hard-links package files from a store on the same filesystem, so a reinstall after a lockfile change is quick. Measured on minis for fleet-holding (993 packages): a fresh install from a warm store takes 0.62 s, and a reflink clone of the whole tree, with 61,723 `node_modules` entries, takes 2.9 s. The global virtual store (`enableGlobalVirtualStore`) cuts the clone to 0.15 s and 1,151 entries, but it is not used, for two reasons. It drops the hidden hoist directory, so a package that resolves an undeclared dependency breaks: under it, fleet-holding's `apps/api` gets 10 type errors, from Fastify plugins whose `declare module "fastify"` augmentation can no longer find `fastify`. And set from the command line it does not stick: the next bare `pnpm exec` sees an install made under other settings and reinstalls the isolated layout. A product whose dependencies typecheck under the global store can enable it in its own `pnpm-workspace.yaml`, where every pnpm command sees it.
- **Databases:** the adapter declares per-workspace DB isolation (HCB: `MIX_TEST_PARTITION` keyed to the workspace; fleet-holding: its existing template-clone `TestRun`). Nothing about the database lives in a snapshot. The build path's one test database sees every branch's migrations, so the Elixir adapter drops it before a run when it holds a migration the checked-out tree lacks.

Targets: a workspace is ready to run tests in under 15 s at p50 on both repos, and its first `mix test` compiles 0 files when HEAD equals the snapshot revision.

### 3.6 Landing without a global lock

The only serialization point is a millisecond-scale ref CAS. No lock is ever held across a test.

Per trunk, one `chgd` runs the lander at a time: it holds the lease `refs/chg/jobs/lander-<trunk>` (3.11), renewed every 15 s. One lander is a throughput optimisation; correctness comes from the CAS, so two landers after a lease race cost a rejected push, never a wrong trunk:

1. Take ready changes in FIFO order, read from the event chains: required checks passed on the latest revision, review approved or auto-approved by policy, dependencies landed.
2. `T` = trunk tip in the lander's mirror, fetched if older than 2 s.
3. For each change `c`: run `git merge-tree --write-tree --merge-base=<c.base> T <c.commit>` (merge-ort in memory, no worktree).
   - Conflict: emit a `conflict` event and send `c` to the resolver (3.9).
   - **Overlap re-check** (SubmitQueue's conflict-graph idea, in miniature): if the files `c` touches, or its affected-test set, intersect anything landed on trunk since `c.base`, run `c`'s affected checks on the merged tree before landing it. Disjoint changes land without that re-check. Most changes are disjoint: only 6 of 449 were even textual conflicts.
   - Otherwise: `git commit-tree <tree> -p T` with the subject, intent body and `Change-Id`/`Revision` trailers, and set `T` to the new commit.
4. Batch up to 20 changes or 2 s, then `git push origin <new>:refs/heads/master` without force. Fast-forward-only makes GitHub's ref update the CAS. No intent row is needed: step 5 derives the outcome from trunk itself.
5. If the push is rejected or its result is unknown, fetch and check which `Change-Id`s are now reachable from trunk. Mark those landed and restart from step 2 with the rest. A change is never committed twice, because reachability is checked before every push.
6. Emit `landed` events; the verifier sees the new tip.

Branch protection on `master` allows fast-forward pushes only from the fleet's GitHub identity, the one landers push as, plus Mark's break-glass. Enrollment's hook refuses a session's own `git push` to master ("use chg submit"), so the identity's bypass is used by landers alone. There is no chg GitHub App (section 10; chg#33).

Capacity: merge-tree plus commit-tree on these repos takes milliseconds; the push takes about 1 s. With batching, sustained throughput is well above 10 landings/s, against a 100x need of about 0.14/s average and about 1/s peak.

### 3.7 Pre-merge checks: affected only, verdicts by content

A revision's required checks are:
- the static set: format, compile with warnings as errors, lint on the changed files, type check (dialyzer/tsc) incremental from the snapshot's PLT or tsbuildinfo;
- the **affected tests** of the revision against its own base.

They run where the change was made: `chg check` in the agent's workspace (phase 1, from `pre-push`), or on the runner pool (phase 3). Either way the result is a **verdict** keyed by `(check_id, input_fingerprint)`. The fingerprint is BLAKE3 over the revision tree's declared input globs, the lockfiles, the toolchain versions (`.tool-versions`, `packageManager`) and the adapter version. A verdict anyone has recorded for that fingerprint is never recomputed: local and CI are the same job, so nothing runs twice.

Affected selection is the adapter's job (3.13). It always has a fail-closed escape, which `chg` applies before calling the adapter: any changed path matching the manifest's `always_all` list (mix.exs, mix.lock, config/**, migrations, test helpers, pnpm-lock.yaml, tsconfig*, vitest/playwright configs, CI definitions) selects the whole suite. A file that only tests read at run time (story data, workflow definitions a guard test parses) goes in `read_at_runtime` instead: an adapter whose coverage record also records each test file's reads selects just its readers, and the whole suite when it has no such record (adapter-contract.md, `CHG_READ`).

### 3.8 Post-merge verification, deploy gating, bisect, revert, flakes

- **Verifier loop, per trunk.** Whenever `tip != verified` and no verification is running, verify the tip: the full suite sharded across the pool, and e2e. Everything that lands during a run joins the next batch, so batch size adapts to load with no tuning. TAP does the same: presubmit is a subset, postsubmit is batched.
- **Green:** fast-forward `verified/master` to that sha (CAS). Snapshots rebuild from it, deploy takes it, and new workspaces base on it. **Agents never start from an unverified tip**, so a red window on trunk blocks nobody's work, only the deploy.
- **Red:** collect the failing test ids, then rerun them twice on the same sha.
  - Passes on rerun: it is **flaky**. Quarantine it (the test leaves the gating set for that trunk, recorded as a `flaky` ledger row and the open issue), file an issue labelled `flaky` (`deferred-finding` style) naming the test, and re-verify.
  - Still failing: **bisect over the batch, running only the failing tests**. Up to `k` prefixes run in parallel (`k` = free shard slots), so 80 changes take 2 rounds at k=8. The first red prefix is the culprit.
- **Revert:** create a revert change (a 3-way merge with base = culprit, ours = tip, theirs = culprit^, via merge-tree) with policy class `revert`. It lands through the same lander, gated by the failing tests going green on the reverted tree. The culprit's change reopens with a `reverted` event carrying the failures. Its author session is notified (ci-status prompt / channel post) and fixes it with `chg revise`, which re-lands like any revision. Idempotency key: `(culprit_change_id, verification_id)`.
- **Deploy:** a deploy job takes the newest verified sha, coalescing bursts (one Fly deploy per app at a time; image label = sha, so a repeat is a no-op), then runs a post-deploy smoke. A failed smoke rolls back to the previous release image and marks that sha `deploy_failed`, which the verifier treats like red.

### 3.9 Conflict resolver

When a textual conflict appears at landing, a `resolve` job goes to the pool. It runs headless Claude in a CoW workspace at the current tip, with a payload of the conflict hunks, both sides' intents and diffs, and the change's affected tests. It produces a new revision authored by the resolver (`Resolved-By: chg-resolver`). That revision goes through the normal checks and review: review sees the interdiff against the change's last approved revision. Two failed attempts send the change back to its author with the conflict (exit 3).

### 3.10 Review integration (intent review)

- Review is a pool job dispatched **at submit, concurrently with checks**, not after CI. The `chgd` that leases it first asks loopctl for the review key of that `(change, revision)` (`chg review-dispatch`, loopctl US-50.3), which the reviewer records its verdict with, and hands the key to the job alone. The payload is built by the job: the change's intent and the story's acceptance criteria, the diff, the full text of the touched files and their immediate callers, and the top KB hits for the touched modules, fetched up front. The target starting context is 15-20k tokens, against 94k today. The reviewer runs with parallel tool calls on and writes findings as structured JSON: `file:line`, failure scenario, CONFIRMED or PLAUSIBLE.
- **Policy classes** in `.chg/policy.toml`, computed by `chg submit` from the diff and re-checked by the lander:
  - `docs` (only `*.md` outside the always-all list), `comment-only` (AST-equal after stripping comments: `Code.string_to_quoted` for Elixir, the TS compiler API for TS) and `test-only` auto-approve with no model review.
  - `sensitive` globs (auth, credentials, billing/money, PHI schemas, migrations, `.github/`, `.chg/`) always get the full review lens set and never auto-approve. Mark's rule stands: they merge on review plus green, never on his say-so.
  - `revert` (3.8) skips review: it is the exact inverse of a reviewed change, and its gate is the failing tests going green. This is a default Mark may overrule (section 10).
- **One round.** Findings come back as a `review_findings` event (exit 2). The agent fixes every confirmed finding (rule 0) and runs `chg revise`. The pool re-reviews **only the interdiff**, once, and the review-round counter reads the change's `review_*` events (each round is also a `review_round` ledger row in loopctl). The cap and the `REVIEW CAP` escalation stay as today.

### 3.11 Runner pool

- `chgd` on every machine declares capacity: slots and CPU/memory per slot, with beelink given most (24 threads), then minis (16), mac-mini and blockit, then nuc (4). It **pulls**: it lists open jobs matching its labels (repo, OS, capabilities such as `postgres`, `browsers`, `claude`) and leases one.
- Jobs are `snapshot_build`, `check`, `verify_shard`, `bisect`, `review`, `resolve` and `deploy`. A job is a ref, `refs/chg/jobs/<idempotency_key>`, whose commit chain records its spec, then each lease (`owner`, `epoch`, `expires_at`: 60 s, renewed every 15 s) and its result. Leasing is a fast-forward push of the next lease commit, so two runners racing for one job cannot both win, and the epoch is the fencing token: a result whose epoch is not the chain's newest is refused by the same CAS. At the projected 0.14 landings/s plus their jobs, ref pushes stay near 1/s, inside the 3.12 trigger. If they do not, the job chains move to a bare repo of the fleet's own (the 3.12 flip), not to a service.
- Every job runs in a CoW workspace named after the job id, under a cgroup slice on Linux. The existing CI-host memory slicing in `infra` carries over.
- A dev machine's agents and its runner share the box. `chgd` admits pool jobs only below a load threshold, and beelink, being dedicated, admits up to its slots.

### 3.12 GitHub: durable store and browser, not the workflow

GitHub keeps `master`, `verified/master` and `refs/chg/*`, so every object and ref is durable off-fleet and browsable. Deploy secrets stay where they are. From phase 2 there are no PRs or Actions in the gate path for enrolled repos. In phase 3, Actions shrinks to nothing, or to the deploy step if Mark prefers it there.

**Do not flip GitHub to a mirror** unless a measured trigger fires: GitHub push p95 over 3 s, sustained landings over 5/s, or a rate-limit response. At 100x the projection is about 0.14/s. If the trigger fires, the flip is local: a bare repo the fleet hosts (beelink, with continuous `git push --mirror` to GitHub) becomes the authority, and only the CAS target changes.

### 3.13 The adapter contract (language-neutral)

A repo declares `.chg/adapter.toml`. `chgd` calls the adapter's commands, which emit one JSON document on stdout:

```toml
[adapter]
kind = "elixir"                 # or "pnpm"
version = "1"
artifacts = ["deps", "_build", "priv/plts"]      # pnpm: ["node_modules", "apps/*/node_modules", "packages/*/node_modules", "packages/*/dist"]
inputs = ["lib/**", "test/**", "config/**", "priv/**", "mix.exs", "mix.lock", ".tool-versions"]
always_all = ["mix.exs", "mix.lock", "config/**", "priv/repo/migrations/**", "test/test_helper.exs", "test/support/**", ".tool-versions", ".chg/**"]
isolation_env = { MIX_TEST_PARTITION = "{workspace_slot}" }

[commands]
snapshot = "mix chg.snapshot"                    # incremental; idempotent
static   = "mix chg.static --base {base}"        # format/compile/credo/dialyzer on the delta
affected = "mix chg.affected --base {base}"      # -> {"mode":"subset"|"all","reason":…,"tests":[…]}
run      = "mix chg.run --tests {file}"          # -> {"results":[{"id","status","ms"}],"junit":"…"}
shard    = "mix chg.shard --of {n} --index {i}"  # full-suite shard for verification
```

- **Elixir adapter:**
  - `snapshot`: `mix deps.get`, `mix compile` for dev and test (with `check_cwd: false`), a PLT build, then `mix chg.refs`, which compiles every test file without running it and records its module references.
  - `affected`: the `--stale` selection without running anything. `mix test --stale --dry-run` cannot do it: on 1.20.4 `--dry-run` turns `--stale` off, and the stale manifest is only written after a green run. So the adapter reads Mix's compile manifest for the module graph and its own reference cache for the tests, and applies `--stale`'s rule: a changed module plus every module referencing it, transitively, selects the test files with a compile or runtime reference into that set. Runtime-only dispatch (string module names, Oban args) can escape it, which is why the post-merge full suite exists.
  - Every task but `snapshot` first runs `mix deps.get` when `mix.lock` is not the lock the hydrated deps were fetched for (recorded in `deps/.chg_lock` by the snapshot and by each fetch).
  - `static`: format and credo on changed files, `compile --warnings-as-errors` (incremental), dialyzer against the warm PLT.
  - `shard`: test files split by a stable hash of their path; not `mix test --partitions`, because `MIX_TEST_PARTITION` already isolates each workspace's test database.
- **TS (pnpm) adapter:**
  - `snapshot`: `pnpm install --frozen-lockfile`, `build` for the packages with one (`packages/*` by default), the repo's code generators (fleet-holding's gitignored TanStack route tree), Playwright browsers when asked, then a warm incremental typecheck.
  - `affected`: a changed source goes to Vitest `list --changed <base> --filesOnly` and Playwright `--only-changed=<base>`, which follow the import graph across packages, so a module selects its own tests and its importers' tests and nothing else in a dependent package. A path the graph cannot see (a deleted source, a non-code file read at runtime) selects every test of its package and of the packages depending on it, as `pnpm --filter "...<pkg>"` would. A path outside every package selects everything unless ignored. When an app package changed, its smoke-tagged e2e subset is added; full e2e is post-merge only.
  - `static`: eslint on changed files; `tsc --noEmit --incremental` per package from the snapshot's build-info files, since fleet-holding has no project references for `tsc -b` to follow; and the repo's own checks (`scripts/check-pr-hygiene.mjs`, the secrets scan) as `--check` commands.
  - `shard`: Vitest `--shard i/n`; Playwright `--shard`.

## 4. Failure design

**Partitions.**
- *Agent ↔ GitHub:* `chg submit` pushes `refs/chg/<id>/<n>` and emits `submitted`; while GitHub is unreachable it queues both in the outbox and `--wait` exits 6 with the entry named. Submission is idempotent on `(change_id, n, tree_sha)`, so a retry after a lost response is a no-op. `chg check` keeps working offline: it records verdicts locally.
- *Runner ↔ GitHub:* the lease expires (60 s) and the job is re-leased elsewhere. A late result from the partitioned runner carries a stale epoch, so its fast-forward push is refused (fencing).
- *Lander ↔ GitHub:* landing pauses. Ready changes stay ready and nothing is lost. On recovery the lander reconciles first (3.6 step 5).
- *Fleet ↔ loopctl:* nothing on the push, check or landing path waits. Ledger rows and events stay in the outbox and are resent with backoff (30 s doubling to 1 h); loopctl holds events that arrive ahead of a gap, and a gap no sender fills alerts the operator, who runs `chg event sync`. New review keys wait, so a change already reviewed lands and one awaiting review waits. During this research the KB timed out twice and then returned 503 `db_unavailable`; that is why loopctl only receives.
- *Fleet ↔ internet* (the LAN is up, the internet is down): agents keep editing and checking locally, and landing waits. Today's GitHub dependency behaves the same; no new failure domain is added.

**State on crash, deploy and failover.**
- Every coordination fact is a ref on GitHub, and every multi-step operation is resumable from refs alone:
  - landing: which `Change-Id`s trunk reaches (3.6 step 5);
  - verification: the `verified/master` ref and the verifier job's chain;
  - revert: the revert change's own events, keyed `(culprit_change_id, verification_id)`;
  - deploy: `fly releases` for the image label.
- The lander and verifier are `chgd` duties held by a lease, holding no state beyond refs. A machine that dies mid-step loses the lease in 60 s, and the next holder starts by reconciling. Even a double lander is safe, because the ff-only push rejects the loser.
- `chgd` keeps its node state on disk (mirror, snapshots, verdict cache, outbox) and rebuilds any of it on corruption, except unsent outbox rows, which a lost disk loses. Events never are: they are on GitHub before they are queued.

**Retry idempotency.**

| Operation | Idempotency key | Duplicate effect |
|---|---|---|
| Submit | `(change_id, tree_sha)` | Returns the existing revision |
| Check | `(check_id, fingerprint)` | Returns the cached verdict |
| Job | `idempotency_key` (its ref) + lease epoch | Late result rejected |
| Change event | `event_seq` allocated by the chain's ff push; loopctl keys `(repo, change_id, event_seq)` | Redelivery is a duplicate; a conflicting body is 409 |
| Ledger row | `(source, host, sha256 of the row)` in loopctl | Counted as a duplicate |
| Review key | `(source, change_id, revision)` in loopctl | Re-mint revokes the earlier key until a verdict, then 409 |
| Land | `Change-Id` reachability check before every push | Never double-lands |
| Revert | `(culprit_change_id, verification_id)` | One revert |
| Deploy | Image label = sha | Fly no-op |
| Flaky quarantine | `(trunk, test_id)` | One issue, commented per run |
| Notifications | `(change_id, event_seq)` | ci-status dedups |

**Slow, not down.**
- Every call has a timeout: a loopctl request 30 s (10 s to connect); `chg wait` 55 s, re-armed; git push 60 s with the reconcile path on timeout. A timeout is an unknown result, never a failure, and is resolved by reconciliation.
- Leases are judged by heartbeat. A slow runner that keeps heartbeating keeps its job; one that stalls loses it. Per-kind wall-clock caps (check 15 min, shard 20 min, review 10 min, resolve 15 min) bound a slow job.
- Snapshots are built locally from git deltas and are never downloaded, so a slow WAN costs only the small fetch.
- A per-machine admission threshold stops pool jobs from starving the agents working on that box.

**Where units of work run, and how they are reached after a restart.**
- Agent sessions run on their own machine. The fleet reaches a session only through its change's event chain: ci-status prompts while it lives, and `chg status` for whichever session picks the change up next (a handoff names the change id).
- Jobs run on whichever runner leased them. After a runner restart the lease lapses and the job runs elsewhere, so nothing addresses a runner directly.
- The lander and verifier run on whichever `chgd` holds their lease and are found through the lease ref. Refs are their memory.
- Outbox sends run on the machine that wrote the rows, started by the writer and by a 10-minute cron line; a restart loses nothing but the run in flight, which the saved offset resumes.
- Deploys run as `deploy` jobs on a runner labelled `fly` (or in GitHub Actions if Mark keeps it there), keyed by sha.

## 5. Build vs buy

| Component | Verdict | Why |
|---|---|---|
| VCS / object store | **Buy: git + GitHub** | Our volume is far below where git breaks. Sapling/Mononoke: the OSS server is "still in development", lacks Thrift APIs and config docs, and has almost no outside adoption. Scion is not public. |
| Merge engine | **Buy: git merge-ort** via `git merge-tree --write-tree` (git ≥2.38) and `git replay` (built for rebase on bare repos, with no worktree) | gitoxide lists merge, cherry-pick, revert, rebase and push as "still need plumbing across crates". Revisit only if fork/exec cost shows up in profiles, which it will not at about 1/s. |
| Change ids, op log, first-class conflicts | **Borrow from jj** (`Change-Id`, per-change event log, conflicts as a state rather than an error) | Agents are fluent in git. Switching the client to jj adds a learning cost and reliability risk for little gain, since our conflicts are rare and the resolver handles them. |
| Merge queue | **Build (small)**. Reject GitHub merge queue, Aviator, Mergify and Graphite | They are all PR-shaped and keep pre-merge testing of the predicted tip on GitHub Actions: the serialization and CI wait we are removing (GitHub caps concurrency at 1-100 builds; Aviator's per-target queues need us to compute affected targets anyway). Uber SubmitQueue (Go, no releases) keeps master green by speculative pre-merge builds, which is compute we choose to spend post-merge instead; we take its conflict-graph idea as the overlap re-check. |
| Presubmit/postsubmit split, culprit finding, auto-revert | **Borrow from Google TAP** (and SafeRevert's caution) | Batched postsubmit with bisect is the proven answer to "what does CI mean at agent scale". |
| Workspace provisioning | **Build on OS primitives**: APFS `clonefile`, XFS reflink on a loop image, pnpm's same-filesystem store, Elixir `check_cwd: false` | No product does per-revision warm snapshots for mix and pnpm. Scalar and partial clone solve volume we do not have. |
| Test result caching | **Build a verdict cache keyed by input fingerprint** (Bazel remote-cache model) | Adopting Bazel means rewriting both builds. Turborepo's cache covers TS tasks only and fleet-holding does not use turbo. |
| Runner | **Build `chgd`**; retire GitHub Actions from the gate path in phase 3 | Actions on one host is the 20 s queue and the 6.9 agent-hours. loopctl-runner supervises Claude sessions, a different job, but its enrollment and lease ideas carry over. |
| Review | **Reuse the existing review lenses and prompts**; build only the payload builder and the pool dispatch. Custody is **loopctl's** (US-47.5, US-50.3): the review key is minted per revision under the source's chg root | The 226 s is mostly harness context and serial position, not the reviewer prompts. |
| Ledger, change record, dashboard | **Extend loopctl** (Epic 47 change events and bindings, Epic 50 ledger rows, cursor, review dispatch, dashboard, `chg_ledger_summary`). Mark, 2026-10-28: *"I insist on extending loopctl for that and NOT building a separate app."* | loopctl already holds stories, custody and the KB, so a change's record sits beside the story it delivers. Its failure domain is kept off the gate by direction: the fleet sends through a local outbox and loopctl never calls back (4, Partitions). loopctl change threads died because they were opt-in and removed no wait (section 8), not because of where they lived. |
| Coordination (landing, leases, event order) | **Build on git ref CAS on GitHub**, no service | The ff-only push is already the authority for trunk (3.6). The same primitive orders events (3.2), leases jobs and elects the lander (3.11), so there is no database to keep in step with the refs and nothing to host. |
| Outbox and sender | **Build (small), in `chg`** | Append-only JSON-lines files with a saved offset, a signed batch POST, backoff, and the shadow log reused as its own queue (docs/outbox.md). A message broker would be a second service to run for one producer per machine. |

**Rust or Elixir.**
- **Rust:** the `chg` CLI and the `chgd` daemon.
  - The CLI runs inside every hook and agent call, so startup time counts (a static Rust binary starts in about 5 ms; an escript pays BEAM boot every time).
  - The clone engine walks about 30k files per HCB workspace; parallel `clonefile`/`FICLONE` in Rust with rayon beats `cp -c -R`, which is single-threaded.
  - It computes BLAKE3 fingerprints over input trees on every check.
  - The job executor needs cgroups, process-group kill and log streaming.
  - It ships as one artifact for macOS arm64 and Linux x86_64, with no runtime to keep in sync across 5 machines.
  - The lander, verifier and job leasing live in `chgd` too: their state is refs, so a supervised daemon per machine with a lease is all they need.
- **Elixir:** what loopctl holds (Epic 47, Epic 50): applying events in seq order, story bindings, the ledger tables, review custody, the LiveView dashboard and the MCP read tool. That is Mark's stack, and loopctl's Postgres is the record.
- **Git** is called by shelling out to `git`. It is the battle-tested merge engine, and wrapping it is cheaper than re-implementing it.

## 6. Phases

Each phase removes a measured wait on its own, ships in days with the fleet building it, and is judged against the 2026-10-02..16 baseline. A phase that does not move its number is reverted, not kept as more machinery.

**Phase 1: Verify once, start warm (about 5-7 days). Still on GitHub PRs.**
- Removes the duplicated gate and full CI re-runs (64%), catch-up merges (51% of PRs), most of the 6.9 agent-hours/day of CI wait, most of the 9-minute gate, and cold worktree setup.
- How:
  - **Adapter contract + Rust `chg`** with the `ws new`, `check`, `snapshot` and `verify-culprit` verbs.
  - **Elixir and TS adapters**, validated on HCB and fleet-holding.
  - **The `local-gate` verdict means "affected checks of head vs its merge base passed".**
  - **The `behind_by` rule is deleted** from both repos' `attest`, so PR CI runs hygiene and secrets only.
  - **Catch-up merges are blocked** unless `git merge-tree` reports a conflict.
  - **Master's existing full-suite run becomes the verifier**: it advances `verified/master`, finds the culprit and opens an auto-revert. Deploy is from verified only, which both repos almost already do.
  - **Workspaces hydrate from snapshots** through the `post-checkout` hook.
- Zero new agent verbs. `git worktree add` and `git push` simply get faster.

**Phase 2: Land without PRs (about 5-7 days).**
- Removes the PR ceremony (create, wait, merge, branch delete, worktree remove), the serial ordering of review after CI, and most of review latency.
- How:
  - **The lander** (`chg land`, a lease-holding loop under a systemd/launchd unit on two machines) with the overlap re-check, reading the event chains.
  - **`chg submit` / `revise` / `wait`**, emitting events through the outbox to loopctl (already built: `chg event`, `chg review-dispatch`, `chg outbox`).
  - **Lean review dispatched at submit**, concurrent with checks, under a loopctl review key.
  - **The conflict resolver.**
  - **Enrollment per repo**: `gh pr create` and branch pushes to `master` are refused by hook with "use chg submit". The delivery-loop text in CLAUDE.md and the ci-status, wait-for-checks and review-counter mechanisms are rewritten in the same PR (no tombstones).
- Checks still run in the agent's workspace (phase 1 `chg check`). The verifier is still master's Actions run.

**Phase 3: Fleet runner pool (about 5-7 days).**
- Removes the single-host CI queue (20 s median pickup becomes under 1 s), post-merge verification latency at 10x (sharded across about 60 slots instead of beelink's 5 fleet-holding jobs), and the time agents' machines spend running their own checks.
- How:
  - **`chgd` as a daemon**: bare mirror, snapshot builder, pull-based leased executor.
  - **Checks, verification shards, bisect, review, resolve and deploy as pool jobs.**
  - **GitHub Actions is out of the gate path**: deleted or reduced to deploy.
  - **Superfan watcher agents**, one each for lander, verifier and pool, reading telemetry, on a schedule.

**Phase 4: Only on a measured trigger.**
- Speculative postsubmit (verify likely-failing targets first; TAP reports 107 to 37 minutes median detection).
- Automated flaky-test repair stories.
- AST-aware policy classes beyond comment-only.
- Directory-level permissions for agents.
- Flipping GitHub to a mirror (trigger in 3.12).

Ordering rationale: phase 1 goes first because it is the largest measured waste (a 9-minute gate paid twice in 64% of PRs, half the PRs doing a pointless merge), it needs no new service, and its adapters and snapshots are what phases 2 and 3 run on.

## 7. Phase 1 stories

All stories ship in both repos unless marked otherwise. "Baseline" means the 2026-10-02..16 HCB numbers. fleet-holding takes its own baseline from the week before its rollout, with the same scripts.

**S1. Adapter contract and `chg` CLI skeleton (Rust).**
- `chg` builds for macOS arm64 and Linux x86_64 and installs into `~/workspace/claude-config/bin` on every machine via claude-config-sync.
- `chg adapter validate` parses `.chg/adapter.toml` and rejects unknown keys, a missing command or an empty `always_all`.
- Adapter JSON output is schema-checked. Malformed output makes `affected` fail closed to `{"mode":"all"}` and print the reason.
- `chg --version` prints the contract version, and adapters declare the version they implement. A mismatch is an error naming both.
- The schema has unit tests, and an integration test against a fixture repo for each adapter kind.

**S2. Elixir adapter (HCB).**
- `mix chg.snapshot` is idempotent: a second run on the same revision does no work and exits 0 in under 10 s.
- `chg adapter exec affected --base <sha>` returns `mode: all` when any `always_all` path changed (`chg` checks before calling the adapter), and otherwise `mix chg.affected`'s file list, which is the one `mix test --stale` would select.
- Seeded test: an edit to one context module selects that module's tests and its dependents' tests and nothing unrelated.
- An edit only to `config/runtime.exs` returns `all`.
- `mix chg.static` runs format and credo on changed files only, plus `compile --warnings-as-errors` and dialyzer against the snapshot PLT.
- Dev and test compile with the cwd check off (`elixirc_options: [check_cwd: false]`), and `mix chg.snapshot` refuses a project that does not.

**S3. TS adapter (fleet-holding).**
- `snapshot` runs `pnpm install --frozen-lockfile` with the product's pnpm settings, builds `packages/*`, and is idempotent.
- `affected` takes `vitest list --changed <base> --filesOnly` and Playwright `--only-changed` for changed sources, and the `pnpm --filter "...<pkg>"` closure for paths the import graph cannot see.
- A change under `packages/domain` selects the tests in `domain` and in every dependent app that imports the changed module. A change to `pnpm-lock.yaml` or any `vitest*.config.ts` returns `all`, through `chg`'s `always_all`.
- `static` runs eslint on changed files, an incremental `tsc` per package, `check-pr-hygiene.mjs` and the secrets scan.

**S4. Snapshot store and CoW workspaces.**
- On each machine, `chg snapshot build <repo> <sha>` produces a snapshot under the store root (`--timeout-secs` lifts the 30 min cap for a first full build on a slow machine), cloned from the previous snapshot. It keeps the newest 3 and never deletes a snapshot a live workspace was cloned from in the last 24 h.
- The `post-checkout` hook on `git worktree add` (branch checkout, prev sha all zeros) runs `chg ws hydrate`, which clones the artifact paths from the nearest-ancestor snapshot.
- p50 time from `git worktree add` to tests-runnable is under 15 s on HCB and fleet-holding, on mac-mini and minis, measured over 10 runs each and recorded.
- In HCB, when HEAD equals the snapshot sha, the first `mix test <file>` prints no `Compiling` line for project modules. In fleet-holding, no install or build runs.
- No snapshot: `ws hydrate` exits 3 with a message and the worktree falls back to today's cold path. It is never left half-hydrated.
- No clone possible (the worktree on another filesystem than the store, or a filesystem without reflink): `ws hydrate` copies the snapshot byte by byte and prints the size, the time and the fix. A slow hydrate still beats a cold build. `chg doctor` clones a probe file from the store into the repo's `.claude/worktrees` and fails until that works (`bin/chg-volume-setup.sh --enroll`); it decides by the clone, not by device numbers, which differ between btrfs subvolumes that clone. A repo whose adapter names no artifacts hydrates nothing and passes. Snapshot builds inside the store never copy.

**S5. Linux reflink volume (minis, x1, nuc, beelink).**
- `bin/chg-volume-setup.sh` creates a sparse image file (300 GB on minis, x1 and beelink, 120 GB on nuc), `mkfs.xfs -m reflink=1`, an fstab loop-mount at `/srv/chg` and a `.claude/worktrees` symlink per enrolled repo.
- The script is idempotent (a second run changes nothing) and refuses when the target path holds data that is not its own.
- `cp --reflink=always` of the HCB snapshot completes and `df` grows by under 50 MB.
- The mount survives a reboot, checked once per box.
- Rollback steps are written into the script header.

**S6. `chg check` replaces the full gate at push.**
- The HCB `.githooks/pre-push` and the fleet-holding pre-push call `chg check` (static plus affected tests against the merge base with the PR's target) instead of `mix precommit` / `pnpm verify`.
- On pass they post the `local-gate` status with a description naming the adapter, fingerprint, toolchain and "affected N/M tests". The existing record and attest scripts keep their trust checks (owner, toolchain).
- Median push-gate time on HCB is at most 3 minutes over the first 30 pushes, against the 9-minute baseline.
- `chg check --all` exists and is what a `full-ci` label or an `always_all` hit runs.

**S7. Attestation no longer bound to the base; catch-up merges stop.**
- HCB `attest` drops the `behind_by > 0` rule and attests a head whose `local-gate` verdict covers head against its merge base. fleet-holding `ci-attest.mjs` does the same.
- PR CI on an attested head runs only hygiene and secrets.
- A `PreToolUse` hook refuses `git merge origin/<base>` / `git pull` into a story branch unless `git merge-tree --write-tree` reports conflicts, and the refusal says why.
- Over the first 5 days: under 5% of PRs carry a catch-up merge (baseline 51%), and under 10% of PR CI runs execute the full suite (baseline 64%).
- The behind-base wording in CLAUDE.md, `docs/harness/ci-waiting.md` and HCB's comments is replaced, not annotated.

**S8. Post-merge verifier, culprit finding and auto-revert on master.**
- When master's full CI run passes, a job fast-forwards `refs/heads/verified/master` to that sha (ff-only; it refuses to move backwards).
- When it fails: the failing test ids are rerun twice on the same sha. If they now pass, the job files a `flaky` issue naming each test and does not revert. If they still fail, it runs only those tests at each commit between `verified/master` and the red sha (parallel up to the runner pool cap) and names the first failing commit.
- The job opens a revert PR labelled `auto-revert`, which merges when the failing tests pass on it, and posts to the culprit PR's author session via the coordination channel. The idempotency key `(culprit_sha, run_id)` guarantees one revert per culprit per run.
- Deploy in both repos runs only from a sha equal to `verified/master`.
- New worktrees are cut from `origin/verified/master`. The worktree command in CLAUDE.md changes in the same PR.

**S9. Measurement.**
- A script reproduces the baseline metrics (gate time, CI full re-runs, catch-up merges, CI wait in agent-hours/day, worktree ready time) for any date range and repo, and is checked into claude-config.
- A before/after table for days 1-5 of phase 1 is posted to the coordination channel and filed to the KB.
- Any metric that did not improve is named, with the cause found.

S1 blocks S2, S3, S4 and S6. S5 is independent. S7 needs S6. S8 is independent of the CLI. S9 starts on day 1.

## 8. Why this does not end like change threads

loopctl change threads (a ledger in loopctl, squash merge through the GitHub API, review dispatch) were never used, for these reasons:
1. They were **opt-in and additive**: a `.loopctl/mode` marker, a `loop/` branch prefix, and the PR path still open and still the default the delivery loop described.
2. They **removed no wait**: GitHub Actions still judged every checkpoint, so a thread was the same pipeline under a new name.
3. They needed a **different way to start work**: runner-dispatched `claude -p` sessions, with the accept path off by default. Mark's actual sessions never passed through it.
4. Every harness mechanism (CLAUDE.md, ci-status, wait-for-checks, the review counter) stayed PR-shaped and had to learn a special case (`thread-mode.sh`).

This design inverts each of those:
- **Phase 1 adds no verb.** The hooks on the commands agents already run (`git worktree add`, `git push`) become faster, and CI stops re-running what was already proven.
- **Phase 2 adds one verb that deletes seven**, and enrollment *closes* the old path by hook in that repo. CLAUDE.md's delivery loop is rewritten in the same PR, not footnoted.
- It serves the interactive sessions Mark already runs, on every machine, with no dispatch model.
- Each phase is accepted only on its baseline numbers, so a phase that adds steps without removing wait is visible within a week and reverted.

## 9. Open facts only Mark holds

1. **The coming project.** Repo count, size, and whether it is a monorepo (affects snapshot size and the `always_all` blast radius). Stack is settled: Elixir and TS are both first-class from phase 1.
2. **Concurrent agents.** Defaulted to **20-50**: pool sizing, lander batch size of 20, per-machine admission thresholds. A number above about 60 means a sixth machine or a Fly-hosted shard pool before phase 3 ends.
3. **Deploy target.** Defaulted to **Fly.io** for the new project. Another target changes only the `deploy` job and its smoke and rollback commands.
4. **Is a red trunk for up to one verification cycle (about 10-15 min) acceptable?** It is the core trade, since deploy is blocked but agents are not. A regulated "trunk must always be green" requirement (HCB handles PHI and Medicaid billing) would add the overlap re-check to *every* change, not just overlapping ones, which costs about one affected-test run per landing.
5. **Where Fly secrets for deploy jobs may live**: on pool machines labelled `fly`, or deploy stays in GitHub Actions.
6. **Budget for headless Claude in review and resolve jobs** at 10-100x volume (model, effort, per-day ceiling).

## 10. Defaults Mark may overrule

- **Auto-reverts land without a `/code-review` round.** The revert is the exact inverse of a reviewed change, and its gate is the failing tests going green. Overrule in `.chg/policy.toml` (`[class.revert] review = true`).
- **Docs-only, comment-only and test-only changes auto-approve** with no model review. Overrule per class in the same file.
- **New worktrees base on `verified/master`, not the master tip.** Overrule with `chg ws new --from tip`.
- **GitHub remains the durable ref and object store** until the trigger in 3.12.
- **Coordination is git ref CAS on GitHub, not a service**: event order (`refs/chg/<id>/events`), job leases and the lander's lease (`refs/chg/jobs/*`). Overrule by naming a host for a coordination service; the cost is a component on the landing path that the fleet must keep up.
- **The loopctl-merge GitHub App (5101362) is retired, not adopted** (chg#33). Landers push trunk as the fleet's existing GitHub identity under a ruleset that allows it fast-forward pushes, so no App private key is copied to every machine. Overrule by adopting the App: a new private key into each machine's secrets, the old one revoked, and the ruleset's bypass actor kept.
- **Every enrolled machine holds its repos' `change_events_secret`** (`~/.chg/loopctl.toml`, mode 0600), so any of them can send rows and mint a review key (loopctl US-50.3). Overrule by sending from one reviewer host only, which makes it a single point of failure for review.
- **The outbox sends every 10 minutes by cron and after every write**, backing off 30 s doubling to 1 h; `chg doctor` fails when a row has waited over 24 h. Overrule in `cli/src/outbox.rs` (`BACKOFF_*`, `STALE_MS`) and `bin/chg-outbox-cron.sh`.
- **A review round is sent only once its branch links to a PR**, and a voided round is sent as a second row of kind `review_round_void`, never deleted. A branch reused for several PRs credits the newest (the row lists all in `prs`). Overrule in `outbox::review_rows`.
