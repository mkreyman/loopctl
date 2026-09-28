defmodule Loopctl.Delivery.CiDefinition do
  @moduledoc """
  Whether a change touches the definitions its own CI runs (US-45.6, lifted for US-26.4.6).
  Pure.

  GitHub Actions runs the workflow files of the commit under test, so a change that edits
  `.github/workflows/` — or a composite action they call — can make its own required checks
  report green: the implementer attesting its own work through a job it wrote. Two callers
  refuse such a change rather than judge it on that CI, and both call `reasons/1` so they
  cannot disagree about what counts:

  - the thread merge gate (`Loopctl.Delivery.MergePrecondition`), before it merges a checkpoint
  - story verification (`Loopctl.Verification.GitHubActions`), before it records a CI verdict

  Matched on every name the diff carries, renames' old and new names included, so moving a
  workflow file is caught too, and on any composite action's `action.yml`, wherever it sits.
  """

  @ci_definition_prefixes [".github/workflows/", ".github/actions/"]

  @doc """
  The refusal a diff earns, as a list so a caller can append it to others:

  - `[]` — nothing listed touches a CI definition
  - `[{:ci_definition_changed, names}]` — the sorted names that do
  - `[{:ci_definition_unknown, reason}]` — the diff could not be listed (truncated at the
    compare cap, unreadable), so it may touch one for all anyone can tell

  Anything that is not a listed diff or a listing error is `[]`: the caller had no diff to
  judge (a merged pull request), which is not this function's refusal to make.
  """
  @spec reasons(term()) ::
          [{:ci_definition_changed, [String.t()]} | {:ci_definition_unknown, term()}]
  def reasons({:ok, %{files: files} = diff}) do
    renamed = for {from, to} <- Map.get(diff, :renames, []), name <- [from, to], do: name

    case Enum.filter(Enum.uniq(files ++ renamed), &ci_definition?/1) do
      [] -> []
      touched -> [{:ci_definition_changed, Enum.sort(touched)}]
    end
  end

  def reasons({:error, reason}), do: [{:ci_definition_unknown, reason}]
  def reasons(_no_diff), do: []

  @doc """
  Whether one path is a CI definition. A composite action can live anywhere a workflow's
  `uses: ./path` points, so its definition file is matched by NAME wherever it sits (#910
  round 2, finding 5); reusable workflows can only live under `.github/workflows/`, which the
  prefix covers.
  """
  @spec ci_definition?(term()) :: boolean()
  def ci_definition?(name) when is_binary(name) do
    Enum.any?(@ci_definition_prefixes, &String.starts_with?(name, &1)) or
      Path.basename(name) in ["action.yml", "action.yaml"]
  end

  def ci_definition?(_name), do: false
end
