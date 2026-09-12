defmodule Loopctl.DeliveryGates.GateA.Result do
  @moduledoc """
  One Gate A evaluation.

  - `decision` — `:proceed` or `:escalate`
  - `verdict` — the trio's unanimous verdict (`:story` or `:reject`) when `decision` is
    `:proceed`, otherwise `nil`
  - `reasons` — why it escalated; every reason is a tuple whose FIRST element names its kind,
    which is what `Loopctl.DeliveryGates.GateA.rate/1` counts by
  - `confidences` — each agent's self-reported confidence in output order, `nil` for an
    output too malformed to read one from. Recorded for ranking; it never gates
  - `soft_signals` — `{output_index, code}` for every escalation reason code that does NOT
    gate. Logged so a soft trigger's rate can be measured before anyone lets it gate
  """

  @enforce_keys [:decision, :verdict, :reasons, :confidences, :soft_signals]
  defstruct [:decision, :verdict, :reasons, :confidences, :soft_signals]

  @type t :: %__MODULE__{
          decision: :proceed | :escalate,
          verdict: :story | :reject | nil,
          reasons: [tuple()],
          confidences: [number() | nil],
          soft_signals: [{non_neg_integer(), String.t()}]
        }
end
