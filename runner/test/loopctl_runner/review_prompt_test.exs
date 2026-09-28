defmodule LoopctlRunner.ReviewPromptTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Contract, ReviewPrompt, Session}

  test "the round ceiling it states is the contract's, never typed" do
    max = Contract.schema_def("RunnerReview")["properties"]["round"]["maximum"]

    review = %{
      "review_id" => Session.uuid4(),
      "round" => 2,
      "checkpoint_id" => Session.uuid4(),
      "checkpoint_seq" => 2,
      "commit_sha" => String.duplicate("a", 40),
      "tree_sha" => String.duplicate("b", 40)
    }

    prompt =
      ReviewPrompt.build(%{"id" => Session.uuid4(), "title" => "Add a greeting"}, review, %{
        repo: "mkreyman/fixture",
        branch: "loop/story-1",
        base: "origin/master",
        token: "tok"
      })

    assert is_integer(max)
    assert prompt =~ "round 2 of at most #{max}\n"
  end

  test "after round 1, introduced_by is the checkpoint under review or none, and nothing else" do
    checkpoint = Session.uuid4()

    build = fn round ->
      review = %{
        "review_id" => Session.uuid4(),
        "round" => round,
        "checkpoint_id" => checkpoint,
        "checkpoint_seq" => 2,
        "commit_sha" => String.duplicate("a", 40),
        "tree_sha" => String.duplicate("b", 40)
      }

      ReviewPrompt.build(%{"id" => Session.uuid4(), "title" => "Add a greeting"}, review, %{
        repo: "mkreyman/fixture",
        branch: "loop/story-1",
        base: "origin/master",
        token: "tok"
      })
    end

    later = build.(2)
    assert later =~ "--introduced-by <#{checkpoint}|none>"
    assert later =~ "`#{checkpoint}`, this checkpoint's id"
    assert later =~ "No other id is accepted"

    refute build.(1) =~ "--introduced-by <"
  end
end
