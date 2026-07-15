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

      # New: a MINIMAL tenant-scoped notification ALSO lands on the fixed firehose
      # topic — same {:audit_chain_entry, _} tuple tag, but the payload is
      # minimized to %{tenant_id: ...} (the subscriber's only tenant-scoping
      # input). Select by this test's unique tenant_id to ignore concurrent tests'
      # firehose traffic.
      firehose_tid = tenant.id
      assert_receive {:audit_chain_entry, %{tenant_id: ^firehose_tid} = firehose_msg}, 1_000

      # The full entry — its :id, arbitrary :payload map, and :actor_lineage —
      # is NEVER placed on the shared cross-tenant firehose (only tenant_id is).
      refute Map.has_key?(firehose_msg, :id)
      refute Map.has_key?(firehose_msg, :payload)
      refute Map.has_key?(firehose_msg, :actor_lineage)

      # AC-35.2.1 also names {:sth_updated,…} and external (witness-cache)
      # subscribers as UNCHANGED. broadcast_sth/2 is untouched by this story, so
      # an STH broadcast must still reach the per-tenant subscriber and must NOT
      # leak onto the firehose (which carries only {:audit_chain_entry,…}). Prove
      # both from the one process subscribed to BOTH topics: consume the
      # per-tenant {:sth_updated}, then refute any further {:sth_updated} (i.e.
      # the firehose did not also deliver one).
      sth = %{id: entry_id, tenant_id: tenant.id, chain_position: entry.chain_position}
      :ok = ChainPubSub.broadcast_sth(tenant.id, sth)

      assert_receive {:sth_updated, %{id: ^entry_id, tenant_id: sth_tid}}, 1_000
      assert sth_tid == tenant.id
      refute_receive {:sth_updated, _}, 200
    end

    test "TC-35.2.1b: the firehose topic is a single fixed cross-tenant topic (not per-tenant)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      :ok = ChainPubSub.subscribe_firehose()

      {:ok, _entry_a} = AuditChain.append(tenant_a.id, append_attrs())
      {:ok, _entry_b} = AuditChain.append(tenant_b.id, append_attrs())

      a_tid = tenant_a.id
      b_tid = tenant_b.id

      # One firehose subscription observes appends from EVERY tenant. The firehose
      # payload is minimized to %{tenant_id: ...}, so select by each test-unique
      # tenant_id (not entry id) to tolerate other async tests broadcasting
      # concurrently.
      assert_receive {:audit_chain_entry, %{tenant_id: ^a_tid}}, 1_000
      assert_receive {:audit_chain_entry, %{tenant_id: ^b_tid}}, 1_000
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

    test "TC-35.2.2c: a burst of REAL appends for one tenant, through the LIVE subscribed enqueuer, coalesces to exactly one scheduled job" do
      # AC-35.2.3 verbatim: append several entries for one tenant in quick
      # succession and assert exactly one ComputeSthWorker job is scheduled — but
      # driven through the WHOLE real path (append/1 -> firehose broadcast -> the
      # live GenServer's handle_info -> enqueue_sth_job -> Oban.insert), not five
      # direct enqueue calls. This catches a regression that mangled handle_info's
      # call into enqueue_sth_job (e.g. dropping the unique/schedule_in opts),
      # which the direct-call TC-35.2.2 cannot see.
      tenant = fixture(:tenant)
      other = fixture(:tenant)

      name = :"sth_enqueuer_coalesce_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: true]}, id: name)
        )

      # Grant the live enqueuer this test's sandbox so its Oban.insert lands in
      # our transaction and is visible to all_enqueued below. append/1 writes via
      # AdminRepo; the enqueue writes oban_jobs via Loopctl.Repo — distinct repos,
      # so the two never contend on one connection.
      Sandbox.allow(Loopctl.Repo, self(), pid)
      Sandbox.allow(Loopctl.AdminRepo, self(), pid)

      # The app-wide Oban testing mode is :inline, which EXECUTES each insert
      # immediately and so bypasses both `unique` and `schedule_in` — the very
      # DB-level coalescing under test. Oban resolves the engine from the
      # INSERTING process's dictionary, so seed the LIVE enqueuer's own dictionary
      # to :manual (Basic engine) via :sys.replace_state/2, which runs the fun
      # inside that process. No production knob — the seam is test-only.
      :sys.replace_state(pid, fn state ->
        Process.put(:oban_testing, :manual)
        state
      end)

      # Five real appends for ONE tenant in quick succession (within the debounce
      # window). Local PubSub delivery is a synchronous send, so each firehose
      # message is in the enqueuer's mailbox before append/1 returns; :sys.get_state
      # then drains that handle_info (and its insert) before the next append, so
      # the enqueuer never processes our message while we run the next append.
      for _ <- 1..5 do
        {:ok, _entry} = AuditChain.append(tenant.id, append_attrs())
        :sys.get_state(pid)
      end

      # A different tenant's real append produces its OWN independent job.
      {:ok, _entry} = AuditChain.append(other.id, append_attrs())
      :sys.get_state(pid)

      jobs = all_enqueued(worker: ComputeSthWorker)
      tenant_jobs = Enum.filter(jobs, &(&1.args["tenant_id"] == tenant.id))
      other_jobs = Enum.filter(jobs, &(&1.args["tenant_id"] == other.id))

      # Exactly one scheduled ComputeSthWorker job for the bursting tenant
      # (coalesced by Oban `unique`), not five — proving the real handle_info path
      # forwards the unique/schedule_in opts.
      assert length(tenant_jobs) == 1
      # Tenant isolation: the burst never merged the other tenant's job away.
      assert length(other_jobs) == 1

      [job] = tenant_jobs
      assert job.state in ["scheduled", "available"]
    end
  end

  describe "live enqueuer end-to-end (AC-35.2.2 / AC-35.2.4)" do
    test "TC-35.2.3: a REAL append, through the live firehose subscription, drives the enqueuer to compute an STH at the new position" do
      tenant = setup_keyed_tenant()

      name = :"sth_enqueuer_e2e_#{System.unique_integer([:positive])}"

      # A LIVE, subscribe: true enqueuer — this exercises the FULL join AC-35.2.4
      # names (real append -> firehose broadcast -> on-start subscription ->
      # handle_info -> STH computed), not a hand-delivered send. Granted the
      # sandbox so its inline Oban run (ComputeSthWorker.perform ->
      # sign_and_store_tree_head via AdminRepo, reading the pre-primed TenantKeys
      # cache) is visible here. start_supervised! returns only after init/1 (and
      # its subscribe_firehose) has completed, so the subscription is live before
      # the append below.
      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: true]}, id: name)
        )

      Sandbox.allow(Loopctl.Repo, self(), pid)
      Sandbox.allow(Loopctl.AdminRepo, self(), pid)

      # Real append: broadcasts {:audit_chain_entry, entry} to the fixed firehose
      # the live enqueuer subscribed to in init. Local PubSub delivery is a
      # synchronous send, so the message is in pid's mailbox before append/1
      # returns; :sys.get_state is then handled AFTER that queued handle_info, so
      # the inline STH computation is complete (and this process was NOT querying
      # the shared connection during it) before we read the result. Concurrent
      # tests' firehose entries also reach this subscriber, but each is a fast
      # no-op perform (their tenant's rows are invisible in our sandbox), so they
      # only add serialized latency, never a wrong result.
      {:ok, entry} = AuditChain.append(tenant.id, append_attrs())
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

      log =
        capture_log(fn ->
          # No tenant_id key at all.
          send(pid, {:audit_chain_entry, %{}})
          # Non-binary tenant_id.
          send(pid, {:audit_chain_entry, %{tenant_id: make_ref()}})
          :sys.get_state(pid)
        end)

      assert Process.alive?(pid)

      # A malformed-but-correctly-shaped entry is a benign, expected case: it is
      # logged as MALFORMED (at warning), NOT via the ERROR/"crashed" path that is
      # reserved for a genuine enqueue fault. This pins that distinction so a
      # regression that routed malformed entries through enqueue_sth_job's raising
      # guard (logging "crashed") would fail here.
      assert log =~ "malformed audit_chain_entry"
      refute log =~ "crashed while enqueuing"
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

  describe "cluster singleton (US-38.3, AC-38.3.1)" do
    test "TC-38.3.1: a single node still enqueues — an explicit local name starts and enqueues" do
      # Single-node behavior is unchanged: an explicit `name:` yields an ordinary
      # LOCAL registration (the async-test seam) and the enqueue path works exactly
      # as before the cluster-singleton change.
      tenant = fixture(:tenant)
      name = :"sth_local_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: name, subscribe: false]}, id: name)
        )

      assert is_pid(pid)
      # Plain local registration — NOT globally registered (only the default app-boot
      # instance claims the {:global, _} name).
      assert Process.whereis(name) == pid

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, _job} = SthEnqueuer.enqueue_sth_job(%{tenant_id: tenant.id})
      end)

      assert [%{args: %{"tenant_id" => enqueued_tid}}] = all_enqueued(worker: ComputeSthWorker)
      assert enqueued_tid == tenant.id
    end

    test "TC-38.3.1: a second instance under the SAME {:global, _} name yields :ignore (one active enqueuer)" do
      # Simulate a multi-node collision on the cluster-global name: the first instance
      # wins the {:global, _} registration; a second start under the SAME global name
      # collides and start_link/1 maps the {:already_started, _} to :ignore, so the
      # local supervisor treats the child as started rather than crash-looping. Net:
      # exactly ONE active enqueuer across the (simulated) cluster.
      global_atom = :"sth_singleton_#{System.unique_integer([:positive])}"
      global_name = {:global, global_atom}

      first =
        start_supervised!(
          Supervisor.child_spec({SthEnqueuer, [name: global_name, subscribe: false]},
            id: :sth_global_singleton
          )
        )

      assert is_pid(first)
      assert :global.whereis_name(global_atom) == first

      # Second registration under the same global name → :ignore (NOT a crash, NOT a
      # second process).
      assert :ignore == SthEnqueuer.start_link(name: global_name, subscribe: false)

      # The original remains the one and only globally-registered, alive instance.
      assert :global.whereis_name(global_atom) == first
      assert Process.alive?(first)
    end

    test "TC-38.3.1: the DEFAULT (unnamed) start is the cluster-global singleton the app already holds" do
      # The app-boot instance started with default opts, so it registered under
      # {:global, SthEnqueuer}. A fresh DEFAULT start therefore collides and returns
      # :ignore — proving the default name IS the cluster-wide global singleton
      # (exactly one active across the cluster), and that a redundant node start is a
      # graceful no-op rather than a crash.
      assert is_pid(:global.whereis_name(SthEnqueuer))
      assert :ignore == SthEnqueuer.start_link(subscribe: false)
    end
  end
end
