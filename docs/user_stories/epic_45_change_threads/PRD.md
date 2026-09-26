# PRD — Epic 45: Change threads, an agent-native replacement for the pull request

**Status:** approved 2026-09-26, review round 1 applied · **Epic:** 45 · **Issue:** mkreyman/loopctl#882
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
| Merge decision | `MergePrecondition`'s recorded `allow` | exists, but PR-shaped: it requires `pr_number` and a `pull_request` fact (`merge_precondition.ex:213-214`, refusals at `:466-467`). Story 45.4 gives it a checkpoint source |
| Merge | loopctl merge executor (new) | §4 |

**Checkpoint, not keystroke.** Delta records edits between commits. We deliberately do not. What
reviewers lacked was each fix's *reasoning* next to its diff, and a checkpoint plus a reasoning
entry gives them that. Edit-level history needs editor integration that we don't own, and it adds
storage and privacy cost for no measured gain. This is the main thing Delta does that we won't.

`thread_entries` is append-only. Each entry is keyed `(story_id, seq)` and carries a NOT NULL
`idempotency_key`, unique per `(story_id, author_principal, idempotency_key)`. A session's key is
`<dispatch_id>:<client_seq>`, and the thread page's key is a per-form nonce, so a retried human
submit is not written twice. The table is hash-linked into the tenant audit chain, as custody
events already are. Kinds: `message`, `checkpoint`, `review_requested`, `finding`, `fix`, `verdict`,
`escalation`, `merge`.

## 4. Merge authority

loopctl merges. GitHub stays the git host and the CI runner; it is no longer where the merge
happens.

**Mechanism: a GitHub App with `contents: write`, installed on the pilot repository only.**

1. On `infra`, a repository **ruleset** on `master` restricts updates to one bypass actor, the
   loopctl App. It also requires linear history and blocks force pushes and deletion. A person, a
   session or a PR merge button pushing to `master` is refused by GitHub itself.
2. The runner pushes the thread branch `loop/<story-id>` with a deploy key. This is the "push to
   `loop/**` only" grant Epic 44 §5 left undecided.
   - **A deploy key cannot be scoped to a branch.** A second ruleset, on `loop/**`, blocks force
     pushes and deletion, so no commit already on a thread branch can be dropped.
   - **Git cannot see a claim epoch.** A reclaimed runner still holding the key can append
     commits, so the fence is in what loopctl adopts:
     - A checkpoint is recorded only when the CURRENT claimant reports it under its epoch.
     - loopctl never adopts a branch head nobody reported.
     - The merge squashes the RECORDED checkpoint's tree, never the branch head.
     - The gate refuses (`branch_head_unrecorded`) while the branch head is not the latest
       recorded checkpoint.
   - **A zombie's commit therefore reaches `master` only inside a checkpoint the current claimant
     reported and the review read.** Every line of the merged tree is in a reviewed checkpoint diff.
3. After `MergePrecondition` records `allow` against a checkpoint SHA, an Oban job
   (`ThreadMergeWorker`, unique per story) performs a **compare-and-swap squash**:
   1. It confirms the checkpoint's history contains the current `master` head (compare API).
   2. It creates one commit whose tree is the checkpoint's tree and whose parent is that head (Git
      Data API).
   3. It **records that commit's SHA on the checkpoint** as `merge_commit_sha`.
   4. Only then does it update the ref, with `force: false`.
   - **If the acknowledgement was lost:** the retry asks whether the recorded `merge_commit_sha` is
     an ancestor of `master`, not whether the trees match. That answer survives other merges
     landing in between. Every squash also carries a `Loopctl-Story: <id>` trailer, for recovery
     if the recorded SHA was itself lost.
   - **An empty change:** a checkpoint whose tree already equals `master`'s is refused as
     `empty_change` and escalated, never read as merged.
4. **When `master` has moved,** the executor does not send the story back to `implementing`:
   1. It asks GitHub to merge `master` INTO the thread branch (`POST /repos/:o/:r/merges`, as the
      App).
   2. It records the result as a `base_update` checkpoint, and CI runs on it.
   3. The story diff against the new merge base is unchanged, so it reuses the recorded review
      verdict and consumes **no review round**.
   - Only a textual conflict goes back to `implementing` over `base_moved`.
   - The cost of a moved base is one CI run on `infra`'s two cheap checks. That is the up-to-date
     rule `strict = false` avoids in `loopctl`, where one suite takes minutes; the pilot pays it
     where it is cheap and measures it (criterion 3).
