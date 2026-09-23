# PRD — Epic 44: Delivery loop completion (control-plane residue of #800)

**Status:** draft, review round 1 applied · **Epic:** 44 · **Parent:** mkreyman/loopctl#800 (handoff part #803)
**Design of record:** `docs/agent-delivery-loop.md` in mkreyman/loopctl-runner. This PRD does not
restate it; it scopes what is still missing on the loopctl side, as of master `1e188024`
(2026-09-23), runner contract `x-contract-version` 1.14.0.

## 1. Where the loop actually is

Shipped and deployed, verified against the code rather than the issue threads:

| design § | piece | where |
|---|---|---|
| 2 | runner contract, authenticated channel, Presence pool, enrolment | `priv/runner_contract/v1.json`, `RunnerChannel`, `Loopctl.Runners` |
| 3 | stage machine as data, CAS rows under a `claim_epoch` fence | `Delivery.StageMachine`, `Delivery.Stages` |
| 4 | triage dispatch and verdict receipt, one merged verdict persisted per dispatch | `TriageDispatcher`, `TriageVerdict`, `triage_verdicts` |
| 5 | both gates, but only at MERGE time, over the real PR, fail-closed | `DeliveryGates`, `Delivery.MergePrecondition`, `POST /stories/:id/merge-precondition` |
| 6 | claiming with lease, HTTP renewal, reclaimer, epoch | `Progress.claim_story/3`, `reclaim_expired_claim/3` |
| 7 | placement, capacity reservation, declared capacity | `Delivery.Placement`, `Runners.Capacity` |
| 9 | post-deploy verification, verdict-mapped resolution, `verified -> done` | `PostDeployVerification`, `Resolution`, `Completion` |
| 10 | reporter text fenced, implementer reads the story only | `Untrusted`, `InjectionDetector`, `ImplementerInput` |
| — | unattended driver ON with declared budgets | `DispatchDriver`, `fly.toml` (#875) |

The first end-to-end run (story `d9975b31`, 2026-09-16) traversed `detected -> … -> escalated ->
done` with zero refusals. **The loop has never delivered a code change.** The reasons split into
authority the runner does not have (§5, not this epic) and defects in the control plane that make
an unattended run unsafe, wasteful or unreachable (§3, this epic).

## 2. Goal

Make the control plane safe to leave running unattended: every way a run ends leaves the story
somewhere a human or the driver acts on, no gate trusts a caller for a fact the server holds, no
run is spent on work a gate will refuse, and every surface the loop needs is reachable.

**Success criteria**

1. No release path leaves a story at `queued` + `agent_status: pending`. Asserted per path.
2. Gate A at merge is decided from persisted per-lens verdicts or a later human resolution;
   `gate_a_inputs: :caller_asserted` no longer appears.
3. A story Gate A or Gate B would refuse at triage is never queued.
4. A driver-placed claim expires no later than its placement time plus the dispatch wall clock plus
   a bounded grace, whatever renews it; no other claimant's lease changes.
5. A reported budget kill (wall clock, turn budget) stops at `escalated` for a human, never in a
   retry loop and never at a runner-decided `failed`; an exhausted subscription spends no attempt.
6. An exhausted runner is not offered work until its (clamped) reset.
7. Every route an operator needs to bring a runner online is in the route index, and the merge
   precondition has an MCP tool.

## 3. Scope — seven stories

Contract changes below are additive, optional fields in one minor bump (1.15.0); a runner that does
not send them gets today's behaviour, and the runner side adopts them by handoff.

### 44.1 Gate A at merge reads persisted per-lens verdicts (security)

`MergePrecondition` takes the trio's outputs from the request (`merge_precondition.ex:277`, every
verdict `gate_a_inputs: :caller_asserted`), so a fabricated unanimous trio clears Gate A. Two
facts make "read the persisted verdict" non-trivial: `GateA.evaluate/1` requires exactly three
outputs (`gate_a.ex:57,68`), while `triage_verdicts` holds ONE merged verdict per dispatch, so the
disagreement signal is gone by the time it is stored.

**Decisions.**
- The triage verdict message gains optional `lens_verdicts` — exactly three entries, one per lens,
  each carrying the same fields Gate A already parses. loopctl persists them with the verdict.
- At merge, Gate A reads the lens verdicts of the triage dispatch BOUND to the story — a
  stage-row identity written on the `detected -> triaged` transition that dispatch took —
  never merely the newest row, which a refused or late dispatch can write. A **`:human_resolution` of a Gate A escalation satisfies Gate A**: a human already decided, and re-escalating their decision at merge would loop.
- No persisted lens verdicts and no later human resolution → `refuse`, never `unevaluated`:
  waiting cannot make a verdict appear. A caller-supplied `trio_outputs` is ignored, recorded as
  ignored, and dropped from the endpoint's required fields (`merge_precondition_controller.ex:208`).
