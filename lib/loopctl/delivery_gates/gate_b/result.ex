defmodule Loopctl.DeliveryGates.GateB.Result do
  @moduledoc """
  One Gate B evaluation.

  - `phase` — `:triage` (over the story's predicted touches) or `:merge` (over the real diff)
  - `outcome` — `:human`, `:prove_effect` or `:clear`, in that precedence
  - `merge_precondition?` — `true` only for the `:merge` run. The `:triage` result decides
    whether to dispatch at all and is NEVER a merge precondition: it certifies a
    prediction, and nothing binds the implementing session to that prediction
  - `reasons` — every reason the outcome is `:human`; empty otherwise
  - `effect_matches` — `{file, pattern}` for every effect path touched, recorded whatever the
    outcome, so a `:human` result still says what the proof would have had to cover
  """

  @enforce_keys [:phase, :outcome, :merge_precondition?, :reasons, :effect_matches]
  defstruct [:phase, :outcome, :merge_precondition?, :reasons, :effect_matches]

  @type t :: %__MODULE__{
          phase: term(),
          outcome: :clear | :prove_effect | :human,
          merge_precondition?: boolean(),
          reasons: [tuple() | atom()],
          effect_matches: [{String.t(), String.t()}]
        }
end
