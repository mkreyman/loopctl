# PRD — Epic 45: Change threads, an agent-native replacement for the pull request

**Status:** draft for review · **Epic:** 45 · **Issue:** mkreyman/loopctl#882
**Builds on:** Epic 44 (`../epic_44_delivery_loop_completion/PRD.md`) and the delivery loop as
documented in `docs/agent-delivery-loop.md`.

**Recommendation: pilot, on `mkreyman/infra`.** Don't build it fleet-wide yet, and don't wait for Delta.
The reasons are in §8.

## 1. The problem

Every change still takes the route `git push` → PR → CI → `gh pr merge`. loopctl holds everything
around the change: the story, its acceptance criteria, the claim, custody, review verdicts and both
gates. It does not hold the change itself or the merge. The route through GitHub is where the
measured failures come from (infra #187 → #188/#189/#190, 2026-09-22, and this fleet's history since):

- **A stale head.** GitHub never picked up a push. The PR's head stayed on the older commit, and CI
  judged it. KB `908176db` records the variant that loses a commit: a merge in that window squashes
  the head GitHub knows about.
- **Superseded CI results.** A green result on one commit was reported, then withdrawn when a push
  moved the head. The `ci-status` plugin exists to issue those retractions.
- **Review rounds that feed on themselves.** Round 2 mostly finds defects introduced by round 1's
  fixes (KB `a9185081`). A PR shows a reviewer the diff and not why each fix was made, so the
  reviewer re-derives the reasoning and misses what it got wrong.
- **Four sources of truth for one change.** These are the PR, the story, the review-round counter
  (a per-machine plugin) and the channel. The fleet's hooks (`gate-unmerged-pr`, `ci-status`,
  `wait-for-checks`, `review-round-counter`) exist to keep them in step.

Zed's Delta (public beta, September 2026) replaces the PR with a **thread**. The agent
conversation and its edits stay together, and DeltaDB records edit-level history between git
commits. Review happens in a sub-thread that has the original agent's context. Zed's own repository
stays on GitHub for now.

## 2. Goal

A change to a pilot repository reaches its base branch **without a pull request**. It goes through a
thread in loopctl that carries the story, the reasoning, every checkpoint, each review round with
its findings and the fixes that answer them, the CI evidence for the exact commit, and the merge.
loopctl performs the merge itself, and only on a recorded `allow` from the merge gate.

**Success criteria for the pilot** (20 consecutive changes on `infra`):

1. Zero stale-head or superseded-CI incidents. By construction, CI evidence is bound to the SHA
   that merges (§5).
2. Every review finding after round 1 can be traced to the checkpoint that introduced it, and every
   fix checkpoint names the findings it answers.
3. Issue-to-merged wall-clock no worse than the last 20 PR-routed infra changes.
4. Mark can read any thread end to end from one URL, without GitHub.
5. No merge to `infra`'s `master` by any actor other than the loopctl App. The ruleset in §4
   enforces this, and a test push proves it.

## 3. The thread model: what is git and what is loopctl

A thread is a **story** (1:1). A thread outlives any single dispatch: a story released and
re-placed keeps its thread.

| piece | lives in | notes |
|---|---|---|
| Code at a point in time | **git**: a commit on the thread branch `loop/<story-id>` | a *checkpoint* |
| Base branch history | **git**: `master` | only the loopctl App updates it (§4) |
| Story, acceptance criteria, contract | loopctl `stories` | exists |
| Claims, custody, lineage | loopctl `stories`, `dispatches`, audit chain | exists |
| Checkpoint record | loopctl `thread_checkpoints` (new) | SHA, tree, parent checkpoint, `claim_epoch`, gate evidence |
| Conversation and reasoning | loopctl `thread_entries` (new) | written by the session, never a raw transcript (§6) |
| Review rounds and findings | loopctl `review_records` + `thread_entries` of kind `finding` | bound to a checkpoint SHA |
| Fix → finding links | `thread_entries` of kind `fix` | a fix checkpoint names the finding ids it answers |
| CI evidence | GitHub check runs and statuses, read **by exact SHA** | copied onto the checkpoint when observed |
| Merge decision | `MergePrecondition`'s recorded `allow` | exists; it now names a checkpoint instead of a PR head |
| Merge | loopctl merge executor (new) | §4 |

**Checkpoint, not keystroke.** Delta records edits between commits. We deliberately do not. What
reviewers lacked was each fix's *reasoning* next to its diff, and a checkpoint plus a reasoning
entry gives them that. Edit-level history needs editor integration that we don't own, and it adds
storage and privacy cost for no measured gain. This is the main thing Delta does that we won't.

