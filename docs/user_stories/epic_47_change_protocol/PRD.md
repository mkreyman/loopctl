# PRD — Epic 47: loopctl's half of the modified-Scion change protocol

**Status:** draft 2026-10-18 · **Epic:** 47 · **Issue:** mkreyman/loopctl#989
**Succeeds:** Epic 45 (`../epic_45_change_threads/PRD.md`), deleted by #984.
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
   and loopctl's merge gate refuses the PR route for an intake source in `mode: :chg` (47.5).
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

chg-server delivers its event log to loopctl over a machine-called webhook
(`POST /api/v1/change_events`, exempt from the MCP-tool rule as an internal machine endpoint,
like the runner socket):

- **Authenticated** by an HMAC over the raw body plus a timestamp (replay window 5 min), keyed
  by a new per-intake-source `change_events_secret` (`Loopctl.Intake.Source`, encrypted like
  `webhook_secret`, which stays GitHub's and is not reused). No API key, so no lineage:
  an event can move a stage loopctl already allows CONTROL to move, never perform a custody act.
- **Idempotent** on `(tenant_id, repo, change_id, event_seq)`. A redelivery is `200` with
  `duplicate: true`.
- **Ordered per change** by `event_seq`. An event arriving ahead of a gap is stored and applied
  when the gap fills; a gap older than 10 min triggers a pull (`GET /changes/:id/events?after=`
  on chg) — reconciliation, not trust in delivery.
- Every applied event is appended to the audit chain with the change id and sha.

The stage mapping, onto the stages `Delivery.StageMachine` already has:

| chg event | stage edge | notes |
|---|---|---|
| `submitted` (first revision) | `implementing → reviewing` | `pr_open` is not entered; the PR stage has no meaning here |
| `review_findings` | `reviewing → implementing` over `:review_findings` (exists) | |
| `check_passed` + review approved | `reviewing → ci` | `ci` reads "ready to land" |
| `landed` | `ci → merged`, `merge_sha` = the landing commit | |
| `verified` (trunk verifier green on a sha containing it) | recorded on the stage as `trunk_verified_sha`; no edge | |
| `deployed` | `merged → deployed` | |
| `reverted` | `merged | deployed → implementing` over **`:reverted`** (new edge, control-only) | not `:merge_refused`, which asserts the merge never held |

`deployed → verified` stays `Delivery.PostDeployVerification`'s, unchanged. `verified → done`
stays `Delivery.Completion`'s.

A stage event that the machine does not allow from the row's current stage (a `landed` for a
story an operator escalated, say) is recorded and escalated `:change_outside_lifecycle`, the
same shape as `:merged_outside_ci` today: trunk holds a change the story did not expect, and
only a human can say what the story is now.

## 6. Review custody

chg dispatches review as a headless `claude -p` job on a fleet host (chg#17, fact 3). For a
story-bound change, that reviewer's verdict must satisfy loopctl's review custody, or the story
cannot be verified.

- **chg-server holds one loopctl key**: an orchestrator-role key minted by the tenant operator
  as its own ROOT dispatch (`POST /api/v1/dispatches` with no parent — only the operator key
  may, `403 root_dispatch_forbidden` otherwise). For each story-bound review it mints a CHILD
  dispatch with a review-scoped ephemeral key and hands that key to the job.
- The review job records its verdict through the existing `review_complete`
  (`exact_role: [:orchestrator, :user]`). `review_records` gains a nullable `commit_sha`, set
  for a chg review to the revision it read, so a verdict on revision 1 is never read as covering
  revision 2. The lineage
  gate is unchanged: a reviewer on the implementer's chain is `409 self_review_blocked`. Because
  chg's lineage root is separate from every implementer's, a chg reviewer passes, and an
  implementer that tried to review its own change through chg would not — the gate reads the
  key, not the claim.
- **A change that lands with no recorded review for a story-bound change** (policy class
  `docs`/`comment-only`/`test-only` auto-approves, chg §3.10) leaves the story at `merged` with
  `review_missing`. Auto-approval is chg's trunk policy; a story's custody still needs a
  reviewer, so loopctl escalates rather than inventing one. The default here is deliberately the
  strict one (§9).
- **Never** let chg-server's key implement: it is orchestrator-role (`claim` is
  `exact_role: :agent`), and the MCP rule "never both implementer and reviewer keys in one
  process" holds for chg-server by construction.

