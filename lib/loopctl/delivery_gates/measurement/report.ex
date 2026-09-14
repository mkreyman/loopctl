defmodule Loopctl.DeliveryGates.Measurement.Report do
  @moduledoc """
  The arithmetic and the two renderings of a measurement run (issue #828).

  Pure. It takes replay results and produces a machine-readable map plus a human summary; it
  reads no file and writes none. The Mix tasks own the I/O.

  ## Redaction, and why a public repository forces it

  loopctl is PUBLIC and `mkreyman/home_care_billing` is PRIVATE. Three things therefore never
  reach a committed artifact:

  - **File paths.** Publishing `(files, verdict)` pairs for hundreds of changes reconstructs
    the guard set — the very map design §13 keeps out of source, because it is a list of which
    paths skip human review. The cleared changes are the worst case: every one of them is a
    proof that none of its paths is guarded.
  - **Trigger patterns and PR titles.** The first is that map directly; the second is a private
    repository's content.
  - **Anything the RUN's own metadata carries** — an absolute checkout path, an absolute corpus
    path, and above all a trigger-parse error, which names a live guard pattern and the private
    repository together. `meta/2` redacts those exactly as `row/2` redacts a row, and it does so
    with an ALLOW-LIST (`published_meta_keys/0`). Redacting rows alone was the first defect; a
    deny-list was the second, and it failed the same day it was written, because a key nobody
    had thought about (`:corpus`, defaulting to a file path) publishes by default under a
    deny-list. Adding a meta key now requires a deliberate act by whoever wants it published.

  What a redacted row keeps is enough to spot-check with: the pull request NUMBER, the sha, the
  date, the diffstat, the file COUNT and the oracle's families. Anyone who can judge "would a
  human have wanted to see this?" can already read the pull request, so the redaction costs a
  reader with access nothing and costs a reader without access exactly what it should.

  `detail: :full` produces the same report with the paths, the patterns and the subjects, for
  writing OUTSIDE the repository. The Mix task defaults it to a gitignored path and says so.

  ## `:clear` is not the auto-merge set

  Gate B's `:clear` plus the size bound is what this measures, and it is a strict SUPERSET of
  what would actually auto-merge: `Loopctl.Delivery.MergePrecondition` additionally requires
  Gate A, custody, an unmoved head and an open pull request. The false-negative RATE survives
  that — everything the merge precondition adds can only remove changes from the set, never add
  one — but the wording must not imply the denominator is the merge set. `scope_note` on every
  Gate B report says so.
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
    "workflow_change_not_defect_fix stands in as the intake chat's [Feature] prefix for an INTAKE ticket and as an enhancement/idea label with no bug label for everything else. The two strata are NOT two corpora: `all` is the whole corpus and therefore MIXES both classifiers, because it contains the intake tickets too. Only the label half carries hindsight (a label is often applied after the outcome was known); the prefix is stamped at filing time.",
    "inverts_or_removes_deliberate_behaviour stands in as an inversion phrase in the title or body, so an inversion described in other words is missed. Conservative.",
    "confidence is sent as 0.0. Gate A requires the field and never reads it; the column is a placeholder, not a measurement.",
    "Read `intake_is_feature_share` before comparing the intake rate with the design's 54%. Where every intake escalation is a [Feature] ticket firing on workflow_change alone, the rate is ARITHMETICALLY the [Feature] share of the corpus — the harness is measuring the corpus split, not Gate A's judgement, and the comparison is weaker than the bare number reads."
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
        "Of the changes Gate B and the size bound would let through, how many can move claim output?",
      scope_note:
        "`clear` is Gate B's own clear plus the size bound, NOT the auto-merge set. Loopctl.Delivery.MergePrecondition additionally requires Gate A, custody, an unmoved head and an open pull request, so `clear` is a strict SUPERSET of what would actually auto-merge. The false-negative rate survives that: everything the merge precondition adds can only REMOVE changes from this set, never add one.",
      meta: meta(meta, detail),
      biases: @gate_b_biases,
      totals: %{
        changes: length(results),
        readable: length(readable),
        unreadable: length(results) - length(readable),
        with_stale_triggers: length(readable) - length(configuration_applied)
      },
      outcomes: outcome_counts(results),
      reason_kinds: reason_kinds(results),
      reason_kinds_by_outcome: reason_kinds_by_outcome(results),
      size_bounded_by_outcome: size_bounded_by_outcome(results),
      strata: %{
        all: stratum(readable),
        configuration_applied: stratum(configuration_applied),
        # NESTED inside configuration_applied on purpose, and named so. Over `readable` its
        # clear rate would carry the stale-trigger artifact the third stratum exists to remove,
        # printed on the line next to the honest one.
        configuration_applied_production_files:
          stratum(Enum.filter(configuration_applied, & &1.production_files?))
      },
      oracle_families: family_counts(readable),
      false_negatives: Enum.map(false_negatives(readable), &row(&1, detail)),
      unscored_clears: Enum.map(unscored_clears(readable), &row(&1, detail)),
      unreadable:
        Enum.map(
          Enum.filter(results, &(&1.outcome == :unreadable)),
          &unreadable_row(&1, detail)
        )
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
      meta: meta(meta, detail),
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
      intake_is_feature_share: feature_share(intake),
      sensitivity: sensitivity(Keyword.get(opts, :sensitivity)),
      escalations:
        Enum.map(Enum.filter(replays, &GateAReplay.escalated?/1), &ticket_row(&1, detail))
    }
  end

  @doc """
  Encodes a report with every object's keys SORTED, so two runs of one pinned corpus differ only
  where they genuinely differ.

  Map iteration order in Erlang is not stable across runs for a map of this size, so re-running
  the same pinned corpus reshuffled the JSON and the whole artifact showed as changed. That is
  not cosmetic here: the deliverable IS a pair of artifacts that get compared, `README.md`
  carries a cross-run rule that assumes a reader can diff two pinned runs and read the result,
  and churn pushes every future reader back to `diff -w` and reading the numbers by eye — the
  manual step the pins exist to remove.

  `generated_at` is deliberately NOT normalised. Two runs SHOULD differ there; one changed line
  is information, a reshuffled object is not.

  Both Mix tasks encode through here rather than calling `Jason.encode!/2` themselves, so the
  two writers cannot drift into producing differently-ordered artifacts.
  """
  @spec encode!(term()) :: String.t()
  def encode!(report), do: Jason.encode!(sort_keys(report), pretty: true) <> "\n"

  # `Stratum` is the only struct that reaches an artifact as an object; every other struct here
  # (a `DateTime`) has its own encoder and a date turned into a map would be a regression, not a
  # sort.
  defp sort_keys(%Stratum{} = stratum), do: stratum |> Map.from_struct() |> sort_keys()
  defp sort_keys(%_other{} = value), do: value

  defp sort_keys(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), sort_keys(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(value), do: value

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
      "reason kinds: " <> ordered(report.reason_kinds),
      "",
      stratum_line("all readable", report.strata.all),
      stratum_line("configuration applied", report.strata.configuration_applied),
      stratum_line(
        "  ... of those, production files",
        report.strata.configuration_applied_production_files
      ),
      "",
      report.scope_note,
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
       [""] ++
       feature_share_lines(report.intake_is_feature_share) ++
       [
         "",
         "design's collapsed-predicate rate, for comparison: 54%",
         "",
         "Read with these:"
       ] ++ Enum.map(report.biases, &("  - " <> &1)))
    |> Enum.join("\n")
  end

  defp feature_share_lines(%{degenerate?: true} = share) do
    [
      "DEGENERATE: all #{share.escalated} intake escalations fired on workflow_change alone, and " <>
        "#{share.request_shaped} of #{share.tickets} intake tickets are [Feature]. The rate IS the " <>
        "feature share of the corpus — this measures the corpus split, not Gate A's judgement."
    ]
  end

  defp feature_share_lines(%{escalation_reason_kinds: kinds}) do
    ["intake escalation reason kinds: #{ordered(kinds)} (not degenerate)"]
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

  # The SAME counting, stratified by outcome. Corpus-wide `reason_kinds` cannot answer "of the
  # changes in outcome X, how many carry reason Y", so a claim of that shape — the shape the
  # README now prescribes for describing a classification change — was not derivable from the
  # record it cited. Only the cross-tab makes it checkable.
  defp reason_kinds_by_outcome(results) do
    results
    |> Enum.group_by(& &1.outcome)
    |> Map.new(fn {outcome, group} -> {outcome, reason_kinds(group)} end)
  end

  # How many changes in each outcome were over a size bound AT ALL — the UNION the per-kind
  # cross-tab above cannot give, because a change over both bounds is counted in both kinds. It
  # is the one number a claim like "of the N in outcome X, M were also over the bound" needs, and
  # without it that claim was not derivable from the artifact carrying it.
  defp size_bounded_by_outcome(results) do
    results
    |> Enum.group_by(& &1.outcome)
    |> Map.new(fn {outcome, group} ->
      {outcome,
       Enum.count(group, &Enum.any?(&1.reasons, fn r -> GateBReplay.size_reason?(r) end))}
    end)
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

  @doc """
  Whether the intake escalation rate is measuring Gate A at all, or just the corpus split.

  When EVERY escalation in the stratum fires on `workflow_change` alone, and that stand-in is the
  `[Feature]` prefix, the escalation count IS the count of feature requests — so the rate is
  arithmetically the `[Feature]` share of the corpus and the harness has measured the intake
  chat's bug/feature mix rather than any judgement Gate A made. `degenerate?` says which case a
  run is in, computed rather than asserted, so a later run where the inversion trigger also fires
  reports `false` and the comparison with the design's 54% regains its force.
  """
  @spec feature_share([GateAReplay.t()]) :: map()
  def feature_share(replays) when is_list(replays) do
    escalated = Enum.filter(replays, &GateAReplay.escalated?/1)

    kinds =
      escalated
      |> Enum.flat_map(&Enum.map(&1.result.reasons, fn r -> elem(r, 0) end))
      |> Enum.uniq()

    request_shaped = Enum.count(replays, & &1.signals.request_shaped?)

    %{
      tickets: length(replays),
      escalated: length(escalated),
      request_shaped: request_shaped,
      escalation_reason_kinds: kinds,
      degenerate?: escalated != [] and kinds == [:workflow_change],
      note:
        "degenerate? true means every escalation fired on workflow_change alone, so the rate equals the [Feature] share of the corpus and measures the corpus split rather than Gate A's judgement. Weigh the comparison with the design's 54% accordingly."
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

  # -- meta redaction --------------------------------------------------------------------------

  # `meta` is REDACTED exactly as a row is, and this is an ALLOW-LIST, not a deny-list. The
  # first version dropped three named keys, which made PUBLISHING the default for every key
  # anyone adds later — and that defect reappeared within the same change, through a
  # DEFAULT: `--corpus` was optional and fell back to the tickets file path, so the absolute
  # path reached the artifact under a key the deny-list did not name. A deny-list has to be
  # updated by whoever adds a key; an allow-list has to be updated by whoever wants one
  # published, which is the person who has thought about it.
  #
  # What is deliberately NOT here, and why:
  #
  # - `:checkout` and `:tickets_file` are ABSOLUTE local paths.
  # - `:unparseable_reasons` echoes whatever a ticket record failed on. The COUNT beside it,
  #   `:unparseable_records`, is the number a reader needs.
  #
  # `:trigger_checksum_source` is published — `"operator_pin"` or `"computed"`. It is a property
  # of the RUN, not of the machine or the target: it names nothing, and it is the only field
  # that says whether the fingerprint beside it was verified against the checksum production
  # pinned or merely recomputed from whatever file was on disk. Without it a reader cannot tell
  # a checked run from an unchecked one. Added for `mix loopctl.gates.check_drift`, which is the
  # task that can be given a pin.
  #
  # `:trigger_status` IS published, reduced: the task REPLAYS a configuration failure rather
  # than refusing, by design, so it is a path the harness is built to take. A
  # `Triggers.parse/2` error is `{:invalid_pattern, ["repos", "<owner/repo>", "effect_paths"],
  # pattern}` — a LIVE GUARD PATTERN and the private repository's name — so only its KIND and
  # the key path's DEPTH survive.
  @meta_published [
    :corpus,
    :corpus_fingerprint,
    :generated_at,
    :gate,
    :harness,
    :head,
    :limit,
    :repo,
    :since,
    :tickets,
    :trigger_checksum_source,
    :trigger_fingerprint,
    :trigger_shape,
    :trigger_status,
    :unparseable_records,
    :until
  ]

  @doc "The meta keys a REDACTED artifact publishes. Everything else is full-detail only."
  @spec published_meta_keys() :: [atom()]
  def published_meta_keys, do: @meta_published

  defp meta(meta, :full), do: meta

  defp meta(meta, _redacted) do
    meta
    |> Map.take(@meta_published)
    |> Map.replace_lazy(:trigger_status, &redact_status/1)
  end

  defp redact_status(%{detail: _detail} = status), do: Map.delete(status, :detail)
  defp redact_status(status), do: status

  @doc """
  A trigger-parse outcome reduced to what may be published: the status, the error's KIND, and how
  deep in the document the key path pointed. Never the pattern and never the repository name.

  Public because the Mix task builds `meta` and the redaction has to be applied to the value it
  built, not to a string it already flattened — `"error: " <> inspect(reason)` cannot be
  un-flattened afterwards.
  """
  @spec trigger_status(term()) :: map()
  def trigger_status({:ok, _triggers}), do: %{status: "parsed"}

  def trigger_status({:error, reason}) do
    %{
      status: "error",
      kind: kind(reason),
      key_path_depth: key_path_depth(reason),
      detail: inspect(reason)
    }
  end

  def trigger_status(other), do: %{status: "error", kind: :unrecognised, detail: inspect(other)}

  defp key_path_depth(reason) when is_tuple(reason) and tuple_size(reason) > 1 do
    case elem(reason, 1) do
      path when is_list(path) -> length(path)
      _other -> nil
    end
  end

  defp key_path_depth(_reason), do: nil

  # -- rows --------------------------------------------------------------------------------------

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

  # The KIND only. A read failure's payload is git's own stderr, and git names paths and object
  # ids in it — "fatal: bad object <sha>", a gitlink's submodule path, a missing ref's name. This
  # run produced only `:root_commit`, which is why the hole was invisible rather than absent.
  defp unreadable_row(%GateBReplay{} = result, :full) do
    %{sha: String.slice(result.sha, 0, 12), error: inspect(result.error)}
  end

  defp unreadable_row(%GateBReplay{} = result, _redacted) do
    %{sha: String.slice(result.sha, 0, 12), error_kind: kind(result.error)}
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

  # The summary names whatever PINS the corpus — a resolved head for Gate B, a content
  # fingerprint for Gate A — so the human artifact says what to pass to reproduce it rather than
  # sending a reader to the JSON for the one value they need.
  defp window_line(meta) do
    "window: #{meta[:since] || "repository start"} .. #{meta[:until] || "corpus head"}" <>
      if(meta[:head], do: " (head #{meta[:head]})", else: "") <>
      if(meta[:corpus_fingerprint],
        do: " (corpus #{meta[:corpus_fingerprint]})",
        else: ""
      )
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
      "not_story=#{stratum.not_story} by_reason=#{ordered(stratum.by_reason)}"
  end

  # The .md is a COMPARED artifact too, and `inspect` over a map renders it in whatever order
  # the map iterates — the same churn the JSON had. Sorted, so a summary diff means something.
  defp ordered(%{} = map), do: map |> Enum.sort() |> inspect()
  defp ordered(list) when is_list(list), do: list |> Enum.sort() |> inspect()

  defp rate(_numerator, 0), do: nil
  defp rate(numerator, denominator), do: numerator / denominator

  defp pct(nil), do: "no measurement"
  defp pct(rate), do: "#{Float.round(rate * 100, 1)}%"
end
