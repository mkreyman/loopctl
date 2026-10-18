# PRD — Epic 47: loopctl's half of the modified-Scion change protocol

**Status:** draft 2026-10-18 · **Epic:** 47 · **Issue:** mkreyman/loopctl#989
**Succeeds:** Epic 45 (change threads), deleted by #984; its PRD is in git history.
**Depends on:** mkreyman/chg, phase 2 (`chg-server`: ledger, lander, review dispatch), designed
in chg `docs/design.md` (2026-10-16).

#989 calls this "Epic 46". Epic 46 is already the async test suite
(`../epic_46_async_suite/`, issue #963), so this epic is 47.

**Recommendation: loopctl does not host the change protocol. chg does, and loopctl becomes the
story, custody and intent authority that chg's changes report into.** §2 says why; that is the
one call in this PRD Mark may want to overrule (§9).

## 1. What Mark asked for, and what already exists

Mark, 2026-10-17: *"The idea is to implement a modified version of what Anthropic currently uses
as its source control system."* That system is Scion (Anthropic engineering, "Redesigning source
control at Anthropic", 2026-10-13). The parts that transfer to a fleet of this size are its
coordination model, not its storage:

- **Server-side landing.** Nothing is pushed to trunk by a client; moving the ref is a
  compare-and-swap.
- **No global merge-queue lock.** Pre-merge checks are cheap and affected-only; full truth is
  post-merge and pre-deploy, with bisect and auto-revert.
- **Agents resolve conflicts.**
- **Intent review.** Approval rules are semantic (comment-only vs sensitive logic), and a human
  reviews what a change is for rather than every line.

The day before #989 was filed, a claude-config session designed exactly that, as **chg**
(mkreyman/chg, `docs/design.md`, 2026-10-16): "Scion's coordination model on git storage".
It is not a test-selection tool. Its phase 2 is a change server — a ledger of changes and
revisions with an append-only event log, a lander doing `git merge-tree` + `commit-tree` + a
fast-forward-only push (the CAS), server-dispatched intent review concurrent with checks, a
conflict resolver, and enrollment that closes the PR path by hook. Phase 1 (affected-only
`chg check`, the verifier advancing `verified/master`, auto-revert) is being built now (chg S8
merged 2026-10-17). Mark answered its open facts on 2026-10-16 (chg#17).

So the change protocol has a design and an owner. #989's scoping note ("chg is referenced, not
absorbed … the test-selection layer") under-describes chg; written against that note, this
epic would rebuild chg phase 2 inside loopctl a second time.

## 2. The split: what is chg and what is loopctl

chg's design already decided where its control plane lives (§5, "Control plane home"): a new
Phoenix app, **not loopctl**, because merges must not stop when loopctl does — "during this
research the KB timed out twice and then returned 503 `db_unavailable`" — and because Epic 45
lived inside loopctl's story lifecycle and died there. This PRD accepts that decision and draws
the line from it:

| concern | owner | why |
|---|---|---|
| Change, revision, event log | chg | its unit of change (`Change-Id` trailer, `refs/chg/<id>/<n>`) |
| Landing (the trunk CAS) | chg | availability: landing must not depend on loopctl |
| Pre-merge checks, verdict cache | chg | `chg check`, keyed by input fingerprint |
| Post-merge verification, `verified/master`, bisect, revert | chg | chg S8 |
| Review dispatch and the round ceiling | chg | chg §3.10; the counter moves server-side there |
| Conflict resolver | chg | chg §3.9 |
| Story, acceptance criteria, contract | **loopctl** | exists |
| Who may implement, review and verify a story (custody, lineage) | **loopctl** | exists; chg holds no custody model |
| The story's lifecycle stage and its audit trail | **loopctl** | exists (`Delivery.StageMachine`, audit chain) |
| Intake, triage, dispatch placement | **loopctl** | exists (Epic 44) |
| The review's intent payload: story, AC, KB hits | **loopctl supplies, chg assembles** | loopctl already serves each piece |

Two consequences shape every story below.

- **loopctl never blocks a landing.** chg lands on its own authority. loopctl records what
  landed, and gates the STORY (`verified`, `done`), never the trunk. A change that lands without
  a separated review leaves its story unverifiable; it does not leave trunk un-landed.
- **loopctl learns by events, not by polling GitHub.** chg's event log (`submitted`,
  `check_passed`, `review_findings`, `landed`, `verified`, `reverted`, …) is the source; a story
  bound to a change follows it.

## 3. Why this fares better than Epic 45

Epic 45 never carried a change: 0 `loop/` branches, infra stayed on PR squashes under thread
mode, and the Stage-1 runbook (KB `d3f3c6f0`) never ran. #989 names three causes. chg §8 names
four, and the split above inverts each one rather than retrying it:

1. **Runner-only.** Thread review arrived only over a runner's socket, so interactive sessions,
   where most work happens, stayed PR-shaped (#917 retrofitted half of it). chg serves the
   interactive session directly — `chg submit` is a CLI verb any session runs — and loopctl's
   half binds a story to a change whoever submitted it (47.1).
2. **No intake.** The pilot's intake was never wired, so nothing had to use threads. Here the
   change protocol does not wait on loopctl's intake at all: chg enrolls a repo and every change
   there goes through it. loopctl's stories are bound as they arrive.
3. **No forcing function.** The rulesets that would have closed the PR path were the last story
   and never ran. chg enrollment closes the old path by hook in the same PR that enrolls a repo,
   and loopctl's merge gate refuses the PR route for an intake source in `mode: :chg` (47.2).
4. **It removed no wait.** Actions still judged every checkpoint. chg phase 1 removes measured
   waits before any server exists, and every phase is accepted only on its baseline numbers.

loopctl's half is deliberately thin. Everything that could fail to be adopted is chg's, and
chg's adoption does not wait on anything here.

## 4. The binding: story ↔ change

A **change** may carry `story_id` (chg §3.2: "story_id (optional)"). loopctl's side:

- **`change_bindings`** (new table, RLS): `(tenant_id, story_id, repo, change_id)`, unique on
  `(tenant_id, repo, change_id)`. A story may bind several changes over its life (a revert, a
  re-submit); exactly one is CURRENT, the newest not superseded by a revert.
- A binding is created when chg reports `submitted` with a `story_id` the tenant owns. A
  `story_id` the tenant does not own is recorded as an unbound event and alerts; it never binds
  (no cross-tenant write through an id in a payload).
- **Who submitted is not custody.** The event's author session is informational. The
  implementer of record stays what the story already holds: `assigned_agent_id` and
  `implementer_dispatch_id`, set by `claim`. A change bound to a story whose claim the
  submitting session does not hold is recorded and flagged `submitter_not_claimant`; it does not
  re-anchor the story's implementer (that is the launder CLAUDE.md's custody section forbids).

## 5. Events in, stages out

chg-server delivers its event log to loopctl over a machine-called webhook,
`POST /api/v1/change_events/:source_id`. It is exempt from the MCP-tool rule as an internal
machine endpoint, like the runner socket. The source id is in the path for the same reason the
GitHub intake has `/intake/github/:source_id` (`router.ex:211`): the secret is found by id, never
by searching every tenant for a repo named in an unauthenticated body.

- **Authenticated** by an HMAC over the raw body plus a timestamp (replay window 5 min), keyed
  by a new per-intake-source `change_events_secret` (`Loopctl.Intake.Source`, encrypted like
  `webhook_secret`, which stays GitHub's and is not reused). An unknown source id, a revoked
  source and a bad signature return the same `401`. No API key, so no lineage: an event can
  move a stage loopctl already lets CONTROL move, and it can never perform a custody act.
- **Idempotent** on `(tenant_id, repo, change_id, event_seq)`. A redelivery returns `200` with
  `duplicate: true`.
- **Ordered per change** by `event_seq`. An event that arrives after a gap is stored and
  applied when the gap fills. A gap older than 10 min triggers a pull from chg
  (`events after N`): reconciliation, not trust in delivery.
- Every applied event is appended to the audit chain with the change id and sha.

**The stage mapping.** It uses the stages `Delivery.StageMachine` already has. The edges marked
new are control-only (never runner-reportable). `pr_open` is skipped: a chg change has no PR.

| chg event | edge | notes |
|---|---|---|
| `submitted` (any revision, n ≥ 1) | `implementing → reviewing`, `:forward` (exists) | each revision after `review_findings` re-enters review this way |
| `review_findings` | `reviewing → implementing`, `:review_findings` (exists) | |
| `review_approved` (`by: model` or `by: policy`) and `check_passed` on the same revision | `reviewing → ci`, **`:change_ready`** (new) | `ci` reads "ready to land". A policy auto-approval takes the same edge; §6 decides what it means for custody |
| `landed` | `ci → merged`, `:forward` (exists), `merge_sha` = the landing commit | chained, like every entry into `merged` |
| `verified` (the trunk verifier went green on a sha containing it) | none | recorded on the stage row as `trunk_verified_sha` |
| `deployed` | `merged → deployed`, `:forward` (exists) | |
| `reverted`, story at `merged` or `deployed` | `→ implementing`, **`:reverted`** (new) | see below |
| `reverted`, story at `verified` | `verified → escalated`, **`:reverted_after_verify`** (new) | see below |
| `reverted`, story at `done` | none | see below |

An event whose target stage is the row's current stage is recorded and applied as a no-op. One
example is a second `submitted` while review is still running on the first.

**`:reverted` is a retraction of a merge, and it is chained like `:merge_refused`.** It goes in
`@chained_edges`, and its `clears/3` clause clears `merge_sha` and the head- and release-keyed
fields exactly as `merge_refused` does (`stage_machine.ex:810`). Otherwise the chain keeps saying
the story merged, and a re-land records a second merge over a stale `merge_sha`. The edge is new
rather than a reuse of `:merge_refused` because the two claims differ: `merge_refused` says the
merge never held, and a revert says it held and was undone.

**After `verified` and `done`.** `done` is terminal by design. A revert that arrives after
`Delivery.Completion` closed the story is appended to the story's audit history. It then opens
a NEW story through the existing intake path: a GitHub issue on the repo carrying chg's failing
tests, fenced as untrusted text. That issue goes through triage like any other report. A
`verified` story is not yet closed, so it escalates over `:reverted_after_verify` and a human
decides.

**An event the machine does not allow** from the row's current stage escalates over a new
control-only edge, `:change_outside_lifecycle`, and the event is recorded. A `landed` on a story
an operator escalated is one example. This is the shape of `:merged_outside_ci` today: trunk
holds a change the story did not expect, and only a human can say what the story is now. Every
control escalation here goes through `Escalations.escalate_as_control/3`, which 47.4 adds
back with its own edges (§10).

## 6. Review custody

chg dispatches review as a headless `claude -p` job on a fleet host (chg#17, fact 3). For a
story-bound change, that reviewer's verdict must satisfy loopctl's review custody. If it does
not, the story cannot be verified.

- **chg-server's root.** The operator mints chg-server's key as a parentless orchestrator-role
  dispatch with the existing `POST /api/v1/dispatches`. Only the operator key may create a
  parentless dispatch; anyone else gets `403 root_dispatch_forbidden`. The intake source records
  that dispatch as `chg_root_dispatch_id`.
- **One child per review.** For each story-bound review, chg mints a CHILD dispatch, keyed by
  `(change_id, revision)`, and hands its ephemeral key to the job.
- **What loopctl checks for a chg-mode story.** `review_complete` is accepted only from a
  CHILD of the source's `chg_root_dispatch_id`. The root's own key, and any key outside that
  subtree, gets `409 chg_reviewer_required`. One child records one verdict.
  `review_records` gains a nullable `commit_sha`, which must name a revision of the story's
  current binding (`422 commit_sha_not_bound` otherwise). A verdict on revision 1 is then never
  read as covering revision 2. The existing gates (`exact_role: [:orchestrator, :user]`,
  `self_review_blocked`) run unchanged on top.
- **What this does NOT prove, stated so nobody reads more into it.** Every chg reviewer key sits
  under chg's root and outside every implementer's chain. The lineage gate therefore always
  passes a chg review, whoever ran the job. loopctl can prove only that chg-server minted the
  reviewer's key. It cannot prove the job ran apart from the implementer's session. That
  separation is chg-server's to construct: chg dispatches the job itself, onto a pool host, and
  never hands the key to the submitting session. chg-server is trusted here the way the
  delivery loop's orchestrator is trusted to place reviewers today. The trust is narrow:
  chg-server can REVIEW but can never implement or verify.
- **chg-server's keys never implement or verify.** `claim` is `exact_role: :agent`, and the
  orchestrator-role root cannot pass it. `verify_story`, `reject` and `verify_all` refuse any
  caller whose lineage root is a registered `chg_root_dispatch_id` with
  `409 chg_root_cannot_verify`. Without that refusal, one process would mint the reviewers and
  then verify the story they reviewed. The MCP rule (never hold implementer and reviewer keys in
  one process) holds for chg-server by construction.
- **Policy auto-approval** (chg §3.10: the `docs`, `comment-only` and `test-only` classes). The
  story reaches `ci` over `:change_ready` and lands like any other, because trunk policy is
  chg's. It then has no `review_records` row for its landed revision. loopctl escalates it from
  `merged` over a new control-only edge, **`:review_missing`**, and it is never verified. The
  default is deliberately the strict one (§9).

## 7. Verification reads `verified/master`

Story verification today reads CI evidence from the intake source (US-26.4.6), which is
PR-shaped. For a `mode: :chg` source it reads instead:

- the bound change's `landed` sha must be an ancestor of the repo's `verified/master` (compare
  API, by sha);
- no `reverted` event may follow it;
- a `review_records` row must exist whose `commit_sha` is the landed revision (§6).

The verifier is whoever verifies stories in the delivery loop today. `verify_story` keeps every
existing gate (exact `:orchestrator`, lineage, recorded separation) and adds §6's
`chg_root_cannot_verify`; only the CI-evidence input changes. A slow or failing compare answers
`unevaluated`/503 with `Retry-After`, never a pass.

## 8. Stories

| story | what | depends on |
|---|---|---|
| 47.1 | `change_bindings` and the binding rules (§4), with tenant isolation | — |
| 47.2 | Intake `mode: :chg` (beside `:pr`; #984 removes `:thread`): `change_events_secret`, `chg_root_dispatch_id`, and the merge gate refusing the PR route | — |
| 47.3 | `POST /change_events/:source_id`: HMAC, idempotency, per-change ordering, gap reconciliation (§5) | 47.1, 47.2, chg phase 2's event schema |
| 47.4 | The stage mapping, with the `:change_ready`, `:reverted` (chained), `:reverted_after_verify` and `:change_outside_lifecycle` edges and revert-after-done intake (§5) | 47.3 |
| 47.5 | Review custody for chg-dispatched reviews: the chg-reviewer check, `review_records.commit_sha`, `:review_missing`, `chg_root_cannot_verify` (§6) | 47.2, 47.4 |
| 47.6 | Story verification from `verified/master` (§7) | 47.4, 47.5 |
| 47.7 | MCP: `change_binding_get`, plus `mode: chg`, the events secret and the chg root in `intake_source_enroll` / `intake_source_update` | 47.1, 47.2 |
| 47.8 | Pilot on the first repo that chg phase 2 enrolls and that has a loopctl intake source | all |

47.1 and 47.2 can start now. 47.3 starts when chg phase 2 publishes its event schema
(mkreyman/chg#33 states what loopctl expects). No story in this epic writes chg code: anything
chg must change is filed on mkreyman/chg.

## 9. Decisions Mark may overrule

| default | where to overrule | effect of overruling |
|---|---|---|
| The change protocol lives in chg-server, not loopctl (chg design §5, §10) | here, or chg `docs/design.md` §10 | loopctl absorbs chg phase 2: this epic grows to ledger + lander + review dispatch, and landing inherits loopctl's outages |
| An auto-approved story-bound change escalates `review_missing` rather than verifying | 47.5 | a story could reach `verified` with no reviewer, which is a custody gap |
| `reverted` returns the story to `implementing`, keeping its claim; after `done` it opens a new story through intake | 47.4 | alternative: release to `queued` for a fresh dispatch |

## 10. Keep / delete verdict on every piece #984 lists

#984's rule: anything that serves more than threads stays. Since the change protocol is chg's,
no thread mechanism is reused by this epic; what stays, stays because something outside threads
calls it today.

| piece (#984) | verdict | why |
|---|---|---|
| Thread ledger: `lib/loopctl/threads.ex`, `threads/*`, tables `thread_checkpoints`, `thread_entries`, `thread_reviews`, `thread_issue_links` | **delete** | Only thread code calls it. chg keeps its own append-only event log in its own database (chg §3.2); 47.1's bindings and 47.3's event rows are loopctl's whole record of a change. The ledger's design survives as prior art: per-key idempotency that refuses a reused key with different content (`threads.ex:1609-1657`) is the rule 47.3 applies to `event_seq` |
| CAS squash merge executor: `merge_executor.ex`, `merge_forge.ex`, `github_app_merge_forge.ex`, `merge_message.ex`, `ThreadMergeWorker`, `ThreadMergeSweepWorker` | **delete** | `MergeExecutor.run/3` is called only by `thread_merge_worker.ex:51`. Landing is chg's (§2), and chg's lander does the same CAS with `merge-tree` + an ff-only push and the same lost-ack recovery by trailer reachability (chg §3.6 step 5) |
| `Loopctl-Story:` trailer | **delete with the executor** | chg writes `Change-Id:`; a story is found from its binding (47.1), not from trunk |
| Checkpoint-bound findings with `introduced_by`, `Reviews` rules, `RunnerReviews`, `thread_review_controller.ex`, `ReviewCeilingWorker`, `Placement.place_review/4`, the `:review_ceiling` edge, the `review` dispatch kind | **delete** | No callers outside threads. The round ceiling moves into chg (chg §3.10: one round plus an interdiff re-review). loopctl keeps only what custody needs: `review_records`, which predates Epic 45 and gains `commit_sha` in 47.5 |
| `Escalations.escalate_as_control/3` | **delete** (amended in #984) | It hard-coded `:review_ceiling`, the one control edge, which goes with `ReviewCeilingWorker`; kept, it could only be called with an edge the machine refuses. What 47.4 and 47.5 need is the replay and `:stale_stage` recovery `escalate/3` already has, minus the claimant check: 47.4 re-adds the function taking its edge (`:change_outside_lifecycle`, and 47.5's `:review_missing`) together with the edges themselves |
| `merge_precondition.ex` thread branch, `checkpoint_source.ex`, thread refusals (`empty_change`, `checkpoint_tree_mismatch`, `no_checkpoint_recorded`, `branch_*`, `base_update_in_flight`) | **delete the branch, keep the module** | The PR-mode gate is the delivery loop's live merge gate (`merge_precondition_controller.ex:414`, MCP `merge_precondition`) and `transient?/1` is shared by verification, `IssueCloser` and post-deploy verification. 47.2 adds the `:chg` refusal to the same module |
| `ci_evidence.ex`, `empty_change.ex`, `ci_definition.ex`, `intake_sources.required_checks` | **keep** | Story verification uses them in both modes (`verification/github_actions.ex:51,81,116-148`, `verification/ci_target.ex:98`) |
| Stage machine thread edges: `:base_updated`, `:merged_outside_ci`, `:review_ceiling`, `claimant_reportable?/3`; `Stages.follow_base_update/4`, `last_allow_query/2` | **delete** | Thread-only. 47.4 adds `:reverted` and `:change_outside_lifecycle`; `:change_outside_lifecycle` is the same idea as `:merged_outside_ci` and is written fresh against the chg event |
| Interactive thread claims: `claim_route.ex`, `interactive_claims.ex`, table `claim_routes`, `runner_dispatches` route columns, the thread route in `dispatch_payload.ex` | **delete** | US-45.9 machinery. A chg-mode story needs no route: the session runs `chg submit`, and the binding comes from the event |
| `runner_threads.ex`, `runner_thread_session.ex`, runner socket `checkpoint`/`thread_entry`/`review_finding`/`review_verdict` messages | **delete**, contract major bump | chg's review jobs report to chg, and loopctl hears through 47.3 |
| `thread_live.ex`, `thread_http.ex`, `thread_controller.ex`, `/threads` routes | **delete** | Criterion 4 is met through `change_binding_get` and story history (47.7), not a page |
| Browser login: `BrowserAuth`, `LoginLive`, `BrowserSessionController`, `RequireBrowserSession`, `web_authn/browser_login.ex`, tables `browser_sessions`, `webauthn_login_challenges` | **delete** | Its only consumer is the thread page. WebAuthn enrollment at signup (the L0 anchor) is separate and stays |
| `thread_*` MCP tools, `mcp-server/lib/threads.js`, `test/threads_tool.test.js`, thread mode in `claim_story` and intake-source tool text | **delete** | Their endpoints go |
| `intake_sources.mode` | **keep the column, drop `:thread`** | 47.2 adds `:chg` to the same enum |
| `forge.ex`, `forge_outbox.ex` | **keep** | Used by intake, verification credentials and `Intake.IssueClosures` |
| `loopctl-merge` GitHub App (id 5101362), Fly secrets `GITHUB_APP_ID`/`GITHUB_APP_PRIVATE_KEY` | **loopctl stops using it; do not delete the App in #984** | Nothing in loopctl but the executor reads it. chg's enrollment needs exactly such an App as trunk's only pusher (chg §3.6), so the App goes to chg phase 2 to adopt (re-key into chg-server) or delete; filed as mkreyman/chg#33. #984 removes the two Fly secrets and their `deploy/FLY_SECRETS.md` rows |
| infra `.loopctl/mode`, `loop/**` CI trigger, thread-only rulesets; loopctl-runner `review_prompt.ex`, `loop-push`, thread dispatch | **delete** (in those repos) | Thread-only. infra's master ruleset 24087505 names App 5101362 as its only bypass; that bypass goes when the App leaves loopctl (PR merges are unaffected, since the ruleset still admits them) |

## 11. Success criteria (from Epic 45's, restated for the split)

On the pilot repo, 20 consecutive story-bound changes:

1. Every one reaches `merged` from a chg `landed` event, with no PR and no stage written by hand.
2. Zero stale-head or superseded-CI incidents. A landing is one sha by construction.
3. Every story's review custody record names a child of the registered chg root, bound to the
   landed revision's sha, or the story escalated `review_missing`; no chg-rooted key verified
   any of them.
4. Mark can read a story's whole path — submit, review findings, landing, verification, any
   revert — from `change_binding_get` (47.7) or the story history, without GitHub.
5. No trunk update by any actor but chg's App, which chg's enrollment enforces and its pilot
   proves.

## 12. Failure design (SOUL rule 9)

- **Partition, chg ↔ loopctl:** chg lands regardless; events queue in chg's outbox and are
  redelivered; loopctl pulls on a gap. The only thing a partition delays is a story's stage.
- **State:** trunk and `verified/master` are GitHub's; changes and events are chg's Postgres;
  bindings, stages and custody are loopctl's under RLS. Each side rebuilds its view of the other
  from the event log (`event_seq` from 1).
- **Retries:** events are idempotent on `(repo, change_id, event_seq)`; binding creation is
  unique on `(repo, change_id)`; review dispatch minting is keyed by `(change_id, revision)`.
- **Slow, not down:** the webhook answers within its own DB transaction and never calls out;
  verification's compare call is bounded and answers `unevaluated` on timeout.
- **Where the unit runs:** event application runs in the request (or an Oban job for gap
  reconciliation, unique per change); chg's review job runs on a fleet host and is reached only
  through chg.
