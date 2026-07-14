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
  # deterministic-per-tenant, independent of the unique dedup key. The window
  # itself is pulled from `ComputeSthWorker.jitter_window_seconds/0` (the
  # implementation's single source of truth) so this can never silently drift
  # from `@jitter_window_seconds` if the window is retuned.
  defp expected_jitter(tenant_id),
    do: rem(:erlang.phash2(tenant_id), ComputeSthWorker.jitter_window_seconds())

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

      max_jitter = ComputeSthWorker.jitter_window_seconds() - 1

      for job <- tenant_jobs do
        tenant_id = job.args["tenant_id"]
        diff = DateTime.diff(job.scheduled_at, now)
        expected = expected_jitter(tenant_id)

        # `scheduled_at` is computed from `utc_now()` at build time (after
        # `now` was captured above), and DateTime.diff truncates to whole
        # seconds -- so diff normally equals `expected` but can be
        # `expected + 1` if wall-clock time crosses a second boundary between
        # capturing `now` and building the job. A single hard bound tolerates
        # that one second of build-time elapsed while still enforcing
        # AC-32.5.2's [0, max_jitter] production bound: at `expected ==
        # max_jitter` the tolerated `expected + 1` is `max_jitter + 1`, so the
        # hard bound must extend one second past `max_jitter` too (previously
        # two separate assertions contradicted each other exactly at that
        # boundary).
        assert diff in expected..(expected + 1)
        assert diff in 0..(max_jitter + 1)
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

      # Guard against a storage-path regression: `:ok` alone is also
      # returned on the sth_needed?==false and :empty_chain branches, so
      # assert the STH was actually signed and persisted for this tenant.
      sth = AuditChain.get_latest_sth(tenant.id)
      assert %AuditChain.SignedTreeHead{} = sth
      assert sth.chain_position == 0
    end
  end

  # US-35.3: the reduced-frequency cron is only a SCHEDULING change; the
  # all-tenants fanout + per-tenant self-gating is unchanged. These tests prove
  # the bounded-lag safety net: with the event-driven enqueuer (US-35.2) OFF
  # (config/test.exs sets :sth_enqueuer_subscribe = false, so the event path is
  # already disabled here — no runtime toggling), running ONE sweep still signs
  # an STH at the latest chain position for any tenant that appended between
  # sweeps, and never produces a spurious STH when nothing changed.
  describe "US-35.3: reduced-frequency safety sweep (AC-35.3.2/.3, TC-35.3.2/.3)" do
    test "TC-35.3.2: a tenant that appended between sweeps gets an STH by the next sweep" do
      {tenant, _priv} = signing_tenant()

      # Two appends -> latest chain_position is 1.
      {:ok, _} = AuditChain.append(tenant.id, append_attrs())
      {:ok, _} = AuditChain.append(tenant.id, append_attrs())

      # No STH yet: the event path is off and no sweep has run.
      assert AuditChain.get_latest_sth(tenant.id) == nil

      # Run exactly ONE all-tenants safety sweep and drain the fanned-out
      # per-tenant jobs (persist under :manual, then execute via drain).
      run_one_sweep()

      sth = AuditChain.get_latest_sth(tenant.id)
      assert %AuditChain.SignedTreeHead{} = sth
      # Bounded-lag guarantee: STH lands at the LATEST appended position.
      assert sth.chain_position == 1
      assert sth_count(tenant.id) == 1
    end

    test "TC-35.3.3: a tenant already at head gets no new STH from a sweep (self-gated)" do
      {tenant, _priv} = signing_tenant()

      {:ok, _} = AuditChain.append(tenant.id, append_attrs())

      # Sign an STH at head first (via the per-tenant path).
      assert :ok = ComputeSthWorker.perform(%Oban.Job{args: %{"tenant_id" => tenant.id}})
      sth_before = AuditChain.get_latest_sth(tenant.id)
      assert %AuditChain.SignedTreeHead{chain_position: 0} = sth_before
      assert sth_count(tenant.id) == 1
      refute AuditChain.sth_needed?(tenant.id)

      # A subsequent sweep with no new entries must be a no-op (self-gated).
      run_one_sweep()

      sth_after = AuditChain.get_latest_sth(tenant.id)
      assert sth_after.chain_position == 0
      assert sth_count(tenant.id) == 1
    end
  end

  # Sets up an active tenant whose stored audit_signing_public_key matches the
  # private key returned by MockSecrets, so `sign_and_store_tree_head/1`
  # succeeds. `append/3` does not touch the signing key, so a single key set is
  # sufficient (unlike the two-step dance TC-32.5.3 uses for illustration).
  defp signing_tenant do
    tenant = fixture(:tenant, %{slug: "sth-sweep-#{System.unique_integer([:positive])}"})
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {matching_pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: matching_pub)
      |> AdminRepo.update!()

    # Stub (not expect) so any number of sign calls resolve the same key.
    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    Loopctl.TenantKeys.init_cache()

    {tenant, priv}
  end

  defp append_attrs do
    %{
      action: "test_event",
      actor_lineage: ["test"],
      entity_type: "test",
      payload: %{"k" => "v"}
    }
  end

  # Runs one all-tenants sweep and drains the fanned-out per-tenant :audit jobs.
  # Under :manual the fanout persists jobs (instead of executing inline), then
  # `drain_queue(with_scheduled: true)` executes them past their jitter delay --
  # the deterministic analogue of the cron sweep + queue draining in production.
  defp run_one_sweep do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = ComputeSthWorker.perform(%Oban.Job{args: %{"mode" => "all_tenants"}})
      Oban.drain_queue(queue: :audit, with_scheduled: true)
    end)
  end

  defp sth_count(tenant_id) do
    AdminRepo.aggregate(
      from(s in AuditChain.SignedTreeHead, where: s.tenant_id == ^tenant_id),
      :count
    )
  end
end
