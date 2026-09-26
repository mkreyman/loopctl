# The agent delivery loop

loopctl can take a problem someone reports on GitHub and carry it through triage, implementation, review, CI, merge and deployment. Agents do the work on your own machines, and loopctl decides what may happen next. This page describes the operator-visible parts: what to set up, what each step does and refuses, and where to look when a story stops moving.

loopctl is the control plane. It holds the queue, the stage of every story, the claims and the gates. The sessions run on **runners**, which are dev machines you enroll and which connect to loopctl over a socket. loopctl never runs a model and never touches your repository. It tells a runner what to do, and it records and judges what the runner reports.

Every step below goes through the same chain of custody as the rest of loopctl. Custody endpoints are `exact_role`-gated, a session cannot resolve its own escalation, and a runner cannot move a story to `verified` or `done`. See [chain-of-custody-v2.md](chain-of-custody-v2.md).

## The flow

```
GitHub issue ──webhook──▶ intake record ──▶ story at `detected`
                                               │  triage session on a runner
                                               ▼
                                   `triaged` ──▶ `queued` | `escalated` | `failed`
                                               │  placement (driver or operator)
                                               ▼
       `claimed` ▶ `worktree` ▶ `implementing` ▶ `reviewing` ▶ `pr_open` ▶ `ci`
                                               │  merge precondition
                                               ▼
                         `merged` ▶ `deployed` ▶ `verified` ▶ `done`
```

The stages, the allowed transitions and the named edges between them are defined in one place, `Loopctl.Delivery.StageMachine` (`lib/loopctl/delivery/stage_machine.ex`). `escalated` means parked for a human. A story leaves it only through a human resolution (`resolve_escalation`).

## 1. Intake: where work comes from

An **intake source** binds one GitHub repository to one work project. It also records the epic that triaged stories are filed into and the branch that dispatches are cut from.

- Enroll it with `intake_source_enroll`, which calls `POST /api/v1/intake/sources` with a user key on a human-anchored tenant. The webhook secret is returned once, and the MCP tool writes it to a file rather than into the transcript.
- Point the repository's webhook at the returned `webhook_url`:
  - content type `application/json`
  - the **Issues** event only
  - the secret from that file
- **Name `target_epic_id`.** A source without one escalates every triaged report to a human.
- **Name `base_branch`.** Set it to `main` for a repository that uses it; the default is `master`.
- Change either later with `intake_source_update`. Revoke a source with `intake_source_revoke`. Revoking keeps the row and frees the repository for a new enrollment.

Every authentication failure on the webhook answers the same 401 `invalid_signature`: an unknown source, a revoked source, a suspended tenant, a wrong signature or a repository mismatch. The response does not tell you which.

Reporter text is untrusted from end to end. It is stored only in `untrusted_*` fields and screened for injection, and a flagged report escalates. The story the implementer eventually sees is the one triage drafted, never the reporter's own words.

## 2. Triage

A cron job (`TriageTriggerWorker`) turns each new intake record into a stub story at `detected`, which carries no reporter text. A second job (`TriageDispatcher`) sends a `triage` session to a runner that declared the `triage` kind. Triage claims nothing.

The runner answers with a `triage_verdict`: `story`, `escalate` or `reject`, with a confidence and optional per-lens verdicts.

- **`story`:** triage's drafted title, description and acceptance criteria replace the stub, and the story moves to `queued`.
- **`escalate`:** the story goes to `escalated`.
- **`reject`:** the story goes to `failed`.

A `story` verdict still escalates instead of queueing when any of these holds:
- its lens verdicts fail Gate A;
- a file it expects to touch trips Gate B;
- the repository has no single live intake source.

The gates are configured by `DELIVERY_GATES_CONFIG`; see `deploy/FLY_SECRETS.md`.

## 3. Runners

A runner is a machine you enroll and that connects to loopctl.

