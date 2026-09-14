defmodule Loopctl.DeliveryGates.Measurement.Change do
  @moduledoc """
  One merged change, as `Loopctl.DeliveryGates.Measurement.RepoHistory` reads it out of a git
  checkout: everything the merge precondition would have been handed for that change, and
  nothing derived from it.

  `diff` is the raw bytes of `git diff --name-status -M -z <parent> <sha>` — the one input
  `Loopctl.DeliveryGates.DiffNames.parse/1` accepts, kept unparsed so the replay parses it the
  way production does rather than handing the gate a list built some other way.

  `content` is the ADDED and REMOVED lines of the same diff and nothing else (no context, no
  hunk headers, no `+++`/`---` file headers). It exists for `EffectOracle`, which must judge
  the change without reading a path, and it is not part of any gate input.
  """

  @enforce_keys [:sha, :parent_sha, :subject, :committed_at, :diff, :diffstat]
  defstruct [
    :sha,
    :parent_sha,
    :pr_number,
    :subject,
    :committed_at,
    :diff,
    :diffstat,
    :content,
    head_files: [],
    base_files: []
  ]

  @type diffstat :: %{files: non_neg_integer(), changed_lines: non_neg_integer()}

  @type t :: %__MODULE__{
          sha: String.t(),
          parent_sha: String.t(),
          pr_number: pos_integer() | nil,
          subject: String.t(),
          committed_at: DateTime.t(),
          diff: binary(),
          diffstat: diffstat(),
          content: String.t() | nil,
          head_files: [String.t()],
          base_files: [String.t()]
        }
end
