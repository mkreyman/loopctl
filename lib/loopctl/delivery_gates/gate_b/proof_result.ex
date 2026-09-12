defmodule Loopctl.DeliveryGates.GateB.ProofResult do
  @moduledoc """
  The judgement of a change's effect proof (`Loopctl.DeliveryGates.GateB.judge_proof/3`).

  - `verdict` — `:pass` or `:fail`
  - `failures` — every reason it failed, all of them rather than the first
  - `route` — `:gate_a` on a failure, `nil` on a pass. A failed proof is never retried into a
    pass by the loop; it goes to the human decision
  """

  @enforce_keys [:verdict, :failures, :route]
  defstruct [:verdict, :failures, :route]

  @type t :: %__MODULE__{
          verdict: :pass | :fail,
          failures: [tuple()],
          route: :gate_a | nil
        }
end
