defmodule Loopctl.Oban.FairShareCounterBehaviour do
  @moduledoc """
  DI seam for the count behind `Loopctl.Oban.FairShare`'s per-tenant fair-share gate (#558).

  It exists for ONE branch: the gate's fail-open handling of a count that EXITS rather than
  raises. `over_cap?/4` documents failing open on any count error and delivered it with a
  `rescue` alone, so a DBConnection checkout against a wedged, saturated or unstarted pool —
  which exits — escaped and killed the Oban job instead of admitting it. That is the fault
  most likely to trigger the gate, handled backwards.

  The branch is unreachable from a test otherwise: the sandboxed test pool answers, and an
  ownership failure raises rather than exits. An untested fail-open is indistinguishable from
  an absent one, which is how the original defect survived review.

  Injected the same way as `Loopctl.Embeddings.ReadPathBehaviour`: `config/test.exs` points
  `:fair_share_counter` at a Mox mock and `Loopctl.DataCase.stub_all_defaults/0` stubs it back
  to the real implementation, so every other test sees production behaviour.
  """

  @doc "Count this tenant's lower-ranked EXECUTING jobs on a queue."
  @callback lower_ranked_executing_count(
              tenant_id :: binary(),
              queue :: atom() | binary(),
              job_id :: integer() | nil
            ) :: non_neg_integer()
end
