defmodule Loopctl.DeliveryGates.Measurement.Report do
  @moduledoc """
  The arithmetic and the two renderings of a measurement run (issue #828).

  Pure. It takes replay results and produces a machine-readable map plus a human summary; it
  reads no file and writes none. The Mix tasks own the I/O.

  ## Redaction, and why a public repository forces it

  loopctl is PUBLIC and `mkreyman/home_care_billing` is PRIVATE. Two things therefore never
  reach a committed artifact:

  - **File paths.** Publishing `(files, verdict)` pairs for hundreds of changes reconstructs
    the guard set — the very map design §13 keeps out of source, because it is a list of which
    paths skip human review. The cleared changes are the worst case: every one of them is a
    proof that none of its paths is guarded.
  - **Trigger patterns and PR titles.** The first is that map directly; the second is a private
    repository's content.

  What a redacted row keeps is enough to spot-check with: the pull request NUMBER, the sha, the
  date, the diffstat, the file COUNT and the oracle's families. Anyone who can judge "would a
  human have wanted to see this?" can already read the pull request, so the redaction costs a
  reader with access nothing and costs a reader without access exactly what it should.

  `detail: :full` produces the same report with the paths, the patterns and the subjects, for
  writing OUTSIDE the repository. The Mix task defaults it to a gitignored path and says so.
  """

  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.DeliveryGates.Measurement.EffectOracle
  alias Loopctl.DeliveryGates.Measurement.GateAReplay
  alias Loopctl.DeliveryGates.Measurement.GateBReplay
  alias Loopctl.DeliveryGates.Measurement.Report.Stratum

  @gate_b_biases [
    "The oracle over-flags by construction (a HCPCS-shaped literal in a test assertion fires it), so the false-negative rate is an UPPER bound.",
    "The oracle is lexical and path-blind, so an arithmetic change that moves claim output without naming any billing vocabulary is invisible to it. A false-negative count of zero is NOT evidence that Gate B has none.",
    "Gate B's proof step (deploy, regenerate 837P from the fixed fixture set, diff it) cannot be replayed over history, so :prove_effect is counted as its own outcome and never scored as a pass or a fail.",
    "The trigger document is TODAY's, replayed over historical trees. A pattern that matches nothing at an old ref escalates as a stale trigger — the gate working, on a question the replay invented. The configuration_applied stratum excludes those.",
    "Only the :merge phase is replayed. The :triage run judges the trio's PREDICTED touches, and a replay has no prediction; substituting the real merged file list would bias that number optimistic."
  ]

  @gate_a_biases [
    "Trio DISAGREEMENT, the design's primary signal, is unobservable in a replay: every ticket is presented as three identical outputs. The measured rate is a strict LOWER BOUND.",
    "The contradicts field is empty by construction, not by measurement. Lower bound again.",
    "workflow_change_not_defect_fix stands in as the intake chat's [Feature] prefix (intake stratum) or an enhancement/idea label with no bug label (all stratum). The label stratum carries hindsight the trio would not have had; the intake stratum does not, because the prefix is stamped at filing time.",
    "inverts_or_removes_deliberate_behaviour stands in as an inversion phrase in the title or body, so an inversion described in other words is missed. Conservative.",
    "confidence is sent as 0.0. Gate A requires the field and never reads it; the column is a placeholder, not a measurement."
  ]

  @doc """
  The Gate B report.

  `meta` is whatever identifies the run — repository, window, trigger fingerprint — and is
  copied through verbatim so a later run can be compared against this one.
  """
  @spec gate_b([GateBReplay.t()], map(), keyword()) :: map()
  def gate_b(results, meta, opts \\ []) when is_list(results) and is_map(meta) do
    detail = Keyword.get(opts, :detail, :redacted)
    readable = Enum.reject(results, &(&1.outcome == :unreadable))

    configuration_applied = Enum.filter(readable, &(&1.stale_triggers == []))

    %{
      gate: "B",
      question:
        "Of the changes Gate B would have cleared for auto-merge, how many can move claim output?",
      meta: meta,
      biases: @gate_b_biases,
      totals: %{
        changes: length(results),
        readable: length(readable),
        unreadable: length(results) - length(readable),
        with_stale_triggers: length(readable) - length(configuration_applied)
      },
      outcomes: outcome_counts(results),
      reason_kinds: reason_kinds(results),
      strata: %{
        all: stratum(readable),
        production_files: stratum(Enum.filter(readable, & &1.production_files?)),
        configuration_applied: stratum(configuration_applied)
      },
      oracle_families: family_counts(readable),
      false_negatives: Enum.map(false_negatives(readable), &row(&1, detail)),
      unscored_clears: Enum.map(unscored_clears(readable), &row(&1, detail)),
      unreadable: Enum.map(Enum.filter(results, &(&1.outcome == :unreadable)), &unreadable_row/1)
    }
  end

  @doc """
  The Gate A report.

  `:sensitivity` takes a SECOND set of replays of the same corpus with the
  `workflow_change_not_defect_fix` stand-in suppressed. Gate A's rate turns almost entirely on
  that one reading, so the report states a RANGE — the rate with every feature request read as a
  workflow change, and the rate with none of them read that way — rather than a number whose
  whole value came from a judgement call nobody can see.
  """
  @spec gate_a([GateAReplay.t()], map(), keyword()) :: map()
  def gate_a(replays, meta, opts \\ []) when is_list(replays) and is_map(meta) do
    detail = Keyword.get(opts, :detail, :redacted)
    intake = Enum.filter(replays, & &1.ticket.intake?)

    %{
      gate: "A",
      question: "How often would Gate A escalate a past ticket to a human?",
      meta: meta,
      biases: @gate_a_biases,
      design_reference: %{
        collapsed_predicate_rate: 0.54,
        note:
          "Design section 5: collapsing Gate A and Gate B into one escalation produced a 54% escalation rate on 80 first-parent commits, and a rate resembling it is a design failure rather than a tuning question."
      },
      strata: %{
        intake: gate_a_stratum(intake),
        all: gate_a_stratum(replays)
      },
      sensitivity: sensitivity(Keyword.get(opts, :sensitivity)),
      escalations:
        Enum.map(Enum.filter(replays, &GateAReplay.escalated?/1), &ticket_row(&1, detail))
    }
  end

  @doc """
  The human summary of either report. One line per number a reader acts on, then the biases,
  because a rate read without them is worse than no rate.
  """
  @spec summarize(map()) :: String.t()
  def summarize(%{gate: "B"} = report) do
    [
      "Gate B replay — #{report.meta[:repo]}",
      window_line(report.meta),
      "changes: #{report.totals.changes} (readable #{report.totals.readable}, unreadable #{report.totals.unreadable}, stale-trigger #{report.totals.with_stale_triggers})",
      "outcomes: " <> outcome_line(report.outcomes),
      "reason kinds: " <> inspect(report.reason_kinds),
      "",
      stratum_line("all readable", report.strata.all),
      stratum_line("production files", report.strata.production_files),
      stratum_line("configuration applied", report.strata.configuration_applied),
      "",
      "false negatives listed: #{length(report.false_negatives)}",
      "unscored clears (oracle could not run): #{length(report.unscored_clears)}",
      "",
      "Read with these:"
      | Enum.map(report.biases, &("  - " <> &1))
    ]
    |> Enum.join("\n")
  end

  def summarize(%{gate: "A"} = report) do
    ([
       "Gate A replay — #{report.meta[:corpus]}",
       window_line(report.meta),
       "",
       gate_a_line("intake tickets", report.strata.intake),
       gate_a_line("all tickets", report.strata.all),
       ""
     ] ++
       sensitivity_lines(report.sensitivity) ++
       [
         "",
         "design's collapsed-predicate rate, for comparison: 54%",
         "",
         "Read with these:"
       ] ++ Enum.map(report.biases, &("  - " <> &1)))
    |> Enum.join("\n")
  end

  defp sensitivity_lines(%{run: false, note: note}), do: ["sensitivity: " <> note]

  defp sensitivity_lines(%{run: true} = sensitivity) do
    [
      "sensitivity — with #{sensitivity.suppressed} suppressed:",
      "  " <> gate_a_line("intake tickets", sensitivity.intake),
      "  " <> gate_a_line("all tickets", sensitivity.all)
    ]
  end

  # -- Gate B arithmetic ---------------------------------------------------------------------

  @doc """
  The counts and rates for one set of replay results.

  `false_negative_rate` is over the SCORED clears, not over all clears: a clear whose oracle
  could not run is neither a false negative nor a true one, and putting it in the denominator
  would report a rate diluted by changes nobody judged.
  """
  @spec stratum([GateBReplay.t()]) :: Stratum.t()
  def stratum(results) when is_list(results) do
    cleared = Enum.filter(results, &(&1.outcome == :clear))
    scored = Enum.filter(cleared, &GateBReplay.scored?/1)
    false_negatives = Enum.filter(scored, &GateBReplay.false_negative?/1)
    dates = results |> Enum.map(& &1.committed_at) |> Enum.reject(&is_nil/1)

    %Stratum{
      first: dates |> Enum.min(DateTime, fn -> nil end) |> iso8601(),
      last: dates |> Enum.max(DateTime, fn -> nil end) |> iso8601(),
      changes: length(results),
      cleared: length(cleared),
      scored_clears: length(scored),
      unscored_clears: length(cleared) - length(scored),
      false_negatives: length(false_negatives),
      clear_rate: rate(length(cleared), length(results)),
      false_negative_rate: rate(length(false_negatives), length(scored))
    }
  end

  defp outcome_counts(results) do
    counts = results |> Enum.map(& &1.outcome) |> Enum.frequencies()

    for outcome <- [:clear, :prove_effect, :human, :size_bound, :unreadable],
        into: %{},
        do: {outcome, Map.get(counts, outcome, 0)}
  end

  # Results carrying at least one reason of each KIND, so a change touching four human paths
  # counts once. Kinds only — a reason's payload is a path or a pattern, and neither belongs in
  # a committed artifact. It is also the first thing to read when a run escalates everything:
  # a single dominant kind is usually the harness feeding the gate a malformed input.
  defp reason_kinds(results) do
    results
    |> Enum.flat_map(fn result ->
      result.reasons |> Enum.map(&kind/1) |> Enum.uniq()
    end)
    |> Enum.frequencies()
  end

  defp kind(reason) when is_atom(reason), do: reason
  defp kind(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp kind(_reason), do: :unrecognised_reason

  defp family_counts(results) do
    for family <- EffectOracle.families(),
        into: %{},
        do: {family, Enum.count(results, &(&1.oracle && family in &1.oracle.families))}
  end

  # `false_negative?/1` already requires `:clear`, so this is one predicate, not two.
  defp false_negatives(results), do: Enum.filter(results, &GateBReplay.false_negative?/1)

  defp unscored_clears(results),
    do: Enum.filter(results, &(&1.outcome == :clear and not GateBReplay.scored?(&1)))

  # -- Gate A arithmetic ---------------------------------------------------------------------

  # Absent, the field says so rather than being omitted: a reader must be able to tell "the
  # sensitivity run was not done" from "it made no difference".
  defp sensitivity(nil) do
    %{
      suppressed: "workflow_change_not_defect_fix",
      run: false,
      note: "no sensitivity run was supplied, so the rate below is the single generous reading"
    }
  end

  defp sensitivity(replays) when is_list(replays) do
    %{
      suppressed: "workflow_change_not_defect_fix",
      run: true,
      note:
        "the same corpus with every feature request read as NOT a workflow change. The true rate is between this and the headline, and which end it sits at is a definition question for the design, not a tuning question.",
      intake: gate_a_stratum(Enum.filter(replays, & &1.ticket.intake?)),
      all: gate_a_stratum(replays)
    }
  end

  defp gate_a_stratum(replays) do
    results = Enum.map(replays, & &1.result)
    rate = GateA.rate(results)

    Map.merge(rate, %{
      not_story: Enum.count(replays, &GateAReplay.not_story?/1),
      by_signal: %{
        request_shaped: Enum.count(replays, & &1.signals.request_shaped?),
        inversion_phrase: Enum.count(replays, & &1.signals.inversion_phrase?),
        rejected: Enum.count(replays, & &1.signals.rejected?)
      }
    })
  end

  # -- rows ------------------------------------------------------------------------------------

  defp row(%GateBReplay{} = result, detail) do
    base = %{
      pr: result.pr_number,
      sha: String.slice(result.sha, 0, 12),
      committed_at: result.committed_at && DateTime.to_iso8601(result.committed_at),
      outcome: result.outcome,
      files: result.diffstat[:files],
      changed_lines: result.diffstat[:changed_lines],
      diff_files_listed: result.file_count,
      oracle_families: (result.oracle && result.oracle.families) || [],
      # A cleared change matched NO trigger by definition. Both lists are carried so a reader
      # sees the absence stated rather than inferring it from a missing key.
      effect_matches: [],
      human_matches: []
    }

    case detail do
      :full -> Map.merge(base, %{subject: result.subject, reasons: inspect(result.reasons)})
      _redacted -> base
    end
  end

  defp unreadable_row(%GateBReplay{} = result) do
    %{sha: String.slice(result.sha, 0, 12), error: inspect(result.error)}
  end

  defp ticket_row(%GateAReplay{} = replay, detail) do
    base = %{
      issue: replay.ticket.number,
      created_at: replay.ticket.created_at,
      intake: replay.ticket.intake?,
      reasons: replay.result.reasons |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
      signals: replay.signals
    }

    case detail do
      :full -> Map.put(base, :title, replay.ticket.title)
      _redacted -> base
    end
  end

  # -- rendering -------------------------------------------------------------------------------

  defp window_line(meta) do
    "window: #{meta[:since] || "repository start"} .. #{meta[:until] || "corpus head"}" <>
      if(meta[:head], do: " (head #{meta[:head]})", else: "")
  end

  defp outcome_line(outcomes) do
    Enum.map_join([:clear, :prove_effect, :human, :size_bound, :unreadable], ", ", fn key ->
      "#{key} #{Map.fetch!(outcomes, key)}"
    end)
  end

  defp stratum_line(label, %Stratum{} = stratum) do
    "#{label}: n=#{stratum.changes} cleared=#{stratum.cleared} (#{pct(stratum.clear_rate)}) " <>
      "scored_clears=#{stratum.scored_clears} false_negatives=#{stratum.false_negatives} " <>
      "(#{pct(stratum.false_negative_rate)}) " <>
      "[#{date(stratum.first)} .. #{date(stratum.last)}]"
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp date(nil), do: "no dates"
  defp date(iso8601), do: String.slice(iso8601, 0, 10)

  defp gate_a_line(label, stratum) do
    "#{label}: n=#{stratum.total} escalated=#{stratum.escalated} (#{pct(stratum.rate)}) " <>
      "not_story=#{stratum.not_story} by_reason=#{inspect(stratum.by_reason)}"
  end

  defp rate(_numerator, 0), do: nil
  defp rate(numerator, denominator), do: numerator / denominator

  defp pct(nil), do: "no measurement"
  defp pct(rate), do: "#{Float.round(rate * 100, 1)}%"
end