`thread_entries` is append-only. Each entry is keyed `(story_id, seq)` and written idempotently by
`(story_id, dispatch_id, client_seq)`. It is hash-linked into the tenant audit chain, as custody
events already are. Kinds: `message`, `checkpoint`, `review_requested`, `finding`, `fix`, `verdict`,
`escalation`, `merge`.

## 4. Merge authority

loopctl merges. GitHub stays the git host and the CI runner; it is no longer where the merge
happens.

**Mechanism: a GitHub App with `contents: write`, installed on the pilot repository only.**

1. On `infra`, a repository **ruleset** on `master` restricts updates to one bypass actor, the
   loopctl App. It also requires linear history and blocks force pushes and deletion. A person, a
   session or a PR merge button pushing to `master` is refused by GitHub itself.
2. The thread branch `loop/<story-id>` is pushable only by the runner's deploy key. This is the
   "push to `loop/**` only" grant Epic 44 §5 left undecided. Every push is fenced by `claim_epoch`
   as in 44.5: loopctl records a checkpoint only from the current claimant's epoch.
3. After `MergePrecondition` records `allow` against a checkpoint SHA, an Oban job
   (`ThreadMergeWorker`, unique per story) performs a **compare-and-swap squash**. It confirms the
   checkpoint's history contains the current `master` head (compare API), creates one commit whose
   tree is the checkpoint's tree and whose parent is that head (Git Data API), and updates the ref
   with `force: false`.
   - **If `master` moved** between the two calls, the non-forced update is refused (not a fast
     forward). The story goes back to `implementing` over the existing `base_moved` edge.
   - **If it succeeded but the acknowledgement was lost**, the retry finds `master` already at a
     commit whose tree is the checkpoint's. It answers `already_merged` and adopts that SHA, as
     `MergePrecondition` already does for a merged PR.
4. The squash commit's message is generated from the thread: the story title, one paragraph drawn
   from the final `verdict` entry, and the thread URL, which replaces the PR link.

"Demote GitHub to a mirror" in the strong sense, with loopctl hosting git, is a **non-goal** (§7).
In this design GitHub keeps git storage, Actions and deploy triggers. What it loses is the PR as
the unit of change and the merge button.

## 5. CI

Threads do not replace CI. They bind CI to the exact commit that merges.

- **Where the results come from:** the pilot's workflows add `push: branches: [loop/**]`. Actions
  does not trigger on custom refs, which is why checkpoints live on a branch rather than under
  `refs/loopctl/*`.
- **What loopctl reads:** the evidence for a checkpoint is read by SHA from **both** the
  check-runs and the commit-status APIs. The combined-status API alone never lists check runs, so a green
  status there says nothing about Actions.
- **The local gate:** the `local-gate` commit status from claude-config#677 counts as evidence for
  the attested tree. For the pilot, a required check is satisfied by a CI success **or** a
  `local-gate` success on the same SHA. The trust boundary is #677's (self-attestation bounded by
  hooks), and the thread records which of the two it was.
- **Why the stale-head failure goes away:** the merge gate evaluates one SHA, and the executor
  squashes that SHA's tree. No second object, like a PR head, can drift from it.
- **After the merge:** `master` runs its full CI on the squash commit as today. That run is the
  drift canary and still gates any deploy.

## 6. Review in a thread

- **Who reviews:** a review is a dispatch of a new kind, `review`, placed like any other. Its
  lineage must be separate from the implementer's (`validate_not_self_review/3`, unchanged). It
  gets its own worktree at the checkpoint, as Delta's review sub-thread does.
- **What it reads:** the story, the checkpoint diff against the base, and the thread's reasoning
  entries. For every checkpoint after the first, it also reads the `fix` entries and the findings
  they answer. This is the context a PR never carried.
- **What it writes:** `finding` entries bound to the checkpoint SHA, each with severity,
  `file:line`, a failure scenario and an optional `introduced_by` checkpoint. It also writes one
  `review_records` row with the round's verdict.
- **The round ceiling moves from a per-machine plugin into the server:**
  - loopctl counts review dispatches per thread.
  - A third round is placed only if a round-2 finding carries `introduced_by` pointing at a round-1
    fix checkpoint. That is today's rule, now decidable from data.
  - At the ceiling with material findings, the story escalates with `review_ceiling`, and the
    remedy is a rewrite.
- **Mark's reviews:** he writes `message` and `finding` entries through the thread view (§6.1) on
  a user key. A human finding has the same standing as an agent's.

### 6.1 Where a human reads a thread

