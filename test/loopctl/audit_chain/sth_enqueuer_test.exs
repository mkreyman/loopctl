defmodule Loopctl.AuditChain.SthEnqueuerTest do
  @moduledoc """
  US-35.2 — Event-driven STH: audit-append firehose topic + supervised
  debounce-enqueuer.

  Covers TC-35.2.1..4:
    * the append firehose broadcast (additive to the per-tenant topic),
    * Basic-Engine-safe burst coalescing via Oban `unique`,
    * end-to-end correctness (a firehose append drives an STH at the new
      position through the LIVE GenServer), and
    * resilience (malformed/unknown messages and enqueue errors never crash the
      subscriber).

  The app's boot `SthEnqueuer` singleton does NOT subscribe under the test
  sandbox (`config :loopctl, :sth_enqueuer_subscribe, false`), so tests that need
  a live subscriber start their OWN named instance with `subscribe: true` and
  grant it the sandbox connection.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.PubSub, as: ChainPubSub
  alias Loopctl.AuditChain.SthEnqueuer
  alias Loopctl.TenantKeys
  alias Loopctl.Workers.ComputeSthWorker

  setup :verify_on_exit!

  defp append_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        action: "test_event",
        actor_lineage: ["test"],
        entity_type: "test",
        payload: %{"k" => "v"}
      },
      overrides
    )
  end

  # Set up a tenant whose audit-signing key is primed in the TenantKeys ETS
  # cache (in THIS owner process, consuming the single MockSecrets expectation),
  # so a DIFFERENT process (the live enqueuer) can sign its STH via a pure cache
  # read — no cross-process Mox allowance needed.
  defp setup_keyed_tenant do
    tenant = fixture(:tenant, %{slug: "sth-enq-#{System.unique_integer([:positive])}"})
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {matching_pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)

    tenant =
      tenant
      |> Ecto.Changeset.change(audit_signing_public_key: matching_pub)
      |> AdminRepo.update!()

    Mox.expect(Loopctl.MockSecrets, :get, fn _name -> {:ok, priv} end)
    TenantKeys.init_cache()
    {:ok, _priv} = TenantKeys.get_private_key(tenant.id)

    tenant
  end

  describe "AuditChain.append/1 firehose broadcast (AC-35.2.1)" do
    # The firehose is a SINGLE fixed topic shared by every tenant (and, in the
    # async suite, every concurrently-running test that appends). Assertions here
    # therefore SELECT this test's own tenant via a guard and use a generous
    # timeout, so foreign firehose traffic and PubSub delivery latency under
    # parallel load can never cause a spurious miss.
    test "TC-35.2.1: append broadcasts the entry to BOTH the per-tenant and firehose topics" do
      tenant = fixture(:tenant)

      :ok = ChainPubSub.subscribe(tenant.id)
      :ok = ChainPubSub.subscribe_firehose()

      {:ok, entry} = AuditChain.append(tenant.id, append_attrs())
      entry_id = entry.id

      # Existing per-tenant behavior is unchanged: the same {:audit_chain_entry,
      # entry} message still lands on the per-tenant topic (which is unique to
      # this tenant).
      assert_receive {:audit_chain_entry, %{id: ^entry_id} = per_tenant_entry}, 1_000
      assert per_tenant_entry.tenant_id == tenant.id
      assert per_tenant_entry.chain_position == entry.chain_position

      # New: the SAME message shape ALSO lands on the fixed firehose topic,
      # carrying entry.tenant_id (the subscriber's only tenant-scoping input).
      # Select this entry by id to ignore concurrent tests' firehose traffic.
      assert_receive {:audit_chain_entry, %{id: ^entry_id} = firehose_entry}, 1_000
      assert firehose_entry.tenant_id == tenant.id
    end

    test "TC-35.2.1b: the firehose topic is a single fixed cross-tenant topic (not per-tenant)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      :ok = ChainPubSub.subscribe_firehose()

      {:ok, entry_a} = AuditChain.append(tenant_a.id, append_attrs())
      {:ok, entry_b} = AuditChain.append(tenant_b.id, append_attrs())

      a_id = entry_a.id
      b_id = entry_b.id

      # One firehose subscription observes appends from EVERY tenant. Select by
      # entry id (unique) to tolerate other async tests broadcasting concurrently.
      assert_receive {:audit_chain_entry, %{id: ^a_id, tenant_id: a_tid}}, 1_000
      assert_receive {:audit_chain_entry, %{id: ^b_id, tenant_id: b_tid}}, 1_000

      assert a_tid == tenant_a.id
      assert b_tid == tenant_b.id
    end
  end

  describe "enqueue_sth_job/1 burst coalescing (AC-35.2.3 / AC-35.2.6)" do
    test "TC-35.2.2: a burst of appends for one tenant collapses to exactly one scheduled job" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        # Five appends for tenant A within the debounce window (simulated by five
        # direct enqueue calls, the exact path handle_info/2 drives). Oban
        # `unique` dedups at the DB, so only one job survives.
        for _ <- 1..5 do
          assert {:ok, _job} = SthEnqueuer.enqueue_sth_job(%{tenant_id: tenant_a.id})
        end

        # A different tenant gets its OWN independent job (strictly per-tenant).
        assert {:ok, _job} = SthEnqueuer.enqueue_sth_job(%{tenant_id: tenant_b.id})
      end)

      jobs = all_enqueued(worker: ComputeSthWorker)

      a_jobs = Enum.filter(jobs, &(&1.args["tenant_id"] == tenant_a.id))
      b_jobs = Enum.filter(jobs, &(&1.args["tenant_id"] == tenant_b.id))

      # Exactly one scheduled ComputeSthWorker job for A (coalesced), not five.
      assert length(a_jobs) == 1
      # Tenant isolation: B's append produced a strictly separate, per-tenant job;
      # the coalescing never merged across tenants.
      assert length(b_jobs) == 1

      # The job is scheduled with the debounce delay (not run immediately).
      [a_job] = a_jobs
      assert a_job.state in ["scheduled", "available"]
    end

    test "TC-35.2.2b: the enqueued job uses string arg keys (Oban JSON Iron Law)" do
      tenant = fixture(:tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, _job} = SthEnqueuer.enqueue_sth_job(%{tenant_id: tenant.id})
      end)

      [job] = all_enqueued(worker: ComputeSthWorker)
      assert job.args == %{"tenant_id" => tenant.id}
    end
  end

  describe "live enqueuer end-to-end (AC-35.2.2 / AC-35.2.4)" do
    test "TC-35.2.3: a firehose entry drives the enqueuer to compute an STH at the new position" do
      tenant = setup_keyed_tenant()

      # An entry must exist on the chain for there to be something to sign.
      {:ok, entry} = AuditChain.append(tenant.id, append_attrs())

      name = :"sth_enqueuer_e2e_#{System.unique_integer([:positive])}"

      # subscribe: false so this test drives handle_info/2 with EXACTLY its own
      # message (the shared firehose would otherwise flood the enqueuer with
      # concurrent tests' appends and force it to share this test's single
      # sandbox connection while we query). We grant it the sandbox so its inline
      # Oban run (ComputeSthWorker.perform → sign_and_store_tree_head via
      # AdminRepo, reading the pre-primed TenantKeys cache) is visible here.
      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: false]}, id: name)
        )

      Sandbox.allow(Loopctl.Repo, self(), pid)
      Sandbox.allow(Loopctl.AdminRepo, self(), pid)

      # Deliver the firehose message shape directly, then synchronize on the
      # GenServer: :sys.get_state is handled AFTER the queued handle_info, so the
      # inline STH computation is complete (and this process was NOT querying the
      # shared connection during it) before we read the result.
      send(pid, {:audit_chain_entry, entry})
      :sys.get_state(pid)

      sth = AuditChain.get_latest_sth(tenant.id)

      assert %AuditChain.SignedTreeHead{} = sth
      assert sth.chain_position == entry.chain_position
    end

    test "TC-35.2.3b: a started enqueuer subscribes to the firehose and reacts to a real append" do
      # A subscribe: true enqueuer NOT granted the sandbox: a real append's
      # firehose broadcast reaches it (proving on-start subscription), its
      # Oban.insert fails without an owned connection, and it logs-and-survives
      # (resilience) rather than crashing. This exercises the actual PubSub wiring
      # without the shared-connection hazard of asserting the STH here.
      tenant = fixture(:tenant)

      name = :"sth_enqueuer_sub_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: true]}, id: name)
        )

      log =
        capture_log(fn ->
          {:ok, _entry} = AuditChain.append(tenant.id, append_attrs())
          # Barrier: the firehose message is enqueued into pid's mailbox before
          # append/1 returns (local PubSub delivery is a synchronous send), so
          # this system message is processed strictly after that handle_info.
          :sys.get_state(pid)
        end)

      assert Process.alive?(pid)
      assert log =~ "SthEnqueuer"
    end
  end

  describe "resilience (AC-35.2.5)" do
    test "TC-35.2.4: an enqueue error is logged and never crashes the enqueuer" do
      name = :"sth_enqueuer_resilient_#{System.unique_integer([:positive])}"

      # subscribe: false so we drive handle_info/2 directly; the instance is NOT
      # granted the sandbox, so Oban.insert raises an ownership error — exactly
      # the "enqueue fails" condition the enqueuer must tolerate.
      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: false]}, id: name)
        )

      log =
        capture_log(fn ->
          send(pid, {:audit_chain_entry, %{tenant_id: Ecto.UUID.generate()}})
          # Synchronization barrier: :sys.get_state is handled after the queued
          # handle_info, so by the time it returns the enqueue attempt is done.
          :sys.get_state(pid)
        end)

      assert Process.alive?(pid)
      assert log =~ "SthEnqueuer"
    end

    test "TC-35.2.4b: a malformed entry (no/invalid tenant_id) is logged and ignored" do
      name = :"sth_enqueuer_malformed_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: false]}, id: name)
        )

      capture_log(fn ->
        # No tenant_id key at all.
        send(pid, {:audit_chain_entry, %{}})
        # Non-binary tenant_id.
        send(pid, {:audit_chain_entry, %{tenant_id: make_ref()}})
        :sys.get_state(pid)
      end)

      assert Process.alive?(pid)
    end

    test "TC-35.2.4c: an unknown message is ignored and never crashes the enqueuer" do
      name = :"sth_enqueuer_unknown_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: false]}, id: name)
        )

      send(pid, :some_unexpected_message)
      send(pid, {:not, :a, :known, :shape})
      # Barrier: both messages processed by the time this returns.
      assert %{} = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end
end
