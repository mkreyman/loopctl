defmodule Loopctl.Threads.ReviewDispatchRaceTest do
  @moduledoc """
  US-45.3: two placements reusing one caller-supplied `dispatch_id` on DIFFERENT stories. Each
  holds only its own story's thread lock, so neither sees the other's row in `placed_before`,
  and the second insert meets the `(tenant_id, dispatch_id)` unique index. That must answer
  `dispatch_id_conflict`, never raise.

  `async: false` and COMMITTED: the race needs two real transactions, which the sandbox's one
  shared connection cannot give. Swept with the committed tenant.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Repo
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

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Repo, fun) end)

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
