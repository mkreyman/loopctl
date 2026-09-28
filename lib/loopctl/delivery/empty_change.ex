defmodule Loopctl.Delivery.EmptyChange do
  @moduledoc """
  Whether a change is EMPTY — nothing shows the work is in the commit (US-45.4, lifted for
  US-26.4.6). Pure.

  Two callers refuse an empty change rather than judge it, and both call `reasons/3` so they
  cannot disagree about what counts:

  - the thread merge gate (`Loopctl.Delivery.MergePrecondition`), before it merges a checkpoint
  - story verification (`Loopctl.Verification.GitHubActions`), before it records a CI verdict

  A change is empty two ways: the commit's tree IS the base's tree now (the work is already on
  the base, or was never made), or the three-dot comparison with the base lists no changed
  file (an old commit of the base, or an empty commit on top of one, whose merge base is its
  parent — only the diff tells).
  """

  @typedoc "The refusals `reasons/3` can answer."
  @type reason ::
          {:empty_change, String.t() | :no_changed_files} | {:base_tree_unreadable, term()}

  @doc """
  The refusal a change earns, as a list so a caller can append it to others, given the
  commit's tree, the base's tree now and the comparison's diffstat:

  - `[]` — the change is not empty
  - `[{:empty_change, tree}]` — the commit's tree is the base's
  - `[{:empty_change, :no_changed_files}]` — the comparison lists no file
  - `[{:base_tree_unreadable, shape}]` — the base's tree could not be read, so emptiness
    cannot be ruled out; never a pass
  """
  @spec reasons(term(), term(), term()) :: [reason()]
  def reasons(tree, tree, _diffstat) when is_binary(tree), do: [{:empty_change, tree}]
  def reasons(_tree, _base, %{files: 0}), do: [{:empty_change, :no_changed_files}]
  def reasons(_tree, base, _diffstat) when is_binary(base), do: []
  def reasons(_tree, base, _diffstat), do: [{:base_tree_unreadable, shape(base)}]

  # What an unreadable base tree WAS, never its content (the shape `MergePrecondition` logs).
  defp shape(%module{}), do: module
  defp shape(value) when is_map(value), do: {:map, value |> Map.keys() |> Enum.sort()}
  defp shape(value) when is_list(value), do: {:list, length(value)}
  defp shape(value) when is_atom(value), do: value
  defp shape(value) when is_integer(value), do: value
  defp shape(_value), do: :unreadable
end
