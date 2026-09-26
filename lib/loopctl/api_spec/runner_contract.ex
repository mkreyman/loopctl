defmodule Loopctl.ApiSpec.RunnerContract do
  @moduledoc """
  The versioned wire contract between loopctl and a runner (issue #801).

  A runner is a dev machine that connects outbound over `LoopctlWeb.RunnerSocket`. This
  module is the ONE declaration of every message on that connection. The same schemas
  VALIDATE messages in both directions (`cast_join/1`, `cast_status/1`,
  `cast_dispatch_reply/1`, `cast_trace_batch/1`, `cast_trace_cursor/1` inbound,
  `cast_dispatch/1` outbound) and are EXPORTED as JSON
  Schema to `priv/runner_contract/v<major>.json` (`mix loopctl.runner_contract`), which
  `mkreyman/loopctl-runner` vendors. A test fails when the checked-in export drifts from
  these declarations, so the file a runner builds against is always the file loopctl
  enforces.

  ## Connection

  - socket: `wss://<host>/runner/socket/websocket?vsn=2.0.0`
  - credential: header `x-loopctl-runner-token: <raw runner key>`. Never a query
    parameter — a URL is logged by every proxy on the path.
  - topic: `"runner:<runner_id>"` — the id returned by `POST /api/v1/runners` — joined
    with a `RunnerJoin` payload. A runner may join only its own topic.

  ## Messages

  | direction | event | schema | ok reply | error `reason`s |
  |---|---|---|---|---|
  | runner -> control | `phx_join` on `"runner:<runner_id>"` | `RunnerJoin` | `{contract_version}` | `rate_limited`, `not_authorized`, `invalid_payload`, `unsupported_contract_version`, `machine_mismatch`, `forbidden_topic`, `unknown_topic` |
  | runner -> control | `"status"` | `RunnerStatus` | empty | `rate_limited`, `invalid_payload`, `internal_error` |
  | control -> runner | `"dispatch"` | `RunnerDispatch` (pushed only by `Loopctl.Runners.dispatch/3`) | — | — |
  | runner -> control | `"dispatch_reply"` | `RunnerDispatchReply` (since 1.1.0) | empty | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `stale_claim_epoch`, `already_replied`, `internal_error` |
  | runner -> control | `"trace"` | `RunnerTraceBatch` of `RunnerTraceEvent` (since 1.1.0) | `RunnerTraceAck` | `rate_limited`, `invalid_payload`, `batch_too_large`, `event_data_too_large`, `unknown_dispatch`, `stale_claim_epoch`, `dispatch_not_accepted`, `run_mismatch`, `internal_error` |
  | runner -> control | `"trace_cursor"` | `RunnerTraceCursor` (since 1.1.0) | `RunnerTraceAck` | `rate_limited`, `invalid_payload`, `internal_error` |
  | runner -> control | `"stage"` | `RunnerStageReport` (since 1.4.0) | `{stage, claim_epoch, lock_version, attempts, effects}` | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `dispatch_not_accepted`, `stale_claim_epoch`, `stale_stage`, `unknown_story_stage`, `effect_conflict`, `audit_chain_append_failed`, `internal_error` |
  | runner -> control | `"session_ended"` | `RunnerSessionEnded` (since 1.16.0) | `RunnerSessionEndedAck` | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `dispatch_not_accepted`, `stale_claim_epoch`, `already_recorded`, `unknown_story_stage`, `audit_chain_append_failed`, `internal_error` |
  | runner -> control | `"checkpoint"` | `RunnerCheckpoint` (since 1.20.0) | `RunnerCheckpointAck` | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `dispatch_not_accepted`, `stale_claim_epoch`, `not_claimant`, `claim_not_live`, `checkpoint_conflict`, `secret_blocked`, `audit_chain_append_failed`, `internal_error` |
  | runner -> control | `"thread_entry"` | `RunnerThreadEntry` (since 1.20.0) | `RunnerThreadEntryAck` | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `dispatch_not_accepted`, `stale_claim_epoch`, `idempotency_key_reused`, `secret_blocked`, `audit_chain_append_failed`, `internal_error` |
  | runner -> control | `"triage_verdict"` | `RunnerTriageVerdictMessage` (since 1.9.0) | `RunnerTriageVerdictAck` | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `dispatch_not_accepted`, `stale_claim_epoch`, `already_recorded`, `unknown_story_stage`, `stale_stage`, `audit_chain_append_failed`, `internal_error` |
  | runner -> control | any other event | — | — | `unknown_event` (since 1.2.0; every time, never `rate_limited`) |
  | control -> runner | `"disconnecting"` | `RunnerDisconnecting` (since 1.2.0) | — | — |
  | (1.3.0) a dispatch's `wall_clock_seconds` is bounded: `RunnerDispatch.max_wall_clock_seconds/0` | | | | |
  | (1.5.0) an implement dispatch carries a `RunnerStory`, and a runner may refuse a kind with `kind_not_supported` | | | | |
  | (1.6.0) a runner DECLARES the kinds it runs on join (`RunnerJoin.kinds`); where present it is the only thing consulted | | | | |
  | (1.7.0) a `triage` dispatch carries a `RunnerTriage` whose `untrusted` field is the reporter's own words, already fenced | | | | |
  | (1.8.0) `x-connection.limits` publishes every bounded field at every depth. A `fields` entry may now be a nested map, and an ARRAY of objects publishes its element bounds under `item_fields` — never `fields`, which always means the bounds of the object you are looking at | | | | |
  | (1.9.0) a triage session's result comes back on its own `triage_verdict` message, carrying EXACTLY ONE of `verdict` or `incomplete`. Idempotent per dispatch: a byte-identical resend is answered `ok`. `x-connection.permanent_errors` says which refusals are worth resending | | | | |
  | (1.9.1) `RunnerTriageVerdictMessage` and `RunnerTriageVerdictAck` are actually DEFINED. 1.9.0 named both in `x-connection` and published neither, so the envelope was unresolvable and a runner had to re-type it. RE-VENDOR: a copy taken at 1.9.0 is missing both, and the version string is the only signal that it is | | | | |
  | (1.9.2) a NULLABLE ENUM publishes `null` as a member. `incomplete` was typed `[string, null]` with an enum of five reasons, and under 2020-12 an enum constrains null too — so a runner validating a message against the published file could not SEND a real verdict beside `"incomplete": null`, while the mirror message validated. loopctl accepted both all along; the schema was what disagreed. Also publishes `x-connection.permanent_error_conditions`. RE-VENDOR to send both keys | | | | |
  | (1.9.3) `x-connection.triage_gating_reasons` publishes the `escalation_reasons` entries the control-side gate matches as whole strings, while the field itself stays free-form prose — and an escalate verdict must now carry at least one entry that is NOT a code, because a classification is not words a person can act on. RE-VENDOR: a copy taken at 1.9.2 has no such key to validate against | | | | |
  | (1.10.0) TRIAGE IS DISPATCHABLE. `x-connection.dispatchable_kinds` is `triage` and `implement`, so loopctl sends a `triage` dispatch for a story it has just detected. Only a runner that DECLARES `triage` on join receives one — `implied_by_silence` stays `implement` alone | | | | |
  | (1.11.0) a `stage` refused `stale_stage` carries the ROW — `stage`, `claim_epoch`, `lock_version`, `attempts`, `effects`, the same shape the ok ack sends. The remedy this code prescribes is to re-read the story and send the transition that applies, and there is no endpoint to read it from: the reply IS the read. A runner holding a `from` fallback list can delete it. `x-connection.error_fields` publishes what EVERY refusal carries beside its `reason`, per event and complete, and `permanent_error_conditions` now names the one state in which `stale_stage` is permanent for `stage`. RE-VENDOR: a copy taken at 1.10.0 has neither key, and the version string is the only signal that it is missing them | | | | |
  | (1.12.0) A SECURITY CORRECTION TO WHAT THIS CONTRACT PROMISES. `RunnerTriageVerdict` said loopctl "fences these strings wherever they later reach a prompt — `story` included". It does not and never did: a drafted story becomes loopctl's own story row and reaches a runner as `RunnerStory`, typed and unfenced. What loopctl DOES do is escape invisible characters and SCREEN the draft with its injection detector, escalating a flagged one to a human instead of queueing it, so it never reaches an implement dispatch. RE-VENDOR and re-read: a copy taken at 1.11.0 tells you the implement path is fenced | | | | |
  | (1.13.0) `RunnerJoin.max_sessions` IS AUTHORITATIVE DOWNWARD. loopctl now reserves against the LESSER of the value a runner declares on join and the `max_sessions` it was ENROLLED with, re-read on every join. Until now only the enrolled number counted, written once with no path from any join, so a machine configured for one session was sent two and refused the second `at_capacity` — a refusal that costs the story's claim. A machine may therefore always lower itself; it cannot raise itself past its enrolled ceiling, which is what stops a compromised runner enlarging its own share of the tenant's admission budget. Nothing changes on the wire and no runner has to send anything new. `0` is the same statement as `draining` — the row keeps `1` because its range is 1..64, and loopctl refuses to PLACE on a machine declaring either, while a direct operator push is still delivered for the runner to refuse. Re-vendoring is worth it for the description, not required for the wire | | | | |
  | (1.14.0) A RUNNER DECLARES THE BRANCH PREFIXES IT ACCEPTS (`RunnerJoin.branch_prefixes`), and loopctl DERIVES a conforming branch instead of guessing one. A runner that enforces a prefix and does not declare it refuses every dispatch loopctl sends, which is what happened: the first real placement was refused `branch_not_allowed` because loopctl derived `feature/story-<n>-<id>` while the machine's config accepted `loop/` alone, and the operator could learn the required prefix only by reading a config file on that box. OMITTING THE FIELD IS EXACTLY TODAY'S BEHAVIOUR — no constraint, and the branch is the one loopctl already derived — so an un-upgraded runner is unaffected and nothing on the wire changes for it. RE-VENDOR to send it | | | | |
  | (1.15.0) A triage verdict message may carry `lens_verdicts` (`RunnerLensVerdict`, exactly one per lens, only beside a `verdict`, capped together by `RunnerLensVerdict.max_bytes/0`). Gate A reads them at triage, before the story is queued, and again at merge, instead of anything a merge caller supplies; a verdict without them escalates at triage. RE-VENDOR to send them; a 1.14.0 holder keeps working and its verdicts escalate at triage | | | | |
  | (1.16.0) A runner may say WHY an implement session ended, with the new `session_ended` message (`RunnerSessionEnded`: `dispatch_id`, `claim_epoch`, `reason` in `completed`, `wall_clock_exceeded`, `max_turns_exceeded`, `usage_exhausted`, `crashed`). A budget kill escalates the story for a human instead of waiting out the lease and being retried, a crash releases the claim at once, and an exhausted subscription releases it without spending an attempt. Recorded ONCE per dispatch: a byte-identical resend is answered `ok` with the row even after the release it caused, a different `reason` is `already_recorded`. OPTIONAL — a runner that never sends it gets exactly today's behaviour, the lease reclaim. RE-VENDOR to send it: a 1.15.0 copy has no such event, no `RunnerSessionEndedAck` and no `session_ended_burst` | | | | |
  | (1.17.0) AN EXHAUSTED SUBSCRIPTION IS NOT CAPACITY. A `status` message may carry `usage` (`RunnerUsage`: `exhausted`, optional `resets_at` and `account_ref`), and control STORES it: while `exhausted` is true the machine — and every machine sending the same `account_ref` in the tenant — is placed nothing, by the unattended driver, the triage dispatcher and an operator's placement alike (`runner_exhausted`), until `resets_at` clamped to `x-connection.limits.usage_hold_seconds` on control's clock, or the upper bound when `resets_at` is absent. `exhausted: false` clears every machine on that `account_ref`. A `session_ended` with reason `usage_exhausted` now also holds the machine out for the upper bound, which the next `usage` corrects. A `status` carrying `usage` whose write could not land is refused `rate_limited` with `min_interval_ms`, nothing applied. OPTIONAL — a runner that never sends `usage` is never held out, except by its own `usage_exhausted` session ends. RE-VENDOR to send it: a 1.16.0 copy has no `RunnerUsage` and its `RunnerStatus` names no `usage` | | | | |
  | (1.18.0) A RELEASED STORY IS NEVER LEFT UNREACHABLE, so the row a `session_ended` ack returns after `crashed` may now be `escalated`. A counted release — a `crashed` session, a lost lease — re-contracts the story for the next placement below the retry ceiling (`DISPATCH_MAX_ATTEMPTS`, counted as `attempts.runner_lost` + `attempts.claim_released`) and escalates it at the ceiling over a new CONTROL-ONLY edge, `attempts_exhausted`, with the count in `escalation_reason`; `usage_exhausted` and a refused placement never count. A second control-only edge, `operator_released`, escalates a story an operator took back. Neither edge is runner-reportable and nothing on the wire changes shape: an `attempts` map may now carry either key. Re-vendoring is worth it for the description, not required for the wire | | | | |
  | (1.19.0) A dispatch control PLACES may carry `deadline_at` (`RunnerDispatch.deadline_at`): an instant the runner must END THE SESSION BY — the EARLIER of its own start + `wall_clock_seconds` and `deadline_at`. It is placed_at + `wall_clock_seconds` + `DISPATCH_LEASE_GRACE_SECONDS` (#879) — a RE-SEND moves it to the re-send's time + its `wall_clock_seconds` + the grace — so the time before the session starts comes out of the grace, not the wall clock; only a start-up longer than the grace shortens the session. loopctl's lease sweep never releases the claim on the story before it (an operator's force-unclaim can), so a runner that stops by it — even one cut off from control — never runs on a story the sweep released and loopctl placed again. OPTIONAL on the wire, and a holder of any earlier contract ignores it (undeclared keys are dropped) — but it is NOT PROTECTED by it: the claim is now capped at this instant whether or not the runner reads it, so a runner on an earlier contract whose start-up takes longer than the grace can still be running when the sweep releases the story. RE-VENDOR to read it | | | | |
  | (1.20.0) A SESSION REPORTS ITS WORK AS IT HAPPENS, on the story's change thread (epic 45, US-45.2). Two new messages: `checkpoint` (`RunnerCheckpoint`: `dispatch_id`, `claim_epoch`, `commit_sha`, `tree_sha`, optional `note`) for each commit the session pushed, and `thread_entry` (`RunnerThreadEntry`: `dispatch_id`, `claim_epoch`, `client_seq`, `body`, optional `checkpoint_id`) for each note it wants on the thread. Both name an ACCEPTED `implement` dispatch at its `claim_epoch`; a checkpoint is recorded only for the story's current claimant while its claim is live. Both are IDEMPOTENT: a resend of the same checkpoint, or of the same `client_seq` with the same content, is answered `ok` with `replayed: true`, and a DIFFERENT write reusing either is `checkpoint_conflict` or `idempotency_key_reused`. Each has its own bucket (`checkpoint_burst`, `thread_entry_burst`) and its own byte budget (`x-connection.limits.checkpoint`, `x-connection.limits.thread_entry`). OPTIONAL — a runner that sends neither gets exactly today's behaviour. RE-VENDOR to send them: a 1.19.0 copy has neither event, no `RunnerCheckpointAck`, no `RunnerThreadEntryAck` and no bucket for either | | | | |

  ## Branch prefixes (since 1.14.0)

  A runner may refuse a dispatch whose `branch` does not start with one of the prefixes it is
  configured for. `RunnerJoin.branch_prefixes` is how it says so, and loopctl then derives a
  branch that satisfies the declaration (`Loopctl.Delivery.DispatchPayload.branch_for/2`).

  **THE INVARIANT, and it is stronger than "silence means no constraint": A RUNNER THAT
  ENFORCES A PREFIX MUST DECLARE IT.** Silence is read as no constraint — that is what makes
  the field additive, and it is the right reading of a runner built before 1.14.0 — but it is
  not a licence to enforce one silently. A runner enforcing an undeclared prefix refuses
  EVERY dispatch loopctl sends it, permanently and invisibly: loopctl has no way to derive the
  name that machine wants, and the refusal costs the story's claim each time. There is no
  second signal. The declaration is the only way the fact reaches the control plane.

  Per-CONNECTION, like `kinds`: it is re-read on every join, so a machine whose configuration
  changed applies it by reconnecting rather than by being re-enrolled. Declare it on EVERY
  join, and declare the SAME set the runner actually enforces — a declaration that is a
  superset of what the machine accepts puts loopctl back where it started.

  The FIRST entry is the one loopctl uses, so declare them in preference order. Uniqueness is
  not negotiable: a derived branch always carries the story number and an id fragment, and a
  prefix that leaves no room for a valid branch name refuses the PLACEMENT rather than the
  join — a machine that cannot get a socket is out of the fleet, which is the trade
  `RunnerJoin.max_sessions` and `RunnerJoin.kinds` already make.

  ## The story object (since 1.5.0)

  An `implement` dispatch carries the story as TYPED FIELDS — `RunnerStory` — and loopctl
  never sends a prompt. The runner composes its own prompt from those fields with its own
  template.

  That is a security property and not a convenience. A dispatch is executed as the machine's
  user with that machine's credentials, so a control plane able to hand a runner PROSE TO
  EXECUTE is a control plane able to run anything on every enrolled laptop. Typed fields
  bound what a dispatch can say: a field the schema does not declare cannot be sent, and
  every field it does declare is data the runner places inside a template it wrote.

  The object is OPTIONAL on the wire, so a 1.4.0 runner ignores it, and it is allowed only on
  an `implement` dispatch. Its `id` must be the dispatch's own `story_id`: a dispatch naming
  one story and carrying another's text is the confusion the check exists to prevent.

  Every cap is declared once in `RunnerStory` and published at
  `x-connection.limits.story`. The per-field caps are `maxLength`/`maxItems` — characters and
  items, the units JSON Schema counts in — and the WHOLE OBJECT is bounded in bytes by the
  same `ByteRule` every other payload here is measured with (`RunnerStory.max_bytes/0`). The
  object cap is the one that usually binds, and loopctl REFUSES an oversize story rather than
  truncating it: a silently dropped acceptance criterion is a story built to the wrong spec.
  See `Loopctl.Delivery.StoryPayload`, which escalates the story to a human instead of
  dispatching a partial one.

  `domain_reference` looks like another repository's concern and is on this wire deliberately.
  `mkreyman/home_care_billing` runs a domain gate that refuses any pull request touching
  `lib/home_care_billing*` without a reference to the domain document the change belongs to
  (loopctl #805). The implementing session has to name it in the pull request it opens, and
  the session's only input is this dispatch — so a field loopctl does not carry is a field the
  session cannot produce, and every such pull request fails that repository's gate. It is one
  bounded string, chosen by triage, and no other repository is obliged to set it.

  ## Dispatchable kinds

  `kind` declares the vocabulary (`triage`, `implement`); `RunnerDispatch.dispatchable_kinds/0`
  is what loopctl will actually send, and `cast_dispatch/1` refuses anything else BEFORE a
  payload is recorded or broadcast. Since 1.10.0 that is BOTH.

  **THE INTERLOCK HAS MOVED (1.10.0), and the reasoning is kept rather than deleted, because
  it is what says when it may move again.** Triage has had its payload since 1.7.0
  (`RunnerTriage`). Until 1.7.0 it was excluded because the
  implement payload had no field that could carry the reporter's words and a triage dispatch
  would have reached a machine with no input. That is fixed: the object exists, it is
  disjoint from `story`, and the cast refuses either one on the wrong kind.

  What held it back was the OTHER END: no runner accepted the kind, so sending it would have
  spent a dispatch and a round trip on a refusal, and against an UNDECLARING runner it would
  have written a permanent `kind_not_supported` for that machine (see `RunnerJoin.kinds`).

  Both halves are answered now. The runner implementation composes its three triage lenses
  from its own tool set and emits a `triage_verdict` (1.9.x), so the work has somewhere to
  land — and an undeclaring runner is still protected, because `implied_by_silence/0` stays
  `implement` ALONE: a machine that says nothing is sent exactly what it was sent before, and
  only a runner that DECLARES `triage` on join receives one. That asymmetry is the whole
  safety of this bump and must not be "tidied up" by making the two lists equal.

  The `kind` enum kept `triage` throughout, which is what let both sides be built at once:
  narrowing an enum is a BREAKING change and a minor version may only add.

  A runner may also answer a dispatch with `kind_not_supported`, a CAPABILITY statement rather
  than a fault: this machine does not do this kind of work. loopctl records it and does not
  send that kind to that runner again (`Loopctl.Runners.DispatchLedger.kind_unsupported?/3`).

  ### A runner DECLARES its kinds on join (since 1.6.0), and the declaration decides

  `RunnerJoin.kinds` is the positive statement of the same fact, and where it is present it is
  the ONLY thing consulted: `Loopctl.Runners.dispatch/3` refuses a kind outside it and sends a
  kind inside it even when the ledger holds an old `kind_not_supported` for that pair. A runner
  that does not send `kinds` — every runner built before 1.6.0 — is read as declaring
  `["implement"]`, the only kind loopctl sent before this version, so nothing it has not already
  agreed to reaches it.

  It exists because the ledger's inference is a CACHED NEGATIVE with no expiry and no clearing
  path: one `kind_not_supported` reply is permanent for the life of the `runners` row, so a
  runner that gains a kind by being upgraded stays ineligible for it until a human revokes and
  re-enrols the machine. Worse in the other direction — `implement` was the only dispatchable
  kind, so a runner that mapped a transient local condition to that reason took itself out of
  ALL work silently. A declaration has neither problem: it is per-CONNECTION, carried in the
  runner's Presence meta rather than a table, so an upgraded runner reconnecting declares its
  new set and is immediately eligible, and a downgrade is just as visible.

  The ledger memory is kept, and is still what an operator reads
  (`Loopctl.Runners.unsupported_kinds/1`): it is the record of what a machine actually REFUSED,
  which a declaration — a claim made at join time about a future dispatch — cannot replace. It
  is the fallback for an undeclaring runner and the audit trail for a declaring one.

  ## Stage reporting (since 1.4.0)

  A runner reports each delivery-stage transition its session made with `stage`. **Postgres
  owns the stage; the message is a request.** The server compare-and-sets `from` -> `to` on
  the story's `story_stages` row in one transaction, fenced on `claim_epoch` exactly as
  `dispatch_reply` and `trace` are, and answers with the row's new stage, epoch,
  `lock_version` and `attempts`. The transition table is published at
  `x-connection.stage_transitions`, derived from the server's own machine.

  **A runner may report what its own session DID AND CONTROL CAN INDEPENDENTLY CHECK, plus
  its own escalation — never the outcome of a check it does not perform.** The published
  table is that rule applied to the server's machine, by two allowlists.

  The EDGES exclude the verdicts some other principal reaches about the session:
  `merge_gate` (the merge-precondition gate is control's), `verification_failed` (post-deploy
  verification compares the deployed sha against the merge commit, which the session cannot
  see) and `budget_exceeded` (`failed` is terminal with no way out at all, so a runner able
  to report it could park a story for good — a session out of budget escalates instead and
  control decides). Also held back: anything into `claimed`, and `runner_lost`,
  `claim_released` and `human_resolution`.

  The SOURCES stop at `merged`, which is where the loop stops producing things control can
  check and starts producing verdicts. `merged` carries a `merge_sha` and `deployed` a
  `release_id`, both of which GitHub can confirm; `verified` and `done` carry nothing and are
  pure verdicts. **A story therefore WAITS at `deployed` for control to decide
  verified-or-escalated, and a runner has no path to `verified` or `done` at all.** Reporting
  the deploy is the last thing a session does.

  Arriving at a terminal stage ends the session and the runner's slot goes back in the same
  transaction — the server decides that from the destination stage, so no message can free a
  slot while its session runs. The only terminal a runner can reach is `escalated`, which
  STOPS the loop rather than completing it; `done` and `failed` are not reportable at all.

  Every `stage` message is safe to REPLAY, and the ack tells you what the server holds. One
  whose first copy committed finds the row already at `to` under the same epoch and is
  answered `ok` with that row, so a re-send after a lost acknowledgement — which happens on
  every rolling deploy — never transitions twice. A message for a row that has moved somewhere
  ELSE is `stale_stage`, and since 1.11.0 that refusal CARRIES THE ROW — the same
  `{stage, claim_epoch, lock_version, attempts, effects}` the ok ack sends, beside the
  `reason`. Send the transition that applies FROM the `stage` it names; do not guess by
  trying each `from` in turn, and do not go looking for an endpoint to read the row from.
  There is none, deliberately: the reply is the read.

  **A replay must carry the SAME identities its first copy did.** One that names a DIFFERENT
  value for an identity already recorded is `effect_conflict`, never `ok`: the case that
  forces it is `ci -> merged`, where a lost ack and a retry that produced a second merge
  commit would otherwise leave the row and the `story_stage_merged` chain entry naming a
  merge that is not the branch's. The ack's `effects` is what the row actually holds, so a
  runner can see which value survived and reconcile against it. Do not re-send after an
  `effect_conflict`.

  ## Session end (since 1.16.0)

  `session_ended` tells control WHY the session under an implement dispatch stopped. Before it,
  control learned a session had died only when its claim lease ran out, so a wall-clock kill, a
  turn-budget kill, a subscription that ran dry and a crash all looked the same and would all
  have been retried. **The message states a FACT; control decides what the story does about
  it**, and a runner's word never makes a story terminal:

  - `completed` — nothing changes. Where the session got to is what its `stage` messages said.
  - `wall_clock_exceeded`, `max_turns_exceeded` — an in-flight story goes to `escalated` over
    `budget_reported`, a CONTROL-ONLY edge that is deliberately absent from
    `x-connection.stage_transitions`: a runner reports the kill, it cannot take the edge. The
    session's slot goes back in that transition, and the claim it ran under ENDS, so the
    escalated story is held by nobody. Never retried — the same budget would kill it again —
    and never `failed`, which has no way out.
  - `crashed` — the claim is released NOW, as a lease reclaim would release it later: the
    story goes back to `queued` over `runner_lost` and the slot goes back. It is a COUNTED
    release (since 1.18.0): below the retry ceiling the story is re-contracted for the next
    placement; the release that reaches the ceiling escalates it instead, over the
    CONTROL-ONLY `attempts_exhausted` edge, so the ack's `stage` is then `escalated`.
  - `usage_exhausted` — released the same way, and NOT counted as an attempt against the
    story: the subscription ran out and the work was never judged. Always re-contracted.

  Send it once, after the session has stopped, for an ACCEPTED `implement` dispatch — a triage
  session ends through `triage_verdict`, and naming a triage dispatch here is
  `unknown_dispatch`. It is optional: a runner that never sends it gets exactly the behaviour
  before 1.16.0.

  **RECORDED ONCE PER DISPATCH, AND RESENDING IS SAFE.** A byte-identical resend is answered
  `ok` with `replayed: true` and the row as it now stands — EVEN AFTER the release its first
  copy caused has moved the story's `claim_epoch` on, because the resend is matched on its
  bytes BEFORE the epoch is checked. So on any refusal outside `permanent_errors`, and on a
  lost acknowledgement, send the same bytes again. A resend carrying a DIFFERENT `reason` is
  `already_recorded`, permanently: the two sides disagree about how the session ended. A FIRST
  report whose `claim_epoch` is not the story's current one is `stale_claim_epoch` and changes
  nothing — the claim it is about has already ended some other way.

  **A BUDGET KILL WHOSE ESCALATION DID NOT LAND** is answered by why, AFTER the report was
  recorded. `rate_limited` — a lock was not free, or the row kept moving under the escalation
  — is the one retry: send the same bytes, and the resend re-drives the escalation and the
  claim's end. `audit_chain_append_failed` — the tenant's hash chain refused the escalation's
  entry — is PERMANENT, exactly as on `stage`: every chained transition in the tenant is
  failing until an operator repairs the chain, so do NOT resend. A chain whose append trips
  its own HASH check answers the same code rather than dropping the connection. The claim stays
  held meanwhile, and the lease reclaim is the re-driver: when the lease runs out it takes the
  same escalation instead of re-queueing the story, and leaves the claim held while the chain
  still refuses — so a budget-killed story is never re-queued, and is escalated on the first
  sweep after the repair.

  ## Change threads (since 1.20.0)

  A story's change thread (`Loopctl.Threads`) is the record of the commits its claimant
  reported and the notes written around them. The runner is the only party that knows when a
  checkpoint exists, so it reports each one as the session pushes it, rather than leaving the
  thread to be reconstructed afterwards. Both messages are OPTIONAL: a runner that never sends
  them gets exactly the behaviour before 1.20.0.

  - `checkpoint` — a commit the session pushed: `commit_sha` and its `tree_sha`, lowercase
    hex, both 40 or both 64 characters, and an optional `note` saying why. It is recorded only
    for the story's CURRENT claimant (the runner's agent, which a placement claims the story
    as) presenting the current `claim_epoch` while the claim is live — `not_claimant`,
    `stale_claim_epoch` and `claim_not_live` otherwise, all permanent: the claim this session
    ran under is over, so stop reporting on it. A checkpoint's parent is loopctl's to derive
    (the previous checkpoint of the same claim); nothing on the wire names one.
  - `thread_entry` — a note on the thread (kind `message`, always). `client_seq` is the
    runner's own counter for the dispatch, and the entry's idempotency key is
    `<dispatch_id>:<client_seq>`, so number each note once and never reuse a number for
    different content. An optional `checkpoint_id` (from a `checkpoint` ack) ties the note to
    that checkpoint. A NEW note is refused `stale_claim_epoch` once the story's claim has
    moved past the message's epoch.

  Both name an ACCEPTED `implement` dispatch; any other kind is `unknown_dispatch`, as on
  `session_ended`, and a dispatch no longer accepted is `dispatch_not_accepted` — except for
  a RESEND, below. The story is never taken off the wire. A write that could not
  get its locks in time is refused `rate_limited` with `min_interval_ms`; nothing was
  written, so resend after that interval.

  **RESENDING IS SAFE, AND IS THE ANSWER TO A LOST ACK.** A byte-identical checkpoint, or a
  `thread_entry` with the same `client_seq` and the same content, is answered `ok` with
  `replayed: true` and the id it was first recorded under. Either one's resend is answered from
  its row even after the claim's lease has lapsed or the claim has moved, and whatever the
  dispatch's status by then, because the write happened while it was live. A DIFFERENT write reusing either identity is refused — `checkpoint_conflict` (the
  same commit under this claim with another tree or note) and `idempotency_key_reused` (the
  same `client_seq` with other content) — permanently, because acknowledging it would tell the
  runner its new content was recorded when it was not.

  **EVERY `note` AND `body` IS SCANNED FOR CREDENTIALS** before anything is written, because
  an entry is served to every role of the tenant and nothing can edit or remove one. A
  credential-shaped value is `secret_blocked`, permanently for those bytes: remove the value
  and send a new write under a new `client_seq`.

  **THE MESSAGE CAP IS WHAT BINDS.** The whole message is bounded by the byte rule at
  `x-connection.limits.checkpoint.max_bytes` / `thread_entry.max_bytes`, so a conforming
  message always fits a frame. The byte rule charges 6 bytes per character, so a note well
  under the per-field `thread_body_max_utf8_bytes` (the HTTP surface's cap, whose `maxLength`
  counts graphemes and is looser still) can already exceed it: measure the message under the
  byte rule, not the field, and split a long note across several entries.

  ## Server-initiated disconnects (since 1.2.0)

  Before loopctl closes a runner's connection itself, it pushes `"disconnecting"` on the
  runner's topic with a stable `reason` (`RunnerDisconnecting.reasons/0`), then closes, so
  the runner can tell a revocation from a deploy from a network drop. `runner_revoked` and
  `no_longer_authorized` precede the socket being closed; `server_shutdown` precedes the
  drain of a stopping node, after which the runner should reconnect. A join refused as
  `not_authorized` cannot carry a push — the topic was never joined — so its error reply
  carries `disconnecting: "join_refused_not_authorized"` instead, and the socket is closed
  only after that reply has been sent.

  ## Rate limits

  Published in `x-connection.limits`, and enforced per channel:

  - `min_interval_ms` (`min_interval_ms/1`) — `status` 1000 ms, `trace` 50 ms,
    `trace_cursor` 50 ms. Each event has its OWN floor: a `trace` batch is not held back by a recent
    `status` or `trace_cursor`, so the resume sequence (cursor, then batches) is never
    refused, and a rejoining runner ships up to 20 batches a second.
  - `dispatch_reply_burst` (`dispatch_reply_burst/0`) — a bucket of 8 replies that refills
    one every 250 ms, so several dispatches can be answered back to back.
  - `triage_verdict_burst` (`triage_verdict_burst/0`) — a bucket of 4 that refills one a
    second. A verdict is produced ONCE per run and cannot be re-derived once the session has
    stopped, so this is sized against losing a run's whole output to a token bucket rather
    than against a flood.
  - `session_ended_burst` (`session_ended_burst/0`, since 1.16.0) — a bucket of 4 that
    refills one a second, for the same reason as the verdict's: one message per session, and a
    report refused by a token bucket is a report the runner must hold and resend.
  - `checkpoint_burst` (`checkpoint_burst/0`, since 1.20.0) — a bucket of 8 that refills one
    every 500 ms. A session pushes a commit every few minutes; the bucket is for a runner
    flushing what it buffered across a rejoin.
  - `thread_entry_burst` (`thread_entry_burst/0`, since 1.20.0) — a bucket of 12 that refills
    one every 250 ms, the `stage` bucket's size: notes come in bursts, and each one is a
    transaction that appends to the tenant's audit chain.
  - `permanent_errors` (`permanent_errors/0`) — the refusal codes no resend can clear.
    Branch on this rather than on a list copied into a runner's own source; everything not
    in it is worth resending unchanged.

  - `triage_gating_reasons` (`Loopctl.DeliveryGates.GateA.gating_reason_codes/0`) — the
    `escalation_reasons` entries the control-side gate matches as WHOLE STRINGS. Published
    for the reason the 1.9.0 envelope had to be: a rule that decides an outcome, living in
    one side's prose, cannot be checked from the other — and it had already failed exactly
    that way, where the lens prompts asked for "one plain sentence per reason" and neither
    code could ever fire.

    **WHERE THEY GATE (since 1.15.0).** In the `escalation_reasons` of each
    `RunnerLensVerdict` a triage message carries: `GateA` reads the three lens verdicts,
    translated by `Loopctl.Delivery.GateAInput` from the wire's `outcome`/enum shape to its
    own, at triage and again at merge. The MERGED verdict's `escalation_reasons` still gate
    nothing — they are recorded for the operator. Before 1.15.0 Gate A read a trio a merge
    caller supplied, which is why this line once said nothing a runner sent could gate.

  - `permanent_error_conditions` (`permanent_error_conditions/0`) — the ONE code in the list
    above whose permanence has a condition, published so a runner reads the condition rather
    than inferring it. `dispatch_not_accepted` means the ledger row for that dispatch is not
    `accepted`, and it covers three states: `sent` — the accept has not landed yet, which is
    the ordinary TRANSIENT case while the runner's own accept reply is in flight,
    rate-limited, or being carried across a rejoin — and `refused` or `superseded`, both of
    which are FINAL and which no later accept can move.

    So the condition is narrower than "an accept is outstanding", and the narrowing is the
    whole content: a runner may back off and retry only while an accept it sent for THIS
    dispatch is unacknowledged AND it has not since refused that dispatch or seen its claim
    reclaimed — a refusal it sent itself, and a `claim_epoch` that has moved, are both things
    the runner knows locally. With any of those, or with no accept outstanding at all, the
    run must be given up: nothing will move the row, and retrying is an unbounded loop
    against a doomed dispatch. Bounded either way — a lost accept reply after a reclaim is
    the case that makes "an accept is outstanding" alone insufficient, and it is exactly the
    case a rejoin produces. Raised by the `loopctl-runner` session on 2026-09-15, whose
    retry behaviour disagreed with what this contract published, rather than left to drift.

  Only a message that is ACTED ON counts: one refused before the database (`invalid_payload`,
  `batch_too_large`, `event_data_too_large`) neither starts a floor nor spends a reply, so
  a runner can correct it and resend at once. A message inside its limit is refused with
  `rate_limited` and `min_interval_ms`; send it again after that long.

  One case that rule does not cover: a message the server ACCEPTED but could not write,
  because a database lock it needed was not free (loopctl #803). It comes back as
  `rate_limited` with a `min_interval_ms` LONGER than that wait, and it has already spent its
  trace floor or a `dispatch_reply` bucket token — it reached the database, which is what the
  floors meter. A runner that keeps re-sending inside the interval it was given can therefore
  run its reply bucket down while none of the replies is recorded; wait the interval out.

  ## Values

  Every UUID a runner sends is normalized to lowercase before it is compared or stored, so
  `ABCD...` and `abcd...` are the same id. `seq` must be below 2^63 - 1, and no number in a
  `trace` or `dispatch_reply` may have more digits than the byte rule allows. No string —
  including any key or value inside an event's `data` — may contain a NUL character
  (`\\u0000`), which Postgres cannot store; such a message is `invalid_payload`.

  ## Dispatch replies

  A runner answers every `dispatch` it validated with one `dispatch_reply`. The first reply
  moves the ledger row out of `sent`; an IDENTICAL second reply is `ok` (so a reply whose
  acknowledgement was lost can be re-sent), and a DIFFERENT one is `already_replied`. A
  reply for a dispatch this runner was not sent — including another runner's or another
  tenant's — is `unknown_dispatch`, and one whose `claim_epoch` is not the dispatched one is
  `stale_claim_epoch`.

  ## Trace

  The runner's on-disk NDJSON file is the source of truth. It ships events in batches of at
  most `RunnerTraceBatch.max_events/0` events and `RunnerTraceBatch.max_bytes/0` bytes, each
  event at most `RunnerTraceEvent.max_bytes/0` with at most `RunnerTraceEvent.max_data_bytes/0`
  of `data`. Every byte limit is counted by ONE published rule (`ByteRule`, exported as
  `x-connection.limits.json_byte_rule` with its text, and quoted in each schema's description):
  six bytes per string character, a fixed width per scalar, a fixed cost per container and
  member. It bounds the compact JSON of any conforming encoder, whatever that encoder escapes,
  so a runner that splits by it never sends a frame the socket closes — the transport closes an
  oversize frame before loopctl sees it. Large payloads belong in object storage, referenced
  from `data`; the server stores `(run_id, seq)` once
  and replies `acked_seq`, the highest seq such that EVERY seq from 0 to it is stored. The
  runner resumes from `acked_seq + 1` — on a rejoin it asks `trace_cursor` first, because
  Phoenix replays nothing and a rejoin happens on every rolling deploy. The first batch of a
  run binds its `run_id` to the dispatch; a run belongs to one accepted dispatch.

  ## Versioning

  `version/0` is semver. A runner sends its `contract_version` on join; the join is
  refused unless the MAJOR matches. Minor versions only ADD optional fields, so an
  older server ignores fields it does not declare rather than refusing them, and a
  runner must do the same with a newer server's pushes.
  """

  require OpenApiSpex

  alias Loopctl.Delivery.StageMachine
  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.Runners.Usage
  alias Loopctl.Threads.Entry, as: ThreadEntry
  alias OpenApiSpex.Schema

  @version "1.20.0"
  @major 1

  defmodule ByteRule do
    @moduledoc false

    # ONE encoder-independent rule for the size of runner-supplied JSON (issue #803). It does
    # not model any encoder's escaping: it charges every string character the most any
    # conforming encoder can spend on it (a six-byte \\uXXXX; two of them for a character
    # outside the BMP), and every scalar a fixed width. Go's encoding/json escapes < > &, .NET
    # escapes more, a JSON library can escape everything — the bound holds for all of them.
    # The constants are published in the contract export, the text in every schema that
    # carries a byte limit, and a test evaluates the PUBLISHED constants against `bytes/1`.
    @per_char 6
    @per_string 12
    @per_scalar 32
    @per_container 2
    @per_member 2
    @max_number_digits 31

    @doc "The rule's constants, as the export publishes them."
    @spec constants() :: %{String.t() => pos_integer()}
    def constants do
      %{
        "per_string_char" => @per_char,
        "per_string" => @per_string,
        "per_scalar" => @per_scalar,
        "per_container" => @per_container,
        "per_member" => @per_member,
        "max_number_digits" => @max_number_digits
      }
    end

    @doc "The rule as one sentence, published verbatim."
    @spec text() :: String.t()
    def text do
      "Byte rule (compact JSON, any encoder): count #{@per_char} bytes for every character " <>
        "of every string and object key (#{2 * @per_char} for a character outside the Basic " <>
        "Multilingual Plane) plus #{@per_string} per string; #{@per_scalar} per number, true, " <>
        "false or null; #{@per_container} per array or object; #{@per_member} per array " <>
        "element or object member. A number may have at most #{@max_number_digits} digits."
    end

    @doc "The largest integer magnitude the rule's fixed scalar width covers."
    @spec max_number_digits() :: pos_integer()
    def max_number_digits, do: @max_number_digits

    @doc "The size of `term` under the rule."
    @spec bytes(term()) :: non_neg_integer()
    def bytes(term) when is_binary(term), do: @per_char * utf16_units(term) + @per_string
    def bytes(term) when is_number(term) or term in [true, false, nil], do: @per_scalar
    def bytes(term) when is_atom(term), do: bytes(Atom.to_string(term))

    def bytes(term) when is_list(term),
      do: @per_container + Enum.sum_by(term, &(@per_member + bytes(&1)))

    def bytes(term) when is_map(term),
      do: @per_container + Enum.sum_by(term, fn {k, v} -> @per_member + bytes(k) + bytes(v) end)

    # A character outside the BMP is two UTF-16 code units (a surrogate pair when escaped).
    # A byte that is not UTF-8 (the socket's JSON decoder refuses those first) counts as one.
    defp utf16_units(string), do: utf16_units(string, 0)
    defp utf16_units(<<>>, n), do: n
    defp utf16_units(<<c::utf8, rest::binary>>, n) when c > 0xFFFF, do: utf16_units(rest, n + 2)
    defp utf16_units(<<_c::utf8, rest::binary>>, n), do: utf16_units(rest, n + 1)
    defp utf16_units(<<_byte, rest::binary>>, n), do: utf16_units(rest, n + 1)
  end

  defmodule Limits do
    @moduledoc false

    alias OpenApiSpex.Schema

    @doc """
    The bounds a runner cannot read off the schema, for `x-connection.limits`.

    ONE implementation, and it is one because there were three. `RunnerStory`,
    `RunnerTriage` and `RunnerTriageVerdict` each carried an identical copy, which is the
    drift this contract spends its comments warning about: the copies were not identical for
    long. The first version handled a flat string and an array of strings only, so a nested
    OBJECT and an array of objects published nothing — and because `RunnerStory` is flat its
    own table looked complete, which made the gap read as a precedent rather than a bug.

    The object cap is the value that matters most here: it is not a JSON Schema keyword, so a
    runner pre-flighting a payload against the vendored contract cannot learn it any other
    way.
    """
    @spec of(Schema.t(), pos_integer()) :: %{String.t() => term()}
    def of(%Schema{} = schema, max_bytes) do
      %{"max_bytes" => max_bytes, "fields" => fields(schema)}
    end

    defp fields(%Schema{properties: props}) when is_map(props) do
      for {name, sub} <- props,
          bounds = field_bounds(sub),
          bounds != %{},
          into: %{},
          do: {Atom.to_string(name), bounds}
    end

    defp fields(%Schema{}), do: %{}

    # EVERY BOUNDED FIELD AT EVERY DEPTH, and "every depth" is now something the code does
    # rather than something this comment claims. It matched `items: %Schema{}`, so an array
    # that declares `maxItems` and leaves its items unstated published NOTHING — `max_items`
    # included. A cap that binds, dropped because the thing inside it had no bound of its own,
    # is the same "reads as complete, is not" defect this module was extracted to end.
    defp field_bounds(%Schema{type: :array, maxItems: items} = schema) when is_integer(items) do
      Map.merge(%{"max_items" => items}, item_bounds(schema.items))
    end

    defp field_bounds(%Schema{type: :string, maxLength: length}) when is_integer(length),
      do: %{"max_length" => length}

    defp field_bounds(%Schema{type: :object, properties: props}) when is_map(props) do
      nested = fields(%Schema{type: :object, properties: props})
      if nested == %{}, do: %{}, else: %{"fields" => nested}
    end

    defp field_bounds(%Schema{}), do: %{}

    # AN ARRAY'S BOUNDS ARE PER-ITEM AND THE KEY MUST SAY SO. `max_item_length` already did,
    # for the string case, and it is kept unchanged so a runner reading the old table still
    # finds what it read before. The object case did NOT: it returned `field_bounds/1`'s
    # `"fields"`, the same key an OBJECT property publishes — so `contradicts` came out as
    # `{"max_items": 3, "fields": {"why": {"max_length": 200}}}` where `fields` means "each
    # item's fields", while `story` published `{"fields": {...}}` where it means "this
    # object's fields". One recursive reader cannot tell them apart, and the one that guesses
    # wrong applies a per-element cap to a three-element array and only finds out when a real
    # verdict is refused. `item_fields` removes the guess. Nothing published before 1.8.0
    # carried a nested map at all — `RunnerStory` is flat — so this renames nothing a runner
    # has vendored.
    defp item_bounds(%Schema{type: :string, maxLength: length}) when is_integer(length),
      do: %{"max_item_length" => length}

    defp item_bounds(%Schema{type: :object, properties: props}) when is_map(props) do
      nested = fields(%Schema{type: :object, properties: props})
      if nested == %{}, do: %{}, else: %{"item_fields" => nested}
    end

    # AN ARRAY OF ARRAYS HAS NO AGREED WIRE SHAPE, and inventing one here would put a key
    # nobody decided on into a contract runners vendor. No such field exists today. It
    # REFUSES rather than dropping the inner bounds silently, because silent dropping is
    # exactly what shipped last time: the build fails the moment such a field is added, and
    # naming its published shape becomes a contract decision instead of an accident.
    defp item_bounds(%Schema{type: :array} = item) do
      raise ArgumentError,
            "an array of arrays has no published limits shape; name one before adding " <>
              "this field: #{inspect(item)}"
    end

    defp item_bounds(%Schema{}), do: %{}
    defp item_bounds(nil), do: %{}
  end

  defmodule Kinds do
    @moduledoc false

    # The dispatch-kind VOCABULARY, and the subset loopctl will actually send. ONE declaration,
    # read by two schemas that sit at opposite ends of this file: `RunnerJoin.kinds` (what a
    # runner says it runs, since 1.6.0) and `RunnerDispatch.kind` (what control sends). They
    # cannot drift, because a second copy is what would let a runner declare a kind the cast
    # then refuses — a runner correctly advertising a capability and never being given it.
    #
    # `triage` stays in the vocabulary and out of the dispatchable set. Narrowing an enum would
    # be a BREAKING change and a minor version may only add — and the vocabulary is what a
    # runner declares and answers `kind_not_supported` about.
    #
    # DO NOT READ AN OLDER REASON HERE. This comment used to say triage was off the wire
    # because `RunnerDispatch` had no field that could carry the reporter's words. Since
    # 1.7.0 it has one — `RunnerTriage` — and the moduledoc was rewritten to say so. This was
    # the surviving copy of the retired reason, in the module whose own comment two lines up
    # argues that a second copy is the drift to avoid. What holds triage back now is the
    # OTHER END: no deployed runner accepts the kind. The moduledoc has the full version;
    # this stays one sentence so the two cannot diverge again.
    @all ["triage", "implement"]
    @dispatchable ["triage", "implement"]

    # What a runner built before 1.6.0 is read as having declared. It MUST be the set loopctl
    # was already sending when the field did not exist, or introducing the field would start
    # sending an undeclaring runner something it never agreed to — or stop sending it work it
    # has been doing all along.
    @implied_by_silence ["implement"]

    @doc "Every dispatch kind the contract names."
    @spec all() :: [String.t()]
    def all, do: @all

    @doc "The kinds loopctl will send. Every other declared kind is refused by the cast."
    @spec dispatchable() :: [String.t()]
    def dispatchable, do: @dispatchable

    @doc """
    The kinds a runner that sends no `kinds` on join is read as declaring. See the module
    comment: it is what loopctl sent before the field existed, and nothing else is safe.
    """
    @spec implied_by_silence() :: [String.t()]
    def implied_by_silence, do: @implied_by_silence
  end

  defmodule RunnerSample do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerSample",
        description:
          "A self-measured health sample. Connected is not able-to-build: a wedged " <>
            "machine still answers heartbeats, so the control plane treats a stale " <>
            "sample as a breached threshold.",
        type: :object,
        required: [:sampled_at, :loadavg_1m, :free_ram_mb, :free_disk_mb],
        properties: %{
          sampled_at: %Schema{type: :string, format: :"date-time"},
          loadavg_1m: %Schema{type: :number, minimum: 0},
          free_ram_mb: %Schema{type: :integer, minimum: 0},
          free_disk_mb: %Schema{type: :integer, minimum: 0},
          last_build_at: %Schema{
            type: :string,
            format: :"date-time",
            nullable: true,
            description: "When this machine last completed a build successfully."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerUsage do
    @moduledoc """
    The `usage` a `status` message may carry (1.17.0, epic 44 US-44.6): whether the account the
    runner's sessions run on is out of subscription usage, and until when.

    Control keeps an exhausted machine out of every placement until the reset, CLAMPED to
    `[now + Loopctl.Runners.Usage.min_hold_seconds(), now + Loopctl.Runners.Usage.max_hold_seconds()]`
    on control's clock. See `Loopctl.Runners.Usage` for what each value does.
    """

    require OpenApiSpex

    # Mirrors the `runners_account_ref_shape` CHECK: printable ASCII, no whitespace. An opaque
    # value compared for equality, so nothing about it needs to be readable — only bounded, and
    # safe to put in a log line and a Postgres text column (no NUL, no control characters).
    @account_ref_max_length 128
    @account_ref_pattern "^[!-~]+$"

    @doc "The longest `account_ref` the contract accepts."
    @spec account_ref_max_length() :: pos_integer()
    def account_ref_max_length, do: @account_ref_max_length

    OpenApiSpex.schema(
      %{
        title: "RunnerUsage",
        description:
          "Whether the account this runner's sessions run on has exhausted its subscription " <>
            "usage (since 1.17.0). `exhausted: true` keeps the machine — and every machine " <>
            "sending the same `account_ref` — out of every placement until `resets_at`, held " <>
            "by control to between one minute and eight days from control's own clock, and to " <>
            "eight days when `resets_at` is absent: an exhaustion is never ignored. " <>
            "`exhausted: false` clears it for every machine on that `account_ref`. A " <>
            "`session_ended` with reason `usage_exhausted` marks the machine for eight days " <>
            "on its own, which the next `usage` with a `resets_at` corrects. Optional; a " <>
            "runner that never sends it is never held out.",
        type: :object,
        required: [:exhausted],
        properties: %{
          exhausted: %Schema{
            type: :boolean,
            description: "True while the account cannot start a session."
          },
          resets_at: %Schema{
            type: :string,
            format: :"date-time",
            nullable: true,
            description:
              "When the account's usage window resets, on the runner's clock. Read only " <>
                "beside `exhausted: true`. Clamped, never trusted as sent."
          },
          account_ref: %Schema{
            type: :string,
            minLength: 1,
            maxLength: @account_ref_max_length,
            pattern: @account_ref_pattern,
            description:
              "An opaque, stable value the runner derives from the login its sessions run " <>
                "under — a hash, never the credential. Machines sending the same value are " <>
                "exhausted and cleared together. Omitted, the value last sent is kept."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerJoin do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.Kinds
    alias Loopctl.ApiSpec.RunnerContract.RunnerSample

    # A SIZE bound on `kinds`, deliberately not `length(Kinds.all())`. Tying it to the
    # vocabulary would refuse the join of a runner declaring a kind a later version adds, or
    # one that repeated an entry — both of which this field promises to ignore rather than
    # punish. Generous enough that no honest runner reaches it, small enough to bound the
    # array a join may carry.
    @max_declared_kinds 20

    # And the other half of that bound, which the entry count alone does not give: a kind is
    # an identifier, and the longest this contract has ever named is nine characters. The
    # size that matters is entries TIMES length, because the value is replicated to every
    # node by Presence and echoed on the pool read.
    @max_kind_length 64

    # `branch_prefixes` carries the SAME exposure as `kinds` and is bounded the same way, in
    # both dimensions: the value goes verbatim into the Presence meta, which `Phoenix.Tracker`
    # replicates to every node for the life of the socket, and `GET /api/v1/runners/pool`
    # echoes it. Entries alone bound nothing — the size that matters is entries TIMES length.
    # Smaller than the `kinds` pair because a prefix is a branch-name fragment a person types
    # into a config file, not an identifier space that grows with the contract.
    @max_declared_branch_prefixes 8
    @max_branch_prefix_length 40

    OpenApiSpex.schema(
      %{
        title: "RunnerJoin",
        description: "The payload a runner joins its own `runner:<runner_id>` topic with.",
        type: :object,
        required: [
          :contract_version,
          :machine,
          :cores,
          :memory_mb,
          :repos,
          :max_sessions,
          :in_flight,
          :draining
        ],
        properties: %{
          contract_version: %Schema{
            type: :string,
            pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$",
            description: "The contract version the runner was built against (semver)."
          },
          machine: %Schema{
            type: :string,
            pattern: "^[a-z0-9][a-z0-9._-]{0,62}$",
            description: "The machine name the runner was enrolled under. Must match exactly."
          },
          cores: %Schema{type: :integer, minimum: 1, maximum: 1024},
          memory_mb: %Schema{type: :integer, minimum: 1},
          repos: %Schema{
            type: :array,
            maxItems: 50,
            items: %Schema{
              type: :string,
              pattern: "^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$"
            },
            description: "GitHub `owner/repo` checkouts this runner can work in."
          },
          max_sessions: %Schema{
            type: :integer,
            minimum: 0,
            maximum: 64,
            description:
              "Concurrent sessions this machine accepts; it refuses past them with " <>
                "`at_capacity`. AUTHORITATIVE DOWNWARD since 1.13.0: loopctl reserves " <>
                "against the LESSER of this and the max_sessions the runner was ENROLLED " <>
                "with, re-read on EVERY join. So a machine can always take itself DOWN and " <>
                "cannot raise itself above its enrolled ceiling — declaring more than that " <>
                "is held at the ceiling, silently, and `GET /api/v1/runners/pool` shows both " <>
                "numbers. Before 1.13.0 this field was advisory and only the enrolled value " <>
                "counted, which no join could correct. Send the real value every time: it is " <>
                "per-connection, so a machine whose configuration changed applies it by " <>
                "reconnecting. Lowering it below the sessions loopctl currently holds on " <>
                "this machine sends no more work until those drain, rather than cancelling " <>
                "them. `0` means THIS MACHINE IS TAKING NO WORK and is the same statement as " <>
                "`draining`: the held column is 1..64 so the row keeps `1`, and loopctl " <>
                "refuses to PLACE on a machine declaring either. Refusing a placement is " <>
                "what is promised and it is not the whole surface — a dispatch an operator " <>
                "pushes at this machine by name is still delivered, and the runner refuses " <>
                "it with `draining`, because that path claims nothing and the refusal reaches " <>
                "a person."
          },
          in_flight: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "Sessions running now, as the runner counts them. A hint: capacity is " <>
                "reserved in Postgres, never read off Presence."
          },
          draining: %Schema{
            type: :boolean,
            description: "True when the runner accepts no new dispatches."
          },
          # NOTHING HERE REFUSES A JOIN OVER WHICH KINDS THE ARRAY NAMES. A capability
          # declaration is the one field where being strict is backwards: a runner upgraded
          # ahead of loopctl — SAME MAJOR, so `supported_version/1` admits it — that declares
          # a kind this server has not heard of would be refused the socket entirely and
          # would drop out of the fleet. That is the opposite of the rolling-deploy
          # discipline the rest of this module keeps (the two dispatch-message shapes in
          # `RunnerChannel`, and `known_fields/2` dropping unknown KEYS in silence), and a
          # minor version is supposed to be additive in both directions.
          #
          # So there is no `enum`: an unknown kind is carried through and simply never
          # matches, because `kind_supported/4` asks `kind in kinds`.
          # `Loopctl.Runners.declared_kinds/1` returns the declaration VERBATIM — an
          # intersection against `Kinds.all/0` was tried there and removed as inert, and its
          # `@doc` records why; do not reintroduce one here in the schema either.
          #
          # SHAPE is still enforced, and that is a different thing from vocabulary. A
          # non-string entry, more than `@max_declared_kinds` entries, or an entry longer
          # than `@max_kind_length` refuses the join — `declared_kinds/1` keeps its own
          # `is_binary` fallback because a meta can be built without passing this cast. Those
          # bounds are about what the payload IS, not about which words a future runner may
          # use, so none of them can drop a forward-version machine.
          #
          # No `minItems` or `uniqueItems`; see the note above `@exported_keywords`, since a
          # keyword this exporter cannot publish refuses a join for a reason the vendored
          # contract does not state.
          #
          # `maxLength` is the entry bound and it is load-bearing, not decoration: this value
          # goes verbatim into the Presence meta, which `Phoenix.Tracker` replicates to EVERY
          # node for the life of the socket, and `GET /api/v1/runners/pool` echoes it. Entries
          # alone would otherwise let one machine carry ~64 KB (the endpoint's frame cap)
          # where every other field in this schema keeps the meta near 10 KB.
          kinds: %Schema{
            type: :array,
            maxItems: @max_declared_kinds,
            items: %Schema{type: :string, maxLength: @max_kind_length},
            description:
              "The dispatch kinds this machine runs (since 1.6.0). Where present and " <>
                "NON-EMPTY this is the ONLY thing consulted: loopctl refuses a kind " <>
                "outside it, and sends a kind inside it even where an earlier " <>
                "`kind_not_supported` reply is on record for this runner. Omitting it, or " <>
                "sending an EMPTY array, is read as declaring `implied_kinds` " <>
                "#{inspect(Kinds.implied_by_silence())} — what loopctl sent before the " <>
                "field existed. An empty array is therefore NOT how a runner says it wants " <>
                "no work; `draining` is. A kind this server does not know is IGNORED, not " <>
                "refused, so a runner upgraded ahead of loopctl still connects — but a " <>
                "declaration of ONLY unknown kinds leaves nothing this server can send, " <>
                "and the machine is then sent nothing until loopctl catches up. Duplicates " <>
                "are ignored. At most #{@max_declared_kinds} entries, a size bound and not " <>
                "a statement about the vocabulary. Declare it on EVERY join: it is " <>
                "per-connection, so an upgraded runner becomes eligible for a new kind by " <>
                "reconnecting rather than by being re-enrolled."
          },
          # WHAT A PREFIX MAY BE IS REFUSED AT THE WIRE, because this value reaches a GIT
          # BRANCH NAME that loopctl hands to a shell on the declaring machine. `machine` and
          # `repos` already draw that line with a `pattern` and this does the same: it must
          # start with an alphanumeric, so no declaration can produce a branch beginning `-`
          # and be read by git as an OPTION rather than a ref; and the class admits only
          # `A-Za-z0-9`, `_`, `/` and `-`, which leaves no shell metacharacter, no whitespace,
          # no control character, and — by excluding `.` outright — no `..` and no `.lock`,
          # the two sequences git refuses in a ref name. Excluding `.` costs a prefix nothing
          # real and removes both cases without a lookahead this exporter could not publish.
          #
          # THAT PATTERN IS NOT THE WHOLE GUARD, and saying where the rest lives is the point
          # of this comment. `^...$` is what the other patterns here use, and under PCRE `$`
          # also matches before a FINAL NEWLINE, so `"loop/\n"` satisfies it. The composed
          # branch is therefore re-validated, fully anchored, by the one derivation
          # (`Loopctl.Delivery.DispatchPayload.branch_for/2`), which also catches what no
          # per-entry pattern can see: `//` inside a prefix, a name that would end on `/`, and
          # a meta built without passing this cast at all. A prefix that survives the wire and
          # still cannot produce a valid branch refuses the PLACEMENT, never the join.
          branch_prefixes: %Schema{
            type: :array,
            maxItems: @max_declared_branch_prefixes,
            items: %Schema{
              type: :string,
              maxLength: @max_branch_prefix_length,
              pattern: "^[A-Za-z0-9][A-Za-z0-9_/-]*$"
            },
            description:
              "The branch-name prefixes this machine ACCEPTS (since 1.14.0). loopctl " <>
                "derives a branch that starts with the FIRST entry, so declare them in " <>
                "preference order; the rest are fallbacks used only when the first cannot " <>
                "produce a valid branch name. Omitting the field, or sending an EMPTY " <>
                "array, declares NO constraint and loopctl derives exactly the branch it " <>
                "derived before this field existed — which is why an un-upgraded runner is " <>
                "unaffected. A RUNNER THAT ENFORCES A PREFIX MUST DECLARE IT: silence is " <>
                "read as no constraint, so a machine enforcing an undeclared prefix refuses " <>
                "every dispatch loopctl sends and each refusal costs the story's claim. " <>
                "Declare the SAME set you enforce — a superset is the same failure. At most " <>
                "#{@max_declared_branch_prefixes} entries of #{@max_branch_prefix_length} " <>
                "characters, each starting with a letter or digit and made only of letters, " <>
                "digits, `_`, `/` and `-`; a branch never begins with `-` and never " <>
                "contains `..`. The derived branch always carries the story number and an " <>
                "id fragment, so two stories on one repository can never share one: a " <>
                "prefix leaving no room for that refuses the placement, not the join. " <>
                "Per-CONNECTION, so declare it on EVERY join — a machine whose " <>
                "configuration changed applies it by reconnecting."
          },
          sample: RunnerSample.schema()
        }
      },
      struct?: false
    )
  end

  defmodule RunnerStatus do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerSample
    alias Loopctl.ApiSpec.RunnerContract.RunnerUsage

    OpenApiSpex.schema(
      %{
        title: "RunnerStatus",
        description:
          "A runner's periodic update, pushed as the `status` event. Any subset of the " <>
            "fields; at least one. `usage` (since 1.17.0) is stored by control, not merely " <>
            "echoed into the pool: a status carrying it is refused `rate_limited` with " <>
            "`min_interval_ms` when that write could not land, and nothing in it was applied.",
        type: :object,
        minProperties: 1,
        properties: %{
          in_flight: %Schema{type: :integer, minimum: 0},
          draining: %Schema{type: :boolean},
          sample: RunnerSample.schema(),
          usage: RunnerUsage.schema()
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTriage do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule
    alias Loopctl.ApiSpec.RunnerContract.Limits

    # THE REPORTER'S OWN WORDS, AND THE ONLY PLACE IN THIS CONTRACT THEY APPEAR (since
    # 1.7.0). An `implement` dispatch carries a story the trio wrote and never this — design
    # §10, the implementer never sees reporter text — so the two objects are disjoint by
    # construction rather than by convention.
    #
    # `untrusted` ARRIVES ALREADY FENCED, and that is the decision worth defending here
    # because the alternative looks more consistent. Everywhere else this contract sends
    # typed fields and lets the runner compose, on the ground that a control plane able to
    # hand a runner prose is able to run anything on it. Reporter text is the exception, and
    # not because the principle is weaker: the principle is about who writes the
    # INSTRUCTIONS, and the runner's template still writes every one of them.
    #
    # It is fenced here because the fence is three independent layers —
    # `Loopctl.Delivery.Untrusted` prefixes every data line so a forged closing line arrives
    # prefixed, escapes the fence brackets so the delimiter cannot appear inside, and carries
    # a random nonce a closing line must repeat. A nonce has to be minted by whoever holds
    # the text first, and a fence is worth nothing if ANY implementation of it is wrong. One
    # tested implementation beats one per runner.
    #
    # So the runner's contract for this field is: paste it into your prompt verbatim. Do not
    # parse it, reformat it, re-wrap it, strip the prefixes, or unwrap the fence.
    # SIZED SO THE WHOLE OBJECT AT EVERY MAXIMUM FITS, which is the third attempt at this
    # number and the first that holds for every record rather than for the convenient one.
    #
    # It was 40_000, a cap the 48_000-byte object could never reach. Round 1 measured the
    # byte rule at ~7_400 characters and set 6_000 "slightly under what the byte rule
    # admits". Round 3 measured that claim on an ESCALATED record — `escalation_reasons` at
    # its own 20x100 maximum, `html_url` at 500 — and got 52_074 bytes: over the cap, so
    # 6_000 was reachable only on a record the detector had never flagged. Two identical
    # 5_500-character reports, one flagged and one not, would have taken different paths for
    # a reason no declared bound could explain.
    #
    # 5_000 is measured against every other field of this object at its own maximum, IN BMP
    # TEXT: 46_074 bytes against the 48_000 cap. That is the worst ORDINARY case and not the
    # worst case simply — the same object in astral characters is 91_290, because the byte
    # rule charges double outside the BMP.
    #
    # Those two numbers were 38_364 and 75_864 for one round, and the error is worth naming
    # because it is arithmetic anyone can redo: 38_364 is this object measured with
    # `RunnerTriageVerdict`'s `escalation_reasons` bounds (5 x 150) instead of its OWN
    # (20 x 100), and 46_074 - 12_282 + 4_572 = 38_364 exactly. It survived because no test
    # named a figure. It matters because the headroom it reports is 9_636 bytes where there
    # are 1_926 — about 321 characters, not 1_606 — so a later session sizing this cap off
    # this block raises it back toward 6_000 and reinstates the defect round 3 removed.
    #
    # The caps are not sized for that, for the reason `RunnerTriageVerdict` states at length:
    # doing so would halve what a reporter may write to defend a case no report produces, and
    # the byte rule is already a worst-case-encoder bound. What holds instead is that the
    # OBJECT CAP binds and `Loopctl.Delivery.TriagePayload` checks it — a report that does not
    # fit is escalated to a human rather than cut. BOTH FIGURES ARE ASSERTED BY NAME in
    # `runner_contract_test.exs`, not merely bounded by `<= cap` and `> cap` — an inequality
    # cannot tell a wrong figure from a right one, which is how the pair above drifted.
    #
    # The six-times charge is deliberate worst-case-encoder accounting, so an ASCII report of
    # this length costs about 5 KB on the wire and the frame is nowhere near full. That
    # conservatism is the contract's and is not relaxed here for one object.
    @max_untrusted_length 5_000
    @max_url_length 500
    @max_reasons 20
    @max_reason_length 100

    # The whole object under `ByteRule`, on the same budget arithmetic as `RunnerStory` and
    # deliberately the same number: a triage dispatch and an implement dispatch ride the same
    # frame, so the object either fits the budget the frame can carry or it does not, and
    # there is no reason for the two to differ. A record whose text exceeds it is escalated
    # to a human rather than truncated — a triage verdict reached on half the reporter's
    # words is worse than no verdict.
    @max_bytes 48_000

    @doc "The largest triage object, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    @doc "The longest rendered untrusted block."
    @spec max_untrusted_length() :: pos_integer()
    def max_untrusted_length, do: @max_untrusted_length

    @doc "The most escalation reasons, and the longest one."
    @spec max_reasons() :: pos_integer()
    def max_reasons, do: @max_reasons

    @doc "The longest escalation reason."
    @spec max_reason_length() :: pos_integer()
    def max_reason_length, do: @max_reason_length

    @doc "The longest issue URL."
    @spec max_url_length() :: pos_integer()
    def max_url_length, do: @max_url_length

    @doc """
    The bounds a runner cannot read off the schema, published in `x-connection.limits`. The
    object cap is the one that matters: it is not a JSON Schema keyword, so a runner
    pre-flighting a payload against the vendored contract sees the per-field `maxLength`
    values and has no way to learn the object is also capped — the "refused for a reason the
    author cannot read anywhere" failure the export's own note warns about.

    At runtime, not compile time: `schema/0` is defined by the macro below.
    """
    @spec limits() :: %{String.t() => term()}
    def limits, do: Limits.of(schema(), @max_bytes)

    OpenApiSpex.schema(
      %{
        title: "RunnerTriage",
        description:
          "The reported problem a `triage` dispatch is for (since 1.7.0), and the only " <>
            "place in this contract that carries the reporter's own words. Allowed only " <>
            "on a `triage` dispatch; an `implement` dispatch carries `story` instead, " <>
            "written by the triage trio, because the implementing session must never see " <>
            "reporter text. `untrusted` ARRIVES ALREADY FENCED as a labelled untrusted-data " <>
            "block: paste it into your prompt verbatim and never parse, reformat, re-wrap " <>
            "or unwrap it. It is fenced by loopctl rather than by you because the fence " <>
            "carries a nonce that must be minted where the text first lands, and because " <>
            "one tested implementation of an escape is worth more than one per runner. " <>
            "Everything outside `untrusted` is loopctl's own and is not reporter-supplied. " <>
            "THE OBJECT CAP IS WHAT BINDS: at most #{@max_bytes} bytes under the byte " <>
            "rule, which charges 6 bytes per character and 12 for one outside the Basic " <>
            "Multilingual Plane, so the per-field maxima do not guarantee a payload that " <>
            "fits. An oversize record is escalated to a human, never truncated.",
        type: :object,
        required: [:record_id, :issue_number, :html_url, :untrusted, :truncated],
        properties: %{
          record_id: %Schema{
            type: :string,
            format: :uuid,
            description: "The intake record this problem was reported on."
          },
          issue_number: %Schema{type: :integer, minimum: 1},
          html_url: %Schema{
            type: :string,
            maxLength: @max_url_length,
            nullable: true,
            description:
              "GitHub's canonical URL for the issue, or NULL. loopctl's, not the " <>
                "reporter's — `Loopctl.Intake.GithubPayload` derives it and deliberately " <>
                "yields nothing unless the payload's URL is exactly the canonical form for " <>
                "the bound repository and issue number, so an enterprise host, a renamed " <>
                "repo or a forged URL leaves it null. Nullable rather than required " <>
                "because it is informational: the session already has `record_id` and " <>
                "`issue_number`, and refusing a whole report because a convenience link " <>
                "did not parse would escalate the wrong thing. A template must handle the " <>
                "absence."
          },
          untrusted: %Schema{
            type: :string,
            maxLength: @max_untrusted_length,
            description:
              "The reporter's title, body and labels, ALREADY RENDERED as ONE fenced " <>
                "untrusted-data block. OPAQUE: paste it into your prompt verbatim and do " <>
                "not parse it, split it, reformat it, re-wrap it, strip its line prefixes " <>
                "or unwrap its fence. One block rather than one per field on purpose — " <>
                "splitting it would make the RUNNER decide how a title, a body and a label " <>
                "relate, which is a structural claim about reporter text that neither side " <>
                "can make safely. If a future session needs the title as its own field, " <>
                "loopctl will derive a separate TRUSTED one; do not recover it from here."
          },
          truncated: %Schema{
            type: :boolean,
            description:
              "loopctl's own fact. TRUE means loopctl cut the SOURCE at intake because it " <>
                "exceeded an intake cap, so the block is complete-as-cut: everything " <>
                "between the fences is intact and the reporter wrote more than it shows. " <>
                "It does NOT mean the block itself was shortened or damaged. A verdict " <>
                "reached on a cut report should say it was working from a partial one."
          },
          escalation_reasons: %Schema{
            type: :array,
            maxItems: @max_reasons,
            items: %Schema{type: :string, maxLength: @max_reason_length},
            description:
              "What loopctl's own detectors flagged on this record — an injection attempt, " <>
                "a fact the extractor could not resolve. loopctl's output, not the " <>
                "reporter's, so it is safe to read as information rather than as data."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerStory do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule
    alias Loopctl.ApiSpec.RunnerContract.Limits

    # EVERY cap of the story object, declared once here (since 1.5.0). The schema below reads
    # them, `RunnerContract.cast_dispatch/1` enforces the byte cap from `max_bytes/0`,
    # `Loopctl.Delivery.ImplementerInput.story_object/2` builds against them, and
    # `limits/0` publishes them. Nothing restates a number.
    #
    # The per-field caps are `maxLength`/`maxItems` — the units JSON Schema counts in, and
    # the ones the runner's vendored validator implements. OpenApiSpex counts a `maxLength`
    # in GRAPHEMES, which is looser than codepoints; that is harmless here because nothing
    # downstream is a Postgres CHECK, and the object cap below is counted with `ByteRule`,
    # which charges six bytes per UTF-16 unit and therefore bounds anything a loose grapheme
    # count let through.
    @max_title_length 200
    @max_description_length 8_000
    @max_criteria 20
    @max_criterion_length 500
    @max_test_cases 20
    @max_test_case_length 500
    @max_touches 100
    @max_touch_length 200
    @max_domain_reference_length 500

    # The WHOLE object, under `ByteRule` — the one byte counter this contract has.
    #
    # It is derived from the frame, not chosen: the contract's demonstrated-safe payload
    # budget is `RunnerTraceBatch.max_bytes/0` (60_000) plus
    # `RunnerContract.frame_envelope_bytes/0`, held against a 64 KB socket frame by a test
    # that assumes an encoder escaping every character. A dispatch's non-story fields, every
    # one of them at its own maximum, cost about 6_000 under the same rule, so 48_000 leaves
    # the story the budget the frame can carry with headroom to spare —
    # `runner_contract_test.exs` asserts that sum rather than trusting this arithmetic.
    #
    # It is also the cap that BINDS. The per-field caps above sum to far more than this, so
    # in practice a story is refused for its total size and not for one long field. Measured
    # on the committed `docs/user_stories` corpus on 2026-09-13: a story's title, description,
    # acceptance criteria and test cases run 14_000-38_500 bytes under this rule, so 48_000
    # admits the corpus and an oversize story is a genuinely oversize story rather than an
    # ordinary one meeting a cap set too low.
    @max_bytes 48_000

    @doc "The largest story object, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    @doc "The longest title."
    @spec max_title_length() :: pos_integer()
    def max_title_length, do: @max_title_length

    @doc "The longest description."
    @spec max_description_length() :: pos_integer()
    def max_description_length, do: @max_description_length

    @doc "The most acceptance criteria, and the longest one."
    @spec max_criteria() :: pos_integer()
    def max_criteria, do: @max_criteria

    @doc "The longest acceptance criterion."
    @spec max_criterion_length() :: pos_integer()
    def max_criterion_length, do: @max_criterion_length

    @doc "The most test cases."
    @spec max_test_cases() :: pos_integer()
    def max_test_cases, do: @max_test_cases

    @doc "The longest test case."
    @spec max_test_case_length() :: pos_integer()
    def max_test_case_length, do: @max_test_case_length

    @doc "The most paths a story may predict it touches."
    @spec max_touches() :: pos_integer()
    def max_touches, do: @max_touches

    @doc "The longest touched path."
    @spec max_touch_length() :: pos_integer()
    def max_touch_length, do: @max_touch_length

    @doc "The longest domain reference."
    @spec max_domain_reference_length() :: pos_integer()
    def max_domain_reference_length, do: @max_domain_reference_length

    @doc """
    Every cap of the story object, as the export publishes them: `max_bytes` for the whole
    object, and `fields` keyed by the field each bound belongs to.

    DERIVED from `schema/0`, never restated. The list used to be written out by hand, so a
    field added to the schema and forgotten here published an incomplete set with every test
    green — and a runner splitting by the published caps would have had no bound for the new
    field. Reading the schema means the two cannot disagree: a bound only exists here because
    it is declared there.

    `max_bytes` is the one entry that is not read off the schema, because it is not a JSON
    Schema keyword — it is the whole object under `ByteRule`.

    At runtime, not compile time: `schema/0` is defined by the `OpenApiSpex.schema` macro
    below and a module attribute cannot call it.
    """
    @spec limits() :: %{String.t() => term()}
    def limits, do: Limits.of(schema(), @max_bytes)

    OpenApiSpex.schema(
      %{
        title: "RunnerStory",
        description:
          "The story an `implement` dispatch is for, as TYPED FIELDS (since 1.5.0). loopctl " <>
            "never sends a prompt: the runner composes one from these fields with its own " <>
            "template, because a dispatch runs as the machine's user and a control plane " <>
            "able to hand a runner prose to execute is able to run anything on it. `id` " <>
            "must be the dispatch's own `story_id`. The whole object is at most " <>
            "#{@max_bytes} bytes under the byte rule below, which is the cap that usually " <>
            "binds; loopctl REFUSES an oversize story and escalates it to a human rather " <>
            "than truncating one, since a dropped acceptance criterion is a story built to " <>
            "the wrong spec. `domain_reference` is the domain document the change belongs " <>
            "to, required by some repositories' own pull-request gates. " <> ByteRule.text(),
        type: :object,
        required: [:id, :title],
        properties: %{
          id: %Schema{
            type: :string,
            format: :uuid,
            description: "The story's id. Must equal the dispatch's `story_id`."
          },
          title: %Schema{type: :string, minLength: 1, maxLength: @max_title_length},
          description: %Schema{type: :string, maxLength: @max_description_length},
          acceptance_criteria: %Schema{
            type: :array,
            maxItems: @max_criteria,
            items: %Schema{type: :string, minLength: 1, maxLength: @max_criterion_length},
            description:
              "What the work is judged against, one string per criterion, in the story's " <>
                "own order. Never truncated: a story with more than #{@max_criteria} is " <>
                "refused."
          },
          test_cases: %Schema{
            type: :array,
            maxItems: @max_test_cases,
            items: %Schema{type: :string, minLength: 1, maxLength: @max_test_case_length}
          },
          touches: %Schema{
            type: :array,
            maxItems: @max_touches,
            items: %Schema{type: :string, minLength: 1, maxLength: @max_touch_length},
            description:
              "The paths triage predicted the change touches. Advisory to the session and " <>
                "never a permission: what a runner may write is its own local allow-list."
          },
          domain_reference: %Schema{
            type: :string,
            minLength: 1,
            maxLength: @max_domain_reference_length
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTriageVerdict do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule
    alias Loopctl.ApiSpec.RunnerContract.Limits
    alias Loopctl.ApiSpec.RunnerContract.RunnerStory

    # WHAT A TRIAGE SESSION RETURNS (since 1.7.0). On the wire and not a convention in a
    # runner's prompt, because a convention has no schema: its shape drifts per runner and per
    # prompt edit, and loopctl cannot REJECT a malformed verdict it never declared. Asked for
    # by the `loopctl-runner` maintaining session on exactly that ground, 2026-09-15, and the
    # session that has to emit it would rather fill a form than author a document — which is
    # also the shape least steerable by the text it just read.
    #
    # **THIS OBJECT IS SESSION-AUTHORED AND IS NOT TRUSTED INPUT.** It was composed by a
    # session whose whole job was to read attacker-controllable text, so every field here is
    # potentially shaped by that text — including `story`, whose fields become a story row.
    # loopctl RECORDS it, bounds it, and never executes it, and anything downstream that puts
    # these strings into another prompt fences them exactly as reporter text is fenced. The
    # trio is the laundering boundary the design relies on (§4, §10); this object is where
    # that reliance is concentrated, so it is the thing to be suspicious of.
    @outcomes ["story", "escalate", "reject"]

    # An ENUM, not a float. A float invites 0.85, and nobody — not the session, not a reader —
    # can say what would have made it 0.8, so it reads as precision that does not exist. Each
    # level below states what it MEANS, so the session is choosing between descriptions rather
    # than inventing a number.
    @confidences ["low", "medium", "high"]

    @max_reasons 5
    @max_reason_length 150
    # EVERY CAP BELOW IS SIZED SO THAT A VERDICT AT ALL OF THEM AT ONCE FITS, which is a
    # stronger invariant than the one round 1 settled for and is the only one that never
    # surprises a session. Round 1 asserted that no single field's maximum exceeds the object
    # cap; round 3 measured that a draft story at its own declared maxima cost 47_424 of
    # 48_000, so a single 200-character `evidence` entry — the field this schema calls the
    # cheapest defence against a confident verdict with nothing behind it — was REFUSED. Each
    # cap was individually reachable and the combination was not, which is the same "reads as
    # a limit, is not what binds" defect one level up again.
    #
    # Measured at these values, in BMP text: a verdict with every field at its maximum is
    # 45_880 against the 48_000 cap. A test asserts BOTH — that it fits, which is the claim
    # that matters, and the figure itself, so a reader can tell whether the headroom has been
    # spent and a wrong number cannot sit here green. Leaving the figure unasserted is what
    # let this object's triage twin carry a figure 7_710 bytes out for a round.
    #
    # The headroom is 2_120 bytes and it is BMP-ONLY. `ByteRule` charges 12 for a character
    # outside the Basic Multilingual Plane against 6 inside, so about 354 astral characters
    # spend it — a handful of emoji do not, a title written in an astral script does. A
    # separate test asserts the astral figure BY NAME (89_584), rather than only that it
    # exceeds the cap — an inequality holds just as well for a number that is wrong.
    @max_evidence 6
    @max_evidence_length 150
    @max_missing 5
    @max_missing_length 150

    # THE DRAFT STORY'S OWN CAPS, smaller than `RunnerStory`'s and not derived from them.
    # Measured: `RunnerStory`'s maxima nested here cost 294_202 bytes against this object's
    # 48_000, so inheriting them gave the story six field caps none of which its own field
    # could ever reach. A draft written from ONE report is not an epic, and a story needing
    # more than this is one triage should be escalating rather than drafting.
    #
    # `title` and `domain_reference` keep `RunnerStory`'s values because they are already
    # small enough to be reachable; only the fields that blew the budget are reduced.
    @max_story_description 900
    @max_story_criteria 5
    @max_story_criterion_length 200
    @max_story_test_cases 4
    @max_story_test_case_length 200
    @max_story_touches 8
    @max_story_touch_length 80
    @max_story_domain_reference 300
    # Also measured down: 20 entries of a 200-character ref and a 500-character why cost
    # 86_842 bytes, nearly twice this object's whole budget. Ten contradictions is already
    # more than a verdict a human will read can carry.
    @max_contradicts 3
    @max_contradict_ref_length 100
    @max_contradict_why_length 200
    @contradict_kinds ["story", "kb", "code"]

    # The same budget as a dispatch object, for the same frame — a verdict arrives INBOUND
    # over the same 64 KB socket, so the arithmetic is the dispatch's.
    #
    # WHAT THIS CAP MEANS, stated because the first version of this module got it wrong.
    # `ByteRule` charges six bytes per character, so 48_000 is about 8_000 CHARACTERS for the
    # whole verdict. The per-field maxima below are INDIVIDUAL limits and do not sum to this;
    # a verdict near several of them at once is refused on the object cap, exactly as
    # `RunnerStory` documents of its own fields. What was wrong before was not that — it was
    # claiming the draft story is "bounded exactly as `RunnerStory` bounds the same fields, so
    # one set of limits governs in both directions". It is not: `RunnerStory` is capped at
    # 48_000 as a whole object, and the same story nested inside a verdict shares that budget
    # with everything else here, so a story valid OUTBOUND can be refused INBOUND. The claim
    # is withdrawn rather than engineered around, because making it true would mean a verdict
    # cap of 48_000 plus a story's worth on a frame that has not got it.
    #
    # The invariant that IS held, and is tested: no single field's declared maximum exceeds
    # the object cap on its own. `evidence` did — 40 entries of 300 characters is about
    # 72_000 bytes, more than the whole verdict may be — which is a cap that cannot be
    # reached by the field it is written on, the same defect as one that cannot bind.
    @max_bytes 48_000

    @doc "Every outcome a verdict may carry."
    @spec outcomes() :: [String.t()]
    def outcomes, do: @outcomes

    @doc "Every confidence level a verdict may carry."
    @spec confidences() :: [String.t()]
    def confidences, do: @confidences

    @doc "The kinds a `contradicts` entry may name."
    @spec contradict_kinds() :: [String.t()]
    def contradict_kinds, do: @contradict_kinds

    @doc "The largest verdict, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    @doc "The most evidence entries, and the longest one."
    @spec max_evidence() :: pos_integer()
    def max_evidence, do: @max_evidence

    @doc """
    The bounds a runner cannot read off the schema, published in `x-connection.limits`. The
    object cap is the one that matters: it is not a JSON Schema keyword, so a runner
    pre-flighting a payload against the vendored contract sees the per-field `maxLength`
    values and has no way to learn the object is also capped — the "refused for a reason the
    author cannot read anywhere" failure the export's own note warns about.

    At runtime, not compile time: `schema/0` is defined by the macro below.
    """
    @spec limits() :: %{String.t() => term()}
    def limits, do: Limits.of(schema(), @max_bytes)

    OpenApiSpex.schema(
      %{
        title: "RunnerTriageVerdict",
        description:
          "What a `triage` session returns (since 1.7.0). SESSION-AUTHORED AND UNTRUSTED: " <>
            "it was composed by a session that had just read reporter text, so loopctl " <>
            "records and bounds it and never executes it. WHAT LOOPCTL DOES WITH `story` IS " <>
            "NOT A FENCE, and this description said it was until 1.12.0: EVERY drafted field " <>
            "that can reach `RunnerStory` - title, description, each acceptance criterion, and " <>
            "the `test_cases`, `touches` and `domain_reference` a dispatch may carry as " <>
            "options - is escaped for invisible characters, SCREENED by the injection " <>
            "detector, and then stored as loopctl's own story row - which " <>
            "`RunnerStory` later carries as ordinary typed fields, with no fence and no " <>
            "marker. A draft the screen flags is escalated to a human instead of queued, so " <>
            "it never reaches an implement dispatch at all; a draft that passes is " <>
            "indistinguishable from a story a person wrote, and a runner composing its " <>
            "prompt should treat `RunnerStory` as content loopctl vouches for rather than as " <>
            "fenced data. Contrast `RunnerTriage.untrusted`, which IS fenced and says so. " <>
            "`story` is REQUIRED when `outcome` is `story` " <>
            "and forbidden otherwise, the same shape rule a dispatch uses for `story` and " <>
            "`triage`; a verdict that says `story` and carries none has moved the work " <>
            "rather than done it. `confidence` is an enum and not a number on purpose: " <>
            "`low` means the session would not act on this without a human reading the " <>
            "report, `medium` means the request is clear but something it could not check " <>
            "remains, `high` means it found the request actionable and contradicted by " <>
            "nothing it read. THE OBJECT CAP IS WHAT BINDS: at most #{@max_bytes} bytes " <>
            "under the byte rule, which charges 6 bytes per character and 12 for one " <>
            "outside the Basic Multilingual Plane — so the per-field character maxima do " <>
            "NOT guarantee a payload that fits. A verdict at every declared maximum fits in " <>
            "ordinary text and does not once enough of it is astral. Check the byte rule " <>
            "against `max_bytes` (published " <>
            "in `x-connection.limits.triage_verdict`) rather than the field lengths: the " <>
            "lengths bound one field each, the cap bounds the message.",
        type: :object,
        required: [:outcome, :confidence],
        properties: %{
          outcome: %Schema{type: :string, enum: @outcomes},
          confidence: %Schema{type: :string, enum: @confidences},
          story: %Schema{
            type: :object,
            description:
              "The draft story, required when `outcome` is `story`. Its caps are SMALLER " <>
                "than `RunnerStory`'s and are not the same numbers: a story at " <>
                "`RunnerStory`'s maxima costs several times this whole object's " <>
                "#{@max_bytes}-byte budget, so inheriting them would have declared limits " <>
                "no field could reach. A draft written from one report is not an epic, and " <>
                "a story needing more than this is one to escalate rather than draft. " <>
                "These are still INDIVIDUAL maxima that do not sum to the object cap. No " <>
                "`id`: the story row exists and loopctl owns its identity.",
            required: [:title, :description, :acceptance_criteria],
            properties: %{
              title: %Schema{type: :string, maxLength: RunnerStory.max_title_length()},
              description: %Schema{type: :string, maxLength: @max_story_description},
              acceptance_criteria: %Schema{
                type: :array,
                maxItems: @max_story_criteria,
                items: %Schema{type: :string, maxLength: @max_story_criterion_length}
              },
              test_cases: %Schema{
                type: :array,
                maxItems: @max_story_test_cases,
                items: %Schema{type: :string, maxLength: @max_story_test_case_length}
              },
              touches: %Schema{
                type: :array,
                maxItems: @max_story_touches,
                items: %Schema{type: :string, maxLength: @max_story_touch_length}
              },
              domain_reference: %Schema{type: :string, maxLength: @max_story_domain_reference}
            }
          },
          escalation_reasons: %Schema{
            type: :array,
            maxItems: @max_reasons,
            items: %Schema{type: :string, maxLength: @max_reason_length},
            description:
              "Why this needs a human. Meaningful when `outcome` is `escalate`. FREE-FORM: a " <>
                "sentence saying what a lens actually saw is what makes an escalation " <>
                "actionable, and at least one entry must be prose — a bare code is not words " <>
                "a person can act on. WHAT LOOPCTL DOES WITH THIS FIELD TODAY: it records it " <>
                "verbatim on the verdict. No string HERE changes what happens to the story. " <>
                "The codes in `x-connection.triage_gating_reasons` gate only where Gate A " <>
                "reads them: in each `RunnerLensVerdict.escalation_reasons` of the message's " <>
                "`lens_verdicts` (since 1.15.0), matched as whole strings, at triage and at " <>
                "merge."
          },
          missing_information: %Schema{
            type: :array,
            maxItems: @max_missing,
            items: %Schema{type: :string, maxLength: @max_missing_length},
            description:
              "What the session would need in order to reach a verdict — the field that " <>
                "makes an escalation actionable rather than putting a human back at the " <>
                "start of the same reading."
          },
          evidence: %Schema{
            type: :array,
            maxItems: @max_evidence,
            items: %Schema{type: :string, maxLength: @max_evidence_length},
            description:
              "What the session actually read: file paths with optional line numbers, " <>
                "knowledge-base article ids. It makes a verdict checkable by someone who " <>
                "does not re-run it, which is the cheapest defence against a confident " <>
                "verdict with nothing behind it. Capped hard: it is session-authored."
          },
          duplicate_of: %Schema{
            type: :string,
            format: :uuid,
            nullable: true,
            description:
              "An existing story this report already describes. Its own field rather than " <>
                "a `contradicts` entry, because a duplicate is the commonest outcome after " <>
                "`reject` and it is not a contradiction."
          },
          contradicts: %Schema{
            type: :array,
            maxItems: @max_contradicts,
            items: %Schema{
              type: :object,
              required: [:kind, :ref, :why],
              properties: %{
                kind: %Schema{type: :string, enum: @contradict_kinds},
                ref: %Schema{type: :string, maxLength: @max_contradict_ref_length},
                why: %Schema{type: :string, maxLength: @max_contradict_why_length}
              }
            },
            description:
              "What this request conflicts with in the existing stories, the knowledge " <>
                "base, or the code. A DUPLICATE is not this; see `duplicate_of`."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerLensVerdict do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerTriageVerdict

    # ONE LENS'S OWN JUDGEMENT (since 1.15.0, epic 44 US-44.1). The merged `verdict` a triage
    # session returns hides the one signal Gate A exists to read — three independently
    # prompted lenses that do not agree — so the three readings travel beside it, on the
    # MESSAGE rather than inside the verdict. Inside, they would share the verdict's
    # `max_bytes`, which a verdict at its declared maxima already spends to within 2_120.
    #
    # Deliberately SMALL. Gate A reads four things from a lens — its outcome, its gating
    # codes, whether it saw a contradiction, and a recorded-never-consulted confidence — so
    # that is all a lens carries. Prose belongs in the merged verdict, which is what an
    # operator reads; the lens entries are what a gate compares.
    #
    # UNTRUSTED like the verdict: runner-authored, recorded and bounded, never executed.
    @lenses ["analyst", "architect", "engineer"]
    @max_reasons 3
    @max_reason_length 60
    @max_contradicts 1
    @max_contradict_ref_length 60
    @max_contradict_why_length 100

    # THE CAP ON ALL THREE TOGETHER, under the byte rule. It is sized from the frame, not from
    # the fields: the message rides the same 64 KiB socket frame as the verdict, which may
    # cost up to `RunnerTriageVerdict.max_bytes/0`, so what is left for the lens entries,
    # the envelope and JSON framing is what this may spend. Three lenses at every declared
    # maximum are asserted to fit, and the figure is asserted by name.
    @max_bytes 9_000

    @doc "The three lens names; each appears exactly once in a message."
    @spec lenses() :: [String.t()]
    def lenses, do: @lenses

    @doc "The cap on all three lens entries together, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    OpenApiSpex.schema(
      %{
        title: "RunnerLensVerdict",
        description:
          "One triage lens's own judgement (since 1.15.0), sent three at a time in " <>
            "`RunnerTriageVerdictMessage.lens_verdicts`, one per lens. loopctl persists them " <>
            "with the verdict and Gate A reads them at triage, before the story is queued, " <>
            "and again at merge, instead of anything a merge caller supplies. SESSION-AUTHORED " <>
            "AND UNTRUSTED, like the verdict. `escalation_reasons` here is for CODES " <>
            "(`x-connection.triage_gating_reasons`); prose belongs in the merged verdict.",
        type: :object,
        required: [:lens, :outcome, :confidence],
        properties: %{
          lens: %Schema{type: :string, enum: @lenses},
          outcome: %Schema{type: :string, enum: RunnerTriageVerdict.outcomes()},
          confidence: %Schema{type: :string, enum: RunnerTriageVerdict.confidences()},
          escalation_reasons: %Schema{
            type: :array,
            maxItems: @max_reasons,
            items: %Schema{type: :string, maxLength: @max_reason_length}
          },
          contradicts: %Schema{
            type: :array,
            maxItems: @max_contradicts,
            items: %Schema{
              type: :object,
              required: [:kind, :ref, :why],
              properties: %{
                kind: %Schema{type: :string, enum: RunnerTriageVerdict.contradict_kinds()},
                ref: %Schema{type: :string, maxLength: @max_contradict_ref_length},
                why: %Schema{type: :string, maxLength: @max_contradict_why_length}
              }
            }
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTriageVerdictMessage do
    @moduledoc """
    The `triage_verdict` message a runner sends when a triage session is FINISHED (1.9.0).

    The verdict object itself (`RunnerTriageVerdict`) names no story, no dispatch and no
    epoch — it is the session's judgement and nothing else — so this is the envelope that
    says which run it is about. `dispatch_id` names the story on loopctl's side; a story id
    is never taken from the wire.

    ## Exactly one of `verdict` or `incomplete`

    A triage run has two ends, and before 1.9.0 only one of them could be reported. Either
    the session produced a verdict, or it did not — it crashed, it ran out of wall clock, it
    could not read the checkout, it wrote nothing, or it wrote something the runner's own
    validator refused. `:triage_escalate` is NOT a runner-reportable stage edge, so a
    `stage` message could never carry "this run ended and produced nothing", and a dispatch
    with no way to say that stays in flight for ever. `incomplete` is that way.

    Every `incomplete` reason routes the same as an `escalate` verdict — a human looks —
    because a triage run that produced nothing usable is the same outcome for the reporter
    as one that produced a refusal, and telling them apart matters to the operators and not
    to her. The enum exists so the operators CAN tell them apart.

    `verdict_invalid` is the one that is easy to leave out and was: the session did not
    crash, did not run out of time, read the checkout fine, and DID write something — which
    its own runner then refused against the schema, the conditional-story rule or the byte
    cap. It is a distinct state from writing nothing.

    ## Resending is safe, and is the correct move on any transient refusal

    A verdict is recorded once per dispatch. A byte-identical resend is answered `ok` with
    the same ack, applies no second transition and appends no second chain entry — which
    matters more than idempotency usually does, because the transition it drives is not
    undoable: `triaged -> failed` earns the reporter a `not_actionable` resolution, so a
    double apply is a second close on her ticket.

    A resend carrying a DIFFERENT verdict for the same dispatch is refused
    `already_recorded`, permanently. A session cannot restate its verdict by design, so a
    differing resend is a defect on one side or the other, and silently taking the second
    would erase the first.
    """

    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerLensVerdict
    alias Loopctl.ApiSpec.RunnerContract.RunnerTriageVerdict

    # The session ended without a usable verdict. Every one escalates; the enum is what lets
    # an operator tell a crash from a refused verdict without reading the run.
    @incomplete_reasons ~w(session_crashed wall_clock_exceeded checkout_unreadable
                           no_verdict_written verdict_invalid)

    @max_detail_length 300

    @doc "Every reason a triage run may report instead of a verdict."
    @spec incomplete_reasons() :: [String.t()]
    def incomplete_reasons, do: @incomplete_reasons

    @doc "The cap on the optional free-text detail beside an `incomplete` reason."
    @spec max_detail_length() :: pos_integer()
    def max_detail_length, do: @max_detail_length

    OpenApiSpex.schema(
      %{
        title: "RunnerTriageVerdictMessage",
        description:
          "What a runner sends when a `triage` session is finished (since 1.9.0). Carries " <>
            "EXACTLY ONE of `verdict` and `incomplete`: a message with both, or with " <>
            "neither, is refused `invalid_payload`. `incomplete` is how a run that produced " <>
            "nothing usable is reported — a `stage` message cannot say it, because the edge " <>
            "it would need (`triage_escalate`) is a control-side verdict no runner may " <>
            "report. IDEMPOTENT PER DISPATCH: a byte-identical resend is answered `ok` and " <>
            "changes nothing, so resending is the correct response to any refusal listed " <>
            "outside `x-connection.permanent_errors`. A resend carrying a DIFFERENT verdict " <>
            "for the same dispatch is refused `already_recorded` and is permanent.",
        type: :object,
        required: [:dispatch_id, :claim_epoch],
        properties: %{
          dispatch_id: %Schema{type: :string, format: :uuid},
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch being answered, echoed."
          },
          # INLINED, exactly as `RunnerDispatch` inlines `story` and `triage`. `allOf` is
          # ENFORCED by OpenApiSpex and NOT published by the export, so a runner validating
          # against the vendored contract would have passed a verdict loopctl then refused —
          # for a rule it could not read. The export's own guard says so and caught it.
          #
          # `nullable` AND the description are RESTORED ONTO the inlined schema, and both were
          # lost by the first inlining. The nullable is the one that mattered: the replaced
          # property accepted `"verdict": null` and `RunnerTriageVerdict.schema()` does not, so
          # a runner whose serializer emits every declared key — Go without `omitempty`, serde
          # without `skip_serializing_if` — sending `"verdict": null` beside a real
          # `incomplete` was refused `invalid_payload`. That code is in `permanent_errors`, so
          # the correct client behaviour is NOT to resend and the run's only output is lost for
          # good. The asymmetry was the tell: `incomplete` and `detail` stayed nullable, so the
          # same runner could send a verdict and could never send an incomplete.
          verdict: %{
            RunnerTriageVerdict.schema()
            | nullable: true,
              description:
                "The session's judgement. Forbidden when `incomplete` is present. Its own " <>
                  "fields are inlined here rather than referenced, so the whole shape is " <>
                  "resolvable from this message."
          },
          incomplete: %Schema{
            type: :string,
            enum: @incomplete_reasons,
            nullable: true,
            description:
              "Why this run produced no usable verdict. Forbidden when `verdict` is " <>
                "present. `verdict_invalid` means the session DID write one and the " <>
                "runner's own validation refused it — a different state from writing none."
          },
          lens_verdicts: %Schema{
            type: :array,
            maxItems: 3,
            nullable: true,
            items: RunnerLensVerdict.schema(),
            description:
              "The three triage lenses' own judgements (since 1.15.0), one per lens, each " <>
                "lens exactly once. Allowed only beside `verdict`. Gate A reads these at " <>
                "triage and again at merge, so a verdict sent WITHOUT them escalates at " <>
                "triage: Gate A cannot be evaluated. At most " <>
                "#{RunnerLensVerdict.max_bytes()} bytes for all three under the byte rule."
          },
          detail: %Schema{
            type: :string,
            maxLength: @max_detail_length,
            nullable: true,
            description:
              "Optional operator-facing note beside an `incomplete` reason, e.g. which " <>
                "check refused the verdict. UNTRUSTED like every other runner-authored " <>
                "string: recorded and bounded, never executed and never put in a prompt " <>
                "unfenced."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTriageVerdictAck do
    @moduledoc """
    The reply to a `triage_verdict` (1.9.0).

    DECLARED, because `replayed` is load-bearing for a documented protocol rather than
    informational: the message's own contract tells a runner to distinguish a fresh apply
    from a resend by this field, and a runner vendoring `v1.json` had nothing to read it
    from. (`stage`'s ack is still undeclared, which is a pre-existing gap and not one this
    field can afford to share.)
    """

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerTriageVerdictAck",
        description: "The reply to an accepted `triage_verdict`.",
        type: :object,
        required: [:recorded_at, :replayed],
        properties: %{
          recorded_at: %Schema{
            type: :string,
            format: :"date-time",
            description:
              "When the verdict was FIRST recorded — unchanged by a resend, so it dates the " <>
                "original delivery rather than the latest one."
          },
          replayed: %Schema{
            type: :boolean,
            description:
              "False on the delivery that recorded this verdict, true on any resend of it. " <>
                "A resend applies no second transition."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerDispatch do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerStory

    # A session's wall clock, bounded (since 1.3.0). The runner stops a session there, and
    # loopctl stores the value and presumes a slot free past it plus a grace
    # (`Loopctl.Runners.Capacity`), so an unbounded one both outlives any real session and
    # overflows the `runner_dispatches.wall_clock_seconds` integer column — a raise out of
    # `Loopctl.Runners.dispatch/3` rather than the `invalid_payload` an out-of-range value
    # deserves. A day is the story claim lease's own default (`STORY_CLAIM_LEASE_SECONDS`):
    # past it the claim would be reclaimed under the session anyway.
    @max_wall_clock_seconds 86_400

    @doc "The longest wall clock a dispatch may give a session."
    @spec max_wall_clock_seconds() :: pos_integer()
    def max_wall_clock_seconds, do: @max_wall_clock_seconds

    # The kind vocabulary and the dispatchable subset are declared ONCE, in
    # `RunnerContract.Kinds` — `RunnerJoin.kinds` reads the same lists and sits 300 lines
    # above this module, so a copy here is exactly the drift that would let a runner declare a
    # kind `cast_dispatch/1` then refuses. These two delegate; the export publishes both lists.
    alias Loopctl.ApiSpec.RunnerContract.Kinds

    @doc "Every dispatch kind the contract names."
    @spec kinds() :: [String.t()]
    def kinds, do: Kinds.all()

    @doc "The kinds loopctl will send. Every other declared kind is refused by the cast."
    @spec dispatchable_kinds() :: [String.t()]
    def dispatchable_kinds, do: Kinds.dispatchable()

    # PUBLISHED AND READ BACK, rather than copied. `Loopctl.Delivery.DispatchPayload` judges a
    # CALLER-supplied ref field before anything is claimed — the cast below runs after the
    # claim, which is the whole reason that check moved earlier — and it bounds the length
    # against this, so the number a caller is refused on is the number the contract states.
    @max_branch_length 255

    @doc "The longest branch name a dispatch may carry, on `branch` and on `base_branch`."
    @spec max_branch_length() :: pos_integer()
    def max_branch_length, do: @max_branch_length

    # EVERY STRING ON THIS SCHEMA IS CLASSIFIED, AND THAT IS THE POINT (846.2 review round 2,
    # findings 1, 2 and 7). Round 1 closed an argument-injection on `branch` by adding a check
    # to `branch`. Round 2 then found the identical schema one line above it on `base_branch`
    # with no check at all, a non-string `branch` skipping the check entirely, and a
    # caller-supplied `branch` defeating the uniqueness this contract publishes — three leaks
    # in one round, each fixable by naming another spelling, which is precisely the failure
    # mode KB `909ba2b2` records: a guard must exempt by PROVING a property, never by
    # enumerating dangerous spellings.
    #
    # So the fields are declared here, once, and `DispatchPayload.fill/3` validates FROM this
    # list rather than from a pair of literals it happens to remember. The two lists are a
    # TOTAL partition of the schema's string properties, and
    # `test/loopctl/api_spec/runner_contract_test.exs` fails in both directions — a new string
    # property classified as neither, and a classified name that is not a property. A ninth
    # ref-shaped field therefore cannot be added without the author deciding which list it is
    # in, which is the only thing that stops the next round finding a fourth spelling.
    #
    # The DISPOSITION is the second decision, and it is here for the same reason. `:story_unique`
    # means the value becomes the branch a session WORKS ON, so it must carry the story's own
    # suffix or two stories on one repository can share a branch and the second session finds
    # the first's work already there. `:shared` means the value names a ref the session reads
    # FROM, which is deliberately common across stories — `master` on every dispatch in the
    # tenant — so uniqueness would be wrong rather than merely strict.
    @ref_fields [branch: :story_unique, base_branch: :shared]

    # NOT refs, each for a reason that is checked elsewhere: `dispatch_id` and `story_id` are
    # UUIDs (`format: :uuid`), `kind` is closed by an `enum`, `repo` carries its own
    # `owner/name` pattern, and `deadline_at` is a `date-time` loopctl writes from the claim
    # and never takes from a caller. None of them reaches a git ref argument.
    @non_ref_string_fields [:dispatch_id, :story_id, :kind, :repo, :deadline_at]

    @doc """
    The fields of a dispatch whose value becomes a GIT REF, and what each one must satisfy.

    `:story_unique` — the branch a session works on; must carry the story's own suffix.
    `:shared` — a ref the session reads from; any valid ref name.

    Read by `Loopctl.Delivery.DispatchPayload`, which validates every entry BEFORE the claim.
    """
    @spec ref_fields() :: keyword(:story_unique | :shared)
    def ref_fields, do: @ref_fields

    @doc """
    The schema's remaining string fields, declared so the classification is TOTAL.

    Nothing reads this at runtime; it exists so that adding a string property without deciding
    whether it is a ref fails a test rather than shipping unvalidated.
    """
    @spec non_ref_string_fields() :: [atom()]
    def non_ref_string_fields, do: @non_ref_string_fields

    OpenApiSpex.schema(
      %{
        title: "RunnerDispatch",
        description:
          "Control pushes `dispatch` to start a session. The runner validates it against " <>
            "its LOCAL allow-list (repos, branch prefixes, wall clock, token budget) and " <>
            "refuses by default: a dispatch runs as the machine's user. Since 1.5.0 an " <>
            "`implement` dispatch carries the story as TYPED FIELDS (`story`) and never a " <>
            "prompt — the runner composes its own from them. `story` is allowed only on an " <>
            "`implement` dispatch and its `id` must equal `story_id`. Only the kinds in " <>
            "`x-connection.dispatchable_kinds` are sent; a runner that does not do a kind " <>
            "answers `kind_not_supported`. Since 1.6.0 that answer is NOT permanent for a " <>
            "runner that declares `kinds` on join: the declaration decides, so the same " <>
            "kind IS sent again on a later connection that declares it, and a handler must " <>
            "not assume one refusal ends the matter. It is suppressed for the rest of the " <>
            "connection it was given on, and stays permanent only for a runner that " <>
            "declares nothing. Declared in contract v1; emitted from #803.",
        type: :object,
        required: [
          :dispatch_id,
          :story_id,
          :kind,
          :repo,
          :base_branch,
          :branch,
          :claim_epoch,
          :wall_clock_seconds,
          :max_turns
        ],
        properties: %{
          dispatch_id: %Schema{type: :string, format: :uuid},
          story_id: %Schema{type: :string, format: :uuid},
          kind: %Schema{type: :string, enum: Kinds.all()},
          repo: %Schema{type: :string, pattern: "^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$"},
          base_branch: %Schema{type: :string, minLength: 1, maxLength: @max_branch_length},
          branch: %Schema{type: :string, minLength: 1, maxLength: @max_branch_length},
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "Echoed on every runner-to-control message about this dispatch. Bumped on " <>
                "reclaim, so a resurrected session's writes are rejected."
          },
          wall_clock_seconds: %Schema{
            type: :integer,
            minimum: 1,
            maximum: @max_wall_clock_seconds,
            description:
              "How long the runner lets the session run before stopping it. At most " <>
                "#{@max_wall_clock_seconds} (a day) since contract 1.3.0."
          },
          max_turns: %Schema{type: :integer, minimum: 1},
          token_budget: %Schema{type: :integer, minimum: 1, nullable: true},
          deadline_at: %Schema{
            type: :string,
            format: :"date-time",
            description:
              "Since 1.19.0, OPTIONAL. A STOP BOUND: end the session by the EARLIER of " <>
                "your own start + `wall_clock_seconds` and this instant, whether or not " <>
                "control is reachable. It is placed_at + `wall_clock_seconds` + " <>
                "`DISPATCH_LEASE_GRACE_SECONDS` (a RE-SEND of the dispatch carries the " <>
                "re-send's time + its `wall_clock_seconds` + the grace), so the time between " <>
                "the push and your start comes out of that grace, not out of " <>
                "`wall_clock_seconds`; only a start-up longer than the grace shortens the " <>
                "session. loopctl's lease sweep never releases the claim on the story before " <>
                "it — your acceptance and a re-send may move the claim later, never earlier " <>
                "— so a session stopped by it never runs on a story the sweep released and " <>
                "loopctl placed again. An operator can still release the claim sooner " <>
                "(force-unclaim). Present on a dispatch control PLACED under a claim; " <>
                "absent otherwise."
          },
          story: RunnerStory.schema(),
          triage: RunnerTriage.schema()
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTraceEvent do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule

    # Both under `ByteRule`. Referenced by the description, the export and
    # `RunnerContract.cast_trace_batch/1`. A schema-valid event with `data` at its cap and
    # every string at its maxLength in astral characters stays under `@max_bytes`, and one
    # such event always fits a batch, so splitting a batch can always make progress.
    @max_data_bytes 6_000
    @max_bytes 12_000

    @doc "The largest `data` object an event may carry, under the byte rule."
    @spec max_data_bytes() :: pos_integer()
    def max_data_bytes, do: @max_data_bytes

    @doc "The largest event, undeclared keys included, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceEvent",
        description:
          "One line of a run's NDJSON trace. The on-disk file is the source of truth: " <>
            "the runner ships `(run_id, seq)`, the server ACKs the last contiguous seq and " <>
            "dedups on the pair, and the runner resumes from that offset on rejoin. " <>
            "`parent` is REQUIRED on every event (null only for the root) so the agent " <>
            "tree can be rebuilt by query. `data` is at most #{@max_data_bytes} bytes and the " <>
            "whole event at most #{@max_bytes}, both under the byte rule below; either excess " <>
            "is refused with `event_data_too_large` naming the event's `seq`. Large payloads " <>
            "(tool output, file contents) belong in object storage, referenced from `data`. " <>
            ByteRule.text(),
        type: :object,
        required: [:run_id, :seq, :event_id, :parent, :ts, :type],
        properties: %{
          run_id: %Schema{type: :string, format: :uuid},
          seq: %Schema{type: :integer, minimum: 0},
          event_id: %Schema{type: :string, minLength: 1, maxLength: 128},
          parent: %Schema{type: :string, minLength: 1, maxLength: 128, nullable: true},
          ts: %Schema{type: :string, format: :"date-time"},
          type: %Schema{type: :string, minLength: 1, maxLength: 64},
          data: %Schema{type: :object, additionalProperties: true}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerDispatchReply do
    @moduledoc false
    require OpenApiSpex

    # `kind_not_supported` (since 1.5.0) is the one refusal that is a CAPABILITY STATEMENT
    # rather than a fault: this machine does not do this kind of work, and it will not do it
    # after a retry either. That is what makes it different from `draining` or `at_capacity`,
    # which are about right now.
    #
    # How long loopctl holds it depends on whether the runner DECLARES its kinds (1.6.0). For
    # a runner that declares nothing it is permanent for that machine and that kind
    # (`Loopctl.Runners.DispatchLedger.kind_unsupported?/3`). For one that declares, the
    # declaration decides instead, and the refusal binds only the connection it was given on
    # — a runner contradicting its own declaration is a bug on the runner rather than a state
    # to recover from, and the bound is on the damage.
    # Like every refusal it gives the slot straight back, so it costs the runner no capacity,
    # and nothing reads a refusal as a health signal.
    @refusal_reasons ~w(dispatches_disabled draining at_capacity insufficient_disk
                        repo_not_allowed branch_not_allowed wall_clock_exceeds_limit
                        max_turns_exceeds_limit token_budget_exceeds_limit
                        kind_not_supported other)
    @max_detail_length 500

    @doc "Every refusal reason a runner may give."
    @spec refusal_reasons() :: [String.t()]
    def refusal_reasons, do: @refusal_reasons

    @doc "The longest `detail` a refusal may carry."
    @spec max_detail_length() :: pos_integer()
    def max_detail_length, do: @max_detail_length

    OpenApiSpex.schema(
      %{
        title: "RunnerDispatchReply",
        description:
          "The runner's answer to one `dispatch`, pushed as the `dispatch_reply` event. " <>
            "`reason` is REQUIRED when `decision` is `refused` and forbidden when it is " <>
            "`accepted`; `detail` is required when `reason` is `other` and allowed only on a " <>
            "refusal. The server applies the first reply, answers an identical repeat `ok`, " <>
            "and refuses a different one with `already_replied`.",
        type: :object,
        required: [:dispatch_id, :claim_epoch, :decision],
        properties: %{
          dispatch_id: %Schema{type: :string, format: :uuid},
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch being answered, echoed."
          },
          decision: %Schema{type: :string, enum: ["accepted", "refused"]},
          reason: %Schema{type: :string, enum: @refusal_reasons},
          detail: %Schema{type: :string, minLength: 1, maxLength: @max_detail_length}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerStage do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.Delivery.StageMachine

    # The wire enums are DERIVED from the stage machine (`StageMachine.runner_transitions/0`),
    # so the contract cannot declare a stage or an edge the machine does not have, and an edge
    # added to the machine is on the wire the moment it is reportable. The individual enums
    # bound each field; `RunnerContract.cast_stage/1` checks the TRIPLE, which is the real
    # rule — `{ci, escalated, ci_red}` passes three separate enums and is not a transition.
    @from_stages Enum.map(StageMachine.runner_from_stages(), &Atom.to_string/1)
    @to_stages Enum.map(StageMachine.runner_to_stages(), &Atom.to_string/1)
    @edges Enum.map(StageMachine.runner_edges(), &Atom.to_string/1)

    # The `story_stages_text_bounds` CHECK's bound, read from `StageMachine` — the ONE place
    # it is declared (#824 round 2), rather than a fourth copy of the number.
    #
    # CODEPOINTS, matching Postgres `char_length`. The schema's `maxLength` below cannot
    # enforce that: OpenApiSpex counts it with `String.length/1`, which counts GRAPHEMES, and
    # an emoji family or a combining mark is one grapheme and several characters to Postgres
    # — so a 4000-grapheme reason cast clean here and was refused by the CHECK afterwards,
    # which is not a retryable class. `RunnerContract.reason_length_errors/1` applies the
    # codepoint bound, and the `maxLength` stays as the published number a runner splits by.
    @max_reason_length StageMachine.max_reason_length()

    @doc "The bound counted the way Postgres counts it."
    @spec codepoints(String.t()) :: non_neg_integer()
    def codepoints(value), do: value |> String.to_charlist() |> length()

    @doc """
    The effect identities a `stage` message may carry, read off the schema's OWN properties.

    `StageMachine.reportable_effects/0` is the DECLARATION; this is what the schema actually
    says, and `runner_contract_test.exs` asserts the two are equal — so a property added here
    without the machine's blessing, or an effect the machine allows and the schema forgot,
    both go red. The ack and the `effect_conflict` refusal read the machine's list.

    At runtime, not compile time: `schema/0` is defined by the `OpenApiSpex.schema` macro
    below and a module attribute cannot call it.
    """
    @spec effect_names() :: [atom()]
    def effect_names, do: schema().properties |> Map.keys() |> Enum.sort()

    @doc "The stages a runner may report a transition OUT of."
    @spec from_stages() :: [String.t()]
    def from_stages, do: @from_stages

    @doc "The stages a runner may report a transition INTO."
    @spec to_stages() :: [String.t()]
    def to_stages, do: @to_stages

    @doc "The edges a runner may report."
    @spec edges() :: [String.t()]
    def edges, do: @edges

    @doc "The longest escalation reason or note a stage message may carry."
    @spec max_reason_length() :: pos_integer()
    def max_reason_length, do: @max_reason_length

    OpenApiSpex.schema(
      %{
        title: "RunnerStageEffects",
        description:
          "The identities a transition produced, recorded on the story's stage row before " <>
            "the effect is repeated. Each is writable only by the stage that produces it, " <>
            "and only once: the same value again is accepted (a replay finds what its " <>
            "first run recorded), a different one is refused. `merge_sha` is the one that " <>
            "cannot be written before its effect, because the merge commit does not exist " <>
            "until GitHub makes it, so it is REQUIRED on the transition into `merged` and " <>
            "accepted nowhere else. `runner_id` is deliberately absent: which machine holds " <>
            "a story is control's to record, not a runner's to assert.",
        type: :object,
        properties: %{
          worktree_path: %Schema{type: :string, minLength: 1, maxLength: 4096},
          branch: %Schema{type: :string, minLength: 1, maxLength: 255},
          head_sha: %Schema{type: :string, pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$"},
          merge_sha: %Schema{type: :string, pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$"},
          pr_number: %Schema{type: :integer, minimum: 1},
          release_id: %Schema{type: :string, minLength: 1, maxLength: 255}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerStageReport do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerStage

    OpenApiSpex.schema(
      %{
        title: "RunnerStageReport",
        description:
          "One delivery-stage transition a runner's session made, pushed as the `stage` " <>
            "event (since 1.4.0). It is a REQUEST, never authority: Postgres owns the " <>
            "stage, and the server compare-and-sets `from` -> `to` on the story's row " <>
            "inside one transaction. `from` is on the wire for that reason — a row that " <>
            "has moved refuses the message with `stale_stage` rather than taking a " <>
            "transition from wherever it happens to be. `claim_epoch` is the fence: it " <>
            "must be the dispatch's AND the story's current epoch, so a session whose " <>
            "claim was reclaimed writes nothing. A REPLAY is safe — a message whose first " <>
            "copy committed finds the row already at `to` and is answered `ok` with the " <>
            "row, so a re-send after a lost acknowledgement never transitions twice. " <>
            "Arriving at a terminal stage also gives the runner slot back, in the same " <>
            "transaction; the server decides that from the stage, so nothing here can free " <>
            "a slot whose session is still running. `escalated` is the only terminal a " <>
            "runner can reach: `verified` and `done` are control's verdicts, not a " <>
            "session's, so a story waits at `deployed`.",
        type: :object,
        required: [:dispatch_id, :claim_epoch, :from, :to],
        properties: %{
          dispatch_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "The ACCEPTED dispatch whose session made this transition. It names the " <>
                "story; a story id is never taken from the wire."
          },
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch, echoed."
          },
          from: %Schema{
            type: :string,
            enum: RunnerStage.from_stages(),
            description: "The stage the runner believed the story was at."
          },
          to: %Schema{type: :string, enum: RunnerStage.to_stages()},
          edge: %Schema{
            type: :string,
            enum: RunnerStage.edges(),
            description:
              "Which transition, when `from` -> `to` has more than one. Defaults to " <>
                "`forward`. Every edge but `forward` counts in the story's `attempts`."
          },
          reason: %Schema{
            type: :string,
            minLength: 1,
            maxLength: RunnerStage.max_reason_length(),
            description:
              "REQUIRED entering `escalated` and on `merge_refused`, a free note " <>
                "otherwise. Session-authored and therefore untrusted: it is recorded and " <>
                "capped, never executed, and fenced as untrusted data wherever it reaches " <>
                "a prompt. At most #{RunnerStage.max_reason_length()} CODEPOINTS — the " <>
                "`maxLength` beside this is the same number counted as graphemes, which " <>
                "is looser, so split by codepoints. A reason over the bound is " <>
                "`invalid_payload`."
          },
          effects: RunnerStage.schema()
        }
      },
      struct?: false
    )
  end

  defmodule RunnerSessionEnded do
    @moduledoc """
    The `session_ended` message: why the session under an implement dispatch stopped (1.16.0,
    epic 44 US-44.3). See "Session end" in `Loopctl.ApiSpec.RunnerContract` for what each
    reason does to the story.

    Three fields and no free text, deliberately. Everything control does with it is decided from
    the `reason` ENUM, and entering `escalated` writes a chained entry that cannot be corrected
    afterwards — so there is no field a session's prose could reach it through.
    """

    require OpenApiSpex

    # Why a session stops, as far as control needs to tell apart: it finished, its budget
    # killed it (two ways), the account it runs on ran dry, or it died.
    @reasons ~w(completed wall_clock_exceeded max_turns_exceeded usage_exhausted crashed)

    @doc "Every reason a runner may give for a session ending."
    @spec reasons() :: [String.t()]
    def reasons, do: @reasons

    OpenApiSpex.schema(
      %{
        title: "RunnerSessionEnded",
        description:
          "Why the session under an ACCEPTED `implement` dispatch stopped (since 1.16.0). " <>
            "Optional: a runner that never sends it gets the lease reclaim, as before. A FACT, " <>
            "not a request — control decides the story's next stage from `reason`: " <>
            "`completed` changes nothing, `wall_clock_exceeded` and `max_turns_exceeded` " <>
            "escalate an in-flight story over the control-only `budget_reported` edge and " <>
            "end its claim, `crashed` releases the claim at once over `runner_lost` — " <>
            "re-queued below the retry ceiling, escalated over the control-only " <>
            "`attempts_exhausted` edge at it (since 1.18.0) — and `usage_exhausted` " <>
            "releases it the same way without counting an attempt. RECORDED ONCE PER DISPATCH: " <>
            "a byte-identical resend is answered `ok` with the row even after the release it " <>
            "caused moved the claim epoch on, and a different `reason` is `already_recorded`.",
        type: :object,
        required: [:dispatch_id, :claim_epoch, :reason],
        properties: %{
          dispatch_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "The ACCEPTED implement dispatch whose session ended. It names the story; a " <>
                "story id is never taken from the wire."
          },
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch, echoed."
          },
          reason: %Schema{
            type: :string,
            enum: @reasons,
            description:
              "Why the session stopped. `usage_exhausted` means the account the session ran " <>
                "on hit its usage limit; `crashed` is any end the runner did not choose and " <>
                "that is not one of the others."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerSessionEndedAck do
    @moduledoc """
    The reply to a `session_ended` (1.16.0): the story's stage row as it stands AFTER control
    acted on the report — the same fields a `stage` ack carries — and whether this delivery was
    a resend of one already recorded.
    """

    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerStage

    OpenApiSpex.schema(
      %{
        title: "RunnerSessionEndedAck",
        description:
          "The reply to an accepted `session_ended`: where the story now is, and whether this " <>
            "was a resend. The row fields are the ones a `stage` ack carries.",
        type: :object,
        required: [:stage, :claim_epoch, :lock_version, :attempts, :effects, :replayed],
        properties: %{
          stage: %Schema{type: :string, description: "The stage the story is at now."},
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "The epoch the row is bound to now. Past the dispatch's after a `crashed` or " <>
                "`usage_exhausted` release: the claim the session ran under has ended."
          },
          lock_version: %Schema{type: :integer, minimum: 0},
          attempts: %Schema{
            type: :object,
            description: "How many times each counted edge has been taken, keyed by edge."
          },
          effects: %{
            RunnerStage.schema()
            | description: "The identities the row holds, as a `stage` ack reports them."
          },
          replayed: %Schema{
            type: :boolean,
            description:
              "False on the delivery that recorded this report, true on any resend of it. A " <>
                "resend changes nothing a second time."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTraceBatch do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule
    alias Loopctl.ApiSpec.RunnerContract.RunnerTraceEvent

    # Referenced by `maxItems` below and enforced by `RunnerContract.cast_trace_batch/1`.
    @max_events 20

    # The byte budget of a whole batch under `ByteRule`. A string's maxLength counts
    # characters, not bytes, so only a byte budget keeps a frame inside the runner socket's
    # 64 KB cap, which Bandit enforces by closing the socket before any of this code runs.
    # This budget plus `RunnerContract.frame_envelope_bytes/0` stays under that cap; a test
    # holds it against an encoder that escapes every character.
    @max_bytes 60_000

    @doc "The most events one `trace` batch may carry."
    @spec max_events() :: pos_integer()
    def max_events, do: @max_events

    @doc "The byte budget of one `trace` batch, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceBatch",
        description:
          "A batch of one run's trace events, pushed as the `trace` event. Every event's " <>
            "`run_id` must equal the batch's. At most #{@max_events} events and at most " <>
            "#{@max_bytes} bytes under the byte rule below; either excess is refused with " <>
            "`batch_too_large`, so split the batch — except that a one-event batch over the " <>
            "budget is refused with `event_data_too_large` naming its `seq`, since splitting " <>
            "cannot help. The run must belong to an ACCEPTED dispatch this runner holds, at " <>
            "the dispatched `claim_epoch`; the first batch binds `run_id` to `dispatch_id`. " <>
            "Replied with `RunnerTraceAck`. " <> ByteRule.text(),
        type: :object,
        required: [:run_id, :dispatch_id, :claim_epoch, :events],
        properties: %{
          run_id: %Schema{type: :string, format: :uuid},
          dispatch_id: %Schema{type: :string, format: :uuid},
          claim_epoch: %Schema{type: :integer, minimum: 0},
          events: %Schema{type: :array, maxItems: @max_events, items: RunnerTraceEvent.schema()}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTraceCursor do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceCursor",
        description:
          "Asks where a run's stored trace ends, pushed as the `trace_cursor` event before " <>
            "resuming a shipment. Replied with `RunnerTraceAck`; a run this runner has not " <>
            "shipped (or does not hold) answers -1.",
        type: :object,
        required: [:run_id],
        properties: %{run_id: %Schema{type: :string, format: :uuid}}
      },
      struct?: false
    )
  end

  defmodule RunnerDisconnecting do
    @moduledoc false
    require OpenApiSpex

    @reasons ~w(runner_revoked no_longer_authorized join_refused_not_authorized server_shutdown)

    @doc "Every reason loopctl gives for a disconnect it initiates."
    @spec reasons() :: [String.t()]
    def reasons, do: @reasons

    OpenApiSpex.schema(
      %{
        title: "RunnerDisconnecting",
        description:
          "Pushed as `disconnecting` on the runner's topic immediately before loopctl closes " <>
            "the runner's connection itself. `runner_revoked` and `no_longer_authorized` mean " <>
            "the credential no longer works: do not reconnect until re-enrolled. " <>
            "`server_shutdown` means the node is stopping: reconnect. " <>
            "`join_refused_not_authorized` arrives as the `disconnecting` field of a refused " <>
            "join's error reply, because an unjoined topic cannot carry a push.",
        type: :object,
        required: [:reason],
        properties: %{reason: %Schema{type: :string, enum: @reasons}}
      },
      struct?: false
    )
  end

  defmodule RunnerCheckpoint do
    @moduledoc """
    The `checkpoint` message: a commit the session under an implement dispatch pushed (1.20.0,
    epic 45 US-45.2). See "Change threads" in `Loopctl.ApiSpec.RunnerContract`.

    Recorded by `Loopctl.Threads.record_checkpoint/3`, the function the HTTP surface uses, with
    the same claimant fence. The story comes from the dispatch, never from the wire, and a
    checkpoint's parent is derived by loopctl, so nothing here names either.
    """

    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule
    alias Loopctl.ApiSpec.RunnerContract.Limits
    alias Loopctl.Threads.Entry

    # The same shape `Loopctl.Threads` enforces: lowercase hex, SHA-1 or SHA-256.
    @sha_pattern "^[0-9a-f]{40}([0-9a-f]{24})?$"

    # The message under the byte rule. A note may be `Entry.max_body_bytes/0` UTF-8 bytes,
    # which the byte rule can charge six times over, so without a message budget a note
    # loopctl would store could be a frame the socket closes on — and that close takes every
    # session on the socket with it. Leaves `frame_envelope_bytes/0` of the frame for the
    # envelope, as `RunnerTraceBatch`'s budget does.
    @max_bytes 60_000

    @doc "The byte budget of one `checkpoint` message, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    @doc "The bounds a runner cannot read off the schema, for `x-connection.limits`."
    @spec limits() :: map()
    def limits, do: Limits.of(schema(), @max_bytes)

    OpenApiSpex.schema(
      %{
        title: "RunnerCheckpoint",
        description:
          "A commit the session under an ACCEPTED `implement` dispatch pushed (since " <>
            "1.20.0), recorded on the story's change thread. Optional: a runner that never " <>
            "sends it gets today's behaviour. Recorded only for the story's current " <>
            "claimant at the current `claim_epoch` while the claim is live. IDEMPOTENT: a " <>
            "resend of the same commit, tree and note is answered `ok` with `replayed: " <>
            "true`; the same commit under this claim with another tree or note is " <>
            "`checkpoint_conflict`. At most #{@max_bytes} bytes under the byte rule. " <>
            ByteRule.text(),
        type: :object,
        required: [:dispatch_id, :claim_epoch, :commit_sha, :tree_sha],
        properties: %{
          dispatch_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "The ACCEPTED implement dispatch whose session pushed the commit. It names the " <>
                "story; a story id is never taken from the wire."
          },
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch, echoed."
          },
          commit_sha: %Schema{
            type: :string,
            pattern: @sha_pattern,
            description: "The pushed commit: lowercase hex, 40 or 64 characters."
          },
          tree_sha: %Schema{
            type: :string,
            pattern: @sha_pattern,
            description:
              "The commit's tree, in the same object format as `commit_sha` (both 40 or " <>
                "both 64); a mismatch is `invalid_payload`."
          },
          note: %Schema{
            type: :string,
            minLength: 1,
            maxLength: Entry.max_body_bytes(),
            description:
              "Why this commit, in the session's words. Untrusted: recorded, never executed. " <>
                "At most #{Entry.max_body_bytes()} UTF-8 BYTES — the `maxLength` beside this " <>
                "is the same number counted as graphemes, which is looser. THE MESSAGE CAP IS " <>
                "WHAT BINDS: the whole message is at most #{@max_bytes} bytes under the byte " <>
                "rule, which charges 6 bytes per character and 12 for one outside the Basic " <>
                "Multilingual Plane, so a note under this field's maximum can still be " <>
                "`invalid_payload`. Whitespace alone is `invalid_payload`, and a " <>
                "credential-shaped value is `secret_blocked`."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerCheckpointAck do
    @moduledoc "The reply to a `checkpoint` (1.20.0)."

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerCheckpointAck",
        description: "The reply to an accepted `checkpoint`.",
        type: :object,
        required: [:checkpoint_id, :seq, :replayed],
        properties: %{
          checkpoint_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "The checkpoint's id — the same on every resend. A `thread_entry` may name it " <>
                "as its `checkpoint_id`."
          },
          seq: %Schema{
            type: :integer,
            minimum: 1,
            description: "The checkpoint's position among the story's checkpoints."
          },
          replayed: %Schema{
            type: :boolean,
            description:
              "False on the delivery that recorded this checkpoint, true on any resend of " <>
                "it. A resend writes nothing."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerThreadEntry do
    @moduledoc """
    The `thread_entry` message: a note the session under an implement dispatch puts on the
    story's change thread (1.20.0, epic 45 US-45.2). Always kind `message`: the kinds that
    decide what may merge are written by the review flow (US-45.3), never by a runner.

    Its idempotency key is `<dispatch_id>:<client_seq>`, built by loopctl, so a runner numbers
    its notes and never spells a key.
    """

    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule
    alias Loopctl.ApiSpec.RunnerContract.Limits
    alias Loopctl.Threads.Entry

    # See `RunnerCheckpoint`'s budget: the same reason, the same number.
    @max_bytes 60_000

    @doc "The byte budget of one `thread_entry` message, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    @doc "The bounds a runner cannot read off the schema, for `x-connection.limits`."
    @spec limits() :: map()
    def limits, do: Limits.of(schema(), @max_bytes)

    OpenApiSpex.schema(
      %{
        title: "RunnerThreadEntry",
        description:
          "A note on the story's change thread from the session under an ACCEPTED " <>
            "`implement` dispatch (since 1.20.0), recorded as a `message` entry. Optional: a " <>
            "runner that never sends it gets today's behaviour. The entry's idempotency key " <>
            "is `<dispatch_id>:<client_seq>`: a resend with the same `client_seq` and the " <>
            "same `body` and `checkpoint_id` is answered `ok` with `replayed: true`, and a " <>
            "different one is `idempotency_key_reused`. At most #{@max_bytes} bytes under " <>
            "the byte rule. " <> ByteRule.text(),
        type: :object,
        required: [:dispatch_id, :claim_epoch, :client_seq, :body],
        properties: %{
          dispatch_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "The ACCEPTED implement dispatch whose session wrote the note. It names the " <>
                "story; a story id is never taken from the wire."
          },
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch, echoed."
          },
          client_seq: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "The runner's own number for this note within the dispatch. Number each note " <>
                "once; a resend carries the same number."
          },
          body: %Schema{
            type: :string,
            minLength: 1,
            maxLength: Entry.max_body_bytes(),
            description:
              "The note. Untrusted: recorded, never executed. At most " <>
                "#{Entry.max_body_bytes()} UTF-8 BYTES — the `maxLength` beside this is the " <>
                "same number counted as graphemes, which is looser. THE MESSAGE CAP IS WHAT " <>
                "BINDS: the whole message is at most #{@max_bytes} bytes under the byte rule, " <>
                "which charges 6 bytes per character and 12 for one outside the Basic " <>
                "Multilingual Plane, so a note under this field's maximum can still be " <>
                "`invalid_payload`; split it across entries. Whitespace alone is " <>
                "`invalid_payload`, and a credential-shaped value is `secret_blocked`."
          },
          checkpoint_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "A checkpoint of THIS story (a `checkpoint` ack's `checkpoint_id`) the note is " <>
                "about. Any other id is `invalid_payload`."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerThreadEntryAck do
    @moduledoc "The reply to a `thread_entry` (1.20.0)."

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerThreadEntryAck",
        description: "The reply to an accepted `thread_entry`.",
        type: :object,
        required: [:entry_id, :seq, :replayed],
        properties: %{
          entry_id: %Schema{
            type: :string,
            format: :uuid,
            description: "The entry's id — the same on every resend."
          },
          seq: %Schema{
            type: :integer,
            minimum: 1,
            description: "The entry's position on the story's thread."
          },
          replayed: %Schema{
            type: :boolean,
            description:
              "False on the delivery that recorded this note, true on any resend of it. A " <>
                "resend writes nothing."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTraceAck do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceAck",
        description:
          "The reply to `trace` and `trace_cursor`: the highest seq such that every seq " <>
            "from 0 to it is stored, or -1 when seq 0 is not. Resume from `acked_seq + 1`.",
        type: :object,
        required: [:acked_seq],
        properties: %{acked_seq: %Schema{type: :integer, minimum: -1}}
      },
      struct?: false
    )
  end

  @schemas [
    RunnerJoin,
    RunnerStatus,
    RunnerSample,
    RunnerUsage,
    RunnerStory,
    RunnerTriage,
    RunnerTriageVerdict,
    RunnerLensVerdict,
    RunnerTriageVerdictMessage,
    RunnerTriageVerdictAck,
    RunnerSessionEnded,
    RunnerSessionEndedAck,
    RunnerCheckpoint,
    RunnerCheckpointAck,
    RunnerThreadEntry,
    RunnerThreadEntryAck,
    RunnerDispatch,
    RunnerDispatchReply,
    RunnerTraceEvent,
    RunnerTraceBatch,
    RunnerTraceCursor,
    RunnerTraceAck,
    RunnerDisconnecting,
    RunnerStage,
    RunnerStageReport
  ]

  # The stable `reason` codes each runner-to-control event can be refused with. Exported, so
  # a runner can switch on them without reading this source.
  #
  # `internal_error` is on EVERY inbound event and is the server admitting a gap: a refusal
  # reason no clause of `LoopctlWeb.RunnerChannel.message_error/1` names. It used to RAISE,
  # which took the channel down and every in-flight session on that socket with it (#824
  # round 2). It is not actionable — retrying is reasonable, the same message may well work
  # once the gap is closed — and the underlying reason is logged server-side, never sent.
  @error_reasons %{
    "status" => ~w(rate_limited invalid_payload internal_error),
    "dispatch_reply" =>
      ~w(rate_limited invalid_payload unknown_dispatch stale_claim_epoch already_replied
         internal_error),
    "trace" =>
      ~w(rate_limited invalid_payload batch_too_large event_data_too_large unknown_dispatch
         stale_claim_epoch dispatch_not_accepted run_mismatch internal_error),
    "trace_cursor" => ~w(rate_limited invalid_payload internal_error),
    # Since 1.4.0. Two codes are NEW because nothing already published carries their remedy,
    # and a runner that cannot tell them apart does the wrong thing:
    #
    # - `stale_stage` — the row is not at `from`. The message is well formed and the claim is
    #   fine, so `invalid_payload` (stop sending this) and `stale_claim_epoch` (stop working
    #   the story) are both actively wrong. Since 1.11.0 the refusal CARRIES the row — the
    #   same `{stage, claim_epoch, lock_version, attempts, effects}` the ok ack sends — and
    #   the transition that applies is read off it. Before that it carried the code alone,
    #   which made the prescribed remedy unfollowable: `story_stages` has no runner-facing
    #   endpoint by design, because the reply IS the read. The deployed runner did the only
    #   thing left and brute-forced three `from` values in turn, all refused, none of them
    #   naming where the row was, and the operator reading the journal could not name it
    #   either (#849).
    # - `unknown_story_stage` — the dispatch's story has no stage row at all, which is a
    #   control-plane state the runner cannot fix by resending or by giving up the claim.
    #   `unknown_dispatch` would name the wrong object: the dispatch is known.
    #
    # Everything the stage machine refuses on the MESSAGE's own content — a transition that
    # is not in the table, a missing escalation reason, a malformed or wrong-stage effect —
    # is `invalid_payload` with details, because resending it unchanged cannot help.
    # - `effect_conflict` — the server already recorded a DIFFERENT identity for this
    #   transition. Read the recorded values off the ack (`effects`) and reconcile; do NOT
    #   re-send. `invalid_payload` would tell a runner whose merge sha was dropped that its
    #   message was malformed, which is both wrong and the wrong remedy. The refusal CARRIES
    #   the recorded identities in `effects`, because the case it exists for is a LOST ack —
    #   the runner never saw the one that named the surviving value.
    # - `audit_chain_append_failed` — the tenant's hash chain refused this transition's entry
    #   and nothing was written. PERMANENT: the next attempt fails the same way and every
    #   custody transition in the tenant is failing until an operator acts. Do NOT retry; it is
    #   deliberately not `rate_limited`, and it is the same code the HTTP surface answers.
    "stage" =>
      ~w(rate_limited invalid_payload unknown_dispatch dispatch_not_accepted stale_claim_epoch
         stale_stage unknown_story_stage effect_conflict audit_chain_append_failed
         internal_error),
    # Since 1.9.0. `already_recorded` is the one that needs its meaning stated: this dispatch
    # already has a verdict and the bytes just sent are NOT the same ones. An identical
    # resend is never refused — it is answered `ok` — so seeing this code means the two sides
    # disagree about what the session decided, which no retry can fix.
    #
    # `stale_stage` HERE CARRIES NO ROW, and that is the one asymmetry a runner writing a
    # single handler for the code must know about (`x-connection.error_fields` says so per
    # event, which is why that map is keyed by event). On `stage` the row is the remedy; here
    # the story has left `detected`, the verdict's first transition can never match again, and
    # the code is permanent — so handing back a row would suggest a retry this contract
    # refuses.
    "triage_verdict" =>
      ~w(rate_limited invalid_payload unknown_dispatch dispatch_not_accepted stale_claim_epoch
         already_recorded unknown_story_stage stale_stage audit_chain_append_failed
         internal_error),
    # Since 1.16.0. `already_recorded` means what it means on `triage_verdict`: this dispatch
    # already has a session-end report and the bytes just sent are NOT the same ones. An
    # identical resend is never refused, even after the release its first copy caused moved
    # the claim epoch — it is matched on its bytes before the epoch is looked at.
    # `stale_claim_epoch` is therefore about a FIRST report only. No `stale_stage`: where the
    # story is, is what the ok reply carries, and nothing the runner sends names a `from`.
    # `audit_chain_append_failed` is a budget kill's escalation refused by the tenant's hash
    # chain, permanent as on `stage`; a budget escalation that merely could not get its lock is
    # `rate_limited`, and the resend completes it.
    "session_ended" =>
      ~w(rate_limited invalid_payload unknown_dispatch dispatch_not_accepted stale_claim_epoch
         already_recorded unknown_story_stage audit_chain_append_failed internal_error),
    # Since 1.20.0 (US-45.2), the change thread. Four codes are NEW, each because nothing
    # already published carries its remedy:
    #
    # - `not_claimant` — the story's claim is not this runner's agent (or the story is not
    #   claimed at all). `stale_claim_epoch` names a moved epoch, which this is not.
    # - `claim_not_live` — the claim is this runner's and at this epoch, but its lease has
    #   run out or review has been requested, so the implementer can no longer add to it.
    # - `checkpoint_conflict` / `idempotency_key_reused` — a resend that is NOT the same write.
    #   Acknowledging it would say the new content was recorded when it was not.
    # - `secret_blocked` — a text field carries a credential shape. `invalid_payload` would
    #   send the runner looking for a malformed field; this names the one thing to remove.
    #
    # `audit_chain_append_failed` is the tenant's hash chain refusing the write's entry, as on
    # `stage`: permanent, and nothing was written.
    "checkpoint" =>
      ~w(rate_limited invalid_payload unknown_dispatch dispatch_not_accepted stale_claim_epoch
         not_claimant claim_not_live checkpoint_conflict secret_blocked
         audit_chain_append_failed internal_error),
    "thread_entry" =>
      ~w(rate_limited invalid_payload unknown_dispatch dispatch_not_accepted stale_claim_epoch
         idempotency_key_reused secret_blocked audit_chain_append_failed internal_error),
    # Since 1.2.0. `join` is the `phx_join` reply; `unknown_event` answers any event this
    # map does not name, every time.
    "join" => ~w(rate_limited not_authorized invalid_payload unsupported_contract_version
         machine_mismatch forbidden_topic unknown_topic),
    "unknown_event" => ~w(unknown_event)
  }

  # WHAT EACH REFUSAL CARRIES BESIDE ITS `reason`, published rather than left in a moduledoc a
  # vendoring runner never reads — the lesson 1.9.2 and 1.9.3 already paid for with
  # `permanent_error_conditions` and `triage_gating_reasons`. A refusal's EXTRA FIELDS were
  # the one part of this contract a holder could only learn by reading loopctl's source or by
  # observing a refusal in production, and 1.11.0 is the release that makes that expensive:
  # its whole point is that a `stale_stage` runner reads the row off the refusal instead of
  # brute-forcing `from`, and a vendored copy said nothing about there being a row to read.
  #
  # COMPLETE, and per EVENT, with an explicit `[]` for every code that carries nothing. Both
  # halves are deliberate. Per event, because `stale_stage` carries the row on `stage` and
  # NOTHING on `triage_verdict` — the same code, two shapes, which a flat map cannot say and
  # which is the same asymmetry `permanent_errors` already has to express. And explicit `[]`
  # rather than absence, because a partial map is worse than none: a runner looking up a code
  # it cannot find has no way to tell "carries nothing" from "nobody wrote this entry", and
  # would reasonably assume the latter. `error_fields_complete?/0` is what keeps it total, and
  # the contract test fails the moment a code is added to `@error_reasons` without one here.
  #
  # `rate_limited` is the reason this is keyed by event at all beyond `stale_stage`: on `join`
  # it carries the join bucket's `max_joins`/`window_ms`, and on every message the channel's
  # `min_interval_ms`. Same code, different fields, and a runner backing off on the wrong key
  # sleeps for a number that is not there.
  @error_field_overrides %{
    "join" => %{
      "rate_limited" => ~w(max_joins window_ms),
      "not_authorized" => ~w(disconnecting),
      "invalid_payload" => ~w(details),
      "unsupported_contract_version" => ~w(sent supported),
      "machine_mismatch" => ~w(declared)
    },
    "status" => %{"rate_limited" => ~w(min_interval_ms), "invalid_payload" => ~w(details)},
    "dispatch_reply" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details)
    },
    "trace" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details),
      "batch_too_large" => ~w(max_events max_bytes),
      "event_data_too_large" => ~w(seq max_data_bytes max_event_bytes)
    },
    "trace_cursor" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details)
    },
    "stage" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details),
      "effect_conflict" => ~w(effects),
      # SINCE 1.11.0, and the reason for the release. The same shape the ok ack sends, so one
      # parser serves both: the row this story's stage is actually at.
      "stale_stage" => ~w(stage claim_epoch lock_version attempts effects)
    },
    "triage_verdict" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details)
    },
    "session_ended" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details)
    },
    "checkpoint" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details)
    },
    "thread_entry" => %{
      "rate_limited" => ~w(min_interval_ms),
      "invalid_payload" => ~w(details)
    },
    "unknown_event" => %{}
  }

  @error_fields Map.new(@error_reasons, fn {event, codes} ->
                  overrides = Map.get(@error_field_overrides, event, %{})
                  {event, Map.new(codes, &{&1, Map.get(overrides, &1, [])})}
                end)

  # The runner-to-control events `LoopctlWeb.RunnerChannel.handle_in/3` acts on.
  @inbound_events ~w(status dispatch_reply trace trace_cursor stage triage_verdict
                     session_ended checkpoint thread_entry)

  # The minimum spacing, per channel, between two acted-on messages of one event. A message
  # inside it is refused with `rate_limited` and `min_interval_ms`. Each event has its OWN
  # floor. `LoopctlWeb.RunnerChannel` enforces exactly these values and the export publishes
  # them.
  @min_interval_ms %{
    "status" => 1_000,
    "trace" => 50,
    "trace_cursor" => 50
  }

  # `dispatch_reply` is a bucket rather than a floor: a runner handed several dispatches at
  # once answers them back to back, and a single per-runner gap refused the second answer.
  @dispatch_reply_burst %{"capacity" => 8, "refill_interval_ms" => 250}

  # A verdict is produced ONCE per run, so the risk here is not a flood, it is a token bucket
  # eating a run's entire output: a refused verdict cannot be re-derived, because the session
  # has stopped and the runner records one verdict per run by design. Sized so a resend
  # always lands well inside a run's remaining wall clock, and generous enough that a runner
  # answering several finished triage sessions at once is never made to hold one.
  @triage_verdict_burst %{"capacity" => 4, "refill_interval_ms" => 1_000}

  # One report per session, like a verdict, and for the same reason sized against losing it
  # rather than against a flood: a runner reconnecting after a deploy may have several
  # finished sessions to report at once, and each one refused is one it has to hold.
  @session_ended_burst %{"capacity" => 4, "refill_interval_ms" => 1_000}

  # The change thread (1.20.0). A checkpoint is one pushed commit, minutes apart in a working
  # session; the bucket is sized for a runner flushing what it buffered across a rejoin, two
  # sessions' worth. A note is written as the session reasons, so it comes in bursts, and each
  # one is a transaction appending to the tenant's audit chain — `stage`'s bucket, for the
  # same reason `stage` has it.
  @checkpoint_burst %{"capacity" => 8, "refill_interval_ms" => 500}
  @thread_entry_burst %{"capacity" => 12, "refill_interval_ms" => 250}

  # THE REFUSALS NO RESEND CAN CLEAR, published so a runner branches on the contract rather
  # than on a list it copied into its own source. Asked for by the `loopctl-runner`
  # maintaining session on that ground, 2026-09-15: it is the same lesson as reading the
  # bounds from `x-connection.limits` instead of re-typing them.
  #
  # Everything NOT here is worth resending unchanged — and for `triage_verdict` that is the
  # correct move on any of them, because an identical resend is idempotent.
  # A FLAT LIST CANNOT SAY THIS, and the first version was a flat list. `stale_stage` is
  # TRANSIENT for `stage` — the runner re-reads the story and sends the transition that now
  # applies — and PERMANENT for `triage_verdict`, where it means the story has left `detected`
  # and the verdict's first transition can never match again, so a conforming runner following
  # a global list would retry a doomed verdict for ever.
  #
  # `"*"` is what holds for every event; an event's own entry ADDS to it and never subtracts,
  # so a code cannot be permanent globally and transient for one message.
  @permanent_errors %{
    "*" => ~w(invalid_payload not_authorized unsupported_contract_version machine_mismatch
         forbidden_topic unknown_topic unknown_event unknown_dispatch stale_claim_epoch
         already_replied already_recorded dispatch_not_accepted run_mismatch effect_conflict
         audit_chain_append_failed unknown_story_stage),
    "triage_verdict" => ~w(stale_stage),
    # 1.20.0. The claim a checkpoint names is over or is not this runner's, or the write is
    # not the one already recorded, or it carries a credential: none of them changes by
    # sending the same bytes again.
    "checkpoint" => ~w(not_claimant claim_not_live checkpoint_conflict secret_blocked),
    "thread_entry" => ~w(idempotency_key_reused secret_blocked)
  }

  # THE ONE CONDITIONAL MEMBER OF THE LIST ABOVE, published rather than left in a moduledoc a
  # vendoring runner never reads. A flat list says "never resend", and for this code that is
  # true in two of its three states and wrong in the third — so a runner following the list
  # alone gives up a run that was about to be acceptable, and one following its own instinct
  # retries a doomed dispatch for ever. Both were live: the `loopctl-runner` session retried
  # it deliberately, with a comment, against what this contract published.
  #
  # Kept as TEXT and not as a second machine-readable rule, because the condition is about
  # the RUNNER's own state — what it has sent and not had acknowledged — which loopctl cannot
  # observe and therefore cannot express as a predicate over anything it publishes.
  #
  # `stale_stage` is the SECOND conditional member, and unlike the first its condition IS a
  # predicate over what this contract publishes — which is why it is worth stating rather
  # than leaving to instinct. `permanent_errors` calls it transient for `stage`, and that is
  # right in the ordinary case: the row moved, you re-read it off the refusal and send the
  # transition that applies. It is WRONG when the stage the refusal names has no transition
  # out for a runner, and that is reachable in production rather than hypothetical: a session
  # that calls `POST /stories/:id/escalate` with its own agent key moves its story to
  # `escalated` under the same `claim_epoch`, so the runner's very next ordinary report is
  # refused `stale_stage` naming a terminal stage. A runner following the transient/permanent
  # split alone then retries a message that can never succeed, for ever. `stage_transitions`
  # is the list to check it against, and it is published for exactly this kind of local
  # decision.
  @permanent_error_conditions %{
    "stale_stage" =>
      "Transient for `stage` in the ordinary case: the row moved, so read the row off this " <>
        "refusal and send the transition that applies from the `stage` it names. It is " <>
        "PERMANENT when no entry of `x-connection.stage_transitions` has that `stage` as its " <>
        "`from` - the story has reached a stage no runner can report out of, which a session " <>
        "reaches by escalating through the HTTP surface while its run continues. Stop, and " <>
        "end the run. For `triage_verdict` it is permanent unconditionally and carries no " <>
        "row: the story has left `detected` and the verdict's first transition can never " <>
        "match again.",
    "dispatch_not_accepted" =>
      "Permanent unless an accept YOU sent for this dispatch is still unacknowledged. " <>
        "The refusal means the ledger row is not `accepted`, which covers `sent` (your " <>
        "accept has not landed yet - in flight, rate-limited, or carried across a rejoin, " <>
        "and the one case worth retrying), and `refused` and `superseded`, which are final " <>
        "and which no later accept can move. So retry, with backoff, only while an accept " <>
        "for this dispatch is outstanding AND you have not since refused it and its " <>
        "`claim_epoch` has not moved; otherwise give the run up, because nothing will move " <>
        "the row."
  }

  # `stage` is a bucket for the same reason, and a bigger one. A machine at `max_sessions: 2`
  # runs two stories at once, each walking a thirteen-stage line, and a runner that has been
  # offline through a rolling deploy ships every transition it buffered the moment it
  # rejoins. A per-channel FLOOR would refuse the second story's message because the first
  # story's had just landed. Each message is a database transaction and some of them append
  # to the tenant's audit chain, so it is metered; the bucket lets a burst through and then
  # paces it.
  @stage_burst %{"capacity" => 12, "refill_interval_ms" => 250}

  # What the Phoenix V2 frame around a `trace` payload can cost under `ByteRule`:
  # [join_ref, ref, "runner:<uuid>", "trace", payload] with 20-digit refs is under 600.
  @frame_envelope_bytes 1_000

  # One below Postgres `bigint`'s maximum: the contiguous-ack query probes `seq + 1`, which
  # must itself fit. The `runner_trace_events_seq` CHECK holds the same bound.
  @max_seq 9_223_372_036_854_775_806

  @doc "The contract version loopctl speaks (semver)."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The minimum interval, in milliseconds, between two messages of `event` on one channel.
  The channel enforces it and the export publishes it (`x-connection.limits.min_interval_ms`).
  """
  @spec min_interval_ms(String.t()) :: pos_integer()
  def min_interval_ms(event), do: Map.fetch!(@min_interval_ms, event)

  @doc """
  The `dispatch_reply` bucket: `capacity` replies back to back, refilled one per
  `refill_interval_ms`. The channel enforces it and the export publishes it.
  """
  @spec dispatch_reply_burst() :: %{String.t() => pos_integer()}
  def dispatch_reply_burst, do: @dispatch_reply_burst

  @doc """
  The `triage_verdict` bucket (1.9.0). See the note above `@triage_verdict_burst`.
  """
  @spec triage_verdict_burst() :: %{String.t() => pos_integer()}
  def triage_verdict_burst, do: @triage_verdict_burst

  @doc """
  The `session_ended` bucket (1.16.0). See the note above `@session_ended_burst`.
  """
  @spec session_ended_burst() :: %{String.t() => pos_integer()}
  def session_ended_burst, do: @session_ended_burst

  @doc """
  The `checkpoint` bucket (1.20.0). See the note above `@checkpoint_burst`.
  """
  @spec checkpoint_burst() :: %{String.t() => pos_integer()}
  def checkpoint_burst, do: @checkpoint_burst

  @doc """
  The `thread_entry` bucket (1.20.0). See the note above `@checkpoint_burst`.
  """
  @spec thread_entry_burst() :: %{String.t() => pos_integer()}
  def thread_entry_burst, do: @thread_entry_burst

  @doc """
  The refusal codes no resend can clear, per event (1.9.0).

  `"*"` holds for every event; an event's own key ADDS to it. A runner branches on this
  rather than on a list copied into its own source, and `permanent_error?/2` is the reading
  of it — everything not named is worth resending unchanged.
  """
  @spec permanent_errors() :: %{String.t() => [String.t()]}
  def permanent_errors, do: @permanent_errors

  @doc """
  The conditions attached to a permanent code, keyed by code (1.9.2).

  One entry today. A code named here is in `permanent_errors/0` as well and stays permanent
  by default: this says when a resend is nevertheless worth making, in terms of the RUNNER's
  own state, which is why it is text and not a predicate.
  """
  @spec permanent_error_conditions() :: %{String.t() => String.t()}
  def permanent_error_conditions, do: @permanent_error_conditions

  @doc """
  What each refusal carries BESIDE its `reason`, keyed by event then by code (1.11.0).

  Complete: every code `error_reasons/0` publishes for an event has an entry here, and a code
  that carries nothing has an explicit `[]`. So a lookup that finds nothing means the EVENT or
  the CODE is not one this contract publishes — never that the refusal happens to be bare.
  """
  @spec error_fields() :: %{String.t() => %{String.t() => [String.t()]}}
  def error_fields, do: @error_fields

  @doc """
  True when every event and code `error_reasons/0` publishes has an `error_fields/0` entry.

  The totality this contract promises, as a function rather than a comment, so the test that
  binds the two can ask instead of re-deriving it.
  """
  @spec error_fields_complete?() :: boolean()
  def error_fields_complete? do
    Enum.all?(@error_reasons, fn {event, codes} ->
      published = Map.get(@error_fields, event, %{})
      Enum.sort(Map.keys(published)) == Enum.sort(codes)
    end)
  end

  @doc """
  The `escalation_reasons` entries the control-side gate matches as whole strings (1.9.3).

  A reading of `Loopctl.DeliveryGates.GateA`, never a copy — see `x-connection` in the
  moduledoc for what the list does and does not mean today.
  """
  @spec gating_reason_codes() :: [String.t()]
  def gating_reason_codes, do: GateA.gating_reason_codes()

  @doc """
  True when `reason` can never be cleared by resending `event`.

  The reason this is a function and not a list the caller filters: `stale_stage` is transient
  for `stage` and permanent for `triage_verdict`, so reading the global set alone gives the
  wrong answer for one of them whichever way it is written.
  """
  @spec permanent_error?(String.t(), String.t()) :: boolean()
  def permanent_error?(event, reason) do
    reason in Map.fetch!(@permanent_errors, "*") or
      reason in Map.get(@permanent_errors, event, [])
  end

  @doc """
  The `stage` bucket: `capacity` transitions back to back, refilled one per
  `refill_interval_ms`. The channel enforces it and the export publishes it.
  """
  @spec stage_burst() :: %{String.t() => pos_integer()}
  def stage_burst, do: @stage_burst

  @doc "The allowance for the V2 frame around a `trace` payload, under the byte rule."
  @spec frame_envelope_bytes() :: pos_integer()
  def frame_envelope_bytes, do: @frame_envelope_bytes

  @doc "The largest `seq` a trace event may carry."
  @spec max_seq() :: pos_integer()
  def max_seq, do: @max_seq

  @doc """
  The stable error `reason` codes, per runner-to-control event, plus `join` (the `phx_join`
  reply) and `unknown_event` (any event not named here).
  """
  @spec error_reasons() :: %{String.t() => [String.t()]}
  def error_reasons, do: @error_reasons

  @doc "The runner-to-control events the channel acts on (`phx_join` aside)."
  @spec inbound_events() :: [String.t()]
  def inbound_events, do: @inbound_events

  @doc "The schema modules the contract declares."
  @spec schema_modules() :: [module()]
  def schema_modules, do: @schemas

  @doc """
  Validates a join payload. Returns the known fields only, with atom keys, or
  `{:error, reason}` where reason is `{:invalid, messages}` or
  `{:unsupported_contract_version, sent, speaks}`.
  """
  @spec cast_join(term()) :: {:ok, map()} | {:error, term()}
  def cast_join(payload) do
    with {:ok, cast} <- cast(payload, RunnerJoin.schema()),
         :ok <- supported_version(cast.contract_version) do
      {:ok, known_fields(cast, RunnerJoin.schema())}
    end
  end

  @doc "Validates a `status` payload. Returns the known fields only, with atom keys."
  @spec cast_status(term()) :: {:ok, map()} | {:error, term()}
  def cast_status(payload) do
    with {:ok, cast} <- cast(payload, RunnerStatus.schema()) do
      case known_fields(cast, RunnerStatus.schema()) do
        empty when map_size(empty) == 0 -> {:error, {:invalid, ["no known status field"]}}
        known -> {:ok, known}
      end
    end
  end

  @doc """
  Validates an outbound `dispatch` payload before it is pushed to a runner. Returns the
  declared fields only, with atom keys, or `{:error, {:invalid, messages}}`.

  Outbound is validated too, because the runner refuses by default and a push it cannot
  parse is a dispatch silently lost — and because nothing the contract does not declare
  may reach a machine that executes the payload as its user.

  Beyond the schema it applies the three cross-field rules JSON Schema cannot state, all
  three of which keep something off a machine that would execute it:

  - the `kind` is one loopctl actually sends (`RunnerDispatch.dispatchable_kinds/0`). Triage
    is declared and not dispatchable; see the moduledoc.
  - a `story` rides only an `implement` dispatch, and its `id` is the dispatch's own
    `story_id`. A dispatch naming one story and carrying another's text is the confusion
    worth refusing rather than resolving.
  - the story is within `RunnerStory.max_bytes/0` under `ByteRule`. Refused, never truncated:
    the caller escalates the story instead (`Loopctl.Delivery.StoryPayload`).
  """
  @spec cast_dispatch(term()) :: {:ok, map()} | {:error, term()}
  def cast_dispatch(payload) do
    with {:ok, cast} <- cast(payload, RunnerDispatch.schema()) do
      dispatch = known_fields(cast, RunnerDispatch.schema())

      case dispatch_shape_errors(dispatch) do
        [] -> {:ok, dispatch}
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  defp dispatch_shape_errors(dispatch) do
    kind_errors(dispatch) ++ story_errors(dispatch) ++ triage_errors(dispatch)
  end

  defp kind_errors(%{kind: kind}) do
    if kind in RunnerDispatch.dispatchable_kinds(),
      do: [],
      else: [
        "kind #{kind} is declared but not dispatchable: loopctl sends only " <>
          Enum.join(RunnerDispatch.dispatchable_kinds(), ", ")
      ]
  end

  defp kind_errors(_dispatch), do: []

  defp story_errors(%{story: story, kind: kind, story_id: story_id}) do
    cond do
      kind != "implement" ->
        ["story is only allowed when kind is implement"]

      Map.get(story, :id) != story_id ->
        ["story.id must be the dispatch's story_id"]

      ByteRule.bytes(story) > RunnerStory.max_bytes() ->
        ["story exceeds #{RunnerStory.max_bytes()} bytes under the byte rule"]

      true ->
        []
    end
  end

  defp story_errors(_dispatch), do: []

  # The mirror of `story_errors/1`, and the pairing is the point: a `story` rides only an
  # implement dispatch and a `triage` rides only a triage one, so the object carrying the
  # reporter's words can never reach an implementing session (design §10). Stated as two
  # independent rules rather than one either/or, so a dispatch carrying BOTH is refused
  # twice rather than passing whichever test it happened to satisfy.
  defp triage_errors(%{triage: triage, kind: kind, story_id: story_id}) do
    cond do
      kind != "triage" ->
        ["triage is only allowed when kind is triage"]

      Map.get(triage, :record_id) == story_id ->
        # Not a type error — a value one, and it means a caller built the payload from the
        # wrong id. The record and the stub story are different rows with different
        # lifetimes, and a dispatch that conflates them would have triage read its own story.
        ["triage.record_id must be the intake record, not the dispatch's story_id"]

      ByteRule.bytes(triage) > RunnerTriage.max_bytes() ->
        ["triage exceeds #{RunnerTriage.max_bytes()} bytes under the byte rule"]

      true ->
        []
    end
  end

  # A `triage` KIND carrying no `triage` object. The head above only matches when the key is
  # present, so without this a dispatch with a template for the wrong job and no input passes
  # every shape rule — which is precisely what the moduledoc claims this payload prevents.
  # `kind_errors/1` masks it today because triage is not dispatchable; it stops masking it the
  # moment the interlock moves, so the clause lands now rather than as part of that change.
  #
  # The mirror gap for `story` on an `implement` dispatch is pre-existing and is NOT fixed
  # here: closing it would refuse every dispatch built before 1.5.0 carried a story, and it is
  # a different change with a different blast radius. Named so the asymmetry is deliberate
  # rather than an oversight.
  defp triage_errors(%{kind: "triage"} = dispatch) when not is_map_key(dispatch, :triage),
    do: ["a triage dispatch must carry the triage object"]

  defp triage_errors(_dispatch), do: []

  @doc """
  Validates a triage verdict (since 1.7.0). Returns the declared fields only, with atom
  keys, or `{:error, {:invalid, messages}}`.

  The schema cannot state the one rule that matters, so this does: a `story` outcome MUST
  carry a draft story and every other outcome must not. A verdict saying `story` and
  carrying none has moved the work rather than done it — a human re-reads the report and
  writes the story by hand, which is the step triage exists to remove — and a draft story on
  a `reject` is a payload whose two halves disagree about what was decided.

  It is the same shape rule `cast_dispatch/1` applies to `story` and `triage`, and it is
  stated the same way: as two independent conditions, so a verdict that breaks both is
  refused for both.

  **What this does NOT do is make the verdict trustworthy.** It bounds a session-authored
  object composed by a session that had just read attacker-controllable text. Passing this
  cast means the shape is right and the strings are within their caps; it says nothing about
  whether the content was steered. Callers record it, never execute it, and fence its
  strings wherever they reach another prompt.
  """
  @spec cast_triage_verdict(term()) :: {:ok, map()} | {:error, term()}
  def cast_triage_verdict(payload) do
    # `values_ok/1` FIRST, as every other inbound cast does. This was the one runner-to-
    # control cast that skipped it, and it is the worst one to skip: the verdict is the most
    # free-form object a runner sends — a draft title, a description, acceptance criteria,
    # evidence, a contradiction's prose — and those fields become a story row. A NUL byte is
    # trivially reachable from the reporter text the authoring session had just read, which
    # is the exact threat model this object is documented against; Postgres refuses one in
    # `text` and in any jsonb string, so it would pass the cast and raise at the write, on
    # every resend.
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerTriageVerdict.schema()) do
      verdict = known_fields(cast, RunnerTriageVerdict.schema())

      case verdict_shape_errors(verdict) do
        [] -> {:ok, verdict}
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  @doc """
  Casts a `triage_verdict` MESSAGE — the envelope plus exactly one of its two payloads.

  The exactly-one rule is checked HERE and not left to the schema, for the same reason the
  dispatch's `story`/`triage` rule is: JSON Schema can express it only with a keyword
  (`oneOf`, or `dependentRequired`) that a vendoring runner's validator may not implement,
  and a rule the other side cannot check is a rule that is enforced by a 4xx nobody
  predicted. Both present, or neither, is `{:invalid, ["exactly_one_of_verdict_or_incomplete"]}`.

  A `detail` string is admitted beside either, and ignored beside a verdict rather than
  refused: it is operator-facing prose, and refusing a message over a field that changes no
  decision would cost a run its whole output.
  """
  @spec cast_triage_verdict_message(term()) :: {:ok, map()} | {:error, term()}
  def cast_triage_verdict_message(payload) do
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerTriageVerdictMessage.schema()) do
      message = known_fields(cast, RunnerTriageVerdictMessage.schema())

      case message_shape_errors(message) do
        [] -> cast_message_verdict(message)
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  defp message_shape_errors(message) do
    verdict? = not is_nil(Map.get(message, :verdict))
    incomplete? = not is_nil(Map.get(message, :incomplete))

    exactly_one =
      if verdict? == incomplete?,
        do: ["exactly_one_of_verdict_or_incomplete"],
        else: []

    exactly_one ++ lens_verdict_errors(Map.get(message, :lens_verdicts), verdict?)
  end

  # The three rules JSON Schema cannot state for `lens_verdicts` (1.15.0): they belong to a
  # verdict and to nothing else, each lens speaks once, and all three together fit the cap.
  # The count is settled here, not by `minItems`, which the export does not publish: naming
  # each of the three lenses exactly once is the same rule as "exactly three, all different".
  defp lens_verdict_errors(nil, _verdict?), do: []
  defp lens_verdict_errors(_lens_verdicts, false), do: ["lens_verdicts_only_beside_a_verdict"]

  defp lens_verdict_errors(lens_verdicts, true) do
    lenses = Enum.map(lens_verdicts, &Map.get(&1, :lens))

    distinct =
      if Enum.sort(lenses) == Enum.sort(RunnerLensVerdict.lenses()),
        do: [],
        else: ["lens_verdicts_must_name_each_lens_once"]

    size =
      if ByteRule.bytes(lens_verdicts) > RunnerLensVerdict.max_bytes(),
        do: ["lens_verdicts exceed #{RunnerLensVerdict.max_bytes()} bytes under the byte rule"],
        else: []

    distinct ++ size
  end

  # The nested verdict goes through `cast_triage_verdict/1` ITSELF rather than being trusted
  # because the envelope cast already walked it. One cast, one set of shape rules: the
  # conditional `story` rule and the object cap live there, and a second reading of the same
  # object is how the two drift into disagreeing about what a valid verdict is.
  defp cast_message_verdict(%{verdict: verdict} = message) when not is_nil(verdict) do
    case cast_triage_verdict(verdict) do
      {:ok, cast} -> {:ok, %{message | verdict: cast}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cast_message_verdict(message), do: {:ok, message}

  # ONE FUNCTION PER RULE, and they are independent `++` terms so a verdict breaking several
  # is refused for each rather than for whichever was checked first. Split out when credo
  # called the combined version too complex, which it was: four unrelated conditions sharing
  # one body read as a checklist rather than as four things the contract says.
  defp verdict_shape_errors(verdict) do
    story_pairing(verdict) ++
      duplicate_pairing(verdict) ++
      escalation_content(verdict) ++
      verdict_size(verdict)
  end

  # A `story` outcome carrying no draft has moved the work rather than done it; a draft on
  # any other outcome is a payload whose halves disagree about what was decided.
  defp story_pairing(%{outcome: "story"} = verdict) do
    if is_nil(Map.get(verdict, :story)),
      do: ["a story outcome must carry the draft story"],
      else: []
  end

  defp story_pairing(verdict) do
    if is_nil(Map.get(verdict, :story)),
      do: [],
      else: ["story is only allowed when outcome is story"]
  end

  # Drafting new work and naming the story this duplicates are different decisions. A
  # consumer reading `outcome` creates a row, one reading `duplicate_of` makes a link, and
  # nothing records which was meant.
  defp duplicate_pairing(%{outcome: "story"} = verdict) do
    if is_nil(Map.get(verdict, :duplicate_of)),
      do: [],
      else: ["a story outcome must not also name duplicate_of"]
  end

  defp duplicate_pairing(_verdict), do: []

  # An escalation with nothing attached reaches a human who starts the same reading from the
  # beginning — the thing `missing_information` exists to prevent. Either field satisfies it:
  # one says why, the other says what is needed.
  # AT LEAST ONE ENTRY THAT IS NOT A CODE. The guard below exists so an escalation reaches a
  # human with something to read; publishing the gating vocabulary made a bare
  # `["workflow_change_not_defect_fix"]` satisfy it, which is a classification and not words.
  # With `@max_reasons` at 5 and three codes defined, a verdict emitting every code still has
  # room for the sentence, so this costs a conforming runner nothing.
  defp prose_entry?(reason) when is_binary(reason),
    do: reason not in GateA.gating_reason_codes()

  defp prose_entry?(_reason), do: false

  defp escalation_content(%{outcome: "escalate"} = verdict) do
    reasons = Map.get(verdict, :escalation_reasons, [])
    missing = Map.get(verdict, :missing_information, [])

    cond do
      reasons == [] and missing == [] ->
        ["an escalate outcome must carry escalation_reasons or missing_information"]

      missing == [] and not Enum.any?(reasons, &prose_entry?/1) ->
        [
          "an escalate outcome must carry words a person can act on: every " <>
            "escalation_reasons entry is a gating code, and a code is a classification " <>
            "rather than a reason. Add a sentence, or missing_information"
        ]

      true ->
        []
    end
  end

  defp escalation_content(_verdict), do: []

  defp verdict_size(verdict) do
    if ByteRule.bytes(verdict) > RunnerTriageVerdict.max_bytes(),
      do: ["verdict exceeds #{RunnerTriageVerdict.max_bytes()} bytes under the byte rule"],
      else: []
  end

  @doc """
  Validates a `dispatch_reply` payload. Returns the declared fields only, with atom keys, or
  `{:error, {:invalid, messages}}` — including for the cross-field rules JSON Schema cannot
  state: `reason` iff refused, `detail` only on a refusal and required with `other`.
  """
  @spec cast_dispatch_reply(term()) :: {:ok, map()} | {:error, term()}
  def cast_dispatch_reply(payload) do
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerDispatchReply.schema()) do
      reply = known_fields(cast, RunnerDispatchReply.schema())

      case reply_shape_errors(reply) do
        [] -> {:ok, reply}
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  defp reply_shape_errors(%{decision: "accepted"} = reply) do
    for key <- [:reason, :detail],
        Map.has_key?(reply, key),
        do: "#{key} is only allowed when decision is refused"
  end

  defp reply_shape_errors(%{decision: "refused", reason: "other"} = reply) do
    if Map.has_key?(reply, :detail), do: [], else: ["detail is required when reason is other"]
  end

  defp reply_shape_errors(%{decision: "refused", reason: _}), do: []
  defp reply_shape_errors(%{decision: "refused"}), do: ["reason is required when refused"]

  @doc """
  Validates a `trace` batch. Returns the declared fields only, with atom keys, or
  `{:error, reason}` where reason is `{:batch_too_large, max_events, max_bytes}`,
  `{:event_data_too_large, seq, max_data_bytes, max_event_bytes}` or `{:invalid, messages}`.

  In order: every value is storable (no NUL, no number wider than the byte rule's scalar);
  the event count; the schema; then each event's own limits, which win over the batch
  budget; then the batch budget. A one-event batch over the budget is refused as
  `event_data_too_large` for that event, because splitting it cannot help. Sizes are taken
  under `ByteRule` on the payload AS SENT, undeclared keys included, since those were in
  the frame.
  """
  @spec cast_trace_batch(term()) :: {:ok, map()} | {:error, term()}
  def cast_trace_batch(payload) do
    with :ok <- values_ok(payload),
         :ok <- event_count_ok(payload),
         {:ok, cast} <- cast(payload, RunnerTraceBatch.schema()),
         batch = known_fields(cast, RunnerTraceBatch.schema()),
         :ok <- events_ok(batch, Map.fetch!(payload, "events")),
         :ok <- batch_bytes_ok(batch, payload) do
      {:ok, batch}
    end
  end

  @doc """
  The size of `term` under the published byte rule (`x-connection.limits.json_byte_rule`):
  an upper bound on the compact JSON any conforming encoder writes for it.
  """
  @spec json_bytes_upper_bound(term()) :: non_neg_integer()
  def json_bytes_upper_bound(term), do: ByteRule.bytes(term)

  defp event_count_ok(%{"events" => events}) when is_list(events) do
    if length(events) > RunnerTraceBatch.max_events(),
      do: {:error, batch_too_large()},
      else: :ok
  end

  defp event_count_ok(_payload), do: :ok

  defp batch_too_large,
    do: {:batch_too_large, RunnerTraceBatch.max_events(), RunnerTraceBatch.max_bytes()}

  defp event_too_large(seq),
    do:
      {:event_data_too_large, seq, RunnerTraceEvent.max_data_bytes(),
       RunnerTraceEvent.max_bytes()}

  # `raw_events` are the events as sent, in the order the cast kept them.
  defp events_ok(%{run_id: run_id, events: events}, raw_events) do
    events
    |> Enum.zip(raw_events)
    |> Enum.reduce_while(:ok, fn {event, raw}, :ok ->
      cond do
        event.run_id != run_id ->
          {:halt, {:error, {:invalid, ["event #{event.seq}: run_id differs from the batch"]}}}

        event.seq > @max_seq ->
          {:halt, {:error, {:invalid, ["event seq #{event.seq} exceeds #{@max_seq}"]}}}

        ByteRule.bytes(Map.get(event, :data, %{})) > RunnerTraceEvent.max_data_bytes() ->
          {:halt, {:error, event_too_large(event.seq)}}

        ByteRule.bytes(raw) > RunnerTraceEvent.max_bytes() ->
          {:halt, {:error, event_too_large(event.seq)}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp batch_bytes_ok(%{events: events}, payload) do
    cond do
      ByteRule.bytes(payload) <= RunnerTraceBatch.max_bytes() -> :ok
      match?([_], events) -> {:error, event_too_large(hd(events).seq)}
      true -> {:error, batch_too_large()}
    end
  end

  @doc """
  Validates a `stage` payload (since 1.4.0). Returns the declared fields only, with the
  stage and edge as ATOMS — `%{dispatch_id:, claim_epoch:, from:, to:, edge:, reason:,
  effects:}` — or `{:error, {:invalid, messages}}`.

  `edge` defaults to `:forward`. Beyond the schema it checks the two cross-field rules JSON
  Schema cannot state:

  - the TRIPLE is a transition a runner may report
    (`Loopctl.Delivery.StageMachine.runner_reportable?/3`). Three independent enums admit
    combinations the machine has no edge for, and refusing them here means a nonsense
    transition never opens a database transaction.
  - a reason is present where the machine requires one (entering `escalated`, and
    `merge_refused`). `Loopctl.Delivery.Stages` refuses it too — this is the copy that
    answers the runner before the write, not the enforcement.

  The stage and edge atoms come from a COMPILE-TIME map of the machine's own atoms, so no
  wire value ever creates one — and, unlike the `String.to_existing_atom/1` this used to
  call, the conversion does not depend on `Loopctl.Delivery.StageMachine` already having been
  loaded. See the comment above `@wire_atoms`.
  """
  @spec cast_stage(term()) :: {:ok, map()} | {:error, term()}
  def cast_stage(payload) do
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerStageReport.schema()) do
      stage =
        cast
        |> known_fields(RunnerStageReport.schema())
        |> Map.put_new(:edge, "forward")
        |> then(
          &%{&1 | from: stage_atom(&1.from), to: stage_atom(&1.to), edge: stage_atom(&1.edge)}
        )

      case stage_shape_errors(stage) do
        [] -> {:ok, stage}
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  # Wire string -> the machine's own atom, resolved through a COMPILE-TIME map and never
  # through `String.to_existing_atom/1`.
  #
  # That function raised here, and the bug is worth naming because it looks impossible: the
  # atoms plainly exist, they are written as literals in `Loopctl.Delivery.StageMachine`. But
  # an atom in a module's constant pool comes into being when that MODULE IS LOADED, and
  # Elixir loads lazily. This module's enums are compiled down to STRINGS
  # (`Atom.to_string/1` at compile time), so nothing in `cast_stage/1`'s path forces
  # `StageMachine` to load before the conversion — the first call in a fresh VM raised
  # `ArgumentError: not an already existing atom` and took the runner's channel down with it.
  # It passed for a while only because some earlier test happened to load the module first,
  # which is a test-ordering accident and not a property of the code.
  #
  # The map's VALUES are atom literals in THIS module's constant pool, so they exist the
  # moment this code runs. `Map.get/2` rather than `fetch!/2`: an unmapped string yields nil,
  # `runner_reportable?/3` refuses the triple, and the caller gets `invalid_payload` instead
  # of a raise. The OpenApiSpex enum has already rejected anything unmapped, but "another
  # validator already checked it" is exactly the reasoning that produced the raise above.
  @wire_atoms Map.new(
                StageMachine.stages() ++ StageMachine.runner_edges(),
                &{Atom.to_string(&1), &1}
              )

  defp stage_atom(name), do: Map.get(@wire_atoms, name)

  defp stage_shape_errors(%{from: from, to: to, edge: edge} = stage) do
    transition_errors(from, to, edge) ++
      reason_errors(to, edge, stage) ++
      reason_length_errors(stage)
  end

  # The `maxLength` on the schema counts GRAPHEMES; Postgres counts CODEPOINTS. Left to the
  # schema alone the wire bound was LOOSER than the `story_stages_text_bounds` CHECK, so a
  # reason of 4000 graphemes and more codepoints was accepted here, refused by
  # `Loopctl.Delivery.Stages` deeper in, and on the HTTP path reached the database and died
  # as a 23514 the caller could do nothing with. Counted here, the wire and the context agree
  # on one number, and it is the number a CALLER can measure: the codepoints of the text it is
  # about to send.
  #
  # The column's own CHECK is deliberately WIDER since #804, and that is not a third
  # disagreement. `escalation_reason` is escaped for invisible characters before storage, which
  # EXPANDS it, so the stored string is longer than the one bounded here. The caller cannot
  # predict that length without implementing loopctl's escape table — which is exactly why the
  # published bound stays on the raw text and the column is given room instead. Bounding the
  # escaped form here would publish a number no client could honour.
  defp reason_length_errors(%{reason: reason}) when is_binary(reason) do
    if RunnerStage.codepoints(reason) > RunnerStage.max_reason_length(),
      do: ["reason may be at most #{RunnerStage.max_reason_length()} codepoints"],
      else: []
  end

  defp reason_length_errors(_stage), do: []

  defp transition_errors(from, to, edge) do
    if StageMachine.runner_reportable?(from, to, edge),
      do: [],
      else: ["#{from} -> #{to} over #{edge} is not a transition a runner may report"]
  end

  defp reason_errors(to, edge, stage) do
    if StageMachine.reason_required?(to, edge) and not Map.has_key?(stage, :reason),
      do: ["reason is required entering #{to} over #{edge}"],
      else: []
  end

  @doc """
  Validates a `session_ended` payload (1.16.0). Returns the declared fields only, with atom
  keys and `reason` left a string — every reason is one of `RunnerSessionEnded.reasons/0`,
  and the schema's enum refuses anything else as `invalid_payload`.
  """
  @spec cast_session_ended(term()) :: {:ok, map()} | {:error, term()}
  def cast_session_ended(payload) do
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerSessionEnded.schema()) do
      {:ok, known_fields(cast, RunnerSessionEnded.schema())}
    end
  end

  @doc """
  Validates a `checkpoint` payload (1.20.0). Returns the declared fields only, with atom keys,
  or `{:error, {:invalid, messages}}` — including for a message over
  `RunnerCheckpoint.max_bytes/0` under the byte rule, measured on the payload as sent.

  The object format rule (both shas 40 or both 64) and the note's UTF-8 byte cap are
  `Loopctl.Threads`' own and are enforced there, where the HTTP surface meets them too.
  """
  @spec cast_checkpoint(term()) :: {:ok, map()} | {:error, term()}
  def cast_checkpoint(payload) do
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerCheckpoint.schema()),
         :ok <- message_bytes_ok(payload, RunnerCheckpoint.max_bytes()) do
      {:ok, known_fields(cast, RunnerCheckpoint.schema())}
    end
  end

  @doc """
  Validates a `thread_entry` payload (1.20.0). Returns the declared fields only, with atom
  keys, or `{:error, {:invalid, messages}}` — including for a message over
  `RunnerThreadEntry.max_bytes/0` under the byte rule, measured on the payload as sent.
  """
  @spec cast_thread_entry(term()) :: {:ok, map()} | {:error, term()}
  def cast_thread_entry(payload) do
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerThreadEntry.schema()),
         :ok <- message_bytes_ok(payload, RunnerThreadEntry.max_bytes()) do
      {:ok, known_fields(cast, RunnerThreadEntry.schema())}
    end
  end

  # Measured on the payload AS SENT, undeclared keys included, as a trace batch is: those were
  # in the frame.
  defp message_bytes_ok(payload, max_bytes) do
    if ByteRule.bytes(payload) <= max_bytes,
      do: :ok,
      else: {:error, {:invalid, ["the message exceeds #{max_bytes} bytes under the byte rule"]}}
  end

  @doc "Validates a `trace_cursor` payload. Returns `{:ok, %{run_id: run_id}}`."
  @spec cast_trace_cursor(term()) :: {:ok, map()} | {:error, term()}
  def cast_trace_cursor(payload) do
    with {:ok, cast} <- cast(payload, RunnerTraceCursor.schema()) do
      {:ok, known_fields(cast, RunnerTraceCursor.schema())}
    end
  end

  # Every value a runner sends must be storable and sizable, checked on the payload as sent:
  #
  # - no NUL in any string, key or value, at any depth. Postgres refuses one in `text` and in
  #   any jsonb string, and the error would escape the channel's handle_in on every resend.
  # - no integer wider than the byte rule's fixed scalar width, which is what lets a runner
  #   count every number at one published size.
  defp values_ok(value) do
    cond do
      contains_nul?(value) ->
        {:error, {:invalid, ["strings may not contain a NUL character"]}}

      too_wide_number?(value) ->
        {:error, {:invalid, ["numbers may have at most #{ByteRule.max_number_digits()} digits"]}}

      true ->
        :ok
    end
  end

  defp contains_nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  defp contains_nul?(value) when is_list(value), do: Enum.any?(value, &contains_nul?/1)

  defp contains_nul?(value) when is_map(value),
    do: Enum.any?(value, fn {k, v} -> contains_nul?(k) or contains_nul?(v) end)

  defp contains_nul?(_value), do: false

  defp too_wide_number?(value) when is_integer(value),
    do: abs(value) >= Integer.pow(10, ByteRule.max_number_digits())

  defp too_wide_number?(value) when is_list(value), do: Enum.any?(value, &too_wide_number?/1)

  defp too_wide_number?(value) when is_map(value),
    do: Enum.any?(value, fn {_k, v} -> too_wide_number?(v) end)

  defp too_wide_number?(_value), do: false

  # OpenApiSpex keeps undeclared keys on an object, at every depth. Drop them at every
  # depth too, so nothing the contract does not declare reaches Presence.
  # An object that declares no properties (`RunnerTraceEvent.data`) is free-form by design.
  defp known_fields(map, %Schema{type: :object, properties: props})
       when is_map(map) and is_map(props) do
    for {key, sub} <- props, Map.has_key?(map, key), into: %{} do
      {key, known_fields(Map.fetch!(map, key), sub)}
    end
  end

  defp known_fields(list, %Schema{type: :array, items: %Schema{} = items}) when is_list(list),
    do: Enum.map(list, &known_fields(&1, items))

  # A UUID is compared and stored in ONE form. OpenApiSpex accepts either case, but Postgres
  # reads a uuid back lowercase, so an uppercase id would never equal its own stored value.
  defp known_fields(value, %Schema{type: :string, format: :uuid}) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp known_fields(value, _schema), do: value

  defp cast(payload, schema) when is_map(payload) do
    case OpenApiSpex.Cast.cast(schema, payload) do
      {:ok, cast} -> {:ok, cast}
      {:error, errors} -> {:error, {:invalid, Enum.map(errors, &to_string/1)}}
    end
  end

  defp cast(_payload, _schema), do: {:error, {:invalid, ["payload must be an object"]}}

  defp supported_version(sent) do
    case String.split(sent, ".") do
      [major | _] when major == unquote(Integer.to_string(@major)) -> :ok
      _ -> {:error, {:unsupported_contract_version, sent, @version}}
    end
  end

  @doc """
  The contract as a JSON Schema document (2020-12), the shape written to
  `priv/runner_contract/v<major>.json`.
  """
  @spec json_schema() :: map()
  def json_schema do
    defs = Map.new(@schemas, fn mod -> {mod.schema().title, schema_to_map(mod.schema())} end)

    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://loopctl.com/runner_contract/v#{@major}.json",
      "title" => "loopctl runner contract",
      "x-contract-version" => @version,
      "x-connection" => %{
        # Beside `errors`, not inside `limits`: it is a property OF the refusal codes, and a
        # runner reads it in the same breath as the code it just got.
        "permanent_errors" => @permanent_errors,
        "permanent_error_conditions" => @permanent_error_conditions,
        # WHAT EACH REFUSAL CARRIES BESIDE `reason`, per event, complete (1.11.0). Beside
        # `errors` for the same reason `permanent_errors` is: a runner reads it in the same
        # breath as the code it just got.
        "error_fields" => @error_fields,
        "triage_gating_reasons" => GateA.gating_reason_codes(),
        "socket_path" => "/runner/socket/websocket",
        "credential_header" => "x-loopctl-runner-token",
        "topic" => "runner:{runner_id}",
        "events" => %{
          "join" => "RunnerJoin",
          "status" => "RunnerStatus",
          "dispatch" => "RunnerDispatch",
          "dispatch_reply" => "RunnerDispatchReply",
          "trace" => "RunnerTraceBatch",
          "trace_cursor" => "RunnerTraceCursor",
          "trace_event" => "RunnerTraceEvent",
          "disconnecting" => "RunnerDisconnecting",
          "stage" => "RunnerStageReport",
          "triage_verdict" => "RunnerTriageVerdictMessage",
          "session_ended" => "RunnerSessionEnded",
          "checkpoint" => "RunnerCheckpoint",
          "thread_entry" => "RunnerThreadEntry",
          "story" => "RunnerStory"
        },
        # The kinds loopctl will actually send. `RunnerDispatch.kind`'s enum is the
        # VOCABULARY, which is wider: `triage` is declared and refused by `cast_dispatch/1`
        # until it has its own payload. Published so a runner knows which it must handle.
        "dispatchable_kinds" => RunnerDispatch.dispatchable_kinds(),
        # What loopctl reads a runner that sends no `RunnerJoin.kinds` as having declared
        # (since 1.6.0). Published rather than left in prose because it is the one value a
        # runner author has to know to tell "I said nothing" from "I said implement" — they
        # are the same thing today, and a runner that wants any other set must send the field.
        "implied_kinds" => Kinds.implied_by_silence(),
        "replies" => %{
          "trace" => "RunnerTraceAck",
          "trace_cursor" => "RunnerTraceAck",
          "triage_verdict" => "RunnerTriageVerdictAck",
          "session_ended" => "RunnerSessionEndedAck",
          "checkpoint" => "RunnerCheckpointAck",
          "thread_entry" => "RunnerThreadEntryAck"
        },
        "errors" => @error_reasons,
        "limits" => %{
          "trace_max_events" => RunnerTraceBatch.max_events(),
          "trace_max_event_data_bytes" => RunnerTraceEvent.max_data_bytes(),
          "trace_max_event_bytes" => RunnerTraceEvent.max_bytes(),
          "trace_max_batch_bytes" => RunnerTraceBatch.max_bytes(),
          "frame_envelope_bytes" => @frame_envelope_bytes,
          "json_byte_rule" => Map.put(ByteRule.constants(), "text", ByteRule.text()),
          "refusal_max_detail_length" => RunnerDispatchReply.max_detail_length(),
          "trace_max_seq" => @max_seq,
          "min_interval_ms" => @min_interval_ms,
          "dispatch_reply_burst" => @dispatch_reply_burst,
          "triage_verdict_burst" => @triage_verdict_burst,
          "session_ended_burst" => @session_ended_burst,
          "checkpoint_burst" => @checkpoint_burst,
          "thread_entry_burst" => @thread_entry_burst,
          "stage_burst" => @stage_burst,
          "stage_max_reason_length" => RunnerStage.max_reason_length(),
          # The clamp control applies to `RunnerUsage.resets_at` (since 1.17.0), in seconds from
          # control's own clock. Not a JSON Schema keyword, so a runner cannot read it anywhere
          # else.
          "usage_hold_seconds" => %{
            "min" => Usage.min_hold_seconds(),
            "max" => Usage.max_hold_seconds()
          },
          "story" => RunnerStory.limits(),
          "triage" => RunnerTriage.limits(),
          "triage_verdict" => RunnerTriageVerdict.limits(),
          # The change thread (1.20.0): each message's byte budget and field bounds, and the
          # UTF-8 cap on a `note` or `body`, which no JSON Schema keyword can state.
          "checkpoint" => RunnerCheckpoint.limits(),
          "thread_entry" => RunnerThreadEntry.limits(),
          "thread_body_max_utf8_bytes" => ThreadEntry.max_body_bytes()
        },
        # The transition table a `stage` message is checked against, published so a runner
        # can refuse an impossible transition locally instead of learning it from a refusal.
        # Derived from `Loopctl.Delivery.StageMachine`, which is what the server enforces.
        "stage_transitions" =>
          Enum.map(StageMachine.runner_transitions(), fn {from, to, edge} ->
            %{"from" => to_string(from), "to" => to_string(to), "edge" => to_string(edge)}
          end)
      },
      "$defs" => defs
    }
  end

  @doc "The export path for the current major version, relative to the app root."
  @spec export_path() :: String.t()
  def export_path, do: "priv/runner_contract/v#{@major}.json"

  @doc "The export encoded as it is checked in: pretty JSON with sorted keys and a newline."
  @spec encoded_json_schema() :: String.t()
  def encoded_json_schema do
    json_schema()
    |> sort_keys()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other

  # OpenApiSpex nullable -> JSON Schema 2020-12 type union. Nested schemas are inlined
  # (`RunnerSample` inside `RunnerJoin`), because `OpenApiSpex.Cast` cannot resolve a
  # module reference without a full spec, and validation must use these exact structs.
  # THE EXPORTED KEYWORD SET IS A CEILING ON WHAT MAY BE ENFORCED, not a formatting detail.
  # `mkreyman/loopctl-runner`'s vendored validator FAILS a definition carrying a keyword it
  # does not implement, so this list cannot grow without upgrading every runner first — and a
  # keyword set on a `Schema` but missing here is enforced by `OpenApiSpex.Cast` while being
  # absent from the published contract. That combination refuses a join for a reason the
  # runner author cannot read anywhere: their own pre-flight check against
  # `priv/runner_contract/v<major>.json` passes and loopctl still says no.
  #
  # So a constraint this cannot carry is not expressed as a schema keyword at all. Either
  # publish it the way `x-connection.limits` and `ByteRule` publish the constraints JSON
  # Schema cannot hold, or accept the value and settle it in code — which is what
  # `RunnerJoin.kinds` does with an empty array and with duplicates. `exported_keywords/0`
  # names the set for the test that binds it in both directions.
  @exported_keywords ~w(type required properties minimum maximum minLength maxLength pattern
                        enum items maxItems minProperties description format
                        additionalProperties)

  @doc """
  The JSON Schema keywords `json_schema/0` publishes — the ceiling on what any schema here
  may enforce. See the note above `schema_to_map/1`: the runner's vendored validator refuses
  an unknown keyword, and a keyword enforced but unpublished refuses a join for a reason the
  published contract does not state.
  """
  @spec exported_keywords() :: [String.t()]
  def exported_keywords, do: @exported_keywords

  defp schema_to_map(%Schema{} = schema) do
    base =
      [
        description: schema.description,
        pattern: schema.pattern,
        format: schema.format && to_string(schema.format),
        minimum: schema.minimum,
        maximum: schema.maximum,
        minLength: schema.minLength,
        maxLength: schema.maxLength,
        maxItems: schema.maxItems,
        minProperties: schema.minProperties,
        enum: exported_enum(schema),
        required: schema.required && Enum.map(schema.required, &to_string/1),
        additionalProperties: schema.additionalProperties,
        items: schema.items && schema_to_map(schema.items),
        properties:
          schema.properties &&
            Map.new(schema.properties, fn {k, v} -> {to_string(k), schema_to_map(v)} end)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    type = to_string(schema.type)
    Map.put(base, "type", if(schema.nullable, do: [type, "null"], else: type))
  end

  # A NULLABLE ENUM MUST PUBLISH `null` AS A MEMBER, and this is the whole fix of 1.9.2.
  #
  # `nullable` widens the exported `type` to `[t, "null"]` — and under JSON Schema 2020-12
  # `enum` constrains EVERY instance, `null` included, so the two keywords contradict each
  # other: the type says null is allowed and the enum says the only allowed values are the
  # five listed strings. A validator that implements enum as written — the runner's does —
  # refuses `"incomplete": null`, while `"verdict": null` beside a real `incomplete` is
  # accepted, because that side is nullable with no enum. loopctl's own cast accepts both —
  # `OpenApiSpex.Cast` short-circuits on `nullable` before it reads the enum — so what was
  # broken is the PUBLISHED schema, and the runner that obeys it cannot send a shape loopctl
  # would have taken.
  #
  # That asymmetry is the SAME defect 1.9.1 fixed on the other field, arriving from the other
  # direction, and it has the same cost: the emitter it bites is the ordinary one — a struct
  # serialised whole, sending every declared key — and the refusal is `invalid_payload`,
  # which `permanent_errors` makes permanent, so the run's only output is lost and nothing
  # resends. Found by the `loopctl-runner` session validating a real message against the
  # vendored file, not by this repo's suite.
  #
  # Fixed HERE rather than on the one field, because the defect is a property of the
  # translation and not of that schema: every nullable enum this contract ever declares would
  # publish the same contradiction. `nullable_enums_publish_null` in the export test walks
  # every published schema and binds it.
  defp exported_enum(%Schema{enum: nil}), do: nil
  defp exported_enum(%Schema{enum: enum, nullable: true}), do: enum ++ [nil]
  defp exported_enum(%Schema{enum: enum}), do: enum
end
