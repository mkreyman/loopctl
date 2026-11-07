defmodule Loopctl.Delivery.UngatedMergeTest do
  @moduledoc """
  US-48.17 inside `Loopctl.Delivery.Stages`.

  - TC-48.17.2 (AC-48.17.4): a `ci -> merged` reported on the pull-request route for a head the
    merge gate never allowed is recorded and then escalated over `:ungated_merge` in the same
    transaction, and the reason names the merge and the head. An allowed head, a story off the
    pull-request route, and a chg story are untouched.
  - The two `ci`-stage records `Loopctl.Delivery.MergeExecution` keeps: `merge_instruction` and
    `runner_absence`, fenced like every other stage write.
  - `Loopctl.Progress.extend_ci_hold_lease/3`, the lease hold control writes.

  Async: every row is on the sandbox connection.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @head String.duplicate("a", 40)
  @merge_sha String.duplicate("c", 40)
  @other String.duplicate("d", 40)

  setup do
    fixture(:merge_instruction_story, %{head_sha: @head})
  end

  describe "TC-48.17.2: an ungated merge is escalated when it is reported" do
    test "no allow recorded: merged, then escalated, and the reason names the merge", ctx do
      assert {:ok, row} = report_merge(ctx)

      # What the runner's ack carries: the row as the transaction left it.
      assert row.stage == :escalated
      assert row.escalation_reason =~ "ungated_merge"
      assert row.escalation_reason =~ @merge_sha
      assert row.escalation_reason =~ @head
      assert row.escalation_reason =~ "no merge-gate allow was recorded"
      # The merge happened; the row keeps it.
      assert row.merge_sha == @merge_sha

      assert [{"ci", "merged", "forward"}, {"merged", "escalated", "ungated_merge"}] =
               transitions(ctx)

      assert [%{data: %{"payload" => data}}] = transition_events(ctx, "ungated_merge")
      assert data["merge_sha"] == @merge_sha
      assert data["head_sha"] == @head
      assert data["allowed_sha"] == nil

      # Two session-ending transitions in one transaction give the runner's slot back ONCE.
      {:ok, runner} =
        Repo.with_tenant(ctx.tenant.id, fn -> Repo.get!(Loopctl.Runners.Runner, ctx.runner.id) end)

      assert runner.in_flight == 0
    end

    test "an allow for ANOTHER head is not an allow for this one", ctx do
      set_stage(ctx, merge_gate_allowed_sha: @other)

      assert {:ok, row} = report_merge(ctx)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "the merge gate allowed #{@other}, a different head"
    end

    test "an allow for the reported head is the gated path: merged stands", ctx do
      set_stage(ctx, merge_gate_allowed_sha: @head)

      assert {:ok, row} = report_merge(ctx)
      assert row.stage == :merged
      assert [{"ci", "merged", "forward"}] = transitions(ctx)
    end

    test "a story off the pull-request route is not judged by it", ctx do
      from(s in Source, where: s.project_id == ^ctx.project_id)
      |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

      assert {:ok, row} = report_merge(ctx)
      assert row.stage == :merged
    end

    test "a chg-mode project is not the pull-request route", ctx do
      story = AdminRepo.get!(Story, ctx.story_id)

      from(s in Source, where: s.project_id == ^ctx.project_id)
      |> AdminRepo.update_all(
        set: [
          mode: :chg,
          change_events_secret: "chg-secret",
          chg_root_dispatch_id: story.verifier_dispatch_id
        ]
      )

      assert {:ok, row} = report_merge(ctx)
      assert row.stage == :merged
    end

    test "a replayed report does not escalate twice", ctx do
      assert {:ok, %{stage: :escalated}} = report_merge(ctx)
      _ = report_merge(ctx)
      assert length(transition_events(ctx, "ungated_merge")) == 1
    end
  end

  describe "record_merge_instruction/4" do
    test "records the instruction with one event, for the row's own head", ctx do
      record = %{"head_sha" => @head, "sends" => 1, "outcome" => "pushed"}

      assert {:ok, row} =
               Stages.record_merge_instruction(ctx.tenant.id, ctx.story_id, record, opts())

      assert row.merge_instruction == record
      assert [%{data: ^record}] = events(ctx, "merge_instructed")
    end

    test "refuses another head, another epoch, another stage, another tenant", ctx do
      record = %{"head_sha" => @other}

      assert {:error, :head_moved} =
               Stages.record_merge_instruction(ctx.tenant.id, ctx.story_id, record, opts())

      record = %{"head_sha" => @head}

      assert {:error, :stale_claim_epoch} =
               Stages.record_merge_instruction(ctx.tenant.id, ctx.story_id, record,
                 claim_epoch: 3
               )

      other = fixture(:merge_instruction_story, %{})

      assert {:error, :not_found} =
               Stages.record_merge_instruction(other.tenant.id, ctx.story_id, record, opts())

      set_stage(ctx, stage: :implementing)

      assert {:error, :wrong_stage} =
               Stages.record_merge_instruction(ctx.tenant.id, ctx.story_id, record, opts())

      assert events(ctx, "merge_instructed") == []
    end

    test "is head-keyed: an edge that clears the head clears it", ctx do
      {:ok, _} =
        Stages.record_merge_instruction(
          ctx.tenant.id,
          ctx.story_id,
          %{"head_sha" => @head},
          opts()
        )

      {:ok, row} =
        Stages.advance(ctx.tenant.id, ctx.story_id, {:ci, :implementing, :base_moved},
          claim_epoch: 0,
          reason: "moved"
        )

      assert is_nil(row.merge_instruction)
    end
  end

  describe "note_runner_absence/5 and clear_runner_absence/3" do
    test "the clock starts at the first sighting and a second writes nothing", ctx do
      t0 = DateTime.truncate(DateTime.utc_now(), :second)

      assert {:ok, ^t0} = note(ctx, ctx.runner.id, t0)
      assert {:ok, ^t0} = note(ctx, ctx.runner.id, DateTime.add(t0, 120))
      assert length(events(ctx, "runner_absence")) == 1
    end

    test "another runner starts a fresh clock", ctx do
      t0 = DateTime.truncate(DateTime.utc_now(), :second)
      later = DateTime.add(t0, 120)
      other = Ecto.UUID.generate()

      assert {:ok, ^t0} = note(ctx, ctx.runner.id, t0)
      assert {:ok, ^later} = note(ctx, other, later)
    end

    test "clearing writes one event, and clearing nothing writes none", ctx do
      assert {:ok, _} = Stages.clear_runner_absence(ctx.tenant.id, ctx.story_id, opts())
      assert events(ctx, "runner_absence") == []

      {:ok, _} = note(ctx, ctx.runner.id, DateTime.utc_now())
      assert {:ok, row} = Stages.clear_runner_absence(ctx.tenant.id, ctx.story_id, opts())
      assert is_nil(row.runner_absence)

      assert [_noted, %{data: %{"cleared" => %{"runner_id" => _}}}] =
               events(ctx, "runner_absence")
    end

    test "is fenced like every stage write", ctx do
      assert {:error, :stale_claim_epoch} =
               Stages.note_runner_absence(
                 ctx.tenant.id,
                 ctx.story_id,
                 ctx.runner.id,
                 DateTime.utc_now(),
                 claim_epoch: 9
               )

      set_stage(ctx, stage: :merged)
      assert {:error, :wrong_stage} = note(ctx, ctx.runner.id, DateTime.utc_now())
    end
  end

  describe "Progress.extend_ci_hold_lease/3" do
    setup ctx do
      now = DateTime.utc_now()
      cap = DateTime.add(now, 60)

      from(s in Story, where: s.id == ^ctx.story_id)
      |> AdminRepo.update_all(
        set: [agent_status: :implementing, claimed_until: cap, claim_lease_cap: cap]
      )

      Map.merge(ctx, %{now: now, cap: cap})
    end

    test "moves cap and lease forward, never back, and leaves the epoch", ctx do
      until = DateTime.add(ctx.now, 900)

      assert {:ok, story} = hold(ctx, until, 0)
      assert DateTime.compare(story.claim_lease_cap, until) == :eq
      assert DateTime.compare(story.claimed_until, until) == :eq
      assert story.claim_epoch == 0

      # Backwards is a no-op, not a shortening.
      assert {:ok, story} = hold(ctx, DateTime.add(ctx.now, 120), 0)
      assert DateTime.compare(story.claim_lease_cap, until) == :eq
    end

    test "refuses another epoch, an ended claim and another tenant", ctx do
      assert {:error, :stale_claim_epoch} = hold(ctx, DateTime.add(ctx.now, 900), 1)

      other = fixture(:merge_instruction_story, %{})

      assert {:error, :stale_claim_epoch} =
               Progress.extend_ci_hold_lease(other.tenant.id, ctx.story_id, %{
                 claim_epoch: 0,
                 until: DateTime.add(ctx.now, 900),
                 actor_label: "control:merge_execution"
               })

      from(s in Story, where: s.id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [agent_status: :reported_done])

      assert {:error, :claim_not_live} = hold(ctx, DateTime.add(ctx.now, 900), 0)
    end

    test "a lapsed lease is not revived", ctx do
      past = DateTime.add(ctx.now, -5)

      from(s in Story, where: s.id == ^ctx.story_id)
      |> AdminRepo.update_all(set: [claimed_until: past, claim_lease_cap: past])

      assert {:error, :claim_not_live} = hold(ctx, DateTime.add(ctx.now, 900), 0)
    end
  end

  # --- helpers -------------------------------------------------------------------------

  defp opts, do: [claim_epoch: 0, actor_label: "control:merge_execution"]

  defp note(ctx, runner_id, at),
    do: Stages.note_runner_absence(ctx.tenant.id, ctx.story_id, runner_id, at, opts())

  defp hold(ctx, until, epoch) do
    Progress.extend_ci_hold_lease(ctx.tenant.id, ctx.story_id, %{
      claim_epoch: epoch,
      until: until,
      actor_label: "control:merge_execution"
    })
  end

  defp report_merge(ctx) do
    RunnerStages.apply(ctx.tenant.id, ctx.runner.id, %{
      dispatch_id: ctx.dispatch_id,
      claim_epoch: 0,
      from: :ci,
      to: :merged,
      edge: :forward,
      effects: %{merge_sha: @merge_sha}
    })
  end

  defp set_stage(ctx, set) do
    {:ok, _} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        from(s in StoryStage, where: s.story_id == ^ctx.story_id) |> Repo.update_all(set: set)
      end)
  end

  defp events(ctx, event) do
    {:ok, rows} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        Repo.all(
          from e in StageEvent,
            where: e.story_id == ^ctx.story_id and e.event == ^event,
            order_by: [asc: e.inserted_at, asc: e.lock_version]
        )
      end)

    rows
  end

  defp transition_events(ctx, edge),
    do: ctx |> events("transitioned") |> Enum.filter(&(&1.edge == edge))

  defp transitions(ctx),
    do: ctx |> events("transitioned") |> Enum.map(&{&1.from_stage, &1.to_stage, &1.edge})
end
