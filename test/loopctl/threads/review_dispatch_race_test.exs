defmodule Loopctl.Threads.ReviewDispatchRaceTest do
  @moduledoc """
  US-45.3: two placements reusing one caller-supplied `dispatch_id` on DIFFERENT stories. Each
  holds only its own story's thread lock, so neither sees the other's row in `placed_before`,
  and the second insert meets the `(tenant_id, dispatch_id)` unique index. That must answer
  `dispatch_id_conflict`, never raise.

  `async: false` and COMMITTED, because the subject is two real transactions meeting on the
  story's thread advisory lock and on the `thread_reviews` `(tenant_id, dispatch_id)` unique
  index, which one sandbox connection cannot give. The rows are this module's own committed
  tenant, swept. And `await_waiter/1` reads `pg_locks` server-wide: alongside async tests,
  any of their lock waits would read as the loser waiting.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Placement
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Threads
  alias Loopctl.Threads.Review
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 2
  @tree String.duplicate("d", 40)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # A story claimed through a dispatch, with one checkpoint of the claim.
  defp claimed_story(tenant_id, implementer, session) do
    story = fixture(:committed_story, %{tenant_id: tenant_id, claim_epoch: @epoch})

    unboxed(fn ->
      {:ok, _} =
        Repo.with_tenant(tenant_id, fn ->
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

      {:ok, checkpoint, :created} =
        Threads.record_checkpoint(tenant_id, story.id,
          agent_id: implementer.id,
          claim_epoch: @epoch,
          commit_sha: String.duplicate("a", 40),
          tree_sha: @tree,
          author_principal: "agent:#{implementer.id}",
          actor_lineage: session.lineage_path
        )

      %{story: story, checkpoint: checkpoint}
    end)
  end

  defp waiting_on_a_lock? do
    unboxed(fn ->
      %{rows: [[waiting]]} =
        AdminRepo.query!("SELECT count(*) FROM pg_locks WHERE NOT granted")

      waiting > 0
    end)
  end

  defp await_waiter(tries \\ 100) do
    cond do
      waiting_on_a_lock?() -> :ok
      tries == 0 -> flunk("the second placement never waited on the first")
      true -> Process.sleep(20) && await_waiter(tries - 1)
    end
  end

  test "the loser of a same-story race answers from the row and does not push again" do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {_raw, operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    {_raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id})

    {implementer, session} =
      unboxed(fn ->
        implementer = fixture(:stage_agent, %{tenant_id: tenant.id})
        session = fixture(:stage_dispatch, %{tenant_id: tenant.id, agent_id: implementer.id})
        {implementer, session}
      end)

    %{story: story} = claimed_story(tenant.id, implementer, session)
    dispatch_id = Ecto.UUID.generate()
    parent = self()

    # The runner on the pool, declaring `review`, so the placement's pre-checks pass.
    {:ok, _ref} =
      Runners.Presence.track(self(), Runners.pool_topic(tenant.id), runner.name, %{
        runner_id: runner.id,
        kinds: ["review"],
        repos: ["acme/widgets"],
        draining: false,
        max_sessions: 4
      })

    # The WINNER: holds the story's thread lock, and records the review only when told to.
    winner =
      Task.async(fn ->
        unboxed(fn ->
          # A plain transaction to hold the thread lock: record_review/3 sets the tenant
          # itself, and a with_tenant/2 around it would be nested.
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1::int, hashtext($2))", [
              Threads.lock_namespace(),
              story.id
            ])

            send(parent, :locked)
            receive do: (:record -> :ok)

            {:ok, review, :created} =
              Threads.record_review(tenant.id, story.id,
                dispatch_id: dispatch_id,
                runner_id: runner.id,
                agent_id: runner.agent_id,
                placed_by: "winner"
              )

            review
          end)
        end)
      end)

    assert_receive :locked, 2_000

    # The LOSER: its look-up finds nothing yet, and its write waits on the winner's lock.
    loser =
      Task.async(fn ->
        unboxed(fn ->
          Placement.place_review(tenant.id, runner.id, story.id,
            api_key: operator,
            dispatch_id: dispatch_id,
            repo: "acme/widgets",
            base_branch: "master",
            wall_clock_seconds: 600,
            max_turns: 20
          )
        end)
      end)

    await_waiter()
    send(winner.pid, :record)
    assert {:ok, review} = Task.await(winner)

    assert {:ok, %{review: %{id: review_id}, dispatch_id: ^dispatch_id}} = Task.await(loser)
    assert review_id == review.id

    # Nothing was pushed by the loser: the ledger holds no row for the id.
    assert unboxed(fn -> DispatchLedger.get_record(tenant.id, dispatch_id) end) == nil
  end

  test "the second of two placements sharing a dispatch_id is dispatch_id_conflict" do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})

    {implementer, reviewer, session} =
      unboxed(fn ->
        implementer = fixture(:stage_agent, %{tenant_id: tenant.id})
        reviewer = fixture(:stage_agent, %{tenant_id: tenant.id})
        session = fixture(:stage_dispatch, %{tenant_id: tenant.id, agent_id: implementer.id})
        {implementer, reviewer, session}
      end)

    a = claimed_story(tenant.id, implementer, session)
    b = claimed_story(tenant.id, implementer, session)
    dispatch_id = Ecto.UUID.generate()
    parent = self()

    # The first placement's row, inserted and NOT yet committed: the second cannot see it.
    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.with_tenant(tenant.id, fn ->
            Repo.insert!(%Review{
              tenant_id: tenant.id,
              story_id: b.story.id,
              dispatch_id: dispatch_id,
              runner_id: reviewer.id,
              agent_id: reviewer.id,
              claim_epoch: @epoch,
              checkpoint_id: b.checkpoint.id,
              round: 1,
              placed_at_seq: 1,
              placed_by: "t"
            })

            send(parent, :held)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :held, 2_000

    racer =
      Task.async(fn ->
        unboxed(fn ->
          Threads.record_review(tenant.id, a.story.id,
            dispatch_id: dispatch_id,
            runner_id: reviewer.id,
            agent_id: reviewer.id,
            placed_by: "t"
          )
        end)
      end)

    await_waiter()
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder)

    assert {:error, {:conflict, "dispatch_id_conflict", _}} = Task.await(racer)
  end
end
