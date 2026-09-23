# PRD — Epic 44: Delivery loop completion (control-plane residue of #800)

**Status:** draft for review · **Epic:** 44 · **Parent:** mkreyman/loopctl#800 (handoff part #803)
**Design of record:** `docs/agent-delivery-loop.md` in mkreyman/loopctl-runner. This PRD does not
restate it; it scopes what is still missing on the loopctl side, as of master `1e188024`
(2026-09-23).

## 1. Where the loop actually is

Shipped and deployed, verified against the code rather than the issue threads:

| design § | piece | where |
|---|---|---|
| 2 | runner contract, authenticated channel, Presence pool, enrolment | `priv/runner_contract/v1.json` (1.12.0), `RunnerChannel`, `Loopctl.Runners` |
| 3 | stage machine as data, CAS rows under a `claim_epoch` fence | `Delivery.StageMachine`, `Delivery.Stages` |
| 4 | triage dispatch and verdict receipt, verdict persisted | `TriageDispatcher`, `TriageVerdict`, `triage_verdicts` |
| 5 | both gates, second run over the real PR, fail-closed | `DeliveryGates`, `Delivery.MergePrecondition`, `POST …/merge-precondition` |
| 6 | claiming with lease, renewal, reclaimer, epoch | `Progress.claim_story/3`, `reclaim_expired_claim/3` |
| 7 | placement, capacity reservation, declared capacity | `Delivery.Placement`, `Runners.Capacity` |
| 9 | post-deploy verification, verdict-mapped resolution, `verified -> done` | `PostDeployVerification`, `Resolution`, `Completion` |
| 10 | reporter text fenced, implementer reads the story only | `Untrusted`, `InjectionDetector`, `ImplementerInput` |
| — | unattended driver ON with declared budgets | `DispatchDriver`, `fly.toml` (#875) |

The first end-to-end run (story `d9975b31`, 2026-09-16) traversed `detected -> … -> escalated ->
done` with zero refusals. **The loop has never delivered a code change**, and the reasons split
cleanly into two kinds: authority the runner does not have (§5, not this epic), and five defects
in the control plane that make an unattended run unsafe or unreachable (§3, this epic).

## 2. Goal

Make the control plane safe to leave running unattended: every way a run can end leaves the story
somewhere a human or the driver can act on, no gate trusts a caller for a fact the server holds,
and an operator can see and reach every surface the loop needs.

**Success criteria**

1. No story can come to rest in a state nothing selects (today: `queued` + `agent_status: pending`).
2. Gate A at merge is decided from persisted verdicts; `gate_a_inputs: :caller_asserted` no longer
   appears on any verdict.
3. A driver-placed claim is released within its dispatch's wall clock plus a bounded grace; no
   other claimant's lease changes.
4. A runner that has declared its subscription exhausted is not offered work until its declared
   reset, and the driver can say when capacity returns.
5. Every route an operator needs to bring a runner online is in the route index.

## 3. Scope — the five stories

### 44.1 Gate A at merge reads the persisted verdicts (security)

`MergePrecondition` takes the trio's outputs from the request (`merge_precondition.ex:277`, every
verdict stamped `gate_a_inputs: :caller_asserted`), so a caller that fabricates a unanimous `story`
trio clears Gate A. Triage has persisted its verdict since contract 1.9.0 (`triage_verdicts`,
unique on `(tenant_id, dispatch_id)`), so the reason the moduledoc gives for trusting the caller
no longer holds. Gate A must read the story's persisted verdict(s) server-side; a caller-supplied
trio is ignored (and recorded as ignored), and a story with no persisted verdict fails closed.

Design questions answered here: *state* — the verdict row is the single source; *retry* — a replayed
gate call reads the same rows and reaches the same verdict; *partition* — a missing row is
`refuse`, never `unevaluated`, because waiting cannot make a verdict appear.

### 44.2 A crashed unattended dispatch never parks its story (#877)

On lease expiry `reclaim_expired_claim/3` sets `agent_status: pending` and moves the stage row to
`queued`; the driver selects `stage == :queued AND agent_status == :contracted`, so the story is
unreachable for ever, with no alert.

