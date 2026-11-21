defmodule Loopctl.Coordination.MessagesRaceTest do
  @moduledoc """
  US-52.22 TC-52.22.2: two inserts on one attachment take consecutive `attachment_seq`
  values and commit in that order.

  `async: false` because the subject is committed transactions racing each other: inside the
  SQL sandbox every allowed process shares one connection, which serialises the inserts on
  its own and would pass with no lock at all. So the rows are COMMITTED under
  `fixture(:committed_tenant)`, each process runs on production's connections
  (`Loopctl.Test.ProductionTopology`), and the module sweeps the tenants it committed
  (`track_committed_tenants/0`).
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Coordination.Messages
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology

  @ownership_timeout :timer.seconds(60)

  setup_all do
    %{ledger: track_committed_tenants()}
  end

  setup %{ledger: ledger} do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    track_committed_tenant(ledger, tenant.id)
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    %{
      tenant: tenant,
      project: fixture(:project, %{tenant_id: tenant.id}),
      agent: fixture(:agent, %{tenant_id: tenant.id})
    }
  end

  defp message(ctx, body) do
    %ChannelPost{tenant_id: ctx.tenant.id, project_id: ctx.project.id, agent_id: ctx.agent.id}
    |> ChannelPost.create_changeset(%{"body" => body})
  end

  defp in_own_connection(fun) do
    Task.async(fn ->
      :ok =
        ProductionTopology.checkout_unboxed!([AdminRepo], ownership_timeout: @ownership_timeout)

      fun.()
    end)
  end

  test "T2 waits on T1's attachment lock, takes n + 1, and commits after T1", ctx do
    parent = self()

    # T1 inserts and holds its transaction open.
    t1 =
      in_own_connection(fn ->
        AdminRepo.transaction(fn ->
          {:ok, post} = Messages.insert(message(ctx, "first"))
          send(parent, {:t1_inserted, post.attachment_seq})

          receive do
            :commit -> :ok
          end

          post
        end)
      end)

    assert_receive {:t1_inserted, n}, 5_000

    # T2 on the same channel blocks on the advisory lock T1 holds.
    t2 =
      in_own_connection(fn ->
        AdminRepo.transaction(fn ->
          {:ok, post} = Messages.insert(message(ctx, "second"))
          post
        end)
      end)

    # T2 cannot finish (so cannot commit) while T1 is open.
    assert Task.yield(t2, 500) == nil, "T2 did not wait on the attachment lock"

    send(t1.pid, :commit)
    assert {:ok, first} = Task.await(t1, 10_000)
    assert {:ok, second} = Task.await(t2, 10_000)

    assert first.attachment_seq == n
    assert second.attachment_seq == n + 1

    seqs =
      AdminRepo.all(
        from(p in ChannelPost,
          where: p.tenant_id == ^ctx.tenant.id,
          order_by: p.attachment_seq,
          select: {p.body, p.attachment_seq}
        )
      )

    assert seqs == [{"first", n}, {"second", n + 1}]
  end

  test "another attachment never waits on the lock", ctx do
    parent = self()
    other = fixture(:project, %{tenant_id: ctx.tenant.id})

    holder =
      in_own_connection(fn ->
        AdminRepo.transaction(fn ->
          {:ok, _} = Messages.insert(message(ctx, "held"))
          send(parent, :held)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :held, 5_000

    elsewhere =
      in_own_connection(fn ->
        %ChannelPost{tenant_id: ctx.tenant.id, project_id: other.id, agent_id: ctx.agent.id}
        |> ChannelPost.create_changeset(%{"body" => "elsewhere"})
        |> Messages.insert()
      end)

    assert {:ok, {:ok, %ChannelPost{attachment_seq: 1}}} = Task.yield(elsewhere, 5_000)

    send(holder.pid, :commit)
    Task.await(holder, 10_000)
  end
end
