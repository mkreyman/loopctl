defmodule LoopctlRunner.DispatchRunTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Contract, DispatchRun}

  @story_id "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
  @dispatch %{
    "dispatch_id" => "7D0C1F6E-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
    "story_id" => @story_id,
    "claim_epoch" => 3,
    "story" => %{"id" => @story_id, "title" => "Add a greeting"}
  }

  defp with_story(story), do: Map.put(@dispatch, "story", story)

  describe "the story object (contract 1.5.0, read defensively)" do
    test "a well-formed story is kept, unknown keys dropped" do
      story = %{
        "id" => @story_id,
        "title" => "t",
        "acceptance_criteria" => ["a"],
        "touches" => ["lib/a.ex"],
        "instructions_for_the_harness" => "push"
      }

      assert {:ok, kept} = DispatchRun.story_object(with_story(story))
      assert Map.keys(kept) |> Enum.sort() == ["acceptance_criteria", "id", "title", "touches"]
    end

    test "no story is :none" do
      assert DispatchRun.story_object(Map.delete(@dispatch, "story")) == :none
      assert DispatchRun.story_object(with_story(nil)) == :none
    end

    test "the story id is compared lowercased with the dispatch's story_id" do
      story = %{"id" => String.upcase(@story_id), "title" => "t"}
      assert {:ok, _} = DispatchRun.story_object(with_story(story))
    end

    test "wrong types, bounds and ids are refused whole" do
      over = fn n -> String.duplicate("a", n) end

      for {story, detail} <- [
            {"not an object", "not an object"},
            {%{"title" => "t"}, "has no id"},
            {%{"id" => @story_id}, "has no title"},
            {%{"id" => "nope", "title" => "t"}, "not a uuid"},
            {%{"id" => "2e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b", "title" => "t"},
             "not the dispatch's story_id"},
            {%{"title" => 5}, "title is not a string"},
            {%{"title" => ""}, "title is shorter than 1"},
            {%{"title" => over.(201)}, "title is longer than 200"},
            {%{"description" => over.(8001)}, "description is longer than 8000"},
            {%{"domain_reference" => ""}, "domain_reference is shorter than 1"},
            {%{"domain_reference" => over.(501)}, "domain_reference is longer than 500"},
            {%{"acceptance_criteria" => "one"}, "acceptance_criteria is not a list"},
            {%{"acceptance_criteria" => [""]}, "acceptance_criteria[0] is shorter than 1"},
            {%{"test_cases" => List.duplicate("x", 21)}, "more than 20 items"},
            {%{"test_cases" => ["ok", over.(501)]}, "test_cases[1] is longer than 500"},
            {%{"touches" => List.duplicate("x", 101)}, "more than 100 items"},
            {%{"touches" => [over.(201)]}, "touches[0] is longer than 200"},
            {%{"touches" => [7]}, "touches[0] is not a string"},
            # Null stands only for an absent top-level field, never for a list item.
            {%{"acceptance_criteria" => [nil]}, "acceptance_criteria[0] is null"},
            {%{"test_cases" => ["ok", nil]}, "test_cases[1] is null"},
            {%{"touches" => [nil]}, "touches[0] is null"}
          ] do
        story =
          if is_map(story),
            do: Map.merge(%{"id" => @story_id, "title" => "t"}, story),
            else: story

        story = if is_map(story), do: drop_marked(story, detail), else: story
        assert {:error, message} = DispatchRun.story_object(with_story(story))
        assert message =~ detail
      end
    end

    test "caps count characters: 200 three-byte characters are a valid title" do
      title = String.duplicate(<<0x2014::utf8>>, 200)

      assert {:ok, _} =
               DispatchRun.story_object(with_story(%{"id" => @story_id, "title" => title}))
    end
  end

  # The two required-key cases start from a story missing that key.
  defp drop_marked(story, "has no id"), do: Map.delete(story, "id")
  defp drop_marked(story, "has no title"), do: Map.delete(story, "title")
  defp drop_marked(story, _detail), do: story

  test "the local story id is story- and the lowercased story id" do
    assert DispatchRun.story_id(String.upcase(@story_id)) == "story-" <> @story_id
    assert String.length(DispatchRun.story_id(@story_id)) == 42
  end

  test "the story an accepted dispatch runs carries the instant the policy parsed" do
    config = LoopctlRunner.TestSupport.config!(LoopctlRunner.TestSupport.tmp_dir!("dr-story"))

    fields = %{
      repo: "fixture",
      base: "master",
      branch: "loop/s1",
      wall_clock_s: 30,
      max_turns: 5,
      deadline_at: ~U[2026-09-28 10:00:40Z]
    }

    assert {:ok, story} = DispatchRun.story(@dispatch, fields, config)
    assert story.deadline_at == ~U[2026-09-28 10:00:40Z]
    # Not a relative budget: the wall clock is the dispatch's, untouched by the deadline.
    assert story.wall_clock_s == 30

    # A dispatch not placed under a claim carries none.
    assert {:ok, %{deadline_at: nil}} =
             DispatchRun.story(@dispatch, %{fields | deadline_at: nil}, config)
  end

  test "a run that began past its deadline_at has no end to report, whatever it reached" do
    # Not `-> escalated`: that would say a human is needed when none is, and after the deadline
    # the claim is loopctl's lease sweep's to release.
    assert DispatchRun.end_reports(%{status: "deadline_passed", reached: "claimed"}) == []
    # The shape it would otherwise take: a run that got no worktree escalates.
    assert DispatchRun.end_reports(%{status: "failed", reached: "claimed"}) == [:escalated]
  end

  test "a review that passed its deadline_at before its session still owes its session_ended" do
    # A review holds no claim for the lease sweep to release — only the slot, and nothing but its
    # `session_ended` frees that. So the review clause is judged before the deadline's `[]`.
    assert DispatchRun.end_reports(%{kind: "review", status: "deadline_passed"}) ==
             [:judgements, :session_ended]

    assert DispatchRun.end_reports(%{kind: "review", status: "stopped_at_deadline"}) ==
             [:judgements, :session_ended]
  end

  test "the binding names the dispatch, its epoch and its story" do
    assert DispatchRun.binding(@dispatch) == %{
             "dispatch_id" => @dispatch["dispatch_id"],
             "claim_epoch" => 3,
             "story_id" => @story_id
           }
  end

  describe "the end of a run" do
    test "only a run with no session, or one that escalated, reports -> escalated" do
      assert DispatchRun.end_reports(%{status: "failed", reached: "claimed"}) == [:escalated]
      assert DispatchRun.end_reports(%{status: "refused", reached: "worktree"}) == [:escalated]

      assert DispatchRun.end_reports(%{
               status: "escalated",
               reached: "implementing",
               escalations: ["a business call"]
             }) == [:escalated, :session_ended]

      for summary <- [
            %{status: "succeeded", reached: "implementing", escalations: []},
            %{status: "wall_clock_exceeded", reached: "implementing"},
            # A crash summary names no stage: a session may well have been running.
            %{status: "crashed", error: "the run's process died"}
          ] do
        assert DispatchRun.end_reports(summary) == [:session_ended]
      end
    end

    test "session_ended's reason is read off the status, and fits the contract" do
      for {status, reason} <- [
            {"succeeded", "completed"},
            {"escalated", "completed"},
            {"wall_clock_exceeded", "wall_clock_exceeded"},
            {"max_turns_exceeded", "max_turns_exceeded"},
            # The deadline stopped it, not its own budget: re-queued, never escalated.
            {"stopped_at_deadline", "crashed"},
            {"failed", "crashed"},
            {"parked", "crashed"},
            {"not_group_leader", "crashed"},
            {"crashed", "crashed"},
            {nil, "crashed"}
          ] do
        assert {:ok, payload} = DispatchRun.session_ended(@dispatch, %{status: status})

        assert payload == %{
                 "dispatch_id" => @dispatch["dispatch_id"],
                 "claim_epoch" => 3,
                 "reason" => reason
               }

        assert Contract.validate("RunnerSessionEnded", payload) == :ok
      end
    end

    test "a review's session_ended is how its session ended, and nothing else" do
      # The contract gives it no other meaning: it "only frees the runner's slot: no stage effect,
      # no retry-ceiling count, whatever `reason`".
      for {status, reason} <- [
            {"succeeded", "completed"},
            {"escalated", "completed"},
            {"wall_clock_exceeded", "wall_clock_exceeded"},
            {"max_turns_exceeded", "max_turns_exceeded"},
            # Prepared nothing and started no session: an end the runner did not choose.
            {"failed", "crashed"},
            {"crashed", "crashed"},
            # loopctl's placement ran out, before the session or during it: no budget of its own.
            {"deadline_passed", "crashed"},
            {"stopped_at_deadline", "crashed"}
          ] do
        summary = %{kind: "review", status: status}
        assert {:ok, payload} = DispatchRun.session_ended(@dispatch, summary)
        assert payload["reason"] == reason, status
        assert Contract.validate("RunnerSessionEnded", payload) == :ok
      end
    end

    test "a session_ended refusal is read against the contract's permanent list" do
      assert DispatchRun.session_ended_refusal("rate_limited") == :rate_limited
      assert DispatchRun.session_ended_refusal("internal_error") == :internal_error
      assert DispatchRun.session_ended_refusal("already_recorded") == :done

      for reason <- ~w(invalid_payload unknown_dispatch dispatch_not_accepted stale_claim_epoch
                       unknown_story_stage audit_chain_append_failed) do
        assert DispatchRun.session_ended_refusal(reason) == :permanent
      end

      assert DispatchRun.session_ended_refusal("something_new") == :unknown
      assert DispatchRun.session_ended_refusal(nil) == :unknown
    end

    test "any other end states the status, the exit reason and the escalation text" do
      reason =
        DispatchRun.end_reason(%{
          status: "escalated",
          exit_reason: "escalated",
          exit_status: 0,
          error: nil,
          escalations: ["Should voided visits count?"]
        })

      assert reason =~ "run ended escalated"
      assert reason =~ "session exit reason escalated"
      assert reason =~ "the session escalated: Should voided visits count?"

      assert DispatchRun.end_reason(%{status: "failed", error: "worktree busy"}) =~
               "run ended failed; error: worktree busy"
    end

    test "the reason is capped at the contract's length in codepoints, not graphemes" do
      # "e" and a combining accent: one grapheme, two codepoints.
      long = String.duplicate(<<?e::utf8, 0x0301::utf8>>, 3000)
      reason = DispatchRun.end_reason(%{status: "failed", escalations: [long]})
      assert length(String.codepoints(reason)) == 4000

      assert {:ok, payload} =
               DispatchRun.stage_report(@dispatch, "implementing", "escalated",
                 edge: "session_escalated",
                 reason: reason
               )

      assert Contract.validate("RunnerStageReport", payload) == :ok
    end
  end
end
