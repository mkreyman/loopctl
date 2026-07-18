defmodule Loopctl.Workers.ChannelPostSweeperTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Workers.ChannelPostSweeper

  # There is no channel_post fixture: create_post/4 always stamps expires_at at
  # now + 30d, so it cannot build an already-expired row. Insert ChannelPost
  # structs directly via AdminRepo (all fields set programmatically, never via
  # changeset) so we control expires_at. Use AdminRepo (BYPASSRLS) for every
  # read/write — the RLS repo would hide/deny these rows.
  defp insert_post(tenant, project, agent, offset_seconds) do
    %ChannelPost{
      tenant_id: tenant.id,
      project_id: project.id,
      agent_id: agent.id,
      body: "post",
      expires_at: DateTime.add(DateTime.utc_now(), offset_seconds, :second)
    }
    |> AdminRepo.insert!()
  end

  defp setup_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project, agent: agent}
  end

  describe "perform/1" do
    # TC-39.5.1
    test "deletes channel posts past expires_at and leaves live ones" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()

      expired = insert_post(tenant, project, agent, -60)
      live = insert_post(tenant, project, agent, 3600)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})

      assert is_nil(AdminRepo.get(ChannelPost, expired.id))
      refute is_nil(AdminRepo.get(ChannelPost, live.id))
    end

    # TC-39.5.2
    test "is idempotent: no expired rows means a zero-delete no-op on repeated runs" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()

      live = insert_post(tenant, project, agent, 3600)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})
      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})

      refute is_nil(AdminRepo.get(ChannelPost, live.id))
    end

    # TC-39.5.3
    test "honors the per-run batch bound: at most limit deleted per run, rest swept next run" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()

      # Three expired rows, a batch limit of 2: first run deletes 2, one remains,
      # second run deletes the last.
      for _ <- 1..3, do: insert_post(tenant, project, agent, -60)

      job = %Oban.Job{args: %{"limit" => 2}}

      assert :ok = ChannelPostSweeper.perform(job)
      assert AdminRepo.aggregate(expired_query(), :count) == 1

      assert :ok = ChannelPostSweeper.perform(job)
      assert AdminRepo.aggregate(expired_query(), :count) == 0
    end

    # TC-39.5.4 — AC-39.5.3: the BYPASSRLS sweep is cross-tenant. The predicate
    # (`expires_at < now()`) carries no tenant column, so a SINGLE perform/1 run
    # must delete an expired row under tenant A while leaving a live row under a
    # DIFFERENT tenant B untouched. This exercises the "across ALL tenants" half
    # of the AC that the single-tenant cases above only assert implicitly.
    test "sweeps expired rows across all tenants in one run, leaving live rows in other tenants" do
      %{tenant: tenant_a, project: project_a, agent: agent_a} = setup_context()
      %{tenant: tenant_b, project: project_b, agent: agent_b} = setup_context()

      assert tenant_a.id != tenant_b.id

      expired_a = insert_post(tenant_a, project_a, agent_a, -60)
      live_b = insert_post(tenant_b, project_b, agent_b, 3600)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})

      assert is_nil(AdminRepo.get(ChannelPost, expired_a.id))
      refute is_nil(AdminRepo.get(ChannelPost, live_b.id))
    end
  end

  defp expired_query do
    import Ecto.Query
    now = DateTime.utc_now()
    from(p in ChannelPost, where: p.expires_at < ^now)
  end
end
