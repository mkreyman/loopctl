defmodule LoopctlRunner.DispatchShapeTest do
  @moduledoc """
  US-48.13, contract 1.30.0: `story_id` left the schema's `required`, so what the schema no longer
  says is held here, in both directions, for every kind loopctl sends.
  """

  use ExUnit.Case, async: true

  alias LoopctlRunner.{Contract, DispatchShape}

  @dispatch_id "0f1e2d3c-4b5a-4697-8877-665544332211"
  @story_id "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"

  @trace %{
    "trace_id" => "5a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
    "failures" => ["human_override"],
    "agent_decision" => %{"outcome" => "agent_result"},
    "human_decision" => %{"route" => "reply", "outcomes" => ["no_result"]},
    "untrusted" => "<<<UNTRUSTED story_text a1>>>\n| text\n<<<END UNTRUSTED story_text a1>>>"
  }

  defp tune(overrides \\ %{}) do
    Map.merge(
      %{
        "target" => %{"id" => "reply_draft", "version" => 1},
        "template" => %{"id" => "reply_draft", "version" => 1},
        "eval_set" => "reply_draft@1",
        "window" => %{"since" => nil, "until" => "2026-11-07T06:00:00Z"},
        "outcome_rows" => 24,
        "traces" => [@trace]
      },
      overrides
    )
  end

  defp spec_tune_dispatch(overrides \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => @dispatch_id,
        "kind" => "spec_tune",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        "branch" => "master",
        "claim_epoch" => 0,
        "wall_clock_seconds" => 1200,
        "max_turns" => 40,
        "spec_tune" => tune()
      },
      overrides
    )
  end

  test "a well-formed spec_tune dispatch passes the schema and the shape" do
    dispatch = spec_tune_dispatch()
    assert Contract.validate("RunnerDispatch", dispatch) == :ok
    assert DispatchShape.errors(dispatch) == []
  end

  test "spec_tune is the one story-less kind, and loopctl sends it" do
    assert DispatchShape.storyless_kinds() == ["spec_tune"]
    assert "spec_tune" in Contract.connection()["dispatchable_kinds"]
  end

  test "a spec_tune that carries a story_id is refused" do
    dispatch = spec_tune_dispatch(%{"story_id" => @story_id})

    assert DispatchShape.errors(dispatch) == [
             "a spec_tune dispatch names no story: story_id is not allowed"
           ]
  end

  test "a spec_tune with any claim_epoch but 0 is refused" do
    assert DispatchShape.errors(spec_tune_dispatch(%{"claim_epoch" => 1})) == [
             "a spec_tune dispatch claims nothing: claim_epoch must be 0"
           ]
  end

  test "a spec_tune with no spec_tune object is refused" do
    dispatch = Map.delete(spec_tune_dispatch(), "spec_tune")

    assert DispatchShape.errors(dispatch) == [
             "a spec_tune dispatch must carry the spec_tune object"
           ]
  end

  test "a spec_tune with no traces, or a trace with no failure, is refused" do
    assert DispatchShape.errors(spec_tune_dispatch(%{"spec_tune" => tune(%{"traces" => []})})) ==
             ["spec_tune.traces must hold at least one trace"]

    bare = Map.put(@trace, "failures", [])

    assert DispatchShape.errors(spec_tune_dispatch(%{"spec_tune" => tune(%{"traces" => [bare]})})) ==
             ["every spec_tune trace must name at least one failure"]
  end

  test "a spec_tune object over the byte rule's cap is refused" do
    # Eight traces of 1500 characters each sit inside every field cap and far over the object's.
    big = for _ <- 1..8, do: Map.put(@trace, "untrusted", String.duplicate("x", 1500))
    dispatch = spec_tune_dispatch(%{"spec_tune" => tune(%{"traces" => big})})

    assert DispatchShape.errors(dispatch) == [
             "spec_tune exceeds #{DispatchShape.max_spec_tune_bytes()} bytes under the byte rule"
           ]
  end

  for kind <- ["implement", "triage", "reply_draft", "verify"] do
    test "a #{kind} dispatch without a story_id is refused" do
      dispatch = %{"kind" => unquote(kind), "dispatch_id" => @dispatch_id, "claim_epoch" => 3}

      assert DispatchShape.errors(dispatch) == [
               "a #{unquote(kind)} dispatch must carry story_id"
             ]
    end

    test "a #{kind} dispatch carrying a spec_tune object is refused" do
      dispatch = %{
        "kind" => unquote(kind),
        "dispatch_id" => @dispatch_id,
        "story_id" => @story_id,
        "claim_epoch" => 3,
        "spec_tune" => tune()
      }

      assert DispatchShape.errors(dispatch) == [
               "spec_tune is only allowed when kind is spec_tune"
             ]
    end

    test "a #{kind} dispatch with a story_id and no spec_tune passes" do
      dispatch = %{
        "kind" => unquote(kind),
        "dispatch_id" => @dispatch_id,
        "story_id" => @story_id,
        "claim_epoch" => 3
      }

      assert DispatchShape.errors(dispatch) == []
    end
  end

  test "every kind loopctl sends is judged one way or the other" do
    for kind <- Contract.connection()["dispatchable_kinds"] do
      without = %{"kind" => kind, "dispatch_id" => @dispatch_id, "claim_epoch" => 0}
      # A story-less kind lacks its object; every other lacks its story. Neither passes bare.
      assert DispatchShape.errors(without) != [], kind
    end
  end
end
