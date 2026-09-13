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

  test "session_escalated leaves from every in-flight stage, plus merged and deployed" do
    sources = for {from, :escalated, :session_escalated} <- StageMachine.transitions(), do: from

    assert Enum.sort(sources) ==
             Enum.sort(StageMachine.in_flight_stages() ++ [:merged, :deployed])

    # `merged` and `deployed` are here because they would otherwise be ABSORBING (#824 round
    # 3, H2), not because a session holds the story there.
    #
    # `verified` is NOT: it is control's, reached only by control's own `deployed -> verified`,
    # and `verified -> done` follows. Nothing a session does leaves it.
    refute :verified in sources
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

    # And never an edge another principal owns.
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

  test "a runner cannot report a verdict SOMEBODY ELSE reaches about its session" do
    # #824 round 1, finding 2. The set was a blocklist and silently admitted all three of
    # these, so a runner could write a chain entry asserting a control-side gate ruling that
    # never ran — and, worse, park a story in a stage with no way out.
    reportable = StageMachine.runner_transitions()

    # The merge-precondition gate (design §5) is control's; the gates compute their own
    # triggers and never read an agent's negative.
    refute {:ci, :escalated, :merge_gate} in reportable
    refute StageMachine.runner_reportable?(:ci, :escalated, :merge_gate)

    # Post-deploy verification (design §9) compares the deployed sha against the merge
    # commit — a comparison the session cannot see.
    refute {:deployed, :escalated, :verification_failed} in reportable
    refute StageMachine.runner_reportable?(:deployed, :escalated, :verification_failed)

    # And `failed` is terminal with NO way out, `:human_resolution` included, so a runner
    # able to report `:budget_exceeded` could park a story for good.
    refute Enum.any?(reportable, &match?({_, :failed, _}, &1))
    refute Enum.any?(reportable, &match?({_, _, :budget_exceeded}, &1))
    refute :failed in StageMachine.runner_to_stages()

    # The three above are real transitions the machine has — this test is about who may
    # report them, not about whether they exist.
    for triple <- [
          {:ci, :escalated, :merge_gate},
          {:deployed, :escalated, :verification_failed},
          {:implementing, :failed, :budget_exceeded}
        ] do
      assert triple in StageMachine.transitions(), inspect(triple)
    end
  end

  test "a runner cannot certify its OWN work: no path to verified or done" do
    # #824 round 2, H1. The edge allowlist alone left `deployed -> verified -> done` on
    # `:forward`, so a session could drive its own story to terminal SUCCESS with no
    # control-side verification — while `verification_failed` was held back on the grounds
    # that the check is control's. A session able to report a check passing but not failing
    # is worse than one able to report neither: `RunnerStages` and `Escalations` are the only
    # callers of `advance/4`, so the positive was the only outcome that could ever be written.
    reportable = StageMachine.runner_transitions()

    refute {:deployed, :verified, :forward} in reportable
    refute {:verified, :done, :forward} in reportable
    refute StageMachine.runner_reportable?(:deployed, :verified, :forward)
    refute StageMachine.runner_reportable?(:verified, :done, :forward)

    # Neither stage is a SOURCE at all, which is what makes the exclusion hold for any edge
    # added out of them later rather than for these two triples.
    refute :deployed in StageMachine.runner_source_stages()
    refute :verified in StageMachine.runner_source_stages()

    # And neither is reachable as a destination that a runner reports INTO.
    refute :verified in StageMachine.runner_to_stages()
    refute :done in StageMachine.runner_to_stages()

    # The only TERMINAL a runner can now reach is `escalated`, which STOPS the loop rather
    # than completing it — the fail-safe direction. `deployed` also ends the SESSION (H1) but
    # is not terminal: the story goes on, waiting on control.
    terminal_reachable =
      StageMachine.runner_to_stages() |> Enum.filter(&(&1 in StageMachine.terminal_stages()))

    assert terminal_reachable == [:escalated]

    session_ends = StageMachine.runner_to_stages() |> Enum.filter(&StageMachine.ends_session?/1)
    assert Enum.sort(session_ends) == [:deployed, :escalated]

    # The line is at the deploy, and the deploy itself stays reportable: it names a
    # `release_id`, and `merged` names a `merge_sha`, both of which control can check.
    # A story WAITS at `deployed` for control to decide verified-or-escalated.
    assert {:ci, :merged, :forward} in reportable
    assert {:merged, :deployed, :forward} in reportable
    assert :deployed in StageMachine.runner_to_stages()

    # Both of these are real transitions. The test is about who may report them.
    assert {:deployed, :verified, :forward} in StageMachine.transitions()
    assert {:verified, :done, :forward} in StageMachine.transitions()
  end

  test "the reportable edge list is an ALLOWLIST, so a new edge is unreportable by default" do
    # The definition the doc, the wire enums and the published table all derive from. Written
    # as a blocklist it admitted three transitions nobody had thought to exclude; as an
    # allowlist a new edge stays out until somebody decides it is a session's to report.
    assert Enum.sort(StageMachine.runner_reportable_edges()) ==
             Enum.sort([
               :forward,
               :ci_red,
               :review_findings,
               :base_moved,
               :merge_refused,
               :session_escalated
             ])

    for {_from, _to, edge} <- StageMachine.runner_transitions() do
      assert edge in StageMachine.runner_reportable_edges()
    end

    for {from, _to, _edge} <- StageMachine.runner_transitions() do
      assert from in StageMachine.runner_source_stages()
    end

    # And the set really is the two filters applied to the machine, not a hand-kept list.
    assert StageMachine.runner_transitions() ==
             for(
               {from, to, edge} <- StageMachine.transitions(),
               from in StageMachine.runner_source_stages(),
               edge in StageMachine.runner_reportable_edges(),
               do: {from, to, edge}
             )
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

  test "the session ends at the deploy as well as at the terminals" do
    # #824 round 3, H1. The set was the terminals alone, which was right while a runner could
    # report through `verified -> done`; once the source filter stopped at `merged` the last
    # thing a session reports is the DEPLOY, and `deployed` is not terminal — so the SUCCESS
    # path released no slot inline and waited out heal's wall-clock bound. The session ending
    # is not the story ending, and that is the distinction the set now draws.
    assert Enum.sort(StageMachine.session_ends_at()) ==
             Enum.sort(StageMachine.terminal_stages() ++ [:deployed])

    for stage <- StageMachine.stages() do
      assert StageMachine.ends_session?(stage) == stage in StageMachine.session_ends_at()
    end

    assert StageMachine.ends_session?(:deployed)
    assert StageMachine.ends_session?(:escalated)

    # The story continues from `deployed` — it waits on control for `verified`. Neither of
    # those is a session end.
    refute StageMachine.ends_session?(:merged)
    refute StageMachine.ends_session?(:verified)
    refute :deployed in StageMachine.terminal_stages()
  end

  test "merged and deployed are not absorbing: a session can escalate out of both" do
    # #824 round 3, H2. Nothing in `lib/` could write any edge out of `deployed`, so the row
    # froze for every principal the moment a deploy was reported.
    for stage <- [:merged, :deployed] do
      assert StageMachine.allowed?(stage, :escalated, :session_escalated),
             "#{stage} has no session escalation and nothing else can leave it"
    end

    # And escalating restores the human path, which is the point.
    for to <- [:queued, :done, :failed] do
      assert StageMachine.allowed?(:escalated, to, :human_resolution)
    end

    # `deployed -> verified` stays for the control writer that does not exist yet.
    assert StageMachine.allowed?(:deployed, :verified, :forward)
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
