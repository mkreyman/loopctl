defmodule Loopctl.DeliveryGates.RepoTriggers do
  @moduledoc """
  One target repository's Gate B triggers, as produced by `Loopctl.DeliveryGates.Triggers.parse/2`.

  - `effect_paths` — changes that can cause an irreversible external effect. Touching one
    makes the change PROVE its effect before it merges.
  - `independent_paths` — changes with no output signature to prove (access-control
    pipelines, auth plugs, data migrations, the code that gates the loop itself). Touching one
    makes the merge wait for INDEPENDENT VERIFICATION: a verifier dispatch whose lineage is
    separate from the implementer's, on another attested machine, with every
    `independent_checks` job green at the head
    (`Loopctl.Delivery.MergePrecondition.independent_verification/3`, US-52.12).
  - `independent_checks` — the CI job names that verification requires at the head; the
    end-to-end suite's job for the repositories that run it.
  - `max_files` / `max_changed_lines` — the size bound, applied only at the merge run,
    because only a real diff has a size.
  """

  alias Loopctl.DeliveryGates.Glob

  @enforce_keys [
    :effect_paths,
    :independent_paths,
    :independent_checks,
    :max_files,
    :max_changed_lines
  ]
  defstruct [
    :effect_paths,
    :independent_paths,
    :independent_checks,
    :max_files,
    :max_changed_lines
  ]

  @type t :: %__MODULE__{
          effect_paths: [Glob.t()],
          independent_paths: [Glob.t()],
          independent_checks: [String.t()],
          max_files: pos_integer(),
          max_changed_lines: pos_integer()
        }
end
