defmodule Loopctl.Workers.ComputeSthWorkerTest do
  @moduledoc """
  Tests for US-32.5 -- STH all-tenants fanout uses Oban.insert_all with
  scheduled jitter.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ComputeSthWorker

  import Ecto.Query

  # The test DB may carry pre-existing active tenants committed outside this
  # test's sandbox transaction (e.g. from a scale-test run). Since the
  # `all_tenants` fanout genuinely queries ALL active tenants system-wide (no
  # tenant scoping applies to that query), neutralize any such rows within
  # this test's own transaction so assertions about exact fanout counts are
  # deterministic. This update is rolled back at the end of the test like
  # everything else in the sandbox -- it never touches real data permanently.
  setup do
    AdminRepo.update_all(from(t in Tenant, where: t.status == :active), set: [status: :suspended])
    :ok
  end

  # Mirrors the jitter derivation in ComputeSthWorker (AC-32.5.2): bounded,
  # deterministic-per-tenant, independent of the unique dedup key.
  defp expected_jitter(tenant_id), do: rem(:erlang.phash2(tenant_id), 56)

  describe "perform/1 with mode: all_tenants" do
    test "TC-32.5.1: one job per active tenant via batch, each within the jitter window" do
      active_1 = fixture(:tenant)
      active_2 = fixture(:tenant)
      active_3 = fixture(:tenant)
      inactive = fixture(:tenant, %{status: :suspended})

      now = DateTime.utc_now()

      result =
        Oban.Testing.with_testing_mode(:manual, fn ->
          ComputeSthWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})
        end)

      assert result == :ok

      tenant_jobs =
        all_enqueued(worker: ComputeSthWorker)
        |> Enum.filter(&Map.has_key?(&1.args, "tenant_id"))

      assert length(tenant_jobs) == 3

      enqueued_tenant_ids = Enum.map(tenant_jobs, & &1.args["tenant_id"])
      assert Enum.sort(enqueued_tenant_ids) == Enum.sort([active_1.id, active_2.id, active_3.id])
      refute inactive.id in enqueued_tenant_ids

      for job <- tenant_jobs do
        tenant_id = job.args["tenant_id"]
        diff = DateTime.diff(job.scheduled_at, now)

        assert diff in 0..55
        assert diff == expected_jitter(tenant_id)
      end
    end

    test "TC-32.5.2: no active tenants is a no-op" do
      fixture(:tenant, %{status: :suspended})

      result =
        Oban.Testing.with_testing_mode(:manual, fn ->
          ComputeSthWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})
        end)

      assert result == :ok

      tenant_jobs =
        all_enqueued(worker: ComputeSthWorker)
        |> Enum.filter(&Map.has_key?(&1.args, "tenant_id"))

      assert tenant_jobs == []
    end
  end

  describe "perform/1 with tenant_id (per-tenant STH computation, unchanged)" do
    test "TC-32.5.3: still signs and stores the tree head as before" do
      tenant = fixture(:tenant, %{slug: "sth-fanout-#{System.unique_integer([:positive])}"})
      pub_key = :crypto.strong_rand_bytes(32)

      tenant =
        tenant
        |> Ecto.Changeset.change(audit_signing_public_key: pub_key)
        |> Loopctl.AdminRepo.update!()

      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
      Loopctl.TenantKeys.init_cache()

      {:ok, _} =
        AuditChain.append(tenant.id, %{
          action: "test_event",
          actor_lineage: ["test"],
          entity_type: "test",
          payload: %{"k" => "v"}
        })

      {matching_pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)

      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: matching_pub)
      |> Loopctl.AdminRepo.update!()

      assert :ok = ComputeSthWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
    end
  end
end
