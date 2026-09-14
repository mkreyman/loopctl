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
  A `Loopctl.DeliveryGates.Triggers.parse/2` error reduced to what is safe to PRINT.

  The reason carries the offending glob verbatim — `{:invalid_pattern, ["repos", "<owner/repo>",
  "effect_paths"], pattern}` is a live guard pattern and the target repository's name — and the
  places that report a parse failure are a terminal and a runner log, which are as public as a
  committed artifact. Only the KIND and the key path's DEPTH survive. Same reduction PR #830
  applies in `Report.trigger_status/1`, for the same reason.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(reason) do
    "#{error_kind(reason)} (key path depth #{key_path_depth(reason)})"
  end

  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp error_kind(_reason), do: :unknown

  defp key_path_depth(reason) when is_tuple(reason) and tuple_size(reason) > 1 do
    case elem(reason, 1) do
      path when is_list(path) -> length(path)
      _other -> 0
    end
  end

  defp key_path_depth(_reason), do: 0

  @doc """
  Asserts that `unmatched/2` and `coverage/2` answer the same question about the same input.

  They are two loops — `unmatched/2` short-circuits per pattern because it runs on Gate B's
  per-evaluation path, `coverage/2` counts because the artifact wants the number — and they
  share only `Glob.match?/2` and the fail-closed guard. Nothing else makes them agree, and a
  disagreement is the failure this module's first paragraph calls worse than no checker: the
  artifact attests every guard alive while the gate escalates on a stale trigger, or the
  reverse. Callers do not need this; it exists so a test can bind them.
  """
  @spec agree?(RepoTriggers.t(), term()) :: boolean()
  def agree?(%RepoTriggers{} = triggers, repo_files) do
    agreed?(unmatched(triggers, repo_files), coverage(triggers, repo_files))
  end

  @doc """
  Whether an `unmatched/2` result and a `coverage/2` result say the same thing.

  Split out from `agree?/2` so a test can hand it a DISAGREEMENT. Nothing else can: the two
  matchers agree on every real input, so a weakening of this comparison is invisible to any test
  that only ever feeds it consistent pairs — which is the shape of unfalsifiable assertion this
  whole change is about.
  """
  @spec agreed?(term(), term()) :: boolean()
  def agreed?({:ok, drifted}, {:ok, coverage}) when is_list(drifted) and is_list(coverage) do
    Enum.sort(drifted) ==
      coverage |> Enum.filter(&(&1.matches == 0)) |> Enum.map(& &1.pattern) |> Enum.sort()
  end

  def agreed?({:error, one}, {:error, other}), do: one == other
  def agreed?(_unmatched, _coverage), do: false

  @doc """
  The sources of every configured pattern that matches none of `repo_files`, in configuration
  order (`effect_paths` then `human_paths`).

  `{:ok, []}` is the clean answer. `{:ok, [_ | _]}` names the drifted patterns.

  A separate loop from `coverage/2`, not a projection of it — see `agree?/2`, which is what
  binds them.
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

  The count is what the UNREDACTED artifact carries: it says a pattern is alive and how broadly
  it reaches. `unmatched/2` is NOT defined over this — it short-circuits per pattern because it
  runs on Gate B's per-evaluation path, while this counts every file. They share `Glob.match?/2`
  and the fail-closed guard and nothing else, so `agree?/2` exists to assert they answer the
  same question, and a test calls it. Two matchers that quietly disagree would let the artifact
  attest every guard alive while the gate escalates on a stale trigger.
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
