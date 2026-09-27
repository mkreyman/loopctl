defmodule Loopctl.Workers.ReviewCeilingWorkerTest do
  @moduledoc """
  US-45.3: the durable half of a review-ceiling escalation. The verdict records the escalation
  entry; this worker moves the delivery stage until it lands, and stops when the move proves
  unnecessary.

  `async: false` and COMMITTED: the cron read is fleet-wide on `AdminRepo`, which cannot see
  the RLS `Repo` sandbox, so the thread and the stage row are written on real connections and
  swept with their committed tenant.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ReviewCeilingWorker

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 2
  @tree String.duplicate("c", 40)

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Repo, fun) end)

  # A story whose round 2 reached the ceiling with a critical finding, and whose stage row is
  # still in flight: the escalation is recorded and the stage has not moved.
  defp ceiling_story do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    story = fixture(:committed_story, %{tenant_id: tenant.id, claim_epoch: @epoch})

    unboxed(fn ->
      implementer = fixture(:stage_agent, %{tenant_id: tenant.id})
      reviewer = fixture(:stage_agent, %{tenant_id: tenant.id})
      session = fixture(:stage_dispatch, %{tenant_id: tenant.id, agent_id: implementer.id})

      {:ok, _} =
        Repo.with_tenant(tenant.id, fn ->
          from(s in Story, where: s.id == ^story.id)
          |> Repo.update_all(
            set: [
              assigned_agent_id: implementer.id,
              implementer_dispatch_id: session.id,
              agent_status: :implementing,
              claimed_until: DateTime.add(DateTime.utc_now(), 3_600)
            ]
          )
        end)

      stage =
        fixture(:story_stage, %{
          tenant_id: tenant.id,
          story_id: story.id,
          stage: :implementing,
          claim_epoch: @epoch
        })

      checkpoint = fn n ->
        {:ok, _cp, :created} =
          Threads.record_checkpoint(tenant.id, story.id,
            agent_id: implementer.id,
            claim_epoch: @epoch,
            commit_sha: String.duplicate(Integer.to_string(n), 40),
            tree_sha: @tree,
            author_principal: "agent:#{implementer.id}",
            actor_lineage: session.lineage_path
          )
      end

      judge = fn review, attrs ->
        {:ok, written, :created} =
          Threads.record_judgement(tenant.id, story.id, review.dispatch_id, attrs,
            runner_id: review.runner_id,
            author_principal: "agent:#{reviewer.id}"
          )

        written
      end

      round = fn n, finding ->
        checkpoint.(n)

        {:ok, review, :created} =
          Threads.record_review(tenant.id, story.id,
            dispatch_id: Ecto.UUID.generate(),
            runner_id: reviewer.id,
            agent_id: reviewer.id,
            placed_by: "t"
          )

        judge.(
          review,
          Map.merge(%{"kind" => "finding", "idempotency_key" => "f#{n}", "body" => "b"}, finding)
        )

        judge.(review, %{"kind" => "verdict", "idempotency_key" => "v#{n}", "body" => "done"})
      end

      round.(1, %{"severity" => "low"})

      %{escalation: escalation} =
        round.(2, %{"severity" => "critical", "introduced_by" => "none"})

      assert escalation

      %{tenant_id: tenant.id, story: story, stage: stage}
    end)
  end

  defp stage_of(ctx) do
    unboxed(fn ->
      {:ok, row} = Repo.with_tenant(ctx.tenant_id, fn -> Repo.get!(StoryStage, ctx.stage.id) end)
      row
    end)
  end

  defp perform, do: unboxed(fn -> ReviewCeilingWorker.perform(%Oban.Job{}) end)

  test "moves an in-flight stage to escalated over the review_ceiling edge, once" do
    ctx = ceiling_story()

    assert :ok = perform()
    assert stage_of(ctx).stage == :escalated

    [event] =
      unboxed(fn ->
        {:ok, events} =
          Repo.with_tenant(ctx.tenant_id, fn ->
            Repo.all(
              from e in StageEvent,
                where: e.story_id == ^ctx.story.id and e.edge == "review_ceiling"
            )
          end)

        events
      end)

    assert event.actor_label == Threads.review_ceiling_principal()

    # Landed: the next run finds nothing to do and writes nothing.
    before = stage_of(ctx).lock_version
    assert :ok = perform()
    assert stage_of(ctx).lock_version == before
  end

  test "a claim that moved on proves the escalation unnecessary" do
    ctx = ceiling_story()

    unboxed(fn ->
      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in StoryStage, where: s.id == ^ctx.stage.id)
          |> Repo.update_all(set: [claim_epoch: @epoch + 1])
        end)
    end)

    # Not a candidate at all, rather than one the escalation refuses every minute: a refused
    # candidate stays oldest in the batch and starves the live ones behind it.
    log = capture_log(fn -> assert :ok = perform() end)
    assert stage_of(ctx).stage == :implementing
    refute log =~ "review_ceiling not yet moved"
  end
end
