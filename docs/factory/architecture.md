# Factory architecture: one control plane in loopctl

This design comes from a conversation with Mark on 2026-11-19 (a chg session on minis), filed as
loopctl#1069. Mark's words are quoted where they set a requirement. The stories that build it
live under `docs/user_stories/epic_52_factory_control_plane/`, one release per migration step.

## Why

One factory change on 2026-11-19 had to cross five repos: chg, loopctl, loopctl-runner,
claude-config and infra. Every defect seen that day came from two copies of the same fact
disagreeing:

- **One piece of work, four copies.** chg#77 existed as a GitHub issue, a channel handoff, a
  loopctl story and an escalation. Closing the handoff and the issue left the story "parked" in
  fleet_dash for 13 hours.
- **One repo, two channels.** chg had the kb scope `chg` and the work project `chg-delivery`.
  loopctl#1065 posted escalation handoffs on `chg-delivery`, and claude-config's
  `gate-channel-claim-scope.sh` refuses claims there (loopctl#1067).
- **Rules in three places.** The same rule lived as prose, as a shell hook and as a server
  check, and nothing checked that they agreed.
- **No coordinated release and no end-to-end test.** loopctl#1065 shipped working in loopctl
  and broken against a claude-config hook.
- **Intake did not re-check.** chg#77 and chg#66 had been fixed weeks earlier, and still went
  through triage and escalation.
- **CI hosts carried state between jobs.** A stale Mix lock file from a killed job hung later
  jobs for 600 s (chg#119).

Mark:

> The factory is NOT the product ... Ideally though, it IS just another product that keeps
> improving itself.

> As much this machinery must be moved to loopctl itself as we can. Or at least under the
> loopctl's repo, so I don't have to keep juggling handoffs between several different repos.

> [Can you hold the system in your head?] Only on a very shallow level. And this is why I want
> it in one place, not spread out.

> A good architecture solves many of these issues. A good test suite keeps it on track.

## The model: five concepts

1. **Work item.** Exactly one record per piece of work, keyed by `<repo>#<issue>` or by a slug.
   One state machine covers stage, holder (with a lease) and done. An append-only event log is
   the only record. Issues, handoffs, stories and escalations stop being separate entities.
2. **Holder.** Whatever currently works an item: a headless runner, a loop worker, or one of
   Mark's interactive sessions, on any machine or, later, in a cloud session. A holder is
   disposable.
3. **Gate.** chg is the factory's verification engine. Its source moves into the loopctl repo.
4. **Policy.** Every rule is decided once, on the server. Hooks and prose in harness files are
   generated from that policy, or are thin calls to it.
5. **Views.** fleet_dash, GitHub issues and channel posts are projections of the event log.
   Mark's interventions are events in the same log.

## Requirements and the decisions they force

### R1. All work state lives in loopctl

Mark: "the state should still live on loopctl".

- An item carries its plan, progress notes, decisions, open questions, holder, stage, linked
  branch and pushed head.
- A holder checkpoints to the item while it works. Taking an item over means reading its record
  and checking out that commit. It never means reconstructing state from a branch, a transcript
  or a prose handoff.
- Uncommitted work travels through loopctl. A move ships the working-tree diff with it, so
  moving at any stage does not force a premature commit.
- Git holds code only. Sessions hold copies only.

### R2. Mark moves work in and out at any stage, and only Mark

Mark: "There's still a lot of ad-hoc work that I have to do. The system must support either, as
well as moving in and out at any stage -- at my will, not at agent's whim!!!"

- Only Mark moves an item between one of his sessions and the loop. A runner never pushes work
  into his session, and his session never puts its work back into the queue on its own.
- Inside the loop, workers hand items to each other freely, because that is scheduling and does
  not need his attention.
- Ad-hoc work in an interactive session is an item too. It is created automatically from the
  session's branch, so fleet_dash shows it and Mark can say "loop, finish this" halfway through.
- Escalations stay inside the loop. Some worker pulls them, and they never wait for Mark.

### R3. Location independence: any machine, later the cloud

Mark: "each one of [my dev machines] can also serve as a ci host ... the work should be able to
move in and out, including moving between machines as well as, potentially, to cloud sessions."

- A holder's whole working set comes from three places: loopctl, the git remote, and secrets
  loopctl issues.
- **The cloud test.** Any step a cloud session could not do depends on hidden local state, and
  that is a design bug even while no cloud session runs. Today that includes the per-machine
  memory dir, `.claude/gate.lock`, ssh-based `session-message.sh`, session scratchpads, and
  fleet_dash being served only on mac-mini.
- **One host agent per machine.** It merges loopctl-runner, the GitHub Actions runner
  registration and the fleet_dash collector. It reports to loopctl what the machine offers (CPU,
  Elixir and OTP versions, databases, free CI and session slots) and its measured load. loopctl
  places and moves items by that report. "Dev box" and "CI host" become capacity, not fixed
  roles.
- **Moving is one verb.** "Move this item to x1" or "to cloud": the current holder checkpoints
  and releases, and the target pulls. Moving between machines and moving between sessions are
  the same operation.
- **Sessions talk only through loopctl,** on the item or on the repo's one channel.
  Cross-machine ssh messaging goes away.

### R4. Nothing reserved for Mark; full visibility and intervention

Mark: "at this point I don't want anything reserved for me, but I want visibility into each part
of the process. So, whoever is coordinating or monitoring the flow, must provide api/mcp for
fleet_dash to display that and for me to intervene, if I see something off."

- Remove human-only gates. `resolve_escalation` behind LOOPCTL_USER_KEY is not a real control,
  because every interactive session holds that key. Keep only correctness guards, such as a
  dispatch never reviewing its own work.
- A visibility API and MCP built on the event log. Per item: stage, holder and lease, full
  history (actor and reason for each transition), linked issue, PR, CI runs and runner, and age
  in its current stage. Per repo and fleet-wide: what is waiting, what is stuck past its stage's
  bound, throughput, and failure classes.
- Intervention verbs on the same API, for fleet_dash and for sessions: re-queue, re-triage,
  reassign or move (R3), cancel, close with a reason, and pause or resume a repo's intake.
- Stuck work is never silent. It shows red in fleet_dash and is handed to a worker. It never
  becomes a question for Mark.

### R5. One identity and one channel per repo

Mark: "The fact that somebody/something continues to create additional channels instead of
reusing the same single channel per repo really annoys me!"

- One project per repo holds the KB scope, the channel and the delivery work. Drop the kb/work
  split for repo-backed projects.
- The server refuses a second project for a repo that already has one: a 409 that returns the
  existing project's id. No client hook should be needed.
- Merge today's duplicates. Checked with `list_projects` on 2026-11-19: four repos each carry a
  kb scope holding the `repo_url` and a work project with no `repo_url` that the intake source
  binds instead: `chg` / `chg-delivery`, `ads_for_care` / `ads_for_care-delivery`,
  `claude-config` / `claude-config-delivery`, and `infra` / `infra-pilot`. reportex,
  freight-pilot, home_care_billing and loopctl each have one project.

### R6. Intake re-checks before triage

Before triage spends anything on an item:

- **Already fixed:** a merged PR or commit references the issue, or its reproduction now passes.
  Close the item with the evidence.
- **Duplicate:** link it to the existing item and close it.
- **Stale reproduction:** the failing check has passed on master since. Re-run the reproduction
  if one is given.
- Only what survives goes to triage, and the re-check's findings go in with it.

### R7. One release and an end-to-end suite

Mark: "every bit of improvement matters -- a lot" (CI capacity is at the budget ceiling).

- **A release set:** one manifest names compatible versions of every part. One command rolls
  the fleet to that set and verifies each machine. Every client reports its version, and
  loopctl refuses mismatches, as the runner contract does today.
- **An end-to-end suite** against a sandbox repo, run nightly and on every factory release. The
  happy path runs issue, intake, triage, dispatch, a PR passing chg and CI, review, merge, issue
  closed, item done, and no queue left open. The failure paths cover an escalation picked up and
  resolved, a red CI fixed, loopctl unreachable mid-run, an item moved between machines
  mid-stage, and an item moved from Mark's session into the loop and back.
- **Model changes** run the suite before rolling out. The suite is the executable spec of the
  five concepts.

### R8. Fresh environment per CI job, without losing speed

Mark: "I'm surprised it's not the case yet. That was the idea from the very beginning!"

- Each job gets its own scratch area: a per-job `TMPDIR`, a work tree and a test database,
  created per job and destroyed after.
- Warm state is a read-only, content-addressed snapshot that chg builds and any machine can
  fetch or rebuild (`_build`, deps, PLTs). Losing a machine loses speed, never work.
- CI stays on GitHub Actions as the trigger and check of record. The runners are capacity that
  the host agents manage (R3).

### R9. Availability

Mark: "I would consider a second region that's still close to Colorado. A replicated db should be
an option ... The first incident and we're moving to that."

- loopctl runs machines in two regions: the current one plus Fly `den` (Denver).
- The database stays single-primary, with tested backups and a written failover runbook. A
  replica comes after the first incident.
- Holders that lose loopctl finish their current lease, record events locally, and send them on
  reconnect. Event ids are idempotent, so a replay never applies twice.
- loopctl is monitored from outside loopctl.

### R10. Consolidation into the loopctl repo

Mark: "Let's move only the factory part of [claude-config]. At least for now."

- **Moves in, with history preserved:** loopctl-runner; chg (CLI and adapters); fleet_dash;
  infra's runner provisioning; and claude-config's factory part:
  - skills: handoff, shepherd, fleet, triage-trio and agent-spec-builder;
  - hooks: the channel and claim gates, review-round-counter, gate-stated-intent and the
    delivery-loop gates;
  - bin scripts: `wait-for-checks.sh`, `delete-merged-branch.sh`, `worktree-remove.sh`,
    `handoff-issue.sh`, `session-message.sh` and the fleet nudger;
  - the delivery-loop section of CLAUDE.md.
- **Stays in claude-config:** SOUL.md, USER.md, personal skills (marketing, learning, KB mining)
  and general hygiene hooks (simple bash, secret redaction).
- **The bridge:** loopctl publishes a factory pack (its hooks, skills and generated policy
  prose), and claude-config installs it like any plugin. A factory rule then changes in one
  repo.
- **Done when** a factory feature like #1065 plus #1067 can be built, reviewed, tested end to end
  and released from the loopctl repo alone.

## Migration order

Each step ships alone, as its own release of Epic 52 on its own epic branch, and leaves the
fleet working.

1. **R5:** one project and one channel per repo, plus the server-side 409. Smallest step, and it
   removes today's daily irritant.
2. **R1 and R4 data model:** the work-item record and event log, with the existing stories,
   handoffs and escalations folded in. Rows that cannot be matched are reported, never guessed.
3. **R4 views and verbs:** the visibility API, MCP and fleet_dash pages, plus removing the
   human-only gates.
4. **R6:** intake re-check.
5. **R10 part 1:** move loopctl-runner and chg into the repo, and set up the release set and the
   end-to-end suite (R7). The suite needs both parts in one tree.
6. **R2 and R3:** checkpointing, moving uncommitted diffs, the move verb, and the host agent per
   machine.
7. **R10 part 2:** move claude-config's factory part as a published pack, and generate hooks
   from policy.
8. **R8 and R9:** per-job scratch with warm snapshots, the second region, and the failover
   runbook.

## Open facts

None blocks step 1. Each is a fact to check in the code or the fleet, not a decision for Mark:

- Where fleet_dash's source lives today. loopctl has a project for
  `git@github.com:mkreyman/fleet_dash.git`; it is served on mac-mini at :4060 and is not
  checked out on minis. Settle before step 5.
- Which claude-config hooks are factory-only. Settle by tracing what each hook reads, before
  step 7.