- The endpoint gets its MCP tool in the same change (CLAUDE.md, "an operator-facing endpoint is
  NOT DONE until an MCP tool calls it"); `route_coverage.test.js` loses the declared gap.

### 44.2 Gates run at triage, before anything is spent

Design §5 runs both gates twice. Only the merge run exists: `TriageVerdict` routes on `outcome`
alone, so with the driver on, a story predicted to touch the claims path is implemented for
USD 10-20 and refused at merge. **Decision:** a triage SCREEN, not the full Gate B, because triage has no
repository file list and `touches` is an optional prediction (`GateB.evaluate/3` would add
`stale_trigger` and `missing_files` reasons and escalate everything). The `story` route runs Gate A
over the lens verdicts and escalates when a drafted touch matches a `human_paths` or `effect_paths`
trigger; it can only ADD an escalation, and the merge run stays the gate. A verdict without lens
verdicts escalates too: queuing it would certainly be refused at merge (44.1), so the loop stops
at triage until the runner adopts 1.15 — nothing merges before delivery authority lands anyway.

### 44.3 A run's end is reported, and a deterministic failure fails

Control learns a session died only through lease expiry: the contract has no implement-run-ended
message, and `:budget_exceeded` has no writer. So a story killed at its wall clock, one killed at
`max_turns` and one whose subscription ran out all look alike. **Decision:** an optional
`session_ended` message `{dispatch_id, claim_epoch, reason}` with `reason` in
`completed | wall_clock_exceeded | max_turns_exceeded | usage_exhausted | crashed`. A runner's
word never makes a story terminal (`failed` has no way out, which is why the stage machine withholds
it from runners), so the two budget reasons take a new control edge
`{in_flight, escalated, :budget_reported}` — never retried, a human decides. `crashed` releases now
instead of at lease expiry, over `:runner_lost` with the reclaim's audit shape; `usage_exhausted`
releases without counting toward the ceiling (44.6 marks the runner). Recorded once per dispatch
with a payload digest checked BEFORE the epoch fence, because a release bumps the epoch and an
honest resend must still be answered ok.

### 44.4 No release parks a story (#877)

`reclaim_expired_claim/3` leaves `agent_status: pending` at stage `queued`; the driver selects
`stage == :queued AND agent_status == :contracted` (`dispatch_driver.ex:137-138`). The same pairing
comes from every `Stages.follow_release/5` caller: `progress.ex:1189` (release), `:1637` (lease
reclaim), `:2931` (force-unclaim, which `Placement.undo_claim/5` uses), `:3601` (verifier-reject
auto-reset), `bulk_operations.ex:610` (bulk reject).

**Decision, per cause:**

| release cause | outcome | spends an attempt |
|---|---|---|
| placement refusal, runner unavailable (`undo_claim/5`) | re-contract | no — the runner refused before any work, and may be free next pass |
| placement refusal that recurs every pass (`undo_claim/5`) | re-contract, or escalate at the ceiling | yes — uncounted it loops every pass |
| `usage_exhausted` (44.3) | re-contract | no |
| lease expiry, `crashed` | re-contract, or escalate at the ceiling | yes |
| verifier reject, bulk reject | re-contract, or escalate at the ceiling | yes — the work was wrong |
| operator force-unclaim | escalate over `{queued, escalated, :operator_released}` | no — a human acted; they resolve it from `escalated` |

The release paths cannot tell these apart today — placement refusal, operator force-unclaim and
the reject auto-reset all pass `:claim_released` — so `force_unclaim_story/3` gains
`release_cause:` and `Placement.undo_claim/5` passes `:placement_refused` or `:attempt` by what refused. A reject of a row already
past `ci` only rebinds it (`stages.ex:984-988`) and keeps today's behaviour. The ceiling is spend, so it follows #875: `DISPATCH_MAX_ATTEMPTS` has **no default**; unset means
a ceiling of 0 (escalate on the first crash, never spend twice). `Stages` already counts attempts per edge (`stages.ex:1080-1093`); the
ceiling counts `runner_lost` and in-flight rejects only. Escalation takes a NEW control-only edge
`{queued, escalated, :attempts_exhausted}` with its own reason code, so the escalated queue tells
a spend ceiling apart from a session asking for Mark (`:session_escalated`). Re-contracting is a
guarded step inside the release's own transaction (`Progress.recontract_in_transaction/3`), writing
the audit entry and webhook `contract_story/4` writes from the same builders.

### 44.5 The claim lease follows the dispatch, with an absolute cap (#879)

The lease is one global value (`claim_lease_seconds/0`, 24h) against a 3600s wall clock. Lowering
the global key is wrong for every non-runner claimant (#879 records it being built and removed).
**Decision:** `claim_story/3` takes `lease_until:`, stored in a new
`stories.claim_lease_cap` column (never `metadata`, which PATCH replaces wholesale); `Placement`
passes `placed_at + wall_clock_seconds + DISPATCH_LEASE_GRACE_SECONDS`, and that instant is an
ABSOLUTE cap: a renewal may never move it later. The grace defaults to 900s and boot refuses
a value below `Capacity.release_grace_seconds/0` (300s) — it has to cover the push and the
worktree setup that run before the runner's own wall clock starts. The dispatch carries the cap as
optional `deadline_at` so an adopting runner kills its session at the same instant control reclaims
it. Every other claim path is untouched, asserted by a test. The MCP `renew_story_claim` text and
`mcp-server/README.md:254` stop saying "default 24 hours" for driver claims.

**Partition.** The cap plus `deadline_at` is what keeps 44.4's re-contract from putting two live
sessions on one story: a runner cut off keeps working only until `deadline_at`, and control places
nothing before that instant. The epoch fences a zombie's loopctl writes; fencing its git pushes is
a requirement on the delivery-authority work (§5), recorded there.

### 44.6 An exhausted subscription is not capacity (#858)

`Runners.accepts?/5` checks draining, `repo` and `kind` (`runners.ex:903-909`); nothing sees the
subscription window. `Placement.place/4` checks only `runner_accepting_work` (`placement.ex:441-443`), so operator
placement needs the same check. **Decision:** the status message gains optional
`usage: {exhausted, resets_at, account_ref}`. State lives in Postgres on the `runners` row
(`usage_exhausted_until`, `account_ref`), not in Presence meta, so it survives a node restart and a
second machine. `resets_at` is CLAMPED to `[now + 60s, now + 8 days]`, and `exhausted: true` with
no `resets_at` holds for the upper bound — never ignored, because ignoring fails open. A `session_ended usage_exhausted` (44.3) also
sets it. `exhausted: false` clears every row sharing the `account_ref`. Runners sharing an `account_ref` (an opaque value the
runner derives from its login) are exhausted together. The driver's and triage dispatcher's
`:no_runner` gains the earliest reset, visible in `runner_pool`.

### 44.7 The loop's routes are discoverable (#878)

Seven served routes are missing from the curated index behind `list_routes`
(`GET/POST /runners`, `DELETE /runners/:id`, `GET /runners/pool`,
`POST /runners/:runner_id/dispatches`, `GET /dispatches/enrolled-keys`,
`POST /dispatches/:id/revoke`). A row each from `mix phx.routes` with role and MCP tool, plus
44.1's merge-precondition route, and the route-discovery test extended so the set cannot drift.

## 4. Non-functional requirements

- Every new env var gets a row in `deploy/FLY_SECRETS.md`; every new refusal, field and edge is in
  the endpoint's `operation/2` spec and the runner contract; `runner_contract_test.exs` stays green
  in both directions.
- Every added assertion is proved falsifiable with `bin/mutate.sh`, the wiring as well as the
  mechanism.
- No change to custody gates, roles or RLS. 44.1 and 44.2 only ever add a refusal.

## 5. Out of scope, with what each would take and what it blocks

| item | what it takes | blocks |
|---|---|---|
| **Delivery authority** — the implement session cannot commit or push; nothing opens a PR or merges | Mark's decision on the narrow grant (push to `loop/**` only, deploy key with `IdentitiesOnly=yes`), runner work in mkreyman/loopctl-runner, narrowing ruleset 23551814 on home_care_billing (#871); must also fence a zombie's pushes by epoch (44.5) | the first delivered change; every stage from `reviewing` in production |
| Who performs the merge (runner vs control plane) | decided with the above; `stage_machine.ex:206-214` records it as undecided | auto-merge (build step 7) |
| `required_approving_review_count` 1 on HCB targets (design §9) | Mark's call, a repo setting | unattended merge without a human |
| Gate B's claim-output harness as an allow | fixture regeneration server-side, HCB fixture coverage | Gate B ever clearing a claims-path change |
| Single-node vs cluster Presence (design §7) | a decision plus `DNS_CLUSTER_QUERY` or pinned machines | a second Fly machine |
| Runner adoption of contract 1.15.0 | runner PRs in mkreyman/loopctl-runner, by handoff | 44.1's merge path and 44.2/44.3/44.6 taking effect in production |
| #804 residue, #805 items 4–5 | HCB-side confirmation step; a `support_tickets` measurement | turning the loop on *for Larisa* |

## 6. Delivery constraint for this epic

All development stays local on `feature/delivery-loop-800`, commits through the local gate,
reviews against the local diff, **nothing pushed** until Mark says so. The epic is not imported
into the production loopctl instance for the same reason.