The PR is where Mark looks today, and removing it without a replacement makes the work invisible.
So the pilot needs a **read-only thread page** on loopctl.com: a LiveView on an authenticated
session that shows entries, checkpoint diffs (fetched from GitHub by SHA, not stored) and
findings, with a comment box that posts a `message` entry. The intake issue on GitHub gets a link
to it. This is the only UI in the epic.

### 6.2 What a thread stores from a session

The thread stores entries the session writes on purpose: a reasoning note per checkpoint, the
answer to each finding, the final verdict. It never stores the raw transcript, which can hold
secrets and tool output, and on `home_care_billing` could hold PHI. Entry bodies are bounded,
pass the existing secret redaction, and are rendered fenced as untrusted text, as
`escalation_reason` is.

## 7. Scope, non-goals and failure design

**Proposed stories:**

1. **45.1 Thread ledger:** `thread_entries` and `thread_checkpoints` with RLS, the API, and MCP
   tools in the same PR (CLAUDE.md: an endpoint without a tool is not done).
2. **45.2 Runner contract:** additive checkpoint and entry reporting, a minor bump. The runner
   adopts it by handoff.
3. **45.3 Review dispatch:** the `review` kind, checkpoint-bound findings, fix links, and the
   server-side round ceiling.
4. **45.4 Merge executor:** the GitHub App and the CAS squash, behind a recorded `allow`.
5. **45.5 CI evidence by exact SHA:** check runs plus statuses, and `local-gate` accepted.
6. **45.6 Read-only thread page:** §6.1.
7. **45.7 Pilot wiring on `infra`:** the ruleset, workflows on `loop/**`, and thread-aware
   variants of the fleet hooks that are PR-shaped today.

**Non-goals:**

- loopctl hosting git.
- Edit-level history.
- Real-time multiplayer editing.
- Replacing Actions.
- Any repository besides the pilot until the success criteria hold.
- `loopctl` itself: the merge gate refuses changes to the loop's own deploy repository.

**Failure design (SOUL rule 9):**

- **Partition, runner ↔ loopctl:** checkpoints are git commits and survive, and entries are
  retried idempotently by `client_seq`. A runner that loses its claim cannot record a checkpoint,
  because of the epoch fence.
- **State:**
  - Code lives in git.
  - The thread lives in Postgres under RLS.
  - The `master` head belongs to GitHub, and loopctl moves it only by CAS.
  - The recorded `allow` is loopctl's, per SHA.
- **Retries:**
  - Entries are idempotent.
  - The merge executor is unique per story, and a repeated merge resolves to `already_merged`.
  - A push the webhook missed is found by reading the branch head, not by trusting the event.
- **Slow GitHub:** the gate answers `unevaluated`/503 with `Retry-After` (exists), the executor
  backs off, and nothing holds a DB connection across a GitHub call.
- **Where the unit runs:** the implement and review sessions run on runners. The merge runs in an
  Oban job on the loopctl node, found by story id after a restart.

## 8. Recommendation: pilot, not build and not wait

- **Why not wait for Delta:**
  - Delta is bound to the Zed editor and is a hosted beta.
  - It has no custody, lineage or gates, which are the parts of a thread loopctl already holds.
  - Its own repository still merges through GitHub.
  - Adopting it would add a fifth source of truth, not remove one.
- **Why not build fleet-wide:** the fleet's tooling is PR-shaped: hooks, `ci-status`, the
  review-round counter and the nudges that tell sessions "the PR body is where Mark looks".
  Converting all of it before one repository proves the model is the expensive order.
- **Why `infra`:**
  - It has no auto-deploy.
  - Two cheap required checks (`Docs`, `Shell tests`).
  - About 30 changes a month (29 in the 30 days to 2026-09-26).
  - A single owner.
  - It is where #882's costs were measured.
  - `home_care_billing` is ruled out: it is a customer repository with PHI.
    `claude-config` is ruled out: it is symlinked into every machine, and the fleet's hooks are
    what the pilot changes.

**What would make this not worth building:**

- Delta shipping a self-hostable server or an API that loopctl's gates can sit in front of.
- GitHub shipping agent-native threads with a merge queue that binds CI to the merged SHA.
- The pilot missing criterion 1 or 3 after 20 changes.

Any one of these means stop at the pilot and fold what it learned into the PR-routed loop.

## 9. Decisions only Mark can make

| decision | recommendation | blocks |
|---|---|---|
| Create the loopctl GitHub App and install it on `infra` with `contents: write` | yes, `infra` only | 45.4 |
| The runner push grant: deploy key, `loop/**` only (Epic 44 §5's open item) | yes, same grant for both epics | 45.2, 45.4 |
| A ruleset on `infra` `master` that only the App can update | yes, after 45.4 is green on a scratch branch | 45.7 |
