defmodule Loopctl.Delivery.StoryPayloadTest do
  @moduledoc """
  Contract 1.5.0: an `implement` dispatch carries the story as typed fields, and a story that
  will not fit the contract's caps is ESCALATED rather than truncated into a spec nobody
  wrote.

  Async: everything here is on the RLS `Loopctl.Repo` sandbox connection, like
  `Loopctl.Delivery.EscalationsTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.RunnerStory
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryPayload
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @epoch 7

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  # A story at `stage` with a claim at `@epoch`, plus whatever story attributes a test needs.
  defp staged(attrs \\ %{}, stage \\ :claimed) do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})

    story =
      case Map.to_list(attrs) do
        [] ->
          story

        changes ->
          as_tenant(story.tenant_id, fn ->
            {1, [updated]} =
              from(s in Story, where: s.id == ^story.id, select: s)
              |> Repo.update_all(set: changes)

            updated
          end)
      end

    fixture(:story_stage, %{
      tenant_id: story.tenant_id,
      story_id: story.id,
      stage: stage,
      claim_epoch: @epoch,
      # `story_stages_escalation_reason` requires one on a row already at `escalated`.
      escalation_reason: if(stage == :escalated, do: "an earlier reason")
    })

    story
  end

  defp opts(overrides \\ []) do
    Keyword.merge([claim_epoch: @epoch, actor_lineage: []], overrides)
  end

  defp long_story_attrs do
    # Over the OBJECT budget by acceptance criteria alone, every one of which is inside its
    # own per-item cap: the object cap is the one that binds, and it is the one that must
    # refuse rather than silently drop criterion 21.
    criteria =
      for index <- 1..RunnerStory.max_criteria() do
        %{
          "id" => "AC-#{index}",
          "description" => String.duplicate("x", RunnerStory.max_criterion_length() - 10)
        }
      end

    %{
      description: String.duplicate("d", RunnerStory.max_description_length() - 1),
      acceptance_criteria: criteria
    }
  end

  describe "build/3" do
    test "builds the object a dispatch carries, and the contract accepts it" do
      story =
        staged(%{
          title: "Round a visit's billable minutes up",
          description: "Bill 7 minutes as one unit.",
          acceptance_criteria: [%{"id" => "AC-1", "description" => "7 minutes is one unit."}]
        })

      assert {:ok, object} =
               StoryPayload.build(
                 story.tenant_id,
                 story.id,
                 opts(
                   touches: ["lib/home_care_billing/billing/visit.ex"],
                   domain_reference: "docs/architecture/timesheets.md",
                   test_cases: ["A visit of 7 minutes bills one unit."]
                 )
               )

      assert object["id"] == story.id
      assert object["title"] == "Round a visit's billable minutes up"
      assert object["acceptance_criteria"] == ["[AC-1] 7 minutes is one unit."]
      assert object["touches"] == ["lib/home_care_billing/billing/visit.ex"]
      assert object["domain_reference"] == "docs/architecture/timesheets.md"

      # The object is only worth anything if the wire takes it, so this goes through the
      # cast the dispatch path actually runs rather than stopping at the map.
      dispatch = build(:runner_dispatch, %{"story_id" => story.id, "story" => object})
      assert {:ok, %{story: cast}} = RunnerContract.cast_dispatch(dispatch)
      assert cast.id == story.id
    end

    test "the same story builds a byte-identical object every time" do
      # A re-dispatch of one dispatch_id must not carry a different story than the send it
      # repeats.
      story = staged()

      assert {:ok, first} = StoryPayload.build(story.tenant_id, story.id, opts())
      assert {:ok, second} = StoryPayload.build(story.tenant_id, story.id, opts())
      assert Jason.encode!(first) == Jason.encode!(second)
    end

    test "an oversize story is escalated and NOT dispatched" do
      story = staged(long_story_attrs())

      assert {:error, {:story_too_large, violations}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert Enum.any?(violations, &(&1 =~ "under the byte rule"))

      row = Stages.get(story.tenant_id, story.id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "exceeds the runner contract's caps"

      events = Stages.list_events(story.tenant_id, story.id)
      transition = Enum.find(events, &(&1.to_stage == "escalated"))
      assert transition.edge == "session_escalated"
      assert transition.data["payload"]["story_payload_violations"] == violations
    end

    test "a story already escalated is not escalated a second time" do
      story = staged(long_story_attrs(), :escalated)

      assert {:error, {:story_too_large, _}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert {:error, {:story_too_large, _}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      escalations =
        story.tenant_id
        |> Stages.list_events(story.id)
        |> Enum.count(&(&1.to_stage == "escalated"))

      assert escalations == 0
    end

    test "an oversize story whose stage has no escalation edge says so, loudly" do
      # `done` is terminal: there is no way out of it and nothing may pretend there is. The
      # caller still must not dispatch, so this is an error either way — a louder one,
      # because a story that is neither dispatchable nor parked is one nothing picks up.
      story = staged(long_story_attrs(), :done)

      assert {:error, {:escalation_failed, :invalid_transition, violations}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert violations != []
      assert Stages.get(story.tenant_id, story.id).stage == :done
    end

    test "a stale claim epoch refuses the escalation rather than writing under a dead claim" do
      story = staged(long_story_attrs())

      assert {:error, {:escalation_failed, :stale_claim_epoch, _}} =
               StoryPayload.build(story.tenant_id, story.id, opts(claim_epoch: @epoch + 1))

      assert Stages.get(story.tenant_id, story.id).stage == :claimed
    end

    test "an unknown story is not found" do
      story = staged()

      assert {:error, :not_found} =
               StoryPayload.build(story.tenant_id, Ecto.UUID.generate(), opts())
    end

    test "tenant isolation: another tenant's story is not found" do
      story = staged()
      other = staged()

      refute story.tenant_id == other.tenant_id

      assert {:error, :not_found} = StoryPayload.build(other.tenant_id, story.id, opts())
      assert {:ok, _} = StoryPayload.build(story.tenant_id, story.id, opts())
    end
  end

  describe "the field caps" do
    test "a title past its cap is refused by name, not trimmed" do
      story = staged(%{title: String.duplicate("t", RunnerStory.max_title_length() + 1)})

      assert {:error, {:story_too_large, violations}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert Enum.any?(violations, &(&1 =~ "title is longer than"))
    end

    test "one criterion too many is refused, and the twentieth is not dropped" do
      criteria =
        for index <- 1..(RunnerStory.max_criteria() + 1),
            do: %{"id" => "AC-#{index}", "description" => "c#{index}"}

      story = staged(%{acceptance_criteria: criteria})

      assert {:error, {:story_too_large, violations}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert Enum.any?(violations, &(&1 =~ "acceptance_criteria has more than"))
    end

    test "an option past its cap is refused too" do
      story = staged()

      for {key, value} <- [
            test_cases: [String.duplicate("t", RunnerStory.max_test_case_length() + 1)],
            touches: [String.duplicate("p", RunnerStory.max_touch_length() + 1)],
            domain_reference: String.duplicate("d", RunnerStory.max_domain_reference_length() + 1)
          ] do
        assert {:error, {:story_too_large, _}} =
                 StoryPayload.build(story.tenant_id, story.id, opts([{key, value}])),
               "expected #{key} past its cap to be refused"
      end
    end
  end
end