- **Enroll:** `runner_enroll` writes the runner's credential to a file, mode 0600, and never returns it. `max_sessions` is the ceiling on concurrent dispatches for that machine. To raise it, revoke and re-enroll.
- **Connect:** the runner joins the socket at `/runner/socket` with its credential in the `x-loopctl-runner-token` header, never in the URL.
- **Declare:** on joining, the runner declares its repositories, the kinds it runs, its capacity and the branch prefixes it accepts.
- **Watch:** `runner_pool` shows who is connected, how many sessions each machine is running, whether it is draining, whether its subscription is exhausted, and the branch prefixes it declared.

The wire protocol is the **runner contract**, declared in `Loopctl.ApiSpec.RunnerContract` and published as `priv/runner_contract/v1.json`. The file carries the current version (`x-contract-version`) and a changelog of what each minor version added. Only the major version must match, and a runner ignores fields it does not know.

## 4. Placement

Placement claims a `queued` story under a freshly minted custody dispatch and pushes the work to one runner. There are two ways to place.

- **An operator** uses `place_dispatch`, which calls `POST /api/v1/runners/:runner_id/dispatches`.
  - It needs an orchestrator-or-higher key on a human-anchored tenant.
  - `dispatch_id` is the idempotency key: retry with the same one rather than start a second session.
  - Do not send `branch`. loopctl derives it from the story, behind a prefix that machine declared.
- **The unattended dispatch driver** (`Loopctl.Delivery.DispatchDriver`) places the oldest eligible story on an eligible runner every minute, fairly across tenants.
  - It is off unless `DISPATCH_DRIVER_ENABLED` is `true` or `1`.
  - It refuses to run while any of its budgets is unset: `DISPATCH_WALL_CLOCK_SECONDS`, `DISPATCH_MAX_TURNS` and `DISPATCH_MAX_ATTEMPTS`.
  - It keeps no memory between runs. A story that needs a person is logged at ERROR as blocked, not retried in a loop.

A placement refusal says what to fix:

| Code | Meaning |
|---|---|
| `no_intake_source`, `ambiguous_intake_source` | The repository has no active intake source, or has two. |
| `runner_declines_work` | The machine is draining or declared zero sessions. |
| `runner_exhausted` | The machine's subscription is exhausted. The body carries `usage_exhausted_until`, and the hold clears by itself at that time. |
| `no_conforming_branch` | The machine's declared prefixes cannot produce a valid branch. Fix `branch_prefixes` on that machine. |
| `runner_at_capacity`, `admission_limit_reached` | No free slot, either on the machine or under the tenant's cap (`RUNNER_MAX_IN_FLIGHT_SESSIONS`). |
| `dispatch_claim_ended` | The claim this `dispatch_id` was placed under has ended. Place again with a new `dispatch_id`. |

The full list is in the OpenAPI spec for the endpoint and in the `place_dispatch` row of [mcp-server/README.md](../mcp-server/README.md).

## 5. The claim: lease and fence

A claim carries a lease (`claimed_until`) and a fence (`claim_epoch`). Every report a runner makes names the epoch, so a runner that lost its claim cannot move a story someone else now holds.

- **Renew:** an agent renews its lease with `renew_story_claim`. A claim the driver placed is capped at the dispatch deadline, and renewing past the cap is refused with 409 `lease_cap_reached`.
- **Expire:** a claim nobody renews is reclaimed by `ReclaimExpiredClaimsWorker`.
- **Release below the ceiling:** a release that counts against the retry ceiling (a crashed session or a lost lease) re-contracts the story for the next placement.
- **Release at the ceiling:** at `DISPATCH_MAX_ATTEMPTS` the release escalates the story instead, and `escalation_reason` carries the count.
- **Releases that don't count:** an exhausted subscription or a refused placement.

## 6. Review, CI and the merge gate

The session on the runner implements the story, reviews it, opens the pull request and reports each stage. A runner may move a story forward only through the stages it holds, plus the edges that send it back to `implementing`: red CI, review findings, a moved base, or a refused merge.

