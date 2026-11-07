defmodule LoopctlRunner.DispatchShape do
  @moduledoc """
  What a `RunnerDispatch` must be beyond its schema (contract 1.30.0, US-48.13). Pure.

  Since 1.30.0 `story_id` is no longer schema-required, because ONE kind names no story:
  `spec_tune`, the improvement loop's tuning run, which proposes a better template for a spec
  from that spec's failed runs and touches no story at all. The rule that replaced the schema's
  `required` is loopctl's code (`Loopctl.ApiSpec.RunnerContract.story_id_errors/1` and
  `spec_tune_errors/1`), and the runner holds the same rule in both directions here, because a
  dispatch the schema now admits is not one this runner may run:

    * a story-less kind (`spec_tune`) that carries a `story_id` is refused — a tuning run must
      never be mistaken for work on that story;
    * a story-less kind whose `claim_epoch` is not `0` is refused — it claims nothing;
    * every OTHER kind that lacks a `story_id` is refused — an implement, triage, reply_draft or
      verify dispatch with no story would name a run nothing can bind;
    * the `spec_tune` object rides a `spec_tune` dispatch and no other, and that dispatch must
      carry it: under the byte rule's cap (`limits.spec_tune.max_bytes`), with at least one trace,
      and every trace naming at least one failure.

  Every refusal is `other`: the dispatch is malformed, not of a kind this runner does not run.
  """

  alias LoopctlRunner.{ByteRule, Contract}

  @storyless ["spec_tune"]

  # Every story-less kind must be one loopctl sends: a story-less rule for a kind nothing
  # dispatches is a rule nothing tests on the wire.
  for kind <- @storyless,
      kind not in Map.fetch!(Contract.connection(), "dispatchable_kinds") do
    raise "#{kind} is story-less here but not in the vendored contract's dispatchable_kinds"
  end

  @max_spec_tune_bytes get_in(Contract.connection(), ["limits", "spec_tune", "max_bytes"]) ||
                         raise("the vendored contract publishes no limits.spec_tune.max_bytes")

  @doc "The kinds that name no story: their dispatch carries no `story_id` and claims nothing."
  @spec storyless_kinds() :: [String.t()]
  def storyless_kinds, do: @storyless

  @doc "Whether `kind` names no story."
  @spec storyless?(term()) :: boolean()
  def storyless?(kind), do: kind in @storyless

  @doc "The `spec_tune` object's cap under the byte rule, as the contract publishes it."
  @spec max_spec_tune_bytes() :: pos_integer()
  def max_spec_tune_bytes, do: @max_spec_tune_bytes

  @doc """
  The cross-field errors of a dispatch that already passed `Contract.validate("RunnerDispatch",
  _)`: `[]` when it is one this runner may decide on, else the reasons, in the runner's words.
  """
  @spec errors(map()) :: [String.t()]
  def errors(%{"kind" => kind} = dispatch) when is_binary(kind) do
    story_id_errors(dispatch, kind) ++ spec_tune_errors(dispatch, kind)
  end

  def errors(_dispatch), do: []

  defp story_id_errors(dispatch, kind) do
    storyless? = storyless?(kind)
    has_story_id? = Map.has_key?(dispatch, "story_id")

    cond do
      storyless? and has_story_id? ->
        ["a #{kind} dispatch names no story: story_id is not allowed"]

      storyless? and dispatch["claim_epoch"] != 0 ->
        ["a #{kind} dispatch claims nothing: claim_epoch must be 0"]

      not storyless? and not has_story_id? ->
        ["a #{kind} dispatch must carry story_id"]

      true ->
        []
    end
  end

  defp spec_tune_errors(%{"spec_tune" => spec_tune}, kind) do
    cond do
      not storyless?(kind) ->
        ["spec_tune is only allowed when kind is " <> Enum.join(@storyless, " or ")]

      ByteRule.bytes(spec_tune) > @max_spec_tune_bytes ->
        ["spec_tune exceeds #{@max_spec_tune_bytes} bytes under the byte rule"]

      traces(spec_tune) == [] ->
        ["spec_tune.traces must hold at least one trace"]

      Enum.any?(traces(spec_tune), &(Map.get(&1, "failures", []) == [])) ->
        ["every spec_tune trace must name at least one failure"]

      true ->
        []
    end
  end

  defp spec_tune_errors(_dispatch, kind) do
    if storyless?(kind),
      do: ["a #{kind} dispatch must carry the spec_tune object"],
      else: []
  end

  defp traces(%{"traces" => traces}) when is_list(traces), do: traces
  defp traces(_spec_tune), do: []
end
