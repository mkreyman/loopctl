defmodule Loopctl.DeliveryGates.GateA do
  @moduledoc """
  Gate A — "Mark decides". Request-shaped, and meant to be rare.

  Its only input is the triage trio's output: three independently prompted agents' verdicts
  on the REQUEST. It reads no file path and has no path configuration, by design — an
  uncontested defect in a sensitive part of the code is not a decision for a human; whether
  the change can cause an irreversible effect is Gate B's question, answered from the diff.

  It escalates when:

  - there are not exactly three outputs, or any output is malformed (fail closed)
  - the three `verdict`s disagree — three separate judgements that do not agree are a far
    better signal than any one agent's confidence
  - any agent's verdict is `"escalate"`
  - any agent reports a non-empty `contradicts` (an existing story, KB decision, or code
    behaviour the request conflicts with)
  - any agent's `escalation_reasons` carries one of the gating reason codes below

  `confidence` is RECORDED on the result and never consulted by the decision.

  ## Gating reason codes

  The trio contract emits these strings in `escalation_reasons`. Any other code is a SOFT
  signal: recorded on the result and never gating, until its measured rate earns it a place
  here.

  - `"inverts_or_removes_deliberate_behaviour"` — the request inverts or removes behaviour a
    previous story deliberately added
  - `"workflow_change_not_defect_fix"` — the request changes a workflow rather than fixing a
    defect

  ## Output contract read

  Each output is the decoded JSON object (string keys) the trio emits:

      %{"verdict" => "story" | "escalate" | "reject",
        "escalation_reasons" => [String.t()],
        "contradicts" => [%{"kind" => "story" | "kb" | "code", "ref" => String.t(), "why" => String.t()}],
        "confidence" => number in 0.0..1.0}

  All four keys are required. `story` is not read here.
  """

  alias Loopctl.DeliveryGates.GateA.Result

  @inverts_deliberate_behaviour "inverts_or_removes_deliberate_behaviour"
  @workflow_change "workflow_change_not_defect_fix"

  @gating_codes %{
    @inverts_deliberate_behaviour => :inverts_deliberate_behaviour,
    @workflow_change => :workflow_change
  }

  @verdicts %{"story" => :story, "escalate" => :escalate, "reject" => :reject}
  @contradiction_kinds ~w(story kb code)
  @trio_size 3

  @doc "The escalation reason codes that gate, as the trio contract spells them."
  @spec gating_reason_codes() :: [String.t()]
  def gating_reason_codes, do: Map.keys(@gating_codes)

  @doc """
  Evaluates the trio's outputs. Anything other than a list of exactly three well-formed
  outputs escalates.
  """
  @spec evaluate(term()) :: Result.t()
  def evaluate(outputs) when is_list(outputs) and length(outputs) == @trio_size do
    parsed = outputs |> Enum.with_index() |> Enum.map(&parse_output/1)
    valid = for {:ok, index, output} <- parsed, do: {index, output}

    reasons =
      malformed_reasons(parsed) ++
        disagreement_reasons(valid) ++
        Enum.flat_map(valid, &agent_reasons/1)

    build(reasons, valid, parsed)
  end

  def evaluate(outputs) do
    size = if is_list(outputs), do: length(outputs), else: :not_a_list

    %Result{
      decision: :escalate,
      verdict: nil,
      reasons: [{:trio_size, size}],
      confidences: [],
      soft_signals: []
    }
  end

  @doc """
  The measured escalation rate over a set of results.

  `by_reason` counts RESULTS carrying at least one reason of each kind, so one output
  contradicting two stories counts once. `rate` is `nil` for an empty set: no
  measurement is not a zero rate.
  """
  @spec rate([Result.t()]) :: %{
          total: non_neg_integer(),
          escalated: non_neg_integer(),
          rate: float() | nil,
          by_reason: %{atom() => pos_integer()}
        }
  def rate(results) when is_list(results) do
    escalated = Enum.filter(results, fn %Result{decision: decision} -> decision == :escalate end)
    total = length(results)

    by_reason =
      escalated
      |> Enum.flat_map(fn %Result{reasons: reasons} ->
        reasons |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      end)
      |> Enum.frequencies()

    %{
      total: total,
      escalated: length(escalated),
      rate: if(total == 0, do: nil, else: length(escalated) / total),
      by_reason: by_reason
    }
  end

  defp build(reasons, valid, parsed) do
    decision = if reasons == [], do: :proceed, else: :escalate

    verdict =
      case {decision, valid} do
        {:proceed, [{_index, %{verdict: verdict}} | _rest]} -> verdict
        _ -> nil
      end

    soft_signals =
      for {index, %{codes: codes}} <- valid,
          code <- codes,
          not Map.has_key?(@gating_codes, code),
          do: {index, code}

    %Result{
      decision: decision,
      verdict: verdict,
      reasons: reasons,
      confidences: Enum.map(parsed, &confidence/1),
      soft_signals: soft_signals
    }
  end

  defp confidence({:ok, _index, %{confidence: confidence}}), do: confidence
  defp confidence({:error, _reason}), do: nil

  defp malformed_reasons(parsed), do: for({:error, reason} <- parsed, do: reason)

  defp disagreement_reasons(valid) do
    verdicts = Enum.map(valid, fn {_index, %{verdict: verdict}} -> verdict end)

    if verdicts |> Enum.uniq() |> length() > 1,
      do: [{:verdict_disagreement, verdicts}],
      else: []
  end

  defp agent_reasons({index, output}) do
    escalated = if output.verdict == :escalate, do: [{:agent_escalated, index}], else: []

    contradicted =
      if output.contradicts == [], do: [], else: [{:contradiction, index, output.contradicts}]

    gating =
      for code <- Enum.uniq(output.codes),
          Map.has_key?(@gating_codes, code),
          do: {Map.fetch!(@gating_codes, code), index}

    escalated ++ contradicted ++ gating
  end

  defp parse_output({output, index}) when is_map(output) do
    with {:ok, verdict} <- field(output, "verdict", &verdict/1),
         {:ok, codes} <- field(output, "escalation_reasons", &codes/1),
         {:ok, contradicts} <- field(output, "contradicts", &contradicts/1),
         {:ok, confidence} <- field(output, "confidence", &confidence_value/1) do
      {:ok, index,
       %{verdict: verdict, codes: codes, contradicts: contradicts, confidence: confidence}}
    else
      {:error, detail} -> {:error, {:malformed_output, index, detail}}
    end
  end

  defp parse_output({_output, index}), do: {:error, {:malformed_output, index, :not_a_map}}

  defp field(output, key, validate) do
    case Map.fetch(output, key) do
      {:ok, value} -> validate.(value)
      :error -> {:error, {:missing, key}}
    end
  end

  defp verdict(value) do
    case Map.fetch(@verdicts, value) do
      {:ok, verdict} -> {:ok, verdict}
      :error -> {:error, {:invalid, "verdict"}}
    end
  end

  defp codes(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {:ok, value},
      else: {:error, {:invalid, "escalation_reasons"}}
  end

  defp codes(_value), do: {:error, {:invalid, "escalation_reasons"}}

  defp contradicts(value) when is_list(value) do
    if Enum.all?(value, &contradiction?/1),
      do: {:ok, value},
      else: {:error, {:invalid, "contradicts"}}
  end

  defp contradicts(_value), do: {:error, {:invalid, "contradicts"}}

  defp contradiction?(%{"kind" => kind, "ref" => ref, "why" => why})
       when kind in @contradiction_kinds and is_binary(ref) and is_binary(why),
       do: true

  defp contradiction?(_value), do: false

  defp confidence_value(value) when is_number(value) and value >= 0 and value <= 1,
    do: {:ok, value}

  defp confidence_value(_value), do: {:error, {:invalid, "confidence"}}
end
