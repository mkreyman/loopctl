defmodule Loopctl.Workers.PendingEnrollmentCleanupWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.PendingEnrollmentCleanupWorker

  # A cutoff older than the TTL — any tenant we age past this is "abandoned".
  defp cutoff,
    do: DateTime.add(DateTime.utc_now(), -Tenants.pending_enrollment_ttl_seconds(), :second)

  # Force a tenant's inserted_at into the past so it predates the TTL cutoff.
  defp age_tenant(tenant, seconds_ago) do
    old = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    {1, _} =
      from(t in Tenant, where: t.id == ^tenant.id)
      |> AdminRepo.update_all(set: [inserted_at: old])

    tenant
  end

  # An abandoned ceremony: pending_enrollment and older than the TTL.
  defp abandoned_tenant do
    fixture(:tenant, %{status: :pending_enrollment})
    |> age_tenant(Tenants.pending_enrollment_ttl_seconds() + 300)
  end

  describe "perform/1" do
    test "deletes abandoned pending-enrollment tenants past the TTL" do
      tenant = abandoned_tenant()

      assert :ok = PendingEnrollmentCleanupWorker.perform(%Oban.Job{})

      assert AdminRepo.get(Tenant, tenant.id) == nil
    end

    test "keeps pending-enrollment tenants still inside the TTL" do
      # inserted_at defaults to "now", so it is newer than the cutoff.
      recent = fixture(:tenant, %{status: :pending_enrollment})

      assert :ok = PendingEnrollmentCleanupWorker.perform(%Oban.Job{})

      assert AdminRepo.get(Tenant, recent.id) != nil
    end

    test "keeps active tenants regardless of age" do
      active_old =
        fixture(:tenant, %{status: :active})
        |> age_tenant(Tenants.pending_enrollment_ttl_seconds() + 300)

      assert :ok = PendingEnrollmentCleanupWorker.perform(%Oban.Job{})

      assert AdminRepo.get(Tenant, active_old.id) != nil
    end
  end

  describe "delete_abandoned/2 (worker-03: SELECT-then-DELETE race)" do
    test "deletes a candidate that is still pending and old" do
      tenant = abandoned_tenant()

      assert {1, _} = PendingEnrollmentCleanupWorker.delete_abandoned([tenant.id], cutoff())
      assert AdminRepo.get(Tenant, tenant.id) == nil
    end

    test "does NOT delete a candidate that activated after being observed" do
      # The tenant was :pending_enrollment + old when the observing SELECT
      # captured its id. Simulate the race: its WebAuthn activation Multi
      # commits in the window BEFORE the DELETE fires.
      tenant = abandoned_tenant()

      activated =
        tenant
        |> Tenant.activate_after_enrollment_changeset()
        |> AdminRepo.update!()

      assert activated.status == :active

      # The guarded DELETE re-checks status + cutoff atomically, so the now
      # active tenant is excluded. The pre-fix id-only DELETE would destroy it.
      assert {0, _} = PendingEnrollmentCleanupWorker.delete_abandoned([tenant.id], cutoff())

      survivor = AdminRepo.get(Tenant, tenant.id)
      assert survivor != nil
      assert survivor.status == :active
    end

    test "does NOT delete a candidate that is pending but no longer old" do
      # e.g. clock skew / a candidate that only just crossed into the window;
      # the DELETE re-checks the cutoff so a fresh tenant is left alone.
      fresh = fixture(:tenant, %{status: :pending_enrollment})

      assert {0, _} = PendingEnrollmentCleanupWorker.delete_abandoned([fresh.id], cutoff())
      assert AdminRepo.get(Tenant, fresh.id) != nil
    end
  end
end
