defmodule Loopctl.Delivery.SessionEndTest do
  @moduledoc """
  US-44.3, contract 1.16.0: `Loopctl.Delivery.RunnerStages.end_session/3` — a runner's
  `session_ended` report, recorded once per dispatch and acted on by control.

  `completed`, the budget kills' ESCALATION, and every refusal are here, async, on one sandbox
  connection. Ending the CLAIM — what `crashed` and `usage_exhausted` do, and what a budget kill
  does after it escalates — is an `AdminRepo` transaction, and the two sandbox connections
  cannot see each other's rows (here the release finds no story and does nothing); those are in
  `Loopctl.Delivery.SessionEndReleaseTest` on committed rows.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.RunnerSessionEnded
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @epoch 4

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  # A story at `stage` under a claim at `@epoch`, with an ACCEPTED implement dispatch on a
  # runner holding one slot for it.
  defp session(stage, opts \\ []) do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
    runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})

    row =
      if Keyword.get(opts, :stage_row?, true) do
        fixture(:story_stage, %{
          tenant_id: story.tenant_id,
          story_id: story.id,
          stage: stage,
          claim_epoch: @epoch,
          escalation_reason: if(stage == :escalated, do: "why")
        })
      end

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: story.tenant_id,
        runner: runner,
        story_id: story.id,
        claim_epoch: @epoch,
        kind: Keyword.get(opts, :kind, "implement"),
        status: Keyword.get(opts, :status, "accepted")
      })

    %{story: story, runner: runner, row: row, record: record}
  end

  defp message(record, reason, attrs \\ %{}) do
    Map.merge(
      %{dispatch_id: record.dispatch_id, claim_epoch: record.claim_epoch, reason: reason},
      attrs
    )
  end

  defp end_session(ctx, reason, attrs \\ %{}) do
    RunnerStages.end_session(
      ctx.story.tenant_id,
      ctx.runner.id,
      message(ctx.record, reason, attrs)
    )
  end

  defp ledger(record),
    do: as_tenant(record.tenant_id, fn -> Repo.get!(DispatchRecord, record.id) end)

  defp in_flight(runner),
    do: as_tenant(runner.tenant_id, fn -> Repo.get!(Runner, runner.id) end).in_flight

  defp stage_of(story), do: Stages.get(story.tenant_id, story.id)

  defp transitions(story) do
    as_tenant(story.tenant_id, fn ->
      Repo.all(
        from e in StageEvent,
          where: e.tenant_id == ^story.tenant_id and e.story_id == ^story.id,
          where: e.event == "transitioned",
          select: {e.from_stage, e.to_stage, e.edge}
      )
    end)
  end

  defp chain_actions(tenant_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id,
          order_by: [asc: e.chain_position],
          select: e.action
      )
    end)
  end

  defp bump_story_epoch(story) do
    as_tenant(story.tenant_id, fn ->
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [claim_epoch: @epoch + 1])
    end)
  end

  describe "completed (AC-44.3.7)" do
    test "changes no stage, releases nothing, and is recorded on the ledger row" do
      ctx = session(:pr_open)

      assert {:ok, %{row: row, replayed?: false}} = end_session(ctx, "completed")

      assert %StoryStage{stage: :pr_open, claim_epoch: @epoch} = row
      assert stage_of(ctx.story).lock_version == ctx.row.lock_version
      assert transitions(ctx.story) == []

      # The runner's word that its session is over frees no slot on its own: the row is not at
      # a stage that ends a session, and the claim it ran under is still live.
      assert in_flight(ctx.runner) == 1

      recorded = ledger(ctx.record)
      assert recorded.session_ended_reason == "completed"
      assert is_binary(recorded.session_ended_digest)
      assert %DateTime{} = recorded.session_ended_at
      assert recorded.counts_toward_retry_ceiling == nil
    end

    test "at a stage that ends the session, the slot goes back: the stage decides, not the word" do
      ctx = session(:deployed)
      assert in_flight(ctx.runner) == 1

      assert {:ok, %{row: %StoryStage{stage: :deployed}}} = end_session(ctx, "completed")
      assert in_flight(ctx.runner) == 0
    end
  end

  describe "a budget kill (AC-44.3.3)" do
    test "wall_clock_exceeded escalates an in-flight story over budget_reported and frees the slot" do
      ctx = session(:implementing)
      assert in_flight(ctx.runner) == 1

      assert {:ok, %{row: row, replayed?: false}} = end_session(ctx, "wall_clock_exceeded")

      assert row.stage == :escalated
      assert row.claim_epoch == @epoch
      assert row.attempts == %{"budget_reported" => 1}
      # Built from the enum, never from anything a session wrote.
      assert row.escalation_reason == "session_ended:wall_clock_exceeded"

      assert transitions(ctx.story) == [{"implementing", "escalated", "budget_reported"}]
      assert chain_actions(ctx.story.tenant_id) == ["story_stage_escalated"]
      assert in_flight(ctx.runner) == 0
      assert ledger(ctx.record).session_ended_reason == "wall_clock_exceeded"
    end

    test "max_turns_exceeded takes the same edge from any in-flight stage, never failed" do
      ctx = session(:reviewing)

      assert {:ok, %{row: row}} = end_session(ctx, "max_turns_exceeded")

      assert row.stage == :escalated
      assert row.escalation_reason == "session_ended:max_turns_exceeded"
      assert transitions(ctx.story) == [{"reviewing", "escalated", "budget_reported"}]
      assert in_flight(ctx.runner) == 0
    end

    test "a resend escalates nothing twice and is answered ok with the row (AC-44.3.2)" do
      ctx = session(:ci)

      assert {:ok, %{row: first, replayed?: false}} = end_session(ctx, "wall_clock_exceeded")
      assert {:ok, %{row: again, replayed?: true}} = end_session(ctx, "wall_clock_exceeded")

      assert again.stage == :escalated
      assert again.lock_version == first.lock_version
      assert again.attempts == %{"budget_reported" => 1}
      assert length(transitions(ctx.story)) == 1
      assert chain_actions(ctx.story.tenant_id) == ["story_stage_escalated"]
    end

    test "a story past the in-flight stages is left where it is" do
      ctx = session(:merged)

      assert {:ok, %{row: %StoryStage{stage: :merged}}} = end_session(ctx, "wall_clock_exceeded")
      assert transitions(ctx.story) == []
    end
  end

  describe "recorded once per dispatch (AC-44.3.2)" do
    test "a DIFFERENT reason for the same dispatch is already_recorded and changes nothing" do
      ctx = session(:implementing)

      assert {:ok, _} = end_session(ctx, "completed")
      assert {:error, :already_recorded} = end_session(ctx, "wall_clock_exceeded")

      assert stage_of(ctx.story).stage == :implementing
      assert ledger(ctx.record).session_ended_reason == "completed"
    end

    test "an identical resend is answered ok BEFORE the epoch is looked at" do
      ctx = session(:implementing)
      assert {:ok, %{replayed?: false}} = end_session(ctx, "completed")

      # The epoch moving on is what a `crashed` release does to its own resend. Matched on its
      # bytes first, the resend is still the report that was recorded.
      bump_story_epoch(ctx.story)

      assert {:ok, %{replayed?: true, row: %StoryStage{stage: :implementing}}} =
               end_session(ctx, "completed")

      # And a DIFFERENT report after the move is still already_recorded, not stale_claim_epoch.
      assert {:error, :already_recorded} = end_session(ctx, "crashed")
    end
  end

  describe "refusals of a first report" do
    test "a claim_epoch that is not the story's current one is stale and changes nothing (AC-44.3.6)" do
      ctx = session(:implementing)
      bump_story_epoch(ctx.story)

      assert {:error, :stale_claim_epoch} = end_session(ctx, "wall_clock_exceeded")

      assert stage_of(ctx.story).stage == :implementing
      assert transitions(ctx.story) == []
      assert ledger(ctx.record).session_ended_reason == nil
    end

    test "an epoch that is not even the dispatch's is stale" do
      ctx = session(:implementing)

      assert {:error, :stale_claim_epoch} =
               end_session(ctx, "wall_clock_exceeded", %{claim_epoch: @epoch - 1})

      assert stage_of(ctx.story).stage == :implementing
      assert ledger(ctx.record).session_ended_reason == nil
    end

    test "a triage dispatch is not one this message can be about" do
      ctx = session(:implementing, kind: "triage")

      assert {:error, :unknown_dispatch} = end_session(ctx, "crashed")
      assert ledger(ctx.record).session_ended_reason == nil
    end

    test "a dispatch that was never accepted ran no session" do
      ctx = session(:implementing, status: "sent")

      assert {:error, :dispatch_not_accepted} = end_session(ctx, "completed")
      assert ledger(ctx.record).session_ended_reason == nil
    end

    test "a story with no stage row is refused before anything is recorded" do
      ctx = session(:implementing, stage_row?: false)

      assert {:error, :unknown_story_stage} = end_session(ctx, "completed")
      assert ledger(ctx.record).session_ended_reason == nil
    end

    test "another runner's dispatch is unknown, exactly as none" do
      ctx = session(:implementing)
      other = fixture(:stage_runner, %{tenant_id: ctx.story.tenant_id})

      assert {:error, :unknown_dispatch} =
               RunnerStages.end_session(
                 ctx.story.tenant_id,
                 other.id,
                 message(ctx.record, "wall_clock_exceeded")
               )

      assert stage_of(ctx.story).stage == :implementing
    end

    test "tenant isolation: another tenant cannot end this tenant's session" do
      ctx = session(:implementing)
      other = session(:implementing)

      assert {:error, :unknown_dispatch} =
               RunnerStages.end_session(
                 other.story.tenant_id,
                 other.runner.id,
                 message(ctx.record, "wall_clock_exceeded")
               )

      assert stage_of(ctx.story).stage == :implementing
      assert ledger(ctx.record).session_ended_reason == nil
    end
  end

  describe "the ledger columns hold their own shape" do
    defp set_session_end(record, fields) do
      as_tenant(record.tenant_id, fn ->
        from(d in DispatchRecord, where: d.id == ^record.id) |> Repo.update_all(set: fields)
      end)
    end

    test "the reason CHECK admits exactly the contract's reasons" do
      [definition] =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
            "WHERE conname = 'runner_dispatches_session_ended_reason'"
        ).rows
        |> List.flatten()

      for reason <- RunnerSessionEnded.reasons() do
        assert definition =~ "'#{reason}'", reason
      end

      ctx = session(:implementing)
      now = DateTime.utc_now()

      assert_raise Postgrex.Error, ~r/runner_dispatches_session_ended_reason/, fn ->
        set_session_end(ctx.record,
          session_ended_reason: "bored",
          session_ended_digest: "d",
          session_ended_at: now
        )
      end
    end

    test "a digest never stands without its reason, and only a release carries a count" do
      ctx = session(:implementing)
      now = DateTime.utc_now()

      assert_raise Postgrex.Error, ~r/runner_dispatches_session_ended_together/, fn ->
        set_session_end(ctx.record, session_ended_digest: "d")
      end

      assert_raise Postgrex.Error, ~r/runner_dispatches_session_ended_counted/, fn ->
        set_session_end(ctx.record,
          session_ended_reason: "completed",
          session_ended_digest: "d",
          session_ended_at: now,
          counts_toward_retry_ceiling: false
        )
      end

      assert_raise Postgrex.Error, ~r/runner_dispatches_session_ended_counted/, fn ->
        set_session_end(ctx.record,
          session_ended_reason: "crashed",
          session_ended_digest: "d",
          session_ended_at: now
        )
      end
    end

    test "a count with NO reason at all is refused too: the CHECK never evaluates to NULL" do
      # `NULL IN (...)` is NULL, and a CHECK that evaluates to NULL PASSES — so without the
      # COALESCE a row with no session end could carry a counted flag. Raw SQL, because what
      # is under test is the database, not anything a writer in `lib/` would do.
      ctx = session(:implementing)

      assert_raise Postgrex.Error, ~r/runner_dispatches_session_ended_counted/, fn ->
        as_tenant(ctx.record.tenant_id, fn ->
          Repo.query!(
            "UPDATE runner_dispatches SET counts_toward_retry_ceiling = true WHERE id = $1",
            [Ecto.UUID.dump!(ctx.record.id)]
          )
        end)
      end
    end
  end

  describe "the dispatch id is canonical before it is digested" do
    test "a resend differing only in the id's CASING is the same report, answered ok" do
      # The digest is taken over the CAST message, and the cast already writes every uuid in
      # its one canonical form (`RunnerContract`'s `known_fields/2`). Pinned here because the
      # digest is where losing that would bite: the same report, refused `already_recorded`
      # for good.
      ctx = session(:implementing)

      cast = fn dispatch_id ->
        {:ok, message} =
          RunnerContract.cast_session_ended(%{
            "dispatch_id" => dispatch_id,
            "claim_epoch" => @epoch,
            "reason" => "completed"
          })

        message
      end

      assert cast.(String.upcase(ctx.record.dispatch_id)).dispatch_id == ctx.record.dispatch_id

      assert {:ok, %{replayed?: false}} =
               RunnerStages.end_session(
                 ctx.story.tenant_id,
                 ctx.runner.id,
                 cast.(ctx.record.dispatch_id)
               )

      assert {:ok, %{replayed?: true}} =
               RunnerStages.end_session(
                 ctx.story.tenant_id,
                 ctx.runner.id,
                 cast.(String.upcase(ctx.record.dispatch_id))
               )
    end
  end

  describe "a budget escalation that fails is a RETRY, never a refusal" do
    test "nothing in its failure branch hands the reason to classify/1" do
      # The record is committed before the escalation runs, so a PERMANENT refusal here leaves
      # the row in flight with nothing to move it but the lease reclaim, which RE-QUEUES a story
      # a budget kill must never retry. The branch is unreachable from a test (it needs a hash
      # chain that refuses appends — see `Loopctl.Delivery.RunnerStagesTest`), so what is bound
      # is the one thing that made it permanent: the function reaching `classify/1`.
      source = File.read!("lib/loopctl/delivery/runner_stages.ex")
      [_, from_head] = String.split(source, "defp take_budget_edge(", parts: 2)
      [body | _] = String.split(from_head, "\n  defp ", parts: 2)

      refute body =~ "classify(",
             "take_budget_edge must answer a failed escalation as a retry (:busy), because the " <>
               "resend is what re-drives it"

      assert body =~ "{:error, :busy}"
    end
  end
end
