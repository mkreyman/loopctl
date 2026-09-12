defmodule Loopctl.DeliveryGates.GateB do
  @moduledoc """
  Gate B — "a human confirms". Effect-shaped and mechanical.

  It asks one question of a change: can it cause an irreversible external effect? A revert
  does not un-submit a claim file, so reversibility of the EFFECT, not of the diff, is what
  licenses a change to merge without a human.

  ## Outcomes, in precedence order

  - `:human` — a human path was touched, the size bound was exceeded, or the gate could not
    evaluate at all: no or bad configuration, an unknown repository, a stale trigger, missing
    or malformed input. Also any escalation an agent signalled
  - `:prove_effect` — an effect path was touched. The change must prove its effect with
    `judge_proof/4` before it merges
  - `:clear` — none of the above

  ## Run twice

  `evaluate(:triage, ...)` runs over the story's PREDICTED touches and decides only whether
  to dispatch. `evaluate(:merge, ...)` runs over the real diff — every added, modified and
  DELETED path (a deletion under a guarded path is a change to it), plus both names of every
  rename — and the real diffstat, applies the size bound, and is the one that gates. Only the `:merge` result
  carries `merge_precondition?: true`.

  ## Input

      %{repo: "owner/repo",
        files: [String.t()],               # predicted touches at :triage; at :merge every
                                           # added, modified, deleted and renamed-to path
        renames: [{old, new}],             # required at :merge (may be []), optional at :triage
        repo_files: [String.t()],          # the target repo's `git ls-files`
        diffstat: %{files: n, changed_lines: n},   # required at :merge, ignored at :triage
        agent_escalations: [term()]}       # optional

  Derive `files` and `renames` together from `git diff --name-status -M -z base...head`
  (or the REST `files[].previous_filename`), NOT from `gh pr diff --name-only`: that prints
  only the new name of a rename, and its parser misreads a path containing " b/". Pass
  unquoted paths (`-z` or `-c core.quotePath=false`); a quoted one escalates.

  ## Agents may only ADD an escalation

  That is a property of this function's wiring, not a rule agents follow. The triggers are
  computed here from the paths and the configuration, and `agent_escalations` is OR-ed onto
  them: every element is an escalation, whatever it says, and an empty or absent list adds
  nothing. There is no input that removes a computed trigger, and nothing reads an agent's
  negative.

  ## Stale triggers

  loopctl holds no checkout of the target repository, so the repository's file list is an
  input. Every configured pattern must match at least one of `repo_files`. A pattern that
  matches nothing means the configuration has drifted from the repository — a rename
  silently unguarded a trigger — and that escalates, naming the pattern.
  """

  alias Loopctl.DeliveryGates.GateB.ProofResult
  alias Loopctl.DeliveryGates.GateB.Result
  alias Loopctl.DeliveryGates.Glob
  alias Loopctl.DeliveryGates.RepoTriggers
  alias Loopctl.DeliveryGates.Triggers

  @phases [:triage, :merge]

  @type phase :: :triage | :merge

  @doc """
  Evaluates a change. `triggers` is the RETURN VALUE of
  `Loopctl.DeliveryGates.Triggers.parse/2`, passed through untouched: `{:ok, triggers}`
  evaluates, and `{:error, reason}`, `nil` or anything else is a `:human` result naming the
  configuration failure.
  """
  @spec evaluate(term(), term(), term()) :: Result.t()
  def evaluate(phase, input, triggers) do
    {computed, effect_matches} = computed_triggers(phase, input, triggers)
    reasons = computed ++ agent_escalations(input)

    outcome =
      cond do
        reasons != [] -> :human
        effect_matches != [] -> :prove_effect
        true -> :clear
      end

    %Result{
      phase: phase,
      outcome: outcome,
      merge_precondition?: phase == :merge,
      reasons: reasons,
      effect_matches: effect_matches
    }
  end

  @doc """
  Judges an effect proof: the fixture set regenerated against the change, compared with the
  baseline.

  - `intent` — `{:changes, [fixture_id, ...]}` (non-empty) or `:no_output_change`
  - `fixture_set` — the ids of the FIXED fixture set, non-empty: every fixture the baseline
    holds. Without it "empty everywhere else" could only be checked over the fixtures that
    happened to report, and a fixture that silently did not run would hide its own change.
  - `fixture_results` — `%{fixture_id => :changed | :unchanged}`, one entry per fixture in
    the set and none outside it
  - `coverage` — `%{required: [code, ...], covered: [code, ...]}`: the service codes,
    modifiers and programs present in the repository, and those the fixtures exercise

  It passes only when the set of changed fixtures EQUALS the intended set — both halves. An
  intended fixture that did not change fails, because "nothing changed" is not a pass for a
  change meant to alter output; an unintended fixture that changed fails. A fixture in the
  set with no result, a result for a fixture outside the set, and an intended fixture that is
  not in the set all fail.
  Every required code must be covered, because a golden-file oracle only sees changes to
  what the fixtures exercise and a path no fixture reaches regresses silently.

  A failure routes to Gate A.
  """
  @spec judge_proof(term(), term(), term(), term()) :: ProofResult.t()
  def judge_proof(intent, fixture_set, fixture_results, coverage) do
    case intent_failures(intent, fixture_set, fixture_results) ++ coverage_failures(coverage) do
      [] -> %ProofResult{verdict: :pass, failures: [], route: nil}
      failures -> %ProofResult{verdict: :fail, failures: failures, route: :gate_a}
    end
  end

  # -- evaluate ---------------------------------------------------------------------------

  defp computed_triggers(phase, input, triggers) do
    with :ok <- phase(phase),
         :ok <- input_map(input),
         {:ok, repo_triggers} <- repo_triggers(triggers, Map.get(input, :repo)) do
      files = Map.get(input, :files)
      {rename_reasons, renamed_from} = renames(phase, input)
      touched = touched(files, renamed_from)

      reasons =
        stale_trigger_reasons(repo_triggers, Map.get(input, :repo_files)) ++
          file_reasons(files) ++
          rename_reasons ++
          human_path_reasons(repo_triggers, touched) ++
          limit_reasons(phase, repo_triggers, files, Map.get(input, :diffstat))

      {reasons, matches(repo_triggers.effect_paths, touched)}
    else
      {:escalate, reason} -> {[reason], []}
    end
  end

  # The paths a trigger is matched against: `files` (added, modified, deleted and renamed-to
  # paths) plus the OLD name of every rename. `gh pr diff --name-only` prints only the new name, so a file
  # moved OUT of a guarded path would otherwise read as touching nothing guarded.
  defp touched(files, renamed_from) when is_list(files), do: Enum.uniq(files ++ renamed_from)
  defp touched(_files, renamed_from), do: renamed_from

  # At :merge the caller must state the renames, even as `[]`: an absent list is
  # indistinguishable from a caller that never asked git for them. At :triage a prediction
  # has no renames to state, so absence adds nothing there.
  defp renames(phase, input) do
    case {phase, Map.fetch(input, :renames)} do
      {:merge, :error} -> {[:missing_renames], []}
      {:triage, :error} -> {[], []}
      {_phase, {:ok, renames}} -> rename_pairs(renames, Map.get(input, :files))
    end
  end

  # A rename's NEW name must also be in `files`. The two lists have to come from one diff of
  # one range; a caller that built them from different commands or refs would otherwise pass
  # renames computed against the wrong range, and miss the real old name of a moved file.
  defp rename_pairs(renames, files) when is_list(renames) do
    if Enum.all?(renames, &rename_pair?/1) do
      listed = if is_list(files), do: files, else: []
      olds = Enum.map(renames, &elem(&1, 0))

      reasons =
        for({old, _new} <- renames, not valid_path?(old), do: {:invalid_path, old}) ++
          for {_old, new} <- renames, new not in listed, do: {:rename_not_in_files, new}

      {reasons, olds}
    else
      {[{:invalid_renames, renames}], []}
    end
  end

  defp rename_pairs(renames, _files), do: {[{:invalid_renames, renames}], []}

  defp rename_pair?({old, new}) when is_binary(old) and is_binary(new), do: true
  defp rename_pair?(_pair), do: false

  defp phase(phase) when phase in @phases, do: :ok
  defp phase(phase), do: {:escalate, {:invalid_phase, phase}}

  defp input_map(input) when is_map(input), do: :ok
  defp input_map(_input), do: {:escalate, :invalid_input}

  defp repo_triggers({:ok, %Triggers{} = triggers}, repo) do
    case Triggers.fetch_repo(triggers, repo) do
      {:ok, %RepoTriggers{} = repo_triggers} -> usable(repo_triggers)
      :error -> {:escalate, {:unknown_repo, repo}}
    end
  end

  defp repo_triggers({:error, reason}, _repo), do: {:escalate, {:config_error, reason}}
  defp repo_triggers(nil, _repo), do: {:escalate, {:config_error, :not_loaded}}
  defp repo_triggers(_other, _repo), do: {:escalate, {:config_error, :unrecognised}}

  # `parse/2` never builds an empty trigger set, but a struct can be built by hand. Checked
  # again here so that no path, however the value was made, turns into "no triggers".
  defp usable(%RepoTriggers{effect_paths: [_ | _], human_paths: [_ | _]} = repo_triggers)
       when is_integer(repo_triggers.max_files) and repo_triggers.max_files > 0 and
              is_integer(repo_triggers.max_changed_lines) and repo_triggers.max_changed_lines > 0,
       do: {:ok, repo_triggers}

  defp usable(_repo_triggers), do: {:escalate, {:config_error, :empty_trigger_set}}

  defp stale_trigger_reasons(repo_triggers, [_ | _] = repo_files) do
    if Enum.all?(repo_files, &is_binary/1) do
      for glob <- repo_triggers.effect_paths ++ repo_triggers.human_paths,
          not Enum.any?(repo_files, &Glob.match?(glob, &1)),
          do: {:stale_trigger, glob.source}
    else
      [:invalid_repo_files]
    end
  end

  defp stale_trigger_reasons(_repo_triggers, _repo_files), do: [:missing_repo_files]

  defp file_reasons([_ | _] = files) do
    for file <- files, not valid_path?(file), do: {:invalid_path, file}
  end

  defp file_reasons([]), do: [:no_files]
  defp file_reasons(_files), do: [:missing_files]

  defp human_path_reasons(repo_triggers, files) do
    for {file, pattern} <- matches(repo_triggers.human_paths, files),
        do: {:human_path, file, pattern}
  end

  defp limit_reasons(:merge, repo_triggers, files, %{files: file_count, changed_lines: lines})
       when is_integer(file_count) and file_count >= 0 and is_integer(lines) and lines >= 0 do
    listed = if is_list(files), do: files |> Enum.uniq() |> length(), else: 0
    count = max(file_count, listed)

    files_reason =
      if count > repo_triggers.max_files,
        do: [{:max_files_exceeded, count, repo_triggers.max_files}],
        else: []

    lines_reason =
      if lines > repo_triggers.max_changed_lines,
        do: [{:max_changed_lines_exceeded, lines, repo_triggers.max_changed_lines}],
        else: []

    files_reason ++ lines_reason
  end

  defp limit_reasons(:merge, _repo_triggers, _files, nil), do: [:missing_diffstat]

  defp limit_reasons(:merge, _repo_triggers, _files, diffstat),
    do: [{:invalid_diffstat, diffstat}]

  defp limit_reasons(:triage, _repo_triggers, _files, _diffstat), do: []

  defp matches(globs, files) when is_list(files) do
    for file <- files, glob <- globs, Glob.match?(glob, file), do: {file, glob.source}
  end

  # A path as git prints it UNQUOTED: relative, no empty, `.` or `..` segment. Anything else
  # cannot be trusted to match the way the configuration author read it. That includes git's
  # own quoted form: under the default `core.quotePath`, a name with non-ASCII or special
  # bytes comes back as `"priv/rates/tarifa_a\303\261o.csv"`, and the leading quote means no
  # anchored pattern ever matches it — a change to that file would read as touching nothing.
  # Callers should pass `-z` or `-c core.quotePath=false`; a quoted path escalates.
  defp valid_path?(path) when is_binary(path) and path != "" do
    String.valid?(path) and not String.contains?(path, [<<0>>, "\""]) and
      not String.contains?(path, "\\") and
      path |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp valid_path?(_path), do: false

  # The OR. Every element is an escalation; there is no element that removes one.
  defp agent_escalations(%{agent_escalations: escalations}) when is_list(escalations) do
    Enum.map(escalations, &{:agent_escalation, &1})
  end

  defp agent_escalations(%{agent_escalations: nil}), do: []

  defp agent_escalations(%{agent_escalations: escalations}),
    do: [{:invalid_agent_escalations, escalations}]

  defp agent_escalations(_input), do: []

  # -- judge_proof ------------------------------------------------------------------------

  defp intent_failures(intent, fixture_set, fixture_results) do
    with {:ok, intended} <- intended_fixtures(intent),
         {:ok, set} <- fixture_set(fixture_set),
         {:ok, results} <- fixture_results(fixture_results) do
      outside_set = Enum.reject(intended, &(&1 in set))
      not_run = Enum.reject(set, &Map.has_key?(results, &1))
      unexpected = results |> Map.keys() |> Enum.reject(&(&1 in set))
      unchanged = Enum.filter(intended, &(Map.get(results, &1) == :unchanged))

      unintended =
        for {id, :changed} <- results, id not in intended, do: id

      failure(:intended_fixture_not_in_set, outside_set) ++
        failure(:fixture_not_run, not_run) ++
        failure(:unexpected_fixture, unexpected) ++
        failure(:intended_fixture_unchanged, unchanged) ++
        failure(:unintended_fixture_changed, unintended)
    else
      {:error, failure} -> [failure]
    end
  end

  defp fixture_set([_ | _] = ids) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, {:invalid_fixture_set, ids}}
  end

  defp fixture_set(ids), do: {:error, {:invalid_fixture_set, ids}}

  defp intended_fixtures({:changes, [_ | _] = ids} = intent) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, {:invalid_intent, intent}}
  end

  defp intended_fixtures(:no_output_change), do: {:ok, []}
  defp intended_fixtures(intent), do: {:error, {:invalid_intent, intent}}

  defp fixture_results(results) when is_map(results) and map_size(results) > 0 do
    if Enum.all?(results, fn {id, state} -> is_binary(id) and state in [:changed, :unchanged] end),
       do: {:ok, results},
       else: {:error, {:invalid_fixture_results, results}}
  end

  defp fixture_results(results), do: {:error, {:invalid_fixture_results, results}}

  defp coverage_failures(%{required: [_ | _] = required, covered: covered})
       when is_list(covered) do
    failure(:uncovered_codes, Enum.uniq(required) -- covered)
  end

  defp coverage_failures(coverage), do: [{:invalid_coverage, coverage}]

  defp failure(_kind, []), do: []
  defp failure(kind, items), do: [{kind, Enum.sort(items)}]
end