Before a merge, an orchestrator or operator calls `merge_precondition`, which calls `POST /api/v1/stories/:id/merge-precondition` with an orchestrator or user key. The story must be at `ci`. The gate re-runs both delivery gates over the real diff, using the lens verdicts that triage recorded rather than anything the caller sends. It also checks these, and refuses on any one:

- custody;
- a hard size bound of 12 files and 1,000 changed lines;
- the head has not moved since it was checked;
- the change is not to the loop's own deploy repository.

| Decision | Meaning |
|---|---|
| `allow` | Recorded against the head. This is the only answer that licenses a merge. |
| `refuse` | The story has already been escalated when this returns. |
| `already_merged`, `head_moved` | Nothing to do, or check again against the new head. |
| `unevaluated` | 503 with `Retry-After`. After repeated `unevaluated` answers the story escalates. |

## 7. After the merge

- **`deployed` to `verified`, or to `escalated`:** `PostDeployVerification` compares the merge commit with the repository's deployment records.
- **`verified` to `done`:** `Loopctl.Delivery.Completion` moves the story on once its GitHub issue is closed, or once it has no issue to close.
- **Closing the issue:** `IntakeIssueCloseWorker` closes the reporter's issue with a resolution label. An escalated story closes nothing.

## 8. When a story stops moving

| You see | Do |
|---|---|
| `story_stage` shows `escalated` | Read `escalation_reason`, which is untrusted session text. Then `resolve_escalation` with `to: queued` to work it again, or `done` / `failed`. It needs a user key that no dispatch minted, so a session cannot resolve its own escalation. |
| A story is held by a session that is gone | `force_unclaim_story` (orchestrator key; `exact_role`). A delivery story then goes to `escalated` over `operator_released` instead of back to the queue. Re-queue it with `resolve_escalation`. |
| A dispatch key must stop working | `revoke_dispatch` revokes it and every dispatch below it. |
| `stage: null` | The loop has never touched this story. |

A session escalates its own story with `escalate_story`, using an agent key held by the claimant.

## Operator settings

Every variable is documented, with its default and what breaks when it is wrong, in [deploy/FLY_SECRETS.md](../deploy/FLY_SECRETS.md). The ones this loop reads:

- **Driver switch:** `DISPATCH_DRIVER_ENABLED`. Turn it on last. Do not set it `false` as a Fly secret, which overrides and persists; change the `fly.toml` `[env]` line instead.
- **Dispatch budgets:** `DISPATCH_WALL_CLOCK_SECONDS`, `DISPATCH_MAX_TURNS`, `DISPATCH_MAX_ATTEMPTS` (no default; unset means the first counted release escalates).
- **Triage budgets:** `TRIAGE_WALL_CLOCK_SECONDS`, `TRIAGE_MAX_TURNS`.
- **Leases:** `STORY_CLAIM_LEASE_SECONDS`, `DISPATCH_LEASE_GRACE_SECONDS`.
- **Tenant cap:** `RUNNER_MAX_IN_FLIGHT_SESSIONS`.
- **Gates:** `DELIVERY_GATES_CONFIG` with `DELIVERY_GATES_CONFIG_SHA256`. Unset means every change escalates.
- **Post-deploy verification:** `DELIVERY_DEPLOY_ENVIRONMENT`, and `GITHUB_TOKEN` with `issues: write` and `deployments: read`.

## Wiring it up, in order

1. Enroll each runner machine (`runner_enroll`) and start the runner there with the token file.
2. Enroll the repository (`intake_source_enroll`) with its `target_epic_id` and `base_branch`, then add the GitHub webhook.
3. Set `DELIVERY_GATES_CONFIG` and its SHA, and the budget variables.
4. Confirm the runner is connected: `runner_pool` shows it, and its `branch_prefixes` are what you expect.
5. Place one story by hand (`place_dispatch`) and watch it with `story_stage`.
6. Turn on `DISPATCH_DRIVER_ENABLED`.
