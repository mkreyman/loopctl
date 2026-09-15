defmodule Loopctl.DeliveryGates.Measurement.GateAReplay do
  @moduledoc """
  Replays Gate A over past tickets, log-only, and reports its escalation rate (issue #828,
  design §12 build order step 3).

  Gate A's only input is the triage trio's three outputs. History has no trio, so a replay must
  RECONSTRUCT one per ticket from signals that already exist on the ticket, hand it to the
  shipped `Loopctl.DeliveryGates.GateA.evaluate/1`, and count with the shipped
  `GateA.rate/1`. What the reconstruction can and cannot supply is the whole honesty of the
  number, so it is spelled out here and restated on every artifact.

  ## What stands in for each of Gate A's four triggers

  | trigger | stand-in | direction of the bias |
  |---|---|---|
  | trio verdicts DISAGREE | nothing — three identical outputs | the measured rate is a strict LOWER BOUND, and this is the design's PRIMARY signal |
  | `contradicts` non-empty | nothing — always `[]` | lower bound again |
  | workflow change, not a defect fix | the intake chat's own `[Feature]` prefix, else an `enhancement`/`idea` label with no `bug` label | see below |
  | inverts or removes deliberate behaviour | an inversion phrase in the title or body | conservative: an inversion described without one of these words is missed |

  Two of the four are UNOBSERVABLE. That is not a defect in the harness; it is what a replay
  of a request-shaped gate can be. Read the number as "at least this often", never as "this
  often".

  ## Why the `[Feature]` prefix and not a label

  The prefix is stamped by the in-app chat at FILING time, before anyone knows what the fix
  turned out to be. A `bug`/`enhancement` LABEL is often applied afterwards, sometimes after
  the work landed, so a corpus classified by label carries hindsight the triage trio would not
  have had. Both strata are reported; the intake one is the headline for exactly this reason.

  ## `confidence` is a placeholder, not a measurement

  Gate A requires the field and never reads it (by design — three independent judgements beat
  one self-report). The reconstruction sends `0.0`, and the artifact says so, so nobody later
  mistakes a column of zeroes for a measured confidence.

  ## A `reject` verdict is not an escalation

  A ticket closed as not-planned reconstructs to a unanimous `reject`, which Gate A answers
  `:proceed` on — it is agreement, and Gate A measures disagreement. The merge precondition is
  what refuses a non-`story` verdict later. The report counts `not_story` separately so the
  two are never added together.
  """

  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.DeliveryGates.Measurement.Ticket

  # READ OFF THE GATE, not restated. These two strings decide what the replay EMITS, and the
  # gate decides what it MATCHES: spelled separately, a rename in `GateA` leaves this harness
  # emitting the old spelling, the gate matching nothing, and `mix loopctl.gates.measure_a`
  # reporting that code's rate as 0% — which reads as "it never fires" rather than "the
  # measurement is broken". That number is what earns a code its gating place, so a silent
  # zero is the worst answer this module can give.
  #
  # Positional: `gating_reason_codes/0` is the gate's own list, and the guard below fails the
  # build if it stops being the two this harness knows how to produce signals for.
  @inverts "inverts_or_removes_deliberate_behaviour"
  @workflow "workflow_change_not_defect_fix"

  @known_codes Enum.sort([@inverts, @workflow])

  if Enum.sort(GateA.gating_reason_codes()) != @known_codes do
    raise """
    GateA's gating codes have changed and this replay harness has not.

    gate:    #{inspect(Enum.sort(GateA.gating_reason_codes()))}
    harness: #{inspect(@known_codes)}

    The harness emits these strings to measure how often each code fires. A code the gate
    matches and the harness never emits measures 0% for ever; a code the harness emits and
    the gate does not match does the same. Add the signal that produces the new code, or
    remove the one that is gone.
    """
  end

  # Anchored on whole words: "remove" must not fire on "removed the typo" only by being a
  # substring of something else, and "revert" must not fire on "reverting" being absent.
  @inversion_phrases [
    ~r/\bno longer\b/i,
    ~r/\bstop (?:showing|sending|creating|generating|requiring)\b/i,
    ~r/\brevert\b/i,
    ~r/\bundo\b/i,
    ~r/\bdisable\b/i,
    ~r/\bturn off\b/i,
    ~r/\bremove the (?:option|requirement|field|column|button|step)\b/i,
    ~r/\bshould not\b/i,
    ~r/\bwe don't want\b/i,
    ~r/\bwe do not want\b/i
  ]

  # An intake ticket the chat stamped `[Bug]` is a defect report by construction, whatever
  # labels were applied later — so the intake stratum tests only for the `[Feature]` stamp.
  @feature_prefix ~r/\A\[Feature\]/
  @request_labels ~w(enhancement idea feature)
  @defect_labels ~w(bug)

  @enforce_keys [:ticket, :result, :trio]
  defstruct [:ticket, :result, :trio, :signals]

  @type t :: %__MODULE__{
          ticket: Ticket.t(),
          result: GateA.Result.t(),
          trio: [map()],
          signals: %{atom() => boolean()}
        }

  @doc """
  Reconstructs a trio for one ticket and evaluates Gate A over it.

  ## `:suppress`

  A list of signal names to force FALSE — `[:request_shaped?]` is the one that matters. It
  exists because the single largest judgement call in this replay is reading the intake chat's
  `[Feature]` stamp as `workflow_change_not_defect_fix`, and that reading is the GENEROUS end:
  the design's trigger is a workflow change, and a feature request that only adds a column to a
  report is a feature but arguably not a workflow change. Running the corpus both ways turns
  that judgement into a stated RANGE rather than a number nobody can audit.
  """
  @spec replay(Ticket.t(), keyword()) :: t()
  def replay(%Ticket{} = ticket, opts \\ []) do
    suppressed = Keyword.get(opts, :suppress, [])
    signals = ticket |> signals() |> suppress(suppressed)
    output = output(ticket, signals)
    trio = [output, output, output]

    %__MODULE__{ticket: ticket, result: GateA.evaluate(trio), trio: trio, signals: signals}
  end

  defp suppress(signals, []), do: signals

  defp suppress(signals, suppressed) do
    Enum.reduce(suppressed, signals, fn signal, acc -> Map.replace!(acc, signal, false) end)
  end

  @doc "True when Gate A escalated this ticket."
  @spec escalated?(t()) :: boolean()
  def escalated?(%__MODULE__{result: %GateA.Result{decision: :escalate}}), do: true
  def escalated?(%__MODULE__{}), do: false

  @doc """
  True when Gate A proceeded on a verdict that is not `story` — a `reject`. Counted apart from
  an escalation because they are different outcomes with different downstream handling.
  """
  @spec not_story?(t()) :: boolean()
  def not_story?(%__MODULE__{result: %GateA.Result{decision: :proceed, verdict: verdict}}),
    do: verdict != :story

  def not_story?(%__MODULE__{}), do: false

  @doc "The reconstruction's per-ticket signals, exposed so a reader can spot-check a verdict."
  @spec signals(Ticket.t()) :: %{atom() => boolean()}
  def signals(%Ticket{} = ticket) do
    %{
      request_shaped?: request_shaped?(ticket),
      inversion_phrase?: inversion_phrase?(ticket),
      rejected?: rejected?(ticket)
    }
  end

  @doc """
  The single reconstructed output, replicated three times by `replay/1`.

  Public so a test can assert the shape Gate A is actually handed, and so a reader can see
  that `contradicts` is empty by construction rather than by measurement.
  """
  @spec output(Ticket.t(), %{atom() => boolean()}) :: map()
  def output(%Ticket{}, signals) do
    codes =
      [{@workflow, signals.request_shaped?}, {@inverts, signals.inversion_phrase?}]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    %{
      "verdict" => if(signals.rejected?, do: "reject", else: "story"),
      "escalation_reasons" => codes,
      # UNOBSERVABLE in a replay. Never populated, and the rate is a lower bound because of it.
      "contradicts" => [],
      # Required by the contract, never read by the gate. A placeholder, not a measurement.
      "confidence" => 0.0
    }
  end

  defp request_shaped?(%Ticket{intake?: true, title: title}),
    do: Regex.match?(@feature_prefix, title)

  defp request_shaped?(%Ticket{labels: labels}) do
    Enum.any?(labels, &(&1 in @request_labels)) and
      not Enum.any?(labels, &(&1 in @defect_labels))
  end

  defp inversion_phrase?(%Ticket{title: title, body: body}) do
    text = title <> "\n" <> (body || "")
    Enum.any?(@inversion_phrases, &Regex.match?(&1, text))
  end

  # `stateReason` is `NOT_PLANNED` for an issue closed without doing it. A ticket still open,
  # or closed as completed, was not rejected.
  defp rejected?(%Ticket{state_reason: "NOT_PLANNED"}), do: true
  defp rejected?(%Ticket{}), do: false
end
