defmodule Loopctl.Delivery.MergePrecondition.Verdict do
  @moduledoc """
  One merge-precondition evaluation (issue #803, design §5 "Both gates run twice" and §9).

  - `decision` — `:allow`, `:refuse` or `:already_merged`
  - `reasons` — every reason a `:refuse` is a refusal, all of them rather than the first,
    so one escalation names the whole list. Empty on the other two decisions
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
    custody: nil
  ]

  @type decision :: :allow | :refuse | :already_merged

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
          custody: :ok | atom() | nil
        }
end
