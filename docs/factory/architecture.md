# Factory control plane: product requirements

This is the one design document for Epic 52 (loopctl#1069). It collects every decision Mark made
in the 2026-11-19 design conversation (a chg session on minis, plus the amendments posted on
#1069), with his words quoted where they set a requirement. The stories that build it live under
`docs/user_stories/epic_52_factory_control_plane/`. Where a story and this document disagree,
this document wins and the story is fixed.

## 1. Problem

The factory is the set of parts that takes a problem from report to merged, deployed and verified
code:
- loopctl (the server);
- loopctl-runner (headless sessions on the fleet);
- chg (the verification gate);
- claude-config's delivery-loop hooks, skills and scripts;
- infra's CI runner provisioning;
- fleet_dash (Mark's dashboard).

One factory change on 2026-11-19 had to cross five repos. Every defect seen that day came from
two copies of one fact disagreeing:

- **One piece of work, four copies.** chg#77 existed as a GitHub issue, a channel handoff, a
  loopctl story and an escalation, each with its own done state. Closing the handoff and the issue
  left the story "parked · triage_escalated" in fleet_dash for 13 hours.
- **One repo, two channels.** chg had the kb scope `chg` and the work project `chg-delivery`.
  loopctl#1065 posted escalation handoffs on `chg-delivery`, and claude-config's
  `gate-channel-claim-scope.sh` refused claims there (loopctl#1067).
- **Rules in three places.** The same rule lived as prose (CLAUDE.md, SOUL.md), as a shell hook
  (claude-config) and as a server check (loopctl), and nothing checked that they agreed.
- **No coordinated release and no end-to-end test.** loopctl#1065 shipped working in loopctl and
  broken against a claude-config hook. Only Mark's own look at fleet_dash caught it.
- **Intake did not re-check.** chg#77 and chg#66 had been fixed weeks earlier (by chg#87 and
  chg#69), and still went through triage and escalation.
- **One identity for every session.** Every fleet session authenticates as one `agent_id`, so a
  second session's `channel_claim` on a held handoff succeeds silently (KB finding `0264d7e0`,
  loopctl#707).
- **CI hosts carried state between jobs.** A stale Mix build-lock file from a killed job hung later
  jobs for 600 s (chg#119).

Mark:

> The factory is just a way for me to automate managing all my other projects. The factory is NOT
> the product, though it keeps taking a lot of my time and effort make it work the way I want it
> to. Ideally though, it IS just another product that keeps improving itself.

> As much this machinery must be moved to loopctl itself as we can. Or at least under the
> loopctl's repo, so I don't have to keep juggling handoffs between several different repos to
> achieve an improvement or implement a new feature in the factory.

> [Can you still hold the system in your head?] Only on a very shallow level. And this is why I
> want it in one place, not spread out.

> A good architecture solves many of these issues. A good test suite keeps it on track.

## 2. Goals and non-goals

**Goals:**
- One record per piece of work.
- One project and one channel per repo.
- All work state in loopctl.
- Work moves freely between holders and machines, and between Mark's sessions and the loop only
  when he says so.
- Sessions coordinate through loopctl, simply and without losing messages.
- Mark sees every part of the flow and can intervene anywhere, but nothing waits for him.
- The factory's parts live in the loopctl repo, release together, and are proven by one
  end-to-end suite.
- loopctl's source becomes private while its MCP stays public (R12). It is in this PRD because
  the factory moves into this repo (R10), so the move changes how every factory part installs and
  where its CI runs.

**Non-goals:**
- Moving fleet_dash. It stays its own repo (`mkreyman/fleet_dash`) and reads loopctl as one of
  its sources (Mark, 2026-11-19).
- Moving claude-config's personal half: SOUL.md, USER.md, marketing, learning and KB-mining skills,
  and general hygiene hooks. Mark: "Let's move only the factory part of it. At least for now."
- Running work in Claude cloud sessions today. Mark: "The current claude cloud is still not a good
  fit for what I do, but who knows the future." The design must not prevent it (R3).
- A replicated database before the first incident (R9).
- Replacing GitHub Actions as CI's trigger and check of record.

## 3. The model: five concepts

1. **Work item.** Exactly one record per piece of work. **The work item is the loopctl story,
   generalized**: the stories table already carries the stage machine
   (`Loopctl.Delivery.StageMachine`), the claim with its lease and fence, and the escalation. It
   gains the parts the other copies held. A GitHub issue, a handoff and an escalation stop being
   separate records: an issue is linked to its story through the intake record, a handoff is a
   move of a story (R2, R3), and an escalation is a stage of the story. Keyed by `<repo>#<issue>`
   when an issue exists, else by a slug.
2. **Holder.** Whatever currently holds a work item's claim. A holder is one session: a headless
   runner session, or one of Mark's interactive sessions, on any machine, or later in a cloud
   session. Holders are disposable.
3. **Gate.** chg is the factory's verification engine. Its source moves into the loopctl repo
   (R10).
4. **Policy.** Every rule is decided once, on the server. Hooks and prose in harness files are
   generated from that policy, or are thin calls to it.
5. **Views.** fleet_dash, GitHub issue comments and channel headlines are projections of the event
   log. Mark's interventions are events in the same log.

Every state change of a work item is one row in an append-only event log, with its actor and its
reason. The log extends the existing stage-event rows and the audit chain. It is not a parallel
store.

## 4. Refactor what exists; never build beside it

Mark: "remember, the existing concepts will have to serve the new functionality. So, refactoring
-- not cementing old."

Every new capability is built by changing an existing loopctl concept until it serves the new
role. A parallel concept is never built beside the old one. A release that replaces a mechanism
deletes the old one in that same release, migrating its rows. It never leaves two paths running,
a compatibility shim or a deprecation window (CLAUDE.md, "Delete what is dead"). The only
exception is the wire contract with clients in the field: there the server accepts the previous
client version for one release (R7).

| existing concept | becomes | release |
|---|---|---|
| `stories` + `story_stages` (stage machine, claim, lease, fence, escalation) | the work item: gains plan, notes, decisions, open questions, branch, head and holder (release 3). Interactive work on a branch opens an item in release 3; release 7 adds starting and pulling one, and the rule that the loop never takes an interactive item | 3, 7 |
| stage events + audit chain | the work item's event log (actor and reason on every event) | 3 |
| `escalated` ("parked for a human") | "needs a different holder"; resolvable by any other holder or the sweep | 5 |
| `channel_claims` + `channel_claim`/`channel_done`/`channel_release` | deleted: claiming a work item is the story claim; open claims migrate to stories | 7 |
| `handoff:` key prefix, `handoff` MCP tool, escalation handoffs (#1065, #1067) | deleted with the move verb that replaces them: a handoff is a move of a work item | 7 |
| `channel_posts` | messages: one attachment (item, session or channel), retention by attachment, cursor reads | 4 |
| `channel_lock` soft-locks: today `channel_posts` rows under the reserved `claim:` key with a TTL of at most 3600 s (`lib/loopctl/coordination/channel_post.ex:137-144`) | same tool and behaviour; the rows are not messages, so release 4 moves them out of `channel_posts` before that table becomes the message store, and the release-4 story names where they go | 4 |
| `channel_posts` `key` slots (one working-state slot per agent, session and key) | folded into the work item's notes (R1), except `handoff:<anchor>` slots: a handoff is a keyed post whose key is its dedupe slot and its claim ref (`lib/loopctl/coordination.ex:725-760,3653-3740`), so those keep their key, their keyed-slot unique index and today's 30-day retention until release 7 deletes them with the handoff mechanism | 4, 7 |
| `agents` (one shared agent per fleet) | the account that holds keys; per-session holders hang off it | 3 |
| dispatch custody (lineage, credentials, `claim_epoch`) | the basis of holder identity: an interactive session gets a holder credential the way a dispatch gets one today | 3 |
| `runners` + the runner socket | the host daemon's registration and socket: delivers to idle sessions (release 4), then reports capacity and owns the machine's GitHub Actions runner pool, absorbing infra's CI runner provisioning (release 7) | 4, 7 |
| intake records and intake sources | the link between a work item and its GitHub issue; intake gains the re-check step | 6 |
| Gate B `human_paths` | `independent_paths`, with the self-deploy refusal's replacement | 2 |
| resolve's `role: :user` plug (`story_escalation_controller.ex:43`) | `role: :agent`, so every holder and fleet_dash's user key pass; a holder's resolution takes one new edge, `escalated -> queued`, refused to the holder that escalated (`self_resolve_blocked`, a check release 5 builds: none exists today). The intervention verbs (R4) are separate control edges of their own (`:retriage`, `:cancelled`, `:closed`), and the sweep's final close takes `:holders_exhausted` | 5 |
| the self-deploy refusal (`{:self_deploy_excluded, repo}`, `merge_precondition.ex:70-99,278`), which escalates every agent merge into loopctl and claude-config to a human because a loopctl merge redeploys the control plane and cannot report its own outcome | deleted in release 2, the first release whose changes all merge into loopctl. A self-modifying merge needs R4's independent verification instead, and every green merge still deploys (KB decision `4d3fd7bb`: no change-detection skip). Its outcome is recorded after the restart by a reconcile step that reads the merged PR and the deploy's health, so no human merges by hand | 2 |
| the `:human_resolution` edges, which want a `:user` key no dispatch minted (`Stages.human_gate/2` and `human?/1`, `stages.ex:2137-2148`) | unchanged and human-only, because other code reads them as "a human decided": a re-queue over one clears Gate A with no triage (`gate_a_input.ex:15-21`, `merge_precondition.ex:732-740`), `escalated -> done` over one closes an item with no verdict (`stage_machine.ex:700`), and `Loopctl.Agents.Spec` refuses any spec naming one (`spec.ex:361,658`). Nothing waits on them: a holder re-queue runs Gate A triage again, and a `:review_missing` hold (`stage_machine.ex:122-127`) leaves `escalated` over the new edge only once an independent holder has recorded the chg review for the landed revision, which `ReviewCustody.ensure_landed_review/3` still requires before verify; judge and draft specs may not name the new edge either | 5 |
| `Loopctl.Delivery.RetryCeiling` + the `:attempts_exhausted` edge | the attempt count before an item escalates to a different holder (R4); `DISPATCH_MAX_ATTEMPTS` keeps having no default | 5 |
| SessionStart TEAM CHANNEL block | the session's inbox read at start, which until release 7 also lists the repo's open `handoff:` posts | 4 |
| `orchestrator_state` | checked in release 3: whatever duplicates work-item state is folded in or deleted | 3 |
| knowledge plane | unchanged | — |

Each story names the existing modules it changes and the ones it deletes. A story that adds a
table, context or tool must say which existing one could not serve, and why.

## 5. Design principles borrowed from Erlang/OTP

OTP already solved most of this problem, so the factory copies it where it fits.

| OTP | Factory |
|---|---|
| A process owns its state and shares nothing | A holder owns its work item's claim, and works in its own worktree |
| One mailbox per process | One inbox per session (R11) |
| Location transparency: send to a pid on any node | Send to a session on any machine, without knowing which (R11) |
| Registered names: send to a name, not a pid; a second registration fails | Send to a work item and it reaches whoever holds it now; a second claim is refused (R3) |
| Monitors: a watcher gets `:DOWN` when a process dies | loopctl sees a holder stop renewing its lease and acts on it |
| Supervisors and "let it crash" | The loop places the item on another holder; nobody nurses a failed session |
| Restart intensity, then escalate to the parent supervisor | After `DISPATCH_MAX_ATTEMPTS` failed attempts (`RetryCeiling`), escalate to a stronger holder, never to Mark (R4) |
| Prefer cast; peers do not block on each other with `call` | Sessions coordinate through work item state; no session blocks waiting on another's reply |
| Ordering per sender only | Messages from one sender to one inbox arrive in order; nothing more is promised |
| GenStage demand | Host daemons report free slots, and loopctl places work only where there is room (R3) |
| Hot code upgrade, old and new code side by side | Every client works with the server's previous version, and the reverse (R7) |
| The supervision tree is the architecture | loop → repo → work item → holder |
| `:sys.get_state`, `:observer` | Any work item's state, history and inbox can be read at any time (R4) |

What the factory does NOT copy:
- **Unreliable delivery.** Erlang drops a message to a dead process or across a network split.
  Here every message is stored before it is delivered (R11).
- **A full mesh between nodes.** loopctl is the hub.

## 6. Requirements

### R1. All work state lives in loopctl

Mark: "the state should still live on loopctl".

- A work item carries its plan, its progress notes, its decisions, its open questions, its holder,
  its stage, its linked branch and its pushed head.
- A holder checkpoints to the item while it works: what it did, what is next, and the head it
  pushed. Taking an item over means reading its record and checking out that head. It never means
  reconstructing state from a branch, a transcript or a prose handoff.
- Uncommitted work travels through loopctl. A move ships the holder's working-tree diff with the
  move, and the next holder applies it. Moving at any stage never forces a premature commit. A
  runner session holds no API key of its own (`placement.ex:78-94`) and the runner socket caps a
  frame at 64,000 bytes (`endpoint.ex:73`), so a runner's diff travels as socket parts.
- Git holds code only. Sessions, the per-machine memory directory and local files hold copies
  only, never the record.

### R2. Mark moves work in and out of his sessions, at any stage, and only Mark

Mark: "There's still a lot of ad-hoc work that I have to do. The system must support either, as
well as moving in and out at any stage -- at my will, not at agent's whim!!!"

- Ad-hoc work in an interactive session is a work item too. It is created when the session starts
  work on a branch, so fleet_dash shows it.
- A move between one of Mark's interactive sessions and the loop happens only on Mark's explicit
  act. There are two paths:
  - fleet_dash, under his user key;
  - a slash command he types in that session. The harness turns his typed command into a one-shot
    grant, and the move tool refuses a boundary move without one.
- A runner never pushes work into Mark's session. Mark's session never hands its work to the loop
  on its own.
- Inside the loop, holders hand items to each other freely, because that is scheduling and does
  not need his attention.
- Until release 7 builds the boundary, an interactive session's item whose lease lapses is
  released through the normal paths, as every claim is today.
- The interactive-boundary move is the only act reserved for Mark, and it is reserved because he
  asked for it. R4's "nothing reserved for Mark" covers everything else, including whether a PR
  at the review-round ceiling gets a redesign (Mark, 2026-11-19: "let the loop decid[e]"). At the
  ceiling the session decides whether to dispatch a redesign or narrow what merges; nothing waits
  and nothing messages Mark.

### R3. Location independence and one identity per session

Mark: "each one of [my dev machines] can also serve as a ci host ... the work should be able to
move in and out, including moving between machines as well as, potentially, to cloud sessions."
And: "I also routinely work on the same machine for the same repo on multiple issues (using
worktrees, of course)."

- **Each session is its own holder.** A session gets a server-minted holder identity when it
  starts (bound to its session id, its host and its worktree). It holds claims in its own name.
  Any number of sessions run on one machine, for one repo or many, each in its own worktree on its
  own item.
- **A second claim is refused.** A claim on a held item by any other holder is refused, whatever
  `agent_id` both share. This closes the shared-identity defect (loopctl#707).
- **A holder's whole working set comes from three places:** loopctl, the git remote, and secrets
  loopctl issues.
- **The cloud test.** Any step a cloud session could not do depends on hidden local state, and that
  is a design bug even while no cloud session runs. Today that covers:
  - the per-machine memory directory;
  - `.claude/gate.lock`;
  - ssh-based `session-message.sh`;
  - session scratchpads;
  - local review-round state.
- **Moving is one verb.** "Move this item to x1" (or to a session, or later to cloud): the current
  holder checkpoints (R1) and releases, and the target pulls, creating its own worktree from the
  item's head plus the shipped diff. Moving between machines and moving between sessions are the
  same operation. A holder that cannot checkpoint (it has died) loses only what it never
  checkpointed.
- **Every holder's claim carries a lease**, interactive and cloud holders included, renewed while
  the holder works; no holder claim is ever issued without one. The global claim lease is 24 h
  (`Loopctl.Progress.claim_lease_seconds/0`), sized for a claimant that renews on its own
  schedule, and runner dispatches already get a shorter, wall-clock-capped lease
  (`Loopctl.Delivery.DispatchLease`). Release 3 sets the session holder's lease and renewal
  interval by measurement (section 9).
- **One host daemon per machine, which is not a holder.** It merges today's loopctl-runner process
  and the GitHub Actions runner registration. It:
  - reports what the machine offers: CPU, Elixir and OTP versions, databases, free CI and session
    slots, and measured load;
  - runs headless sessions when loopctl places work there;
  - delivers messages to idle interactive sessions on its machine (R11).

  It never stands between an interactive session and loopctl. loopctl places and moves work by the
  daemons' reports, so "dev box" and "CI host" become capacity, not fixed roles.

### R4. Nothing waits for Mark; he sees everything and can intervene anywhere

Mark: "at this point I don't want anything reserved for me, but I want visibility into each part
of the process. So, whoever is coordinating or monitoring the flow, must provide api/mcp for
fleet_dash to display that and for me to intervene, if I see something off."

Mark's standing rule (KB decision `edf682c9`): "I don't want any handoffs/issues "parked". The
entire point of this automation and workflow is to get every issue resolved, one way or another,
without involving me personally."

- **No human-only gates: nothing waits on a human.**
  - `escalated` stops meaning "parked for a human". It means "this holder could not finish; place
    it with a different holder". Any holder other than the one that escalated may re-queue it,
    and so may loopctl's own sweep.
  - `resolve_escalation` stops requiring a user key: its `role: :user` plug becomes
    `role: :agent`, and a holder's resolution takes a new `escalated -> queued` edge. The
    `:human_resolution` edges stay human-only, because Gate A, the chg `:review_missing` hold,
    `escalated -> done` and agent-spec validation read them as "a human decided" (section 4).
    None of them is required for an item to move on.
  - A holder credential (R3) is minted at `:agent`, because claim, start, `renew_claim`, unclaim
    and escalate are `exact_role: :agent` (`story_status_controller.ex:59-61`,
    `story_escalation_controller.ex:37`). The intervention verbs below are new `role: :agent`
    routes, so a holder and fleet_dash's user key both reach them. `place_dispatch` and
    `revoke_dispatch` keep `role: :orchestrator` (`dispatch_controller.ex:35`,
    `dispatch_placement_controller.ex:56`), reached by a coordinating session's own credential,
    never by a holder credential; a holder that needs another holder escalates. `force_unclaim_story`
    stays `exact_role: :orchestrator`, a custody gate that is never converted to `role:`, and is
    not the re-queue path.
  - Every action is recorded with its actor and reason.
- **Correctness guards stay**, because they are not human gates:
  - a session never verifies or reviews its own work;
  - a session never resolves its own escalation: new in release 5 (`self_resolve_blocked`,
    holder identity against the escalating event's actor), because today only the role split
    between escalate (`:agent`) and resolve (`:user`) keeps them apart;
  - the merge gate still judges every merge.
- **Self-modification paths go to an independent holder, not to Mark.** loopctl#986 sent every change
  to chg's and claude-config's gating code to a human. Under R4 such a change needs:
  - verification by a holder whose lineage shares no root with the implementer's, the test the
    recorded-separation clause of verify already applies (`verify_lineage_separated/4`,
    `progress.ex:4508`). That clause also refuses on `assigned_agent_id` equality
    (`progress.ex:4522`), and all fleet sessions share one `agent_id`, so release 3 compares
    holder identity there instead;
  - a different machine, where the host is server-attested: today only a runner's host is,
    through its registration on the runner socket, so until the host daemon (release 7) this
    verifier is a runner dispatch on another runner's host, never a host name a session reports;
  - the full end-to-end suite (R7) passing at the change's head.

  The Gate B `human_paths` list keeps its role, renamed `independent_paths`. This ships in
  release 2 with runner dispatches as the independent verifier, because release 2 moves the
  runner and chg into loopctl and every later release merges there; release 3 switches the
  lineage check to holder identity. Mark: no escalation to him "unless I'm asking for it and/or
  moved the work out".
- **A visibility API and MCP** built on the event log:
  - per item: stage, holder and lease, full history (actor and reason for each transition), linked
    issue, PR, CI runs and runner, its thread (R11), and its age in its current stage;
  - per repo and fleet-wide: what is in flight, what is waiting, throughput and failure classes.
- **Intervention verbs** on the same API, open to fleet_dash and to sessions alike: re-queue,
  re-triage, move (R3), cancel, close with a reason, and pause or resume a repo's intake.
- **Nothing pages Mark and nothing turns red to draw his attention.** Mark: "All this 'becomes
  red', etc. is just something to draw my attention, already limited, and won't serve us well."
  Work that stops moving is the loop's own business: a holder whose lease lapses is replaced
  (section 5, monitors). An item that reaches the `DISPATCH_MAX_ATTEMPTS` ceiling
  (`Loopctl.Delivery.RetryCeiling`) escalates to a stronger holder: first a holder on another
  machine, then one on a larger model. When those have failed too, the sweep closes the item with
  the reason and its evidence, so no item loops for ever. fleet_dash shows whatever Mark chooses
  to look at.

### R5. One identity and one channel per repo

Mark: "The fact that somebody/something continues to create additional channels instead of
reusing the same single channel per repo really annoys me!"

Release 1 (52.1-52.3) builds this:
- One project per repo holds the KB scope, the channel and the delivery work.
- The server refuses a second project for a repo that already has one: a 409
  `repo_already_has_project` naming the existing project's id.
- An intake source enrolled on a kb scope promotes that scope to a work project.
- The four duplicates are merged (`chg`/`chg-delivery`, `ads_for_care`/`ads_for_care-delivery`,
  `claude-config`/`claude-config-delivery`, `infra`/`infra-pilot`).

### R6. Intake re-checks before triage

Before triage spends anything on an item:
- **Already fixed:** a merged PR or commit references the issue, or its reproduction now passes.
  The item is closed with the evidence.
- **Duplicate:** another open item covers the same failure. The new one is linked to it and closed.
- **Stale reproduction:** the failing check named in the issue has passed on the base branch since.
  The reproduction is re-run when the issue gives one.

Only what survives goes to triage, and triage receives the re-check's findings as input. Every
auto-close carries its evidence in the issue comment.

### R7. One release set and an end-to-end suite

Mark: "every bit of improvement matters -- a lot" (CI capacity is at its budget ceiling). On model
changes: "A good architecture solves many of these issues. A good test suite keeps it on track."

- **The end-to-end suite comes first** (release 2), against a sandbox repo, run nightly and on
  every factory release.
  - Its happy path runs: issue, intake, triage, placement, a PR passing chg and CI, review, merge,
    issue closed, item done, and nothing left open in any queue.
  - Each later release adds its own paths:
    - an escalation resolved by another holder;
    - a red CI fixed;
    - loopctl unreachable mid-run;
    - an item moved between machines mid-stage;
    - an item moved from an interactive session into the loop and back;
    - two sessions on one machine and one repo never colliding;
    - a message reaching an idle session on another machine.
- **A release set.** One manifest names compatible versions of every part. One command rolls the
  fleet to that set and verifies each machine. Every client reports its version, and loopctl
  refuses an incompatible one, as the runner contract does today. Each client works with the
  server's previous version, and the reverse.
- **Model changes** run the suite before rolling out. The suite is the executable spec of the five
  concepts.

### R8. A fresh environment for every CI job, without losing speed

Mark: "I'm surprised it's not the case yet. That was the idea from the very beginning!"

- Each job gets its own scratch area, created for the job and destroyed after it:
  - a per-job `TMPDIR`;
  - its own work tree;
  - its own test database.
- Warm state is a read-only, content-addressed snapshot that chg builds and any machine can fetch
  or rebuild (`_build`, deps, PLTs). Losing a machine loses speed, never work.
- CI stays on GitHub Actions as the trigger and the check of record. The runners are capacity the
  host daemons manage (R3).

### R9. Availability

Mark: "I would consider a second region that's still close to Colorado. A replicated db should be
an option, but so far the volume is growing, but not huge. The first incident and we're moving to
that." And: "We bring it up asap. And we give it as many machines and dbs as it needs."

- loopctl runs machines in two regions: the current one plus Fly `den` (Denver).
- Each region keeps at least one machine running, never suspended, so R11's subscriptions hold.
  `fly.toml` does not give that today: `min_machines_running = 2` (`fly.toml:180`) holds only in
  `primary_region = "lax"` (`:5`), and `auto_stop_machines = "suspend"` (`:176`) applies to `den`
  too. The release also raises `EXPECTED_APP_NODES` (`:171`) with the machine count, because
  `DbCapacity` divides the connection budget by it and `ClusterReadiness` alarms on a missing
  peer (`fly.toml:163-169`).
- The database stays single-primary, with tested backups and a written failover runbook. A replica
  comes after the first incident.
- The database is the shared `ecf-postgres` (role connection limit 80), not managed Postgres, so
  `DbCapacity`'s budget (`lib/loopctl/db_capacity.ex:87-90`) is re-measured for the new machine
  count. `den` machines reach the primary in `lax` across regions, and an outage of `lax` takes the
  database with it: the second region adds app capacity, not database availability, until the
  replica.
- A holder that loses loopctl finishes its current lease, records its events and checkpoints
  locally, and sends them on reconnect. Event ids are idempotent, so a replay never applies twice.
- loopctl is monitored from outside loopctl.

### R10. The factory lives in the loopctl repo

- **Moves in, with history preserved:**
  - loopctl-runner;
  - chg (CLI and adapters);
  - infra's CI runner provisioning (release 7, when the host daemon takes over the machine's
    GitHub Actions runner pool);
  - claude-config's factory half:
    - skills: handoff, shepherd, fleet, triage-trio and agent-spec-builder;
    - hooks: the channel and claim gates, review-round-counter, gate-stated-intent and the
      delivery-loop gates;
    - bin scripts: `wait-for-checks.sh`, `delete-merged-branch.sh`, `worktree-remove.sh`,
      `handoff-issue.sh`, `session-message.sh` and the fleet nudger;
    - the delivery-loop section of CLAUDE.md.
- **The bridge.** loopctl publishes a factory pack (its hooks, skills and generated policy prose),
  and claude-config installs it like any plugin. A factory rule then changes in one repo.
- **Retired once R2, R3 and R11 replace them:** handoff posts, `session-message.sh`, the fleet
  nudger's remaining ssh hop, and the claim-scope gate hooks. Each is deleted in claude-config in
  the release that deletes what it calls (release 4 for messaging, release 7 for handoffs and
  claims), through a claude-config PR merged before that release deploys. Release 8 moves only what
  is still alive.
- **Done when** a factory feature like #1065 plus #1067 can be built, reviewed, tested end to end
  and released from the loopctl repo alone.

### R11. Messaging between sessions

Mark: "Sessions should be able to communicate and coordinate between themselves. Both inside the
same repo and between repos." And: "I do need real time communications, slack channels of sorts,
as well as 'DMs', as appropriate. Again, all this functionality is hosted on loopctl." And: "I
want the system simple enough, and adding types will prove to be unused in real life and too
complicated. Effectively that introduces more channels inside channels, introducing confusion and
lost messages. All messages, if they don't get attached to session/item, get swiped like unused
memory. ... the messaging system must be totally fool-proof."

**The whole model.** A message is text, an author and exactly one attachment:
- a **work item**: its thread;
- a **session**: a DM;
- or a **channel**: one per repo (R5), plus a few fleet-wide channels.

Messages carry no types, kinds or priorities, and there are no sub-channels. A decision, a plan
or a blocker is work-item state (R1), written with work-item verbs. A message that matters is
attached to an item, or its content is written into item state.

**Retention follows the attachment:**
- An item's thread lives as long as the item.
- A DM lives as long as its session. When the session ends, the server re-sends each unread DM
  into the thread of every item the session held, one copy per item with its own id, or sweeps it
  if the session held none.
- A channel message is swept after a short window (default 7 days; today's channel posts keep 30)
  unless it is attached to an item. Until release 7, `handoff:` posts are not channel messages
  for this rule and keep 30 days (section 4).
- Nothing unattached lingers.

**Fool-proof delivery:**
- Every message is stored before it is delivered. It has an id, and a retried send is idempotent.
- Every session has exactly one inbox: its DMs, plus the threads of the items it holds. It reads
  by cursor, so nothing is skipped and nothing is read twice. The cursor is kept per attachment
  (the DMs, and each item thread), not per inbox. A holder that takes an item over starts that
  thread's cursor at its beginning, so it reads the item's whole thread once.
- Messages from one sender to one inbox arrive in order (section 5).
- A message to a work item reaches whoever holds it now. Moving an item moves its thread. The
  sender never needs to know who holds an item or on which machine.
- A DM to a session that has ended is refused at send time, never silently dropped. The refusal
  names the items that session held and their current holders, so the sender writes to an item.
- **No per-session cap.** Mark: "I trust agents enough that they'd avoid any abuses." A cap would
  refuse a busy session's legitimate message exactly when coordination matters most. Today every
  limit is per key, and under R3 a key is a session:
  - the API pipeline allows 300 requests a minute per key (`@default_per_key_limit`, tenant
    setting `rate_limit_requests_per_minute`) and three times that per tenant
    (`lib/loopctl_web/plugs/rate_limiter.ex:37,54`);
  - channel posts allow 120 writes and 240 reads a minute per key
    (`lib/loopctl_web/controllers/channel_post_controller.ex:146,154`).

  The soft-lock and claim endpoints carry per-key caps of the same kind
  (`channel_lock_controller.ex:92`, `channel_claim_controller.ex:136,141`).

  Release 4 removes the per-key limits for holder credentials and every per-key coordination cap
  (channel posts, locks and claims). The
  only bound left is the tenant-wide limit. Today it is not stored: it is derived as
  `per_key_limit * 3` (`rate_limiter.ex:54`), so release 4 makes it a tenant setting of its own
  with a fixed default of 900 a minute, today's derived value at the default per-key limit. It is
  counted on `Loopctl.RateLimiter.Postgres`, which is cluster-global; the default node-local
  Hammer counter (`rate_limiter.ex:17-21`) would let the bound grow with the node count R9 adds.

**Real-time delivery.** The coordination-bus design (2026-07) chose store-and-poll and no
WebSockets for agents, because an agent reads only at a turn boundary. That still holds for a
busy session. What it missed is the idle session: a message to a session waiting for input waits
until someone types. This design delivers at the earliest moment each consumer can read:
- **A busy session** gets new inbox messages at its next tool round, through a hook, which is
  finer than the turn boundary the bus design assumed.
- **An idle session** is woken by its machine's host daemon (R3). The daemon holds a Phoenix
  Channels subscription and hands the message to the session through Claude Code's local
  cross-session delivery, which works today between sessions on one machine.
- **A session that is not running** reads from its cursor when it resumes, or its successor does
  when its items are taken over.
- **fleet_dash** subscribes to the same stream, and Mark posts from there.
- Fly's `auto_stop_machines = suspend` must not drop subscriptions. R9's one never-suspended
  machine per region covers this.

**Replaced by R11:** free-text `channel_post`, `session-message.sh`, cross-machine `SendMessage`,
and the nudger's remaining observe-only ssh hop (its ssh delivery is already gone). Handoff posts go in release 7, with the move verb that replaces them
(a move is a work-item event). The advisory file soft-locks (`channel_lock`) keep their behaviour:
they are coordination hints, not messages (section 4).

### R12. loopctl becomes private; its MCP stays public

Mark: "I'm considering closing loopctl and making it a private repo. Only its mcp should remain
public. I just don't want all the risks involved by letting potential intruders to see the source
code."

- The repo becomes private. The MCP server (`mcp-server/`) keeps being published to npm as a
  public package.
- **Security never depends on hidden source.** The public MCP shows every route. Authentication,
  tenant isolation and rate limits must hold with the code visible.
- **CI cost.** Jobs that run on `ubuntu-latest` become billed GitHub-hosted minutes on a private
  repo. They move to the self-hosted `fleet-ci` pool, or are measured against the free allowance
  first. npm refuses `--provenance` from a private repo, so the publish workflows
  (`mcp-autopublish.yml:65`, `npm-publish.yml:56`) drop the flag.
- **Branch protection stays.** Mark's GitHub plan is paid, so master's protection keeps applying
  on a private repo (`gh api repos/mkreyman/loopctl/branches/master/protection` answers, read
  2026-11-19). The flip script reads protection again after the flip and sets the repo back to
  public if it is gone.
- **Installs authenticate.** Once runner and chg live in a private repo, their installers fetch
  release artifacts with a token, and a future cloud session needs a deploy token.
- **Self-hosted runners become safer.** A public repo's fork PRs can reach self-hosted runners;
  a private repo has no forks from strangers.
- **Public docs stay served by the app.** `/docs`, `/swaggerui` and `/api/v1/openapi`
  (`lib/loopctl_web/router.ex:69,162,231-232`) are served by the running app, which repo privacy
  does not touch, so they stay and remain the API reference. Everything that points readers into
  the repo moves out of it: the MCP usage now read from the repo's README goes to the npm
  package's README; template links and `/.well-known/loopctl`'s `repository_url` point at the app
  or the package; and the terms and privacy contact is support@ecommercefriendly.com.

## 7. Failure design

1. **During a partition**, a holder keeps working its current lease, records events and
   checkpoints locally, and replays them by idempotent id on reconnect (R9). Messages to it wait in
   its inbox. A lease that lapses during the partition is reclaimed, and the late holder's replayed
   events are fenced out of the item's state by the claim epoch, exactly as runner reports are
   today. Its checkpoint, working-tree diff included, is not dropped. It is stored on the work
   item as a fenced checkpoint (R1 checkpoint state, not a message, so the untyped 16 KiB message
   body of `channel_post.ex:97,308` does not apply), under the same diff bound as any checkpoint
   (point 4), for the current holder to apply or ignore. A diff over that bound is pushed by the
   late holder to its own work-in-progress branch, which needs git access and no lease, and the
   fenced checkpoint names that branch.
2. **State lives in loopctl's Postgres**, as work items, the event log and inboxes. Sessions,
   machines and git hold copies. A crash, a deploy or a restart of a session loses only what was
   never checkpointed. A crash of loopctl loses nothing committed.
3. **Retries never act twice.** Events, messages and moves carry ids. A second claim is refused by
   `Progress.claim_story/3`'s transition check (`validate_transition_ctx/3` under the story row
   lock `do_claim_story/3` takes, `progress.ex:283-299`), keyed on holder identity from release 3;
   `not_held/2` there refuses only a story whose delivery stage is held (escalated, done or
   failed). A retried move finds the item already moved and answers the first move's result. Two
   different moves or resolves of one item are serialized on its stage row, which every stage
   transition, resolve included, locks `FOR UPDATE` after taking the story `FOR SHARE`
   (`lib/loopctl/delivery/stages.ex:78-84`): the first to commit wins, and the second is refused
   with the item's new holder and stage, never applied on top.
4. **On a slow connection**, delivery is by cursor, so slow means late, never lost or duplicated.
   Checkpoints are small (notes, a head, a diff), and the diff is bounded; a diff over the bound
   forces a commit to a work-in-progress branch instead.
5. **The unit of work runs in a holder's worktree** on some machine. It is reached by its holder
   identity through loopctl, wherever it is. After a restart, the session presents its holder
   identity again, or a new holder takes the item over from its record.

## 8. Releases (migration order)

Each release ships alone, on its own epic branch, leaves the fleet working, and extends the
end-to-end suite. loopctl-runner and chg move in first (release 2), so that every later release,
including the host daemon's duties in releases 4 and 7, is built in this repo alone. The host
daemon is the runner process refactored (section 4), so it grows duties release by release
rather than appearing at once.

| release | requirements | what ships |
|---|---|---|
| 1 | R5 | One project per repo; the four duplicates merged (52.1-52.3) |
| 2 | R10 part 1, R7, R4 self-modification | loopctl-runner and chg moved into this repo with history; the release manifest; the end-to-end suite's happy path against a sandbox repo, run nightly; the self-deploy refusal deleted and `independent_paths` in place of `human_paths` |
| 3 | R1, R3 identity | Work item generalization, the event log, server-minted holder identity, second claims refused |
| 4 | R11 | Inboxes, item threads, DMs, channel retention, real-time delivery; the runner process gains idle-session delivery, its first host-daemon duty |
| 5 | R4 | Visibility API and MCP, intervention verbs, resolve open to holders, stronger-holder escalation |
| 6 | R6 | Intake re-check |
| 7 | R1 checkpoints, R2, R3 move | Checkpoints, diff transfer, the move verb, the interactive boundary; the runner process becomes the host daemon (capacity reports, the GitHub Actions runner pool with infra's provisioning moved in); handoffs and `channel_claims` deleted |
| 8 | R10 part 2 | claude-config's factory half moved in; the factory pack; hooks generated from policy |
| 9 | R8 | Per-job scratch and warm snapshots |
| 10 | R9 | Second region and failover runbook |
| 11 | R12 | Private repo |

## 9. Open technical questions

Each one is settled inside the release that needs it, by measurement or by reading code. None
is a decision for Mark.

- **Waking an idle session** (release 4). Measure whether a host daemon can deliver into an idle
  Claude Code session on its own machine through the local cross-session socket, with no human
  approval prompt, on Linux and on macOS. If it cannot, release 4 falls back to delivery at the
  next turn and records the gap.
- **The interactive-boundary grant** (release 7). Confirm a UserPromptSubmit hook can see that
  Mark typed the move command, and mint a one-shot grant the server can verify.
- **The session holder's lease** (release 3). Measure how long interactive sessions go between
  tool calls before choosing the lease and its renewal interval.
- **Which claude-config hooks are factory-only** (release 8). Trace what each hook reads.
- **The diff bound** (release 7). Measure diff sizes at real handoff points before choosing it.
