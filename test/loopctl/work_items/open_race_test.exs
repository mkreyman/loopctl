defmodule Loopctl.WorkItems.OpenRaceTest do
  @moduledoc """
  US-52.18 AC-52.18.5: two holders opening one branch at once yield ONE item.

  `async: false` because the subject is committed transactions racing each other: inside the
  SQL sandbox every allowed process shares one connection, which serialises the opens on its
  own and would pass with no lock at all. So the rows are COMMITTED under
  `fixture(:committed_tenant)`, every process runs on production's connections
  (`Loopctl.Test.ProductionTopology`), and the module sweeps the tenants it committed
  (`track_committed_tenants/0`).
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Holders
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkItems
  alias Loopctl.WorkItems.Open

  @ownership_timeout :timer.seconds(60)

  setup_all do
    %{ledger: track_committed_tenants()}
  end

  setup %{ledger: ledger} do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    track_committed_tenant(ledger, tenant.id)
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    agent = fixture(:agent, %{tenant_id: tenant.id})

    project =
      fixture(:project, %{tenant_id: tenant.id, repo_url: "https://github.com/mkreyman/chg"})

    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 3})

    holders =
      for session <- ["session-a", "session-b"] do
        attrs = %{"kind" => "interactive", "session_id" => session, "host" => "minis"}
        {:ok, %{holder: holder}} = Holders.register(tenant.id, agent.id, attrs)
        holder
      end

    %{tenant: tenant, epic: epic, holders: holders}
  end

  # The lock itself: an open waits while another session holds the branch's key, so two opens
  # can never both read "no item" and both create one.
  test "an open waits on the branch lock another session holds", ctx do
    %{tenant: tenant, epic: epic, holders: [holder | _]} = ctx
    parent = self()

    locker =
      Task.async(fn ->
        :ok =
          ProductionTopology.checkout_unboxed!([AdminRepo], ownership_timeout: @ownership_timeout)

        AdminRepo.transaction(fn ->
          AdminRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            Open.lock_key(tenant.id, epic.project_id, "fix/locked")
          ])

          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000

    opener_task =
      Task.async(fn ->
        :ok =
          ProductionTopology.checkout_unboxed!([Repo, AdminRepo],
            ownership_timeout: @ownership_timeout
          )

        opener = %{
          api_key_id: Ecto.UUID.generate(),
          agent_id: holder.agent_id,
          holder_id: holder.id
        }

        WorkItems.open_interactive(tenant.id, opener, %{
          "repo_url" => "https://github.com/mkreyman/chg",
          "branch" => "fix/locked",
          "epic_id" => epic.id
        })
      end)

    assert Task.yield(opener_task, 500) == nil, "the open did not wait on the branch lock"

    send(locker.pid, :release)
    Task.await(locker)
    assert {:ok, :created, _story} = Task.await(opener_task, 10_000)
  end

  # TC-52.18.4
  test "two holders racing one branch yield one item", %{tenant: tenant, epic: epic} = ctx do
    attrs = %{
      "repo_url" => "https://github.com/mkreyman/chg",
      "branch" => "fix/race",
      "epic_id" => epic.id
    }

    results =
      ctx.holders
      |> Enum.map(fn holder ->
        Task.async(fn ->
          :ok =
            ProductionTopology.checkout_unboxed!([Repo, AdminRepo],
              ownership_timeout: @ownership_timeout
            )

          opener = %{
            api_key_id: Ecto.UUID.generate(),
            agent_id: holder.agent_id,
            holder_id: holder.id
          }

          {holder.id, WorkItems.open_interactive(tenant.id, opener, attrs)}
        end)
      end)
      |> Task.await_many(:timer.seconds(30))

    created = for {_h, {:ok, :created, story}} <- results, do: story

    refused =
      for {_h, {:error, {:branch_held, story_id, holder_id}}} <- results,
          do: {story_id, holder_id}

    assert [story] = created
    assert [{story_id, winner}] = refused
    assert story_id == story.id
    assert winner == story.assigned_holder_id

    assert AdminRepo.aggregate(from(s in Story, where: s.tenant_id == ^tenant.id), :count) == 1
  end
end