**Decision: bounded retry, then escalate; with no configured ceiling, escalate immediately.**
Option 2 of #877 is what the loop is for (a runner reboot must not need a human), but the ceiling
is spend, so it follows the #875 pattern: `DISPATCH_MAX_ATTEMPTS` has **no default**. Unset, a
release escalates on the first crash (option 1 — never spends twice). Set to N, the release
re-contracts the story and counts the attempt on the stage row's existing `attempts` map, and the
(N+1)th release escalates naming the count. Every release path that produces the pairing is
covered. `Stages.follow_release/5` has five callers today — `progress.ex:1189` (release),
`:1637` (lease reclaim, `:runner_lost`), `:2931` (force-unclaim, which `Placement.undo_claim/5`
uses), `:3601` (auto-reset on a verifier reject), and `bulk_operations.ex:610` — and the policy decides by WHY the claim ended, not by
which caller ended it: an operator's deliberate force-unclaim or a placement refusal is not a
crash and must not spend an attempt.

### 44.3 The claim lease follows the dispatch, per claim (#879)

The lease is one global value (`claim_lease_seconds/0`, 24h) against a 3600s dispatch wall clock,
so a killed session holds its story for up to 23 more hours. Lowering the global key is wrong for
every non-runner claimant (#879 records it being built and removed). **Decision:** a claim taken by
`Placement` for a runner dispatch gets `claimed_until = now + wall_clock_seconds + grace`
(`DISPATCH_LEASE_GRACE_SECONDS`, documented, defaulted — a grace is a safety margin, not spend); a
renewal from that runner extends it by the same rule. Every other claim path is untouched and a
test asserts it.

### 44.4 An exhausted subscription is not capacity (#858)

`Runners.accepts?/5` sees socket, draining, repo, kind and slots — not the subscription window,
which is the scarce resource. **Decision:** the runner DECLARES, loopctl derives (the pattern of
846.2 and 846.4): an optional `usage` object on the status message, `{exhausted: bool,
resets_at: iso8601 | null}` (contract minor bump). An exhausted runner is ineligible until
`resets_at`, or until its next status says otherwise; a `resets_at` in the past or beyond a bound
is ignored rather than trusted. The driver's and triage dispatcher's `:no_runner` gains the
earliest declared reset, logged and visible in `runner_pool`. A runner that sends no `usage` is
unaffected — backward compatible, so the runner side adopts it separately (handoff).

### 44.5 The runner and placement routes are discoverable (#878)

Seven served routes are missing from the curated index behind `list_routes`
(`GET/POST /runners`, `DELETE /runners/:id`, `GET /runners/pool`,
`POST /runners/:runner_id/dispatches`, `GET /dispatches/enrolled-keys`,
`POST /dispatches/:id/revoke`). Add a row each, taken from `mix phx.routes`, with the role and the
MCP tool that reaches it, and extend the route-discovery test so the delivery-loop set cannot
drift out again.

## 4. Non-functional requirements

- Every new env var gets a row in `deploy/FLY_SECRETS.md` (`mix loopctl.check_env_docs`); every
  new refusal or field is in the endpoint's `operation/2` spec and the runner contract.
- Contract changes are additive minor bumps; `runner_contract_test.exs` stays green in both
  directions.
- Every added assertion is proved falsifiable with `bin/mutate.sh`, and the mutation list names the
  WIRING as well as the mechanism.
- No change to custody gates, roles or RLS. 44.1 only ever adds a refusal.

## 5. Out of scope, with what each would take and what it blocks

| item | what it takes | blocks |
|---|---|---|
| **Delivery authority** — the implement session cannot commit or push; nothing opens a PR or merges | Mark's decision on the narrow grant (push to `loop/**` only, via a deploy key with `IdentitiesOnly=yes`), runner work in mkreyman/loopctl-runner, narrowing ruleset 23551814 on home_care_billing (#871) | the first delivered change; everything from `reviewing` onward in production |
| Who performs the merge (runner vs control plane) | decided with the above; `stage_machine.ex:206-214` records it as undecided | auto-merge (build step 7) |
| `required_approving_review_count` 1 on HCB targets (design §9) | Mark's call, a repo setting | unattended merge without a human |
| Gate B's claim-output harness as an allow, not only a refusal | fixture regeneration server-side, HCB fixture coverage | Gate B ever clearing a claims-path change |
| Single-node vs cluster Presence (design §7) | a decision plus `DNS_CLUSTER_QUERY` or pinned machines | a second Fly machine |
| #804 residue, #805 items 4–5 | HCB-side confirmation step; a `support_tickets` measurement | turning the loop on *for Larisa* |

## 6. Delivery constraint for this epic

All development stays local: branch `feature/delivery-loop-800`, commits through the local gate,
reviews run against the local diff, **nothing pushed** until Mark says so. The epic is not imported
into the production loopctl instance for the same reason.
