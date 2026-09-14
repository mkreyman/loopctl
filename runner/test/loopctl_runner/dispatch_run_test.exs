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

  test "the binding names the dispatch, its epoch and its story" do
    assert DispatchRun.binding(@dispatch) == %{
             "dispatch_id" => @dispatch["dispatch_id"],
             "claim_epoch" => 3,
             "story_id" => @story_id
           }
  end

  describe "the end of a run" do
    test "a finished run's reason is exactly the merge-nothing sentence" do
      assert DispatchRun.end_reason(%{status: "succeeded", escalations: []}) ==
               "first end-to-end run: implementation finished, merging nothing by design"
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
