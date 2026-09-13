defmodule Loopctl.Delivery.StageMachineTest do
  @moduledoc """
  Issue #803: the stage machine's table and the facts derived from it. The table itself is
  exercised against the database in `Loopctl.Delivery.StagesTest`, which enumerates
  `StageMachine.transitions/0`; this file pins the shape the design (§3) requires and the
  binding between the table and the migration's CHECK.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Delivery.StageMachine

  @main_line ~w(detected triaged queued claimed worktree implementing reviewing pr_open ci
                merged deployed verified done)a

  test "every main-line step is a forward transition, and there are no other forward ones" do
    expected =
      @main_line
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [f, t] -> {f, t, :forward} end)

    forward = for {_f, _t, :forward} = t <- StageMachine.transitions(), do: t
    assert forward == expected
  end

  test "the failure edges named by the design are in the table" do
    for triple <- [
          {:ci, :implementing, :ci_red},
          {:reviewing, :implementing, :review_findings},
          {:ci, :implementing, :base_moved},
          {:deployed, :escalated, :verification_failed},
          {:triaged, :escalated, :triage_escalate},
          {:ci, :escalated, :merge_gate},
          {:merged, :implementing, :merge_refused},
          {:implementing, :failed, :budget_exceeded},
          {:implementing, :queued, :runner_lost}
        ] do
      assert triple in StageMachine.transitions(), inspect(triple)
    end
  end

  test "done and failed have no way out, and escalated only a human's" do
    for {from, _to, edge} <- StageMachine.transitions(), from in [:done, :failed, :escalated] do
      assert from == :escalated and edge == :human_resolution
    end

    assert Enum.any?(StageMachine.transitions(), &match?({:escalated, _, :human_resolution}, &1))
  end

  test "runner_lost leaves only from in-flight stages, never from merged on" do
    sources = for {from, :queued, :runner_lost} <- StageMachine.transitions(), do: from
    assert Enum.sort(sources) == Enum.sort(StageMachine.in_flight_stages())
    refute Enum.any?(sources, &(&1 in [:merged, :deployed, :verified]))
  end

  test "the merge identity is writable at the stage that performs the merge" do
    # Recording it only at `merged` left the merge with no replay identity.
    assert :ci in StageMachine.effect_stages(:merge_sha)
    assert :merged in StageMachine.effect_stages(:merge_sha)
  end

  test "a refused merge clears the identity it never realised" do
    assert StageMachine.clears(:merged, :implementing, :merge_refused) == [:head_sha, :merge_sha]
  end

  test "every stage is reachable from detected" do
    reachable = reach([:detected], MapSet.new([:detected]))
    assert MapSet.equal?(reachable, MapSet.new(StageMachine.stages()))
  end

  test "the audit chain takes exactly claim, merge, escalate and the way out of escalation" do
    chained =
      for {f, t, _e} <- StageMachine.transitions(), StageMachine.chained?(f, t), do: {f, t}

    assert Enum.all?(chained, fn {f, t} ->
             t in [:claimed, :merged, :escalated] or f == :escalated
           end)

    refute StageMachine.chained?(:implementing, :reviewing)
    refute StageMachine.chained?(:ci, :implementing)
  end

  test "the migration's stage CHECK allows exactly StageMachine.stages/0" do
    [[definition]] =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'story_stages_stage'"
      ).rows

    in_check =
      ~r/'([a-z_]+)'/
      |> Regex.scan(definition, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_existing_atom/1)

    assert Enum.sort(in_check) == Enum.sort(StageMachine.stages())
  end

  defp reach([], seen), do: seen

  defp reach([stage | rest], seen) do
    next =
      for {^stage, to, _edge} <- StageMachine.transitions(), not MapSet.member?(seen, to), do: to

    reach(rest ++ Enum.uniq(next), MapSet.union(seen, MapSet.new(next)))
  end
end
