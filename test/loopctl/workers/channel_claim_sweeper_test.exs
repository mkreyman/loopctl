defmodule Loopctl.Workers.ChannelClaimSweeperTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Workers.ChannelClaimSweeper

  # A DONE claim older than the retention window (done_at < now - 7d).
  defp done_and_old(ctx) do
    old =
      DateTime.add(DateTime.utc_now(), -(Coordination.claim_done_retention_days() + 1) * 86_400)

    fixture(:channel_claim, Map.merge(ctx, %{done_at: old, lease_expires_at: old}))
  end

  # An abandoned lease: not done, lease already expired.
  defp expired_open(ctx) do
    past = DateTime.add(DateTime.utc_now(), -60)
    fixture(:channel_claim, Map.merge(ctx, %{done_at: nil, lease_expires_at: past}))
  end

  # An OPEN, unexpired claim — must NEVER be swept.
  defp open_unexpired(ctx) do
    future = DateTime.add(DateTime.utc_now(), 3600)
    fixture(:channel_claim, Map.merge(ctx, %{done_at: nil, lease_expires_at: future}))
  end

  # A DONE-but-RECENT claim (within retention) — must NOT be swept yet.
  defp done_recent(ctx) do
    now = DateTime.utc_now()
    fixture(:channel_claim, Map.merge(ctx, %{done_at: now, lease_expires_at: now}))
  end

  defp base(tenant, project) do
    %{tenant_id: tenant.id, project_id: project.id}
  end

  # Tenant-scoped live-row count. The concurrent race test
  # (coordination_claim_race_test.exs) runs sandbox:false and transiently commits
  # a channel_claim row visible to other async connections via READ COMMITTED, so a
  # GLOBAL `AdminRepo.aggregate(ChannelClaim, :count)` would flake. Scope to the
  # test's own tenant.
  defp live_count(tenant) do
    AdminRepo.aggregate(from(c in ChannelClaim, where: c.tenant_id == ^tenant.id), :count)
  end

  describe "perform/1 — lifecycle-aware reclaim (TC-40.B1.5)" do
    test "sweeps done+old and abandoned-lease claims; leaves open+unexpired and done+recent" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      ctx = base(tenant, project)

      old_done = done_and_old(ctx)
      abandoned = expired_open(ctx)
      open = open_unexpired(ctx)
      recent_done = done_recent(ctx)

      assert :ok = ChannelClaimSweeper.perform(%Oban.Job{args: %{}})

      # Reclaimed
      assert is_nil(AdminRepo.get(ChannelClaim, old_done.id))
      assert is_nil(AdminRepo.get(ChannelClaim, abandoned.id))

      # Survivors — an open unexpired claim MUST NEVER be deleted; a done claim
      # within retention is kept as an audit/idempotency breadcrumb.
      refute is_nil(AdminRepo.get(ChannelClaim, open.id))
      refute is_nil(AdminRepo.get(ChannelClaim, recent_done.id))
    end

    test "an abandoned lease reopens the ref (its slot frees for a re-claim)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      abandoned =
        fixture(:channel_claim, %{
          tenant_id: tenant.id,
          project_id: project.id,
          ref: "handoff:repo#812",
          done_at: nil,
          lease_expires_at: DateTime.add(DateTime.utc_now(), -60)
        })

      assert :ok = ChannelClaimSweeper.perform(%Oban.Job{args: %{}})
      assert is_nil(AdminRepo.get(ChannelClaim, abandoned.id))

      # The unique (tenant, project, ref) slot is free — a fresh claim of the same
      # ref now inserts cleanly (no already_claimed). Tenant-scoped: the race test
      # commits a row with the same ref in a DIFFERENT tenant.
      assert AdminRepo.aggregate(
               from(c in ChannelClaim,
                 where: c.ref == "handoff:repo#812" and c.tenant_id == ^tenant.id
               ),
               :count
             ) == 0
    end

    test "is idempotent: nothing reclaimable is a zero-delete no-op" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      open = open_unexpired(base(tenant, project))

      assert :ok = ChannelClaimSweeper.perform(%Oban.Job{args: %{}})
      assert :ok = ChannelClaimSweeper.perform(%Oban.Job{args: %{}})

      refute is_nil(AdminRepo.get(ChannelClaim, open.id))
    end

    test "honors the per-run batch bound" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      ctx = base(tenant, project)

      for _ <- 1..3, do: expired_open(ctx)

      job = %Oban.Job{args: %{"limit" => 2}}
      assert :ok = ChannelClaimSweeper.perform(job)
      assert live_count(tenant) == 1

      assert :ok = ChannelClaimSweeper.perform(job)
      assert live_count(tenant) == 0
    end

    test "clamps an oversized limit arg so it never exceeds the bind-parameter cap" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      ctx = base(tenant, project)

      for _ <- 1..3, do: expired_open(ctx)

      assert :ok = ChannelClaimSweeper.perform(%Oban.Job{args: %{"limit" => 70_000}})
      assert live_count(tenant) == 0
    end

    test "sweeps across all tenants in one run (BYPASSRLS, tenant-independent predicate)" do
      t_a = fixture(:tenant)
      p_a = fixture(:project, %{tenant_id: t_a.id})
      t_b = fixture(:tenant)
      p_b = fixture(:project, %{tenant_id: t_b.id})

      abandoned_a = expired_open(base(t_a, p_a))
      open_b = open_unexpired(base(t_b, p_b))

      assert :ok = ChannelClaimSweeper.perform(%Oban.Job{args: %{}})

      assert is_nil(AdminRepo.get(ChannelClaim, abandoned_a.id))
      refute is_nil(AdminRepo.get(ChannelClaim, open_b.id))
    end
  end
end
