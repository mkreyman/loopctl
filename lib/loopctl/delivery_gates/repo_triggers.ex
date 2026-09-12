defmodule Loopctl.DeliveryGates.RepoTriggers do
  @moduledoc """
  One target repository's Gate B triggers, as produced by `Loopctl.DeliveryGates.Triggers.parse/2`.

  - `effect_paths` — changes that can cause an irreversible external effect. Touching one
    makes the change PROVE its effect before it merges.
  - `human_paths` — changes with no output signature to prove (access-control pipelines,
    auth plugs, data migrations). Touching one means a human confirms.
  - `max_files` / `max_changed_lines` — the size bound, applied only at the merge run,
    because only a real diff has a size.
  """

  alias Loopctl.DeliveryGates.Glob

  @enforce_keys [:effect_paths, :human_paths, :max_files, :max_changed_lines]
  defstruct [:effect_paths, :human_paths, :max_files, :max_changed_lines]

  @type t :: %__MODULE__{
          effect_paths: [Glob.t()],
          human_paths: [Glob.t()],
          max_files: pos_integer(),
          max_changed_lines: pos_integer()
        }
end
