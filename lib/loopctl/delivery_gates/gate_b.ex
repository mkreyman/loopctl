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
    `judge_proof/3` before it merges
  - `:clear` — none of the above

  ## Run twice

  `evaluate(:triage, ...)` runs over the story's PREDICTED touches and decides only whether
  to dispatch. `evaluate(:merge, ...)` runs over the real `gh pr diff --name-only` plus the
  real diffstat, applies the size bound, and is the one that gates. Only the `:merge` result
  carries `merge_precondition?: true`.

  ## Input

      %{repo: "owner/repo",
        files: [String.t()],               # predicted touches at :triage, real diff at :merge
        repo_files: [String.t()],          # the target repo's `git ls-files`
        diffstat: %{files: n, changed_lines: n},   # required at :merge, ignored at :triage
        agent_escalations: [term()]}       # optional

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
  - `fixture_results` — `%{fixture_id => :changed | :unchanged}`, non-empty
  - `coverage` — `%{required: [code, ...], covered: [code, ...]}`: the service codes,
    modifiers and programs present in the repository, and those the fixtures exercise

  It passes only when the set of changed fixtures EQUALS the intended set — both halves. An
  intended fixture that did not change (or did not run) fails, because "nothing changed" is
  not a pass for a change meant to alter output; an unintended fixture that changed fails.
  Every required code must be covered, because a golden-file oracle only sees changes to
  what the fixtures exercise and a path no fixture reaches regresses silently.

  A failure routes to Gate A.
  """
  @spec judge_proof(term(), term(), term()) :: ProofResult.t()
  def judge_proof(intent, fixture_results, coverage) do
    case intent_failures(intent, fixture_results) ++ coverage_failures(coverage) do
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

      reasons =
        stale_trigger_reasons(repo_triggers, Map.get(input, :repo_files)) ++
          file_reasons(files) ++
          human_path_reasons(repo_triggers, files) ++
          limit_reasons(phase, repo_triggers, files, Map.get(input, :diffstat))

      {reasons, matches(repo_triggers.effect_paths, files)}
    else
      {:escalate, reason} -> {[reason], []}
    end
  end

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

  defp matches(_globs, _files), do: []

  # A path git would print: relative, no empty, `.` or `..` segment. Anything else cannot be
  # trusted to match the way the configuration author read it.
  defp valid_path?(path) when is_binary(path) and path != "" do
    String.valid?(path) and not String.contains?(path, <<0>>) and
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

  defp intent_failures(intent, fixture_results) do
    with {:ok, intended} <- intended_fixtures(intent),
         {:ok, results} <- fixture_results(fixture_results) do
      not_run = Enum.reject(intended, &Map.has_key?(results, &1))
      unchanged = Enum.filter(intended, &(Map.get(results, &1) == :unchanged))

      unintended =
        for {id, :changed} <- results, id not in intended, do: id

      failure(:intended_fixture_not_run, not_run) ++
        failure(:intended_fixture_unchanged, unchanged) ++
        failure(:unintended_fixture_changed, unintended)
    else
      {:error, failure} -> [failure]
    end
  end

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
