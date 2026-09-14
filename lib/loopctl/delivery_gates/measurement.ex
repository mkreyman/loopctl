defmodule Loopctl.DeliveryGates.Measurement do
  @moduledoc """
  Offline replay harnesses for the two delivery gates (issue #828, design §12 build order
  steps 2 and 3).

  Neither gate has ever been measured, and design §12 makes step 7 — auto-merge — conditional
  on both having a track record. Nothing here changes a gate, gates anything, or writes to the
  database. It replays the SHIPPED gate code over history and counts.

  ## What each harness answers

  - `GateBReplay` — Gate B over a target repository's real merged history. The number that
    matters is the FALSE NEGATIVE rate: changes Gate B would have cleared for auto-merge that
    a human would not have. "Would not have" is decided by `EffectOracle`, an independent,
    path-blind judgement built from the diff's own text, so it cannot agree with the gate by
    construction.
  - `GateAReplay` — Gate A over a corpus of past tickets, log-only. The number that matters is
    the ESCALATION RATE, against the design's statement that a rate resembling the collapsed
    predicate's 54% is a design failure rather than a tuning question.

  ## One judge, not two

  Both harnesses call the SHIPPED gate functions — `Loopctl.DeliveryGates.GateA.evaluate/1`,
  `Loopctl.DeliveryGates.GateA.rate/1`, and `Loopctl.Delivery.MergePrecondition`'s own
  `gate_b_verdict/2` and `hard_bound_reasons/1`, over inputs built with
  `Loopctl.DeliveryGates.DiffNames` exactly as the merge precondition builds them. A harness
  that re-implemented the judgement would measure the re-implementation.

  ## What a replay cannot see, stated once

  Every bias below is repeated on the artifact each run writes, because a rate read without
  it is worse than no rate:

  - Gate B's `:triage` run judges the trio's PREDICTED touches. A replay has no prediction, so
    the real merged file list stands in for it. That biases the triage-phase number OPTIMISTIC:
    a real prediction is wrong in ways the merged list is not. Only the `:merge` phase number
    is a measurement of the run that actually gates.
  - Gate B's proof step — deploy to staging, regenerate 837P output from the fixed fixture set —
    cannot be replayed over history at all. So `:prove_effect` is counted as its own outcome and
    never scored as a pass or a fail.
  - Gate A's strongest signal is the trio DISAGREEING, and a replay has no trio. Every
    reconstructed ticket presents three identical outputs, so the measured Gate A rate is a
    strict LOWER BOUND, and so is the `contradicts` axis, which is not observable either.

  ## Refuse rather than guess

  Every module here fails on a missing input instead of defaulting it: a diff that does not
  parse, a change with no files, a ticket with no title, an empty corpus. A measurement that
  quietly substituted a default for an input it could not read would report a rate about a
  corpus that does not exist.
  """
end
