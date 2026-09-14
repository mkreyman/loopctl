defmodule Loopctl.DeliveryGates.Measurement.EffectOracle do
  @moduledoc """
  An independent, PATH-BLIND judgement of whether a change can move claim output.

  It exists to answer the only question worth asking of Gate B: of the changes the gate would
  have cleared for auto-merge, how many should a human have seen? A false-negative measure
  needs a second opinion that cannot agree with the gate by construction, so this one reads
  ONLY the added and removed lines of the diff. It never sees a file path, and it is never
  given the trigger document.

  ## The four signal families

  Each is a list of anchored patterns over the changed lines. A change fires a family when any
  of its patterns matches; the oracle's verdict is effect-bearing when any family fires.

  - `:edi` — X12 structure: a quoted segment identifier, or an `837`/`835` transaction number.
    837P generation is the irreversible effect the design names first.
  - `:billing_codes` — a HCPCS-shaped literal (a letter and four digits, `T1019`), the
    vocabulary that names one (`procedure_code`, `billing_code`, `revenue_code`), a QUALIFIED
    `modifier` (`modifier_code`, `hcpcs_modifier` — never the bare word, which is ordinary
    programming vocabulary), or a literal HCPF modifier value.
  - `:rates` — what a claim is priced at: `fee_schedule`, `rate_cents`, `unit_rate`,
    `reimbursement`, `medicaid`. A rate table edit is a Medicaid rate change.
  - `:outbound` — what carries the effect out of the building: `sftp`, `clearinghouse`,
    `remittance`, `payer_id`, an EVV aggregator's name, `submit_claim`.

  ## Its two biases, both named

  It **over-flags**, deliberately. `\\b[A-TV-Z]\\d{4}\\b` matches a HCPCS code and also matches
  an unrelated constant that happens to look like one, and a test file asserting on
  `procedure_code` fires `:billing_codes` while changing no behaviour. Over-flagging inflates
  the false-negative count, which is the safe direction for a gate measurement: the rate it
  produces is an UPPER bound on Gate B's false negatives.

  Two patterns over-flagged in ways that bias is NOT a licence for, and both were narrowed after
  the first run: the `837`/`835` pattern was bounded by DECIMAL digits and therefore fired inside
  any hex digest containing the substring, and `modifier` was unqualified and therefore fired on
  the ordinary programming word. A bias the moduledoc declares is a bound on the number; a
  pattern matching a content hash is not a bias, it is a bug, and it moved the rate.

  It **under-detects silently**, and this one has no bound. A change that alters claim output
  through arithmetic — a rounding rule in a shared helper, a date-window boundary, a sort order
  that decides which visit lands on which claim line — touches none of this vocabulary and the
  oracle will call it inert. Only the design's own harness (regenerate 837P from a fixed
  fixture set and diff it) can close that, and it cannot be run over history. So a
  false-negative count of zero from this oracle is NOT evidence that Gate B has no false
  negatives.

  ## Why not a dependency graph

  The correct oracle is "does this change reach 837P generation", which needs the target
  repository compiled and `mix xref` over it. That is not offline, not repeatable against a
  historical tree without checking it out, and the harness may not change the target
  repository's checkout state. Lexical over a path-blind input is what is measurable here, and
  the paragraph above is the price.
  """

  @families [
    edi: [
      ~r/["'](ISA|GS|GE|IEA|ST|SE|CLM|SV1|SV2|SV5|NM1|HI|DTP|SBR|PRV|CAS|SVC|AMT|QTY)["']/,
      # NOT `\b83[57]\b`: an underscore is a word character, so `\b` never fires on
      # `build_837` or `Generator837P` — the two shapes an EDI module is actually named in.
      #
      # THREE guards. Every one of them was paid for by an earlier version being wrong, twice in
      # each direction, which is why the still-fires cases below are pinned as hard as the
      # suppressed ones:
      #
      # - `(?<![0-9])` / `(?![0-9])` — no DECIMAL digit touching it. Without this `18370`,
      #   `8350`, `8375` and `9837` all read as EDI. A transaction number never has a digit
      #   beside it.
      # - `(?<![0-9][.\-])` / `(?![.\-][0-9])` — a dot or hyphen only blocks when a DIGIT sits on
      #   its FAR side, which is what a version string (`1.0.837`) and a UUID boundary
      #   (`-837-4f79`) look like. Blocking a dot or hyphen OUTRIGHT was the round-2 defect and
      #   it failed in the unbounded direction: it stopped `Generator837.build`, `Edi837.new()`,
      #   `"claims-837.txt"` and `"out/837.edi"` — the commonest Elixir spellings of an EDI call
      #   — so a cleared change whose only evidence was one of those scored inert and dropped
      #   OUT of the false-negative count, pushing the published rate DOWN.
      # - `(?<![0-9A-Fa-f]{2})` / `(?![0-9A-Fa-f]{2})` — no RUN of two hex characters touching
      #   it, which is what a content hash looks like. A SINGLE hex character was too strong and
      #   lost `era835`, silently dropping a real claims-path false negative (PR 1263).
      #
      # Known residual, accepted rather than chased: a UUID segment of the shape `<hex>-837a-`
      # still matches, because neither neighbour is a digit and neither run is two hex
      # characters. That is an OVER-flag, the bounded direction — it can only inflate the
      # false-negative count, which the moduledoc already declares an upper bound — and every
      # attempt so far to close a residual by widening a guard has cost a real signal.
      ~r/(?<![0-9])(?<![0-9][.\-])(?<![0-9A-Fa-f]{2})83[57]P?(?![0-9])(?![.\-][0-9])(?![0-9A-Fa-f]{2})/,
      ~r/\bx12\b/i,
      ~r/\bedi_/i,
      ~r/\bsegment_terminator\b/i
    ],
    billing_codes: [
      ~r/\b[A-TV-Z]\d{4}\b/,
      ~r/\bhcpcs\b/i,
      ~r/\bprocedure_code/,
      ~r/\bbilling_code/,
      ~r/\brevenue_code/,
      # NOT a bare singular `\bmodifier`: that is an ordinary programming word (a modifier
      # function, a modifier key, a CSS modifier) and it fired on code with no billing content
      # at all. The domain sense arrives qualified, as the SV1 field names `modifier_1`..
      # `modifier_4`, or as the PLURAL — which the first narrowing dropped along with the bare
      # word, and which is how the list is spelled everywhere it is a list of HCPCS modifiers.
      # `modifiers` does occur in ordinary programming prose; that is the accepted cost of not
      # losing the domain spelling, and both directions have a test.
      ~r/\bmodifier_(code|codes|program|list|values?)\b/,
      ~r/\bmodifier_[1-4]\b/,
      ~r/\bmodifiers\b/,
      ~r/\b(hcpcs|billing|service|claim|payer|procedure)_modifiers?\b/,
      # `SE` is deliberately absent: it is an X12 segment id, already in the :edi family, and
      # listing it here would report one signal as two families.
      ~r/["'](U[1-9]|HQ|TT|GT|TF|TG|UA|UB|SC)["']/
    ],
    rates: [
      ~r/\bfee_schedule/,
      ~r/\brate_cents\b/,
      ~r/\bunit_rate\b/,
      ~r/\breimbursement/i,
      ~r/\bmedicaid\b/i
    ],
    outbound: [
      ~r/\bsftp\b/i,
      ~r/\bclearinghouse\b/i,
      ~r/\bremittance/i,
      ~r/\bpayer_id\b/,
      ~r/\bsandata\b/i,
      ~r/\bhha_?exchange\b/i,
      ~r/\bsubmit_claim/,
      ~r/\bclaim_file/
    ]
  ]

  @type verdict :: %{effect_bearing?: boolean(), families: [atom()]}

  @doc "The family names, in the order they are reported."
  @spec families() :: [atom()]
  def families, do: Keyword.keys(@families)

  @doc """
  Judges the changed lines of a diff.

  `nil` or anything that is not a binary is `{:error, :no_content}`: a change whose content
  could not be read is not an inert change, and scoring it as one would silently shrink the
  false-negative count by exactly the changes nobody could read.
  """
  @spec judge(term()) :: {:ok, verdict()} | {:error, :no_content}
  def judge(content) when is_binary(content) do
    families =
      for {family, patterns} <- @families,
          Enum.any?(patterns, &Regex.match?(&1, content)),
          do: family

    {:ok, %{effect_bearing?: families != [], families: families}}
  end

  def judge(_content), do: {:error, :no_content}
end
