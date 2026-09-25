# Rewrite brief — the triage-verdict apply path (US-44.1 / US-44.2)

**Why a rewrite.** Four review cycles on `Loopctl.Delivery.TriageVerdict`'s apply path (branch
`feature/delivery-loop-800-44.2`, head `76f5d66f`) each found about ten defects, most introduced by
the previous round's fix. Round 3 of US-44.2 still found material defects, which the delivery loop
reads as evidence about the source. Rewrite the apply path against the invariants below; do not
patch it further.

## Invariants the reviews established (each has a test on the branch today)

1. **One deciding dispatch.** `detected -> triaged` carries `triage_dispatch_id` as a transition-only
   effect (`StageMachine`, `advance/4` `:effects`), so leaving `detected` and naming the decider is
   one transaction. It is a story-lifetime identity: no transition clears it.
2. **Only the decider moves the story further.** `Stages.advance/4` refuses `:triage_not_bound` for a
   transition out of `triaged` naming another session dispatch; the verdict path refuses a verdict
   for a story already past `triaged` that is not bound to it. Each layer has its own test.
3. **A loser never writes.** Its draft never lands on the story row; its resend is refused again
   (a binding refusal is its own code until the wire, where it is `stale_stage`).
4. **The bound dispatch finishes its route whatever the epoch.** The draft is authorised by the
   binding, not the epoch (a reclaim moves the epoch, not the decider); the reclaim repair
   completes every route out of `triaged` (queued, escalated, failed).
5. **The screen decides once.** Gate A over the lens verdicts plus `GateB.triage_screen/3` over the
   drafted touches; its decision is recorded as CODES (reason kind, trigger pattern — never the
   session's text or the touched file) on the `detected -> triaged` event and read back by any
   later attempt; nothing re-screens against facts that may have moved.
6. **Gate A never reads a caller.** `Loopctl.Delivery.GateAInput`: the bound dispatch's lens
   verdicts, or a human resolution of an escalation that was about Gate A (trio `escalate`, the
   screen's Gate A codes, control's oversize ticket, a merge-gate refusal naming Gate A) — never a
   flagged/undispatchable draft or an incomplete run. Contradiction `ref`/`why` and soft-signal prose
   are redacted where the Gate A result is built.

## Open findings the rewrite must close (US-44.2 round 3, against `76f5d66f`)

1. Rows triaged before the binding existed (and rows the dispatcher's too-large route leaves at
   `triaged`) have `triage_dispatch_id` NULL and can never finish. Backfill it in the migration for
   rows past `detected` with exactly one recorded verdict, and decide the dispatcher case explicitly.
2. The screen-code byte cap can drop every code, recording `gate_screen: []`, which reads back as
   "queue". A refusal must always record at least one code (e.g. a `screen_overflow` sentinel), and
   a cap must SKIP an oversized code rather than halt on it.
3. The cap counts raw bytes; `Stages` measures the JSON-encoded payload. Budget the encoded size, as
   `fit_signals` / `StoryPayload.violation_event_data` already do.
4. An incomplete triage has no path to a merge: re-queueing it implements work certain to be refused.
   Needs a re-triage route (`escalated -> detected` for a human, clearing the binding) — a design
   decision to make explicitly, or record why not.
5. The comment above `draft_if_still_ours` still describes a deleted epoch fence.
6. The one-decision-source rule, the byte cap and the soft-code pattern have no test that fails if
   reverted.
7. The apply path screens and re-reads the whole transition history on every verdict, twice on a
   resend; branch on the triage step's result instead, and refuse a non-bound dispatch before
   screening.
8. The moduledoc still points at the deleted `continue_after/7`.
9. The widened soft-code pattern passes session text such as `IGNORE-ALL.prior:rules` verbatim;
   narrow it back to the gating-code shape and redact the rest.
10. `:triage_not_bound` reaching `LoopctlWeb.RunnerChannel.Refusal` from any other caller answers
    `internal_error`; map it at the wire boundary (and keep `TriageVerdict` from double-mapping).
