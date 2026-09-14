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
  import ExUnit.CaptureLog

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.RunnerStory
  alias Loopctl.Delivery.StageMachine
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

      assert {:error, {:story_not_dispatchable, violations}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert Enum.any?(violations, &(&1 =~ "under the byte rule"))

      row = Stages.get(story.tenant_id, story.id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "does not satisfy the runner contract's story object"

      events = Stages.list_events(story.tenant_id, story.id)
      transition = Enum.find(events, &(&1.to_stage == "escalated"))
      assert transition.edge == "session_escalated"
      assert transition.data["payload"]["story_payload_violations"] == violations
    end

    test "a story already escalated is not escalated a second time" do
      story = staged(long_story_attrs(), :escalated)

      assert {:error, {:story_not_dispatchable, _}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert {:error, {:story_not_dispatchable, _}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      escalations =
        story.tenant_id
        |> Stages.list_events(story.id)
        |> Enum.count(&(&1.to_stage == "escalated"))

      assert escalations == 0
    end

    test "a stage escalation cannot leave is NAMED, not reported as a bare invalid transition" do
      # Every stage the session-escalation edge does not leave, not just the terminal one:
      # `queued` and `triaged` are the reachable mistakes — a caller composing a payload
      # before claiming — and a bare `:invalid_transition` gives them nothing to act on.
      for stage <- [:queued, :triaged, :done] do
        story = staged(long_story_attrs(), stage)

        assert {:error, {:escalation_failed, {:no_escalation_edge, ^stage}, violations}} =
                 StoryPayload.build(story.tenant_id, story.id, opts()),
               "expected #{stage} to be named"

        assert violations != []
        assert Stages.get(story.tenant_id, story.id).stage == stage
      end
    end

    test "the named stages are exactly the ones the machine has no escalation edge from" do
      # Bound to the machine, so an edge added there stops being a refusal here without
      # anyone remembering to update a list.
      escapable =
        for {from, :escalated, :session_escalated} <- StageMachine.transitions(), do: from

      refute :queued in escapable
      refute :triaged in escapable
      refute :done in escapable
      assert :claimed in escapable
    end

    test "the NOT-escalated outcome logs at error and the escalated one does not" do
      # The two used to be the wrong way round: the harmless branch — a human now has the
      # story — logged a warning, and the strictly worse one, neither dispatchable nor
      # parked, logged nothing at all. Captured at `:error` alone, so the assertion is about
      # the LEVEL and not the wording.
      parked = staged(long_story_attrs())

      quiet =
        capture_log([level: :error], fn ->
          assert {:error, {:story_not_dispatchable, _}} =
                   StoryPayload.build(parked.tenant_id, parked.id, opts())
        end)

      assert quiet == ""

      stranded = staged(long_story_attrs(), :done)

      loud =
        capture_log([level: :error], fn ->
          assert {:error, {:escalation_failed, _, _}} =
                   StoryPayload.build(stranded.tenant_id, stranded.id, opts())
        end)

      assert loud =~ "NOT ESCALATED"
      assert loud =~ stranded.id
    end

    test "another writer parking the story first is the ok outcome, not the loudest error" do
      # Whoever parked it, the story is where this call wanted it, so the caller gets the
      # ordinary refusal and NOTHING is logged at error — the level reserved for a story that
      # is neither dispatchable nor parked.
      story = staged(long_story_attrs())

      {:ok, _row} =
        Stages.advance(story.tenant_id, story.id, {:claimed, :escalated, :session_escalated},
          claim_epoch: @epoch,
          actor_lineage: [],
          actor_label: "someone-else",
          reason: "a human was already asked to look at this"
        )

      log =
        capture_log([level: :error], fn ->
          assert {:error, {:story_not_dispatchable, _}} =
                   StoryPayload.build(story.tenant_id, story.id, opts())
        end)

      assert log == ""

      row = Stages.get(story.tenant_id, story.id)
      assert row.stage == :escalated
      # The other writer's reason stands: this call did not park it a second time.
      assert row.escalation_reason == "a human was already asked to look at this"
    end

    test "a stale claim epoch refuses the escalation rather than writing under a dead claim" do
      story = staged(long_story_attrs())

      assert {:error, {:escalation_failed, :stale_claim_epoch, _}} =
               StoryPayload.build(story.tenant_id, story.id, opts(claim_epoch: @epoch + 1))

      assert Stages.get(story.tenant_id, story.id).stage == :claimed
    end

    test "a story with hundreds of violations still escalates, with a bounded event" do
      # The regression: `list_violations/4` emits one message per offending ITEM and nothing
      # caps how many acceptance criteria a story may carry, so an unbounded event_data pushed
      # past `Stages.max_event_data_bytes/0`, `advance/4` answered `:invalid_event_data`, and
      # the story was neither dispatched NOR escalated — the exact outcome the reason
      # truncation already existed to prevent.
      criteria =
        for index <- 1..400,
            do: %{
              "id" => "AC-#{index}",
              "description" => String.duplicate("y", RunnerStory.max_criterion_length() + 1)
            }

      story = staged(%{acceptance_criteria: criteria})

      assert {:error, {:story_not_dispatchable, violations}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert length(violations) > 100

      assert Stages.get(story.tenant_id, story.id).stage == :escalated

      transition =
        story.tenant_id
        |> Stages.list_events(story.id)
        |> Enum.find(&(&1.to_stage == "escalated"))

      recorded = transition.data["payload"]

      # The COUNT is exact even though the list is a prefix, so a reader is never misled
      # about how many there were.
      assert recorded["story_payload_violation_count"] == length(violations)
      assert length(recorded["story_payload_violations"]) < length(violations)
      assert recorded["story_payload_violations"] != []

      assert byte_size(Jason.encode!(recorded)) <= Stages.max_event_data_bytes()
    end

    test "both required options are read before the story is, not only when it is oversize" do
      # A composer integration-tested against ordinary stories must not pass everything and
      # then raise on its first oversize one.
      story = staged()

      for missing <- [:claim_epoch, :actor_lineage] do
        assert_raise KeyError, fn ->
          StoryPayload.build(story.tenant_id, story.id, Keyword.delete(opts(), missing))
        end
      end
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

  describe "settle_lost_race/3" do
    # The race itself cannot be staged from one process: the read and the write are two calls
    # inside `build/3`, and a test that has to win a real race is a flaky test. So the
    # RESOLUTION is exercised directly — it is the whole of the logic — while the outcome a
    # caller sees is asserted through `build/3` above. Every mutation of this function is
    # killed here; the pipe that CALLS it is killed by the build-level test.
    test "a refusal caused by the row moving becomes ok once the row is escalated" do
      story = staged(long_story_attrs(), :escalated)

      for reason <- [:stale_stage, :invalid_transition] do
        assert {:ok, row} =
                 StoryPayload.settle_lost_race({:error, reason}, story.tenant_id, story.id)

        assert row.stage == :escalated
      end
    end

    test "the same refusal on a row that is NOT escalated stays the caller's error" do
      story = staged(long_story_attrs())

      for reason <- [:stale_stage, :invalid_transition] do
        assert {:error, ^reason} =
                 StoryPayload.settle_lost_race({:error, reason}, story.tenant_id, story.id)
      end
    end

    test "any other outcome passes straight through, escalated row or not" do
      story = staged(long_story_attrs(), :escalated)

      # A story parked for some OTHER reason must not turn a stale epoch into a success:
      # only the two refusals that mean "the row moved" are re-read.
      assert {:error, :stale_claim_epoch} =
               StoryPayload.settle_lost_race(
                 {:error, :stale_claim_epoch},
                 story.tenant_id,
                 story.id
               )

      row = Stages.get(story.tenant_id, story.id)
      assert {:ok, ^row} = StoryPayload.settle_lost_race({:ok, row}, story.tenant_id, story.id)
    end
  end

  describe "the field caps" do
    test "a title past its cap is refused by name, not trimmed" do
      story = staged(%{title: String.duplicate("t", RunnerStory.max_title_length() + 1)})

      assert {:error, {:story_not_dispatchable, violations}} =
               StoryPayload.build(story.tenant_id, story.id, opts())

      assert Enum.any?(violations, &(&1 =~ "title is longer than"))
    end

    test "one criterion too many is refused, and the twentieth is not dropped" do
      criteria =
        for index <- 1..(RunnerStory.max_criteria() + 1),
            do: %{"id" => "AC-#{index}", "description" => "c#{index}"}

      story = staged(%{acceptance_criteria: criteria})

      assert {:error, {:story_not_dispatchable, violations}} =
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
        assert {:error, {:story_not_dispatchable, _}} =
                 StoryPayload.build(story.tenant_id, story.id, opts([{key, value}])),
               "expected #{key} past its cap to be refused"
      end
    end
  end
end