5. **The squash commit's message quotes no session text.** It carries the story id, the story
   title reduced to one line of printable characters, the thread URL (which replaces the PR link)
   and the trailer. A reader who wants the verdict follows the link, where it renders fenced.

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
- **The local gate is recorded, never trusted for the merge.** A `local-gate` status from
  claude-config#677 is posted by whoever pushed, so on this path it is the implementer attesting
  its own work, which is the shape chain of custody exists to refuse. The thread shows it as an
  early signal, and the merge requires the real required checks on the checkpoint SHA.
  Revisit only if the attestation is produced by a lineage separate from the implementer's.
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
  `file:line`, a failure scenario and `introduced_by`. `introduced_by` is required on every finding
  after round 1: a checkpoint id, or `none`. It also writes one `review_records` row with the
  round's verdict.
- **The round ceiling moves from a per-machine plugin into the server:**
  - loopctl counts COMPLETED rounds, meaning `review_records` rows, not dispatches. A review
    dispatch that dies before recording a verdict uses no round and is simply placed again.
  - A third round is placed only if a round-2 finding carries `introduced_by` pointing at a round-1
    fix checkpoint. That is today's rule, now decidable from data.
  - At the ceiling with material findings, the story escalates with `review_ceiling`, and the
    remedy is a rewrite.
- **Mark's reviews:** he writes `message` and `finding` entries through the thread page (§6.1),
  as the tenant's human principal. A human finding has the same standing as an agent's: it binds
  to a checkpoint and counts toward `introduced_by` and the ceiling.

### 6.1 Where a human reads a thread

The PR is where Mark looks today, and removing it without a replacement makes the work invisible.
So the pilot needs a **thread page** on loopctl.com.

- **What it shows:** entries, checkpoint diffs (fetched from GitHub by SHA, not stored) and
  findings.
- **What it writes:** `message` and `finding` entries, each carrying a form nonce as its
  idempotency key.
- **The intake issue** on GitHub links to it.

**loopctl has no authenticated browser session today.** The router mounts only the
`:public_signup` and `:public_wiki` live sessions, and every principal is an API key. Story 45.6
therefore includes browser login:
- WebAuthn, with the credential enrolled at signup (the L0 human anchor);
- a session bound to that tenant's human `:user` principal, with RLS scoped as for its key;
- CSRF protection.

Entries from the page are attributed to that principal with an empty lineage, which is the
human-operator shape `review-complete` already permits. This is the only UI in the epic.

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
4. **45.4 Gate and stage machine speak checkpoints:**
   - a checkpoint implementation of the existing `Delivery.PullRequestSource` behaviour, so
     `MergePrecondition` evaluates a checkpoint without `pr_number`;
   - `pr_open` reinterpreted as "checkpoint under review" for a thread-mode intake source;
   - a `ci → ci` `base_updated` edge beside `base_moved`;
   - the `branch_head_unrecorded` and `empty_change` refusals.

   This is the epic's largest change.
5. **45.5 Merge executor:** the GitHub App, the CAS squash with its recorded `merge_commit_sha`,
   and the base update, all behind a recorded `allow`.
6. **45.6 CI evidence by exact SHA:** check runs plus statuses; `local-gate` recorded but not
   merge-eligible.
7. **45.7 Thread page with WebAuthn browser login:** §6.1.
8. **45.8 Pilot wiring on `infra`:**
   - the `master` and `loop/**` rulesets;
   - workflows on `loop/**`;
   - thread-aware variants of the fleet hooks that are PR-shaped today.

**Non-goals:**

- loopctl hosting git.
- Edit-level history.
- Real-time multiplayer editing.
- Replacing Actions.
- Any repository besides the pilot until the success criteria hold.
- `loopctl` itself: the merge gate refuses changes to the loop's own deploy repository.

**Failure design (SOUL rule 9):**

- **Partition, runner ↔ loopctl:** checkpoints are git commits and survive, and entries are
  retried idempotently. A runner that loses its claim can still push, but cannot record a
  checkpoint, and an unrecorded head blocks the merge (§4 item 2).
- **State:**
  - Code lives in git.
  - The thread lives in Postgres under RLS.
  - The `master` head belongs to GitHub, and loopctl moves it only by CAS.
  - The recorded `allow` is loopctl's, per SHA.
- **Retries:**
  - Entries are idempotent.
  - The merge executor is unique per story. A repeated merge resolves to `already_merged` by the
    ancestry of the recorded `merge_commit_sha`.
  - A checkpoint report that never arrived is re-sent by the runner. loopctl never infers one
    from the branch head.
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

All three approved by Mark on 2026-09-26 ("Approved. Go ahead with the plan"), on the recommendations below.

| decision | recommendation | blocks |
|---|---|---|
| Create the loopctl GitHub App and install it on `infra` with `contents: write` | yes, `infra` only | 45.5 |
| The runner push grant: deploy key, `loop/**` only (Epic 44 §5's open item) | yes, same grant for both epics | 45.2, 45.5 |
| Rulesets on `infra`: only the App updates `master`; no force push or deletion on `loop/**` | yes, after 45.5 is green on a scratch branch | 45.8 |
