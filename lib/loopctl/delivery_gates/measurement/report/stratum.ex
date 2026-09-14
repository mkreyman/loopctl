defmodule Loopctl.DeliveryGates.Measurement.Report.Stratum do
  @moduledoc """
  The counts for one stratum of a Gate B replay corpus, and the rates derived from them.

  Every rate is `nil` when its denominator is zero. That is `Loopctl.DeliveryGates.GateA.rate/1`'s
  convention and it is kept here for the same reason: no measurement is not a zero rate, and a
  report that printed `0.0` for an empty stratum would be read as "the gate never cleared
  anything" rather than "nothing was measured".

  `first`/`last` are the stratum's OWN date range, which is not the run's window. The
  `configuration_applied` stratum in particular is the subset where every configured pattern
  matched at both refs, and that subset can be a few weeks of a nine-month history — a rate read
  against the run's window instead of the stratum's would be attributed to the wrong period.
  """

  @derive Jason.Encoder
  @enforce_keys [:changes]
  defstruct changes: 0,
            cleared: 0,
            scored_clears: 0,
            unscored_clears: 0,
            false_negatives: 0,
            clear_rate: nil,
            false_negative_rate: nil,
            first: nil,
            last: nil

  @type t :: %__MODULE__{
          changes: non_neg_integer(),
          cleared: non_neg_integer(),
          scored_clears: non_neg_integer(),
          unscored_clears: non_neg_integer(),
          false_negatives: non_neg_integer(),
          clear_rate: float() | nil,
          false_negative_rate: float() | nil,
          first: String.t() | nil,
          last: String.t() | nil
        }
end