## 7. Verification reads `verified/master`

Story verification today reads CI evidence from the intake source (US-26.4.6), PR-shaped. For a
chg-enrolled source it reads instead:

- the bound change's `landed` sha is an ancestor of the repo's `verified/master` (compare API,
  by sha), and
- no `reverted` event after it.

`verify_story` keeps every existing gate (exact `:orchestrator`, lineage, recorded separation);
only the CI-evidence input changes. A slow or failing compare answers `unevaluated`/503 with
`Retry-After`, never a pass.

## 8. Stories

| story | what | depends on |
|---|---|---|
| 47.1 | `change_bindings` + binding rules (§4), tenant isolation | — |
| 47.2 | `POST /change_events`: HMAC, idempotency, per-change ordering, gap reconciliation (§5) | 47.1, chg phase 2 event schema |
| 47.3 | Stage mapping, the `:reverted` and `:change_outside_lifecycle` edges (§5) | 47.2 |
| 47.4 | Review custody for chg-dispatched reviews: the chg root, child review dispatches, `review_missing` (§6) | 47.1 |
| 47.5 | Intake source `mode: :chg` (beside `:pr`; #984 removes `:thread`): the merge gate refuses the PR route for it; story verification reads `verified/master` (§7) | 47.3 |
| 47.6 | MCP: `change_binding_get` (a story's changes and their events), and `mode: chg` plus the events secret in `intake_source_enroll`/`intake_source_update` | 47.1, 47.5 |
| 47.7 | Pilot on the first repo chg phase 2 enrolls that has a loopctl intake source | all |

47.1 and 47.4 can start now; 47.2 starts when chg phase 2 publishes its event schema. The
epic's stories never write chg code: anything chg must change is filed on mkreyman/chg.

## 9. Decisions Mark may overrule

| default | where to overrule | effect of overruling |
|---|---|---|
| The change protocol lives in chg-server, not loopctl (chg design §5, §10) | here, or chg `docs/design.md` §10 | loopctl absorbs chg phase 2: this epic grows to ledger + lander + review dispatch, and landing inherits loopctl's outages |
| An auto-approved story-bound change escalates `review_missing` rather than verifying | 47.4 | a story could reach `verified` with no reviewer, which is a custody gap |
| `reverted` returns the story to `implementing`, keeping its claim | 47.3 | alternative: release to `queued` for a fresh dispatch |

## 10. Keep / delete verdict on every piece #984 lists

#984's rule: anything that serves more than threads stays. Since the change protocol is chg's,
no thread mechanism is reused by this epic; what stays, stays because something outside threads
calls it today.

| piece (#984) | verdict | why |
|---|---|---|
| Thread ledger: `lib/loopctl/threads.ex`, `threads/*`, tables `thread_checkpoints`, `thread_entries`, `thread_reviews`, `thread_issue_links` | **delete** | Only thread code calls it. chg keeps its own append-only event log in its own database (chg §3.2); 47.1's bindings and 47.2's event rows are loopctl's whole record of a change. The ledger's design survives as prior art: per-key idempotency that refuses a reused key with different content (`threads.ex:1609-1657`) is the rule 47.2 applies to `event_seq` |
| CAS squash merge executor: `merge_executor.ex`, `merge_forge.ex`, `github_app_merge_forge.ex`, `merge_message.ex`, `ThreadMergeWorker`, `ThreadMergeSweepWorker` | **delete** | `MergeExecutor.run/3` is called only by `thread_merge_worker.ex:51`. Landing is chg's (§2), and chg's lander does the same CAS with `merge-tree` + an ff-only push and the same lost-ack recovery by trailer reachability (chg §3.6 step 5) |
| `Loopctl-Story:` trailer | **delete with the executor** | chg writes `Change-Id:`; a story is found from its binding (47.1), not from trunk |
| Checkpoint-bound findings with `introduced_by`, `Reviews` rules, `RunnerReviews`, `thread_review_controller.ex`, `ReviewCeilingWorker`, `Placement.place_review/4`, the `:review_ceiling` edge, the `review` dispatch kind | **delete** | No callers outside threads. The round ceiling moves into chg (chg §3.10: one round plus an interdiff re-review). loopctl keeps only what custody needs: `review_records`, which predates Epic 45 and gains `commit_sha` in 47.4. `Escalations.escalate_as_control/3` exists only for this worker and goes with it |
| `merge_precondition.ex` thread branch, `checkpoint_source.ex`, thread refusals (`empty_change`, `checkpoint_tree_mismatch`, `no_checkpoint_recorded`, `branch_*`, `base_update_in_flight`) | **delete the branch, keep the module** | The PR-mode gate is the delivery loop's live merge gate (`merge_precondition_controller.ex:414`, MCP `merge_precondition`) and `transient?/1` is shared by verification, `IssueCloser` and post-deploy verification. 47.5 adds the `:chg` refusal to the same module |
| `ci_evidence.ex`, `empty_change.ex`, `ci_definition.ex`, `intake_sources.required_checks` | **keep** | Story verification uses them in both modes (`verification/github_actions.ex:51,81,116-148`, `verification/ci_target.ex:98`) |
| Stage machine thread edges: `:base_updated`, `:merged_outside_ci`, `:review_ceiling`, `claimant_reportable?/3`; `Stages.follow_base_update/4`, `last_allow_query/2` | **delete** | Thread-only. 47.3 adds `:reverted` and `:change_outside_lifecycle`; `:change_outside_lifecycle` is the same idea as `:merged_outside_ci` and is written fresh against the chg event |
| Interactive thread claims: `claim_route.ex`, `interactive_claims.ex`, table `claim_routes`, `runner_dispatches` route columns, the thread route in `dispatch_payload.ex` | **delete** | US-45.9 machinery. A chg-mode story needs no route: the session runs `chg submit`, and the binding comes from the event |
| `runner_threads.ex`, `runner_thread_session.ex`, runner socket `checkpoint`/`thread_entry`/`review_finding`/`review_verdict` messages | **delete**, contract major bump | chg's review jobs report to chg, and loopctl hears through 47.2 |
| `thread_live.ex`, `thread_http.ex`, `thread_controller.ex`, `/threads` routes | **delete** | Criterion 4 is met through `change_binding_get` and story history (47.6), not a page |
| Browser login: `BrowserAuth`, `LoginLive`, `BrowserSessionController`, `RequireBrowserSession`, `web_authn/browser_login.ex`, tables `browser_sessions`, `webauthn_login_challenges` | **delete** | Its only consumer is the thread page. WebAuthn enrollment at signup (the L0 anchor) is separate and stays |
| `thread_*` MCP tools, `mcp-server/lib/threads.js`, `test/threads_tool.test.js`, thread mode in `claim_story` and intake-source tool text | **delete** | Their endpoints go |
| `intake_sources.mode` | **keep the column, drop `:thread`** | 47.5 adds `:chg` to the same enum |
| `forge.ex`, `forge_outbox.ex` | **keep** | Used by intake, verification credentials and `Intake.IssueClosures` |
| `loopctl-merge` GitHub App (id 5101362), Fly secrets `GITHUB_APP_ID`/`GITHUB_APP_PRIVATE_KEY` | **loopctl stops using it; do not delete the App in #984** | Nothing in loopctl but the executor reads it. chg's enrollment needs exactly such an App as trunk's only pusher (chg §3.6), so the App goes to chg phase 2 to adopt (re-key into chg-server) or delete; filed as mkreyman/chg#33. #984 removes the two Fly secrets and their `deploy/FLY_SECRETS.md` rows |
| infra `.loopctl/mode`, `loop/**` CI trigger, thread-only rulesets; loopctl-runner `review_prompt.ex`, `loop-push`, thread dispatch | **delete** (in those repos) | Thread-only. infra's master ruleset 24087505 names App 5101362 as its only bypass; that bypass goes when the App leaves loopctl (PR merges are unaffected, since the ruleset still admits them) |

## 11. Success criteria (from Epic 45's, restated for the split)

On the pilot repo, 20 consecutive story-bound changes:

1. Every one reaches `merged` from a chg `landed` event, with no PR and no stage written by hand.
2. Zero stale-head or superseded-CI incidents. A landing is one sha by construction.
3. Every story's review custody record names a chg-minted reviewer lineage separate from its
   implementer's, or the story escalated `review_missing`.
4. Mark can read a story's whole path — submit, review findings, landing, verification, any
   revert — from `change_binding_get` or the story history, without GitHub.
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
