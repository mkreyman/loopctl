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

  test "session_escalated leaves from every in-flight stage and no other" do
    sources = for {from, :escalated, :session_escalated} <- StageMachine.transitions(), do: from
    assert Enum.sort(sources) == Enum.sort(StageMachine.in_flight_stages())

    # Not from `merged` on: the outward effect has happened and no session holds the story.
    refute Enum.any?(sources, &(&1 in [:merged, :deployed, :verified]))
    # And not from `triaged`, which has its own verdict edge with its own meaning.
    refute :triaged in sources
  end

  test "the runner-reportable subset holds back exactly what a runner must not report" do
    reportable = StageMachine.runner_transitions()

    # Nothing out of a stage no session holds, so an escalated story cannot be moved back by
    # the session that was escalated away from.
    for {from, _to, _edge} <- reportable do
      refute from in [:detected, :triaged, :queued, :escalated, :done, :failed]
    end

    # Nothing INTO `claimed` — that transition writes `runner_id` and a chain entry, and it
    # is control's, alongside the claim itself.
    refute Enum.any?(reportable, &match?({_, :claimed, _}, &1))

    # And never the three edges another principal owns.
    for edge <- [:runner_lost, :claim_released, :human_resolution] do
      refute Enum.any?(reportable, &match?({_, _, ^edge}, &1))
    end

    # What is left is a real subset of the machine, not a second table.
    assert reportable -- StageMachine.transitions() == []
    assert {:implementing, :reviewing, :forward} in reportable
    assert {:ci, :merged, :forward} in reportable
    assert {:implementing, :escalated, :session_escalated} in reportable
    assert StageMachine.runner_reportable?(:ci, :implementing, :ci_red)
    refute StageMachine.runner_reportable?(:queued, :claimed, :forward)
  end

  test "the published from/to/edge lists are the reportable table's own projections" do
    reportable = StageMachine.runner_transitions()

    assert Enum.sort(StageMachine.runner_from_stages()) ==
             reportable |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    assert Enum.sort(StageMachine.runner_to_stages()) ==
             reportable |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    assert Enum.sort(StageMachine.runner_edges()) ==
             reportable |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()
  end

  test "ends_session? is exactly the terminal stages, and no live one" do
    for stage <- StageMachine.stages() do
      assert StageMachine.ends_session?(stage) == stage in StageMachine.terminal_stages()
    end

    assert StageMachine.ends_session?(:escalated)
    refute StageMachine.ends_session?(:merged)
    refute StageMachine.ends_session?(:verified)
  end

  test "the merge identity is writable only at merged, where the sha exists" do
    # A merge commit does not exist until GitHub merges, so a sha written at `ci` would be
    # one the caller never obtained. Replay safety comes from pr_number + head_sha instead.
    assert StageMachine.effect_stages(:merge_sha) == [:merged]
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
      for {f, t, e} <- StageMachine.transitions(), StageMachine.chained?(f, t, e), do: {f, t, e}

    assert Enum.all?(chained, fn {f, t, e} ->
             t in [:claimed, :merged, :escalated] or f == :escalated or e == :merge_refused
           end)

    refute StageMachine.chained?(:implementing, :reviewing, :forward)
    refute StageMachine.chained?(:ci, :implementing, :ci_red)

    # A merge is a chained fact, so retracting it writes a counter-entry.
    assert StageMachine.chained?(:merged, :implementing, :merge_refused)
    assert StageMachine.reason_required?(:implementing, :merge_refused)
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
