defmodule Loopctl.Delivery.MergePrecondition.Verdict do
  @moduledoc """
  One merge-precondition evaluation (issue #803, design §5 "Both gates run twice" and §9).

  - `decision` — one of:
    - `:allow` — and only from `enforce/3`, which records the allow against the head it
      judged. Nothing else licenses a merge
    - `:refuse` — a gate verdict. The story is escalated
    - `:already_merged` — the forge had already merged THIS head, and a recorded allow says
      the gate authorised it. Adopt `merge_sha`
    - `:head_moved` — the pull request's head is not the one CI ran on and the story was
      verified at, so the change goes back to `implementing`. New commits are ordinary; this
      is not an escalation
    - `:unevaluated` — nothing was decided yet, and nothing transitions; the caller retries.
      Either a TRANSIENT fault (the forge, or database contention), which one network blip
      must not turn into a parked story, or — THREAD mode (US-45.6) — required CI checks
      still running or not yet reported on the checkpoint's commit. Only the first counts
      toward the consecutive-unevaluated bound; a CI wait is bounded in time instead
  - `reasons` — every reason the decision is what it is, all of them rather than the first,
    so one escalation names the whole list. Empty on `:allow` and on an authorised
    `:already_merged`
  - `gate_a_inputs` — what Gate A was judged on, resolved server-side by
    `Loopctl.Delivery.GateAInput`: `:persisted_triage` (the lens verdicts recorded with the
    story's most recent triage), `:human_resolution` (a human re-queued it from a Gate A
    escalation), or `:missing` (neither, so Gate A refused). Never anything a caller sent
  - `trio_outputs_ignored` — true when the caller still sent `trio_outputs`. Recorded so a
    caller relying on the old contract can see that nothing it sent was read
  - `recorded_head_sha` — the head the STAGE ROW carries: what CI ran on and the story was
    verified at. Known even when the forge cannot be reached, which is why the
    consecutive-unevaluated count is kept per THIS head rather than the forge's
  - `retry_after` — on `:unevaluated`, the seconds the forge asked a caller to wait, when it
    said so at all, or loopctl's own 60 for a CI wait. The endpoint sends it as `Retry-After`; the dominant cause of an
    unevaluated verdict is a rate limit, so an unbounded retry would amplify the very
    condition it is waiting out
  - `repo`, `pr_number`, `head_sha`, `merge_base_sha` — what was judged, server-resolved.
    A verdict is only ever about the diff at THIS head. In THREAD mode `merge_base_sha` is
    what a thread-mode allow records as `base_sha`, and the merge executor (US-45.5) merges
    only while the base head still equals it, taking the base-update path otherwise
  - `mode` — `:pr` or `:thread`: the mode BOUND on the claim's implement dispatch at
    placement (US-45.4), not the intake source's current mode. nil when the route could not
    be read (the verdict is then `:unevaluated`)
  - `checkpoint_id`, `checkpoint_sha` — THREAD mode: the recorded checkpoint judged. An allow
    in thread mode is recorded naming both
  - `ci_evidence` — THREAD mode (US-45.6): what CI said about the checkpoint's exact commit,
    as `Loopctl.Delivery.CiEvidence.to_record/5` shapes it, and what `enforce/3` copies onto
    the checkpoint's `gate_evidence`. nil when it was not read
  - `merge_sha` — set only on `:already_merged`: the sha the forge reports for a pull
    request that was merged before this evaluation ran
  - `diffstat` — `%{files: n, changed_lines: n}`. In pr mode the forge's own totals, never
    `length(files)`. In THREAD mode GitHub's comparison carries no totals, so both are derived
    from the files it lists — and a list that reaches `@compare_file_cap` in
    `Loopctl.Delivery.GitHubPullRequestSource` is refused as truncated rather than counted
  - `gate_a`, `gate_b`, `proof` — the underlying gate results, recorded whatever the
    decision, so a refusal can be read without re-running anything. `nil` for a gate that
    was never reached
  - `custody` — `:ok` or the custody refusal code from `Loopctl.Progress`

  ## It is a value, never an authority

  Nothing stores a verdict as the fact that a merge is permitted. It is recomputed from the
  forge and the database on every ask, so a second ask after a new commit judges the NEW
  diff and a second ask about an unchanged pull request gives the same answer. What IS
  persisted is the consequence: a refusal's escalation, written through the stage machine.
  """

  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.DeliveryGates.GateB

  @enforce_keys [:decision, :reasons]
  defstruct [
    :decision,
    :reasons,
    :repo,
    :pr_number,
    :head_sha,
    :merge_base_sha,
    :merge_sha,
    :diffstat,
    :gate_a,
    :gate_b,
    :proof,
    :retry_after,
    :recorded_head_sha,
    :checkpoint_id,
    :checkpoint_sha,
    :ci_evidence,
    mode: :pr,
    custody: nil,
    gate_a_inputs: :missing,
    trio_outputs_ignored: false
  ]

  @type decision :: :allow | :refuse | :already_merged | :head_moved | :unevaluated

  @type t :: %__MODULE__{
          decision: decision(),
          reasons: [term()],
          repo: String.t() | nil,
          pr_number: pos_integer() | nil,
          head_sha: String.t() | nil,
          merge_base_sha: String.t() | nil,
          merge_sha: String.t() | nil,
          diffstat: %{files: non_neg_integer(), changed_lines: non_neg_integer()} | nil,
          gate_a: GateA.Result.t() | nil,
          gate_b: GateB.Result.t() | nil,
          proof: GateB.ProofResult.t() | nil,
          custody: :ok | atom() | nil,
          gate_a_inputs: :persisted_triage | :human_resolution | :missing,
          trio_outputs_ignored: boolean(),
          retry_after: pos_integer() | nil,
          recorded_head_sha: String.t() | nil,
          mode: :pr | :thread | nil,
          checkpoint_id: Ecto.UUID.t() | nil,
          checkpoint_sha: String.t() | nil,
          ci_evidence: map() | nil
        }
end
