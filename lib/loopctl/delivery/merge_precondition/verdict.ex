defmodule Loopctl.Delivery.MergePrecondition.Verdict do
  @moduledoc """
  One merge-precondition evaluation (issue #803, design §5 "Both gates run twice" and §9).

  - `decision` — one of five:
    - `:allow` — and only from `enforce/3`, which records the allow against the head it
      judged. Nothing else licenses a merge
    - `:refuse` — a gate verdict. The story is escalated
    - `:already_merged` — the forge had already merged THIS head, and a recorded allow says
      the gate authorised it. Adopt `merge_sha`
    - `:head_moved` — the pull request's head is not the one CI ran on and the story was
      verified at, so the change goes back to `implementing`. New commits are ordinary; this
      is not an escalation
    - `:unevaluated` — a TRANSIENT forge fault. Nothing was decided and nothing transitions;
      the caller retries. Never an escalation, because one network blip must not park a
      story until a human acts
  - `reasons` — every reason the decision is what it is, all of them rather than the first,
    so one escalation names the whole list. Empty on `:allow` and on an authorised
    `:already_merged`
  - `gate_a_inputs` — `:caller_asserted` while the triage trio's outputs arrive in the
    request. Recorded on every verdict and named in the escalation reason, because Gate A's
    verdict is only as trustworthy as inputs the same principal supplied
  - `repo`, `pr_number`, `head_sha`, `merge_base_sha` — what was judged, server-resolved.
    A verdict is only ever about the diff at THIS head
  - `merge_sha` — set only on `:already_merged`: the sha the forge reports for a pull
    request that was merged before this evaluation ran
  - `diffstat` — the forge's own `%{files: n, changed_lines: n}`, never `length(files)`
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
    custody: nil,
    gate_a_inputs: :caller_asserted
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
          gate_a_inputs: :caller_asserted
        }
end
