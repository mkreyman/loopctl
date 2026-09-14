defmodule Loopctl.DeliveryGates.TriggerDrift do
  @moduledoc """
  Whether every configured Gate B pattern still matches something in the target repository.

  The design (§5) says the trigger path set is "read literally off the repo and asserted by a
  test that fails when one stops existing". This module is that assertion, and it is the SAME
  code `Loopctl.DeliveryGates.GateB` runs per evaluation — extracted from its private
  `stale_trigger_reasons/2` rather than reimplemented, because a drift checker that can
  disagree with the gate is worse than none: it would certify a configuration the gate then
  escalates on, or clear one the gate silently under-guards.

  ## Why drift matters more than it reads

  loopctl holds no checkout of the target repository, so the repository's file list is an
  input. A pattern that matches nothing means the configuration has drifted from the
  repository — most often a rename — and the path it named is no longer guarded by it. At
  runtime that escalates, naming the pattern, which is the fail-closed direction but announces
  itself as one more escalation among many. Checked ahead of time it is a configuration alarm,
  which is what it actually is.

  ## Fail closed

  An absent, empty or non-list file list is `{:error, :missing_repo_files}` and a list carrying
  a non-binary is `{:error, :invalid_repo_files}`. Neither is "no drift": a checker that cannot
  read the tree has proved nothing, and an empty tree would vacuously match no pattern while
  reporting every one of them as drifted. Both are refusals, and every caller — the gate, the
  Mix task and the test — treats a refusal as a failure.
  """

  alias Loopctl.DeliveryGates.Glob
  alias Loopctl.DeliveryGates.RepoTriggers

  @type kind :: :effect | :human

  @type pattern_coverage :: %{
          kind: kind(),
          index: non_neg_integer(),
          pattern: String.t(),
          matches: non_neg_integer()
        }

  @type error :: :missing_repo_files | :invalid_repo_files

  @doc """
  The sources of every configured pattern that matches none of `repo_files`, in configuration
  order (`effect_paths` then `human_paths`).

  `{:ok, []}` is the clean answer. `{:ok, [_ | _]}` names the drifted patterns.
  """
  @spec unmatched(RepoTriggers.t(), term()) :: {:ok, [String.t()]} | {:error, error()}
  def unmatched(%RepoTriggers{} = triggers, repo_files) do
    with :ok <- usable(repo_files) do
      # `Enum.any?` and not `coverage/2`'s count: this runs on Gate B's per-evaluation path, and
      # the question here is only "at least one", so it stops at the first match. `coverage/2`
      # counts because the artifact wants the number; the two would otherwise be one function
      # doing the expensive half of the work for the caller that does not need it.
      drifted =
        for glob <- triggers.effect_paths ++ triggers.human_paths,
            not Enum.any?(repo_files, &Glob.match?(glob, &1)),
            do: glob.source

      {:ok, drifted}
    end
  end

  @doc """
  Every configured pattern with the NUMBER of files it matches, in configuration order.

  The count is what an artifact can carry in a public repository: it says a pattern is alive
  and how broadly it reaches without naming the pattern or a single path. `unmatched/2` is
  defined over this, so the count a report publishes and the verdict the gate reaches come
  from one matcher.
  """
  @spec coverage(RepoTriggers.t(), term()) :: {:ok, [pattern_coverage()]} | {:error, error()}
  def coverage(%RepoTriggers{} = triggers, repo_files) do
    with :ok <- usable(repo_files) do
      {:ok,
       tagged(triggers.effect_paths, :effect, repo_files) ++
         tagged(triggers.human_paths, :human, repo_files)}
    end
  end

  # The one place the fail-closed rule is decided, so `unmatched/2` and `coverage/2` cannot
  # come to different conclusions about a file list neither of them can use.
  defp usable([_ | _] = repo_files) do
    if Enum.all?(repo_files, &is_binary/1), do: :ok, else: {:error, :invalid_repo_files}
  end

  defp usable(_repo_files), do: {:error, :missing_repo_files}

  defp tagged(globs, kind, repo_files) do
    globs
    |> Enum.with_index()
    |> Enum.map(fn {glob, index} ->
      %{
        kind: kind,
        index: index,
        pattern: glob.source,
        matches: Enum.count(repo_files, &Glob.match?(glob, &1))
      }
    end)
  end
end
