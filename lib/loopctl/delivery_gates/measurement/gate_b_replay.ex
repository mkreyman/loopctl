defmodule Loopctl.DeliveryGates.Measurement.GateBReplay do
  @moduledoc """
  Replays Gate B's MERGE run over one already-merged change and scores it against the
  independent `EffectOracle` (issue #828, design §12 build order step 2).

  ## It calls the shipped gate, not a copy of it

  The input is built by `Loopctl.DeliveryGates.DiffNames.parse/1` over the raw bytes of
  `git diff --name-status -M -z`, exactly as `Loopctl.Delivery.MergePrecondition` builds it,
  and judged by that module's own `gate_b_verdict/2` (Gate B at head AND at merge base, OR-ed)
  and `hard_bound_reasons/1` (the design's 12-file / 1,000-line ceiling). A harness with its
  own judge measures the harness.

  ## The five outcomes

  - `:clear` — Gate B cleared it and the hard bound allowed it, and the only outcome a false
    negative can live in. It is a strict SUPERSET of what would actually auto-merge:
    `Loopctl.Delivery.MergePrecondition` additionally requires Gate A, custody, an unmoved head
    and an open pull request. The false-negative RATE survives that, because everything the
    merge precondition adds can only remove changes from this set
  - `:prove_effect` — an effect path was touched. Not scored as pass or fail: the proof step
    regenerates 837P output from a fixed fixture set on a deployed branch, which cannot be
    replayed over history
  - `:human` — a human path, an unreadable input, a stale trigger, or a configuration failure
  - `:size_bound` — refused ONLY on size: the configured `max_files` / `max_changed_lines`, the
    design's 12-file / 1,000-line ceiling, or both. Reported apart from `:human` because the two
    say different things about the gate — a human path is the gate finding something, a size
    refusal is the gate declining to look. A change over the bound that ALSO touches a human
    path is `:human`, and one that also touches an EFFECT path is `:prove_effect`: what the gate
    found beats what it declined to look at, in both cases
  - `:unreadable` — the change could not be read at all. Counted, never dropped

  ## What counts as a false negative

  `:clear` from the gate AND `effect_bearing?: true` from the oracle. Both bounds on that
  number are in `EffectOracle`'s moduledoc and are restated on every artifact: it over-flags
  by construction, so the rate is an upper bound, and it cannot see an arithmetic change that
  moves claim output without naming any billing vocabulary, so zero is not evidence of none.

  ## Stale triggers are an artifact of replay, and are reported apart

  The trigger document is TODAY's. Replayed over a tree from before a guarded path existed,
  every configured pattern that matches nothing escalates as `{:stale_trigger, pattern}` — the
  gate working exactly as designed, on a question the replay invented. Those changes are
  counted separately so the headline rates are over the changes where the configuration
  actually applied.
  """

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.DeliveryGates.DiffNames
  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.DeliveryGates.Measurement.Change
  alias Loopctl.DeliveryGates.Measurement.EffectOracle

  @enforce_keys [:sha, :outcome]
  defstruct [
    :sha,
    :pr_number,
    :subject,
    :committed_at,
    :outcome,
    :diffstat,
    :oracle,
    :error,
    reasons: [],
    effect_matches: [],
    stale_triggers: [],
    file_count: 0,
    production_files?: false
  ]

  @type outcome :: :clear | :prove_effect | :human | :size_bound | :unreadable

  # Every reason that is a SIZE refusal — Gate B's configured limits and the merge
  # precondition's own ceiling. Named here rather than matched by shape, so a new reason kind
  # is classified `:human` by default: an unrecognised refusal is a human's business.
  @size_reasons [
    :max_files_exceeded,
    :max_changed_lines_exceeded,
    :hard_bound_files_exceeded,
    :hard_bound_changed_lines_exceeded
  ]

  @type t :: %__MODULE__{
          sha: String.t(),
          pr_number: pos_integer() | nil,
          subject: String.t() | nil,
          committed_at: DateTime.t() | nil,
          outcome: outcome(),
          diffstat: Change.diffstat() | nil,
          oracle: EffectOracle.verdict() | nil,
          error: term(),
          reasons: [term()],
          effect_matches: [term()],
          stale_triggers: [String.t()],
          file_count: non_neg_integer(),
          production_files?: boolean()
        }

  # A change whose every file is under one of these is documentation or test scaffolding. It is
  # a CORPUS stratification, never an oracle input: the oracle stays path-blind, and this only
  # decides which stratum a change is counted in.
  @non_production_prefixes ["test/", "docs/", ".github/", "priv/repo/", "assets/"]

  @doc """
  Replays one change against one trigger set.

  `triggers` is the RETURN VALUE of `Loopctl.DeliveryGates.Triggers.parse/2`, passed through
  untouched exactly as the gate takes it, so a configuration failure is measured rather than
  worked around.
  """
  @spec replay(Change.t(), String.t(), term()) :: t()
  def replay(%Change{} = change, repo, triggers) do
    parsed = DiffNames.parse(change.diff)

    facts = %{
      repo: {:ok, repo},
      triggers: triggers,
      head_files: {:ok, change.head_files},
      base_files: {:ok, change.base_files}
    }

    # `:diff` is a `DiffNames.parse/1`-SHAPED value, not raw bytes — the same shape
    # `Loopctl.Delivery.GitHubPullRequestSource` puts on a pull request, so a diff that did not
    # parse reaches the gate as the unreadable-diff marker rather than as an argument error.
    pr = %{diff: parsed, diffstat: change.diffstat}

    base = %__MODULE__{
      sha: change.sha,
      pr_number: change.pr_number,
      subject: change.subject,
      committed_at: change.committed_at,
      outcome: :unreadable,
      diffstat: change.diffstat,
      oracle: oracle(change),
      file_count: file_count(parsed),
      production_files?: production_files?(parsed)
    }

    case MergePrecondition.gate_b_verdict(facts, pr) do
      {:ok, %GateB.Result{} = result} ->
        score(base, result, MergePrecondition.hard_bound_reasons(change.diffstat))

      {:refuse, reasons} ->
        %{base | outcome: :human, reasons: reasons}
    end
  end

  @doc """
  A false negative: the gate cleared it for auto-merge and the independent oracle says the
  change can move claim output.

  A `:clear` with an oracle that could not run (`nil`) is NOT a false negative and is NOT a
  true negative either — it is unscored, and `Report` counts it as such.
  """
  @spec false_negative?(t()) :: boolean()
  def false_negative?(%__MODULE__{outcome: :clear, oracle: %{effect_bearing?: true}}), do: true
  def false_negative?(%__MODULE__{}), do: false

  @doc "A change the replay could score at all: the oracle ran and the change was readable."
  @spec scored?(t()) :: boolean()
  def scored?(%__MODULE__{outcome: :unreadable}), do: false
  def scored?(%__MODULE__{oracle: nil}), do: false
  def scored?(%__MODULE__{}), do: true

  @doc """
  A replay result for a change that could not be read. Kept in the corpus so the denominator
  is the window, not the window minus whatever failed.
  """
  @spec unreadable(String.t(), term()) :: t()
  def unreadable(sha, reason) when is_binary(sha) do
    %__MODULE__{sha: sha, outcome: :unreadable, error: reason}
  end

  defp score(base, %GateB.Result{} = result, hard_bound) do
    stale = for {:stale_trigger, pattern} <- result.reasons, do: pattern
    reasons = result.reasons ++ hard_bound
    non_size = Enum.reject(reasons, &size_reason?/1)

    # PRECEDENCE, strongest signal first, the same rule that puts a human path above a size
    # refusal: what the gate FOUND beats what it declined to look at. Ordering `:size_bound`
    # above the effect signal lost it on any change that was also over the bound — inert at
    # today's limits and live for any looser configuration.
    #
    # Read `effect_matches` rather than the Result's own `outcome`: Gate B reports `:human` the
    # moment it has ANY reason, size reasons included, so a change over the bound that touches an
    # effect path never carries a `:prove_effect` outcome to read. `effect_matches` is computed
    # from the paths independently of the reasons, which is what makes it the honest signal here.
    outcome =
      cond do
        non_size != [] -> :human
        result.effect_matches != [] -> :prove_effect
        reasons != [] -> :size_bound
        true -> :clear
      end

    %{
      base
      | outcome: outcome,
        reasons: reasons,
        effect_matches: Enum.map(result.effect_matches, &elem(&1, 1)) |> Enum.uniq(),
        stale_triggers: Enum.uniq(stale)
    }
  end

  defp size_reason?(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: elem(reason, 0) in @size_reasons

  defp size_reason?(_reason), do: false

  defp oracle(%Change{content: content}) do
    case EffectOracle.judge(content) do
      {:ok, verdict} -> verdict
      {:error, :no_content} -> nil
    end
  end

  defp file_count({:ok, %{files: files}}), do: length(files)
  defp file_count(_parsed), do: 0

  defp production_files?({:ok, %{files: [_ | _] = files}}) do
    Enum.any?(files, fn file ->
      not Enum.any?(@non_production_prefixes, &String.starts_with?(file, &1))
    end)
  end

  defp production_files?(_parsed), do: false
end
