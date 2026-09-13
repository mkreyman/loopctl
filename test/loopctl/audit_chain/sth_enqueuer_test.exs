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

    test "TC-38.3.1: two :singleton instances contend → exactly ONE leader, one live standby (one active enqueuer)" do
      # Simulate a multi-node cluster on ONE test node: two :singleton-mode instances
      # contend for one isolated leadership_key via :global.register_name/2. Exactly
      # one wins leadership (the sole drainer); the OTHER is a LIVE standby monitoring
      # the leader — NOT :ignore, NOT dead. That live standby is what makes real
      # failover possible (see the failover test below).
      key = :"sth_lead_#{System.unique_integer([:positive])}"

      {a, b} = start_two_singletons(key)

      # Barrier: :sys.get_state blocks until each handle_continue(:establish_role) ran.
      roles = Enum.sort([:sys.get_state(a).role, :sys.get_state(b).role])
      assert roles == [:leader, :standby]

      leader = :global.whereis_name(key)
      assert leader in [a, b]

      # BOTH remain alive — the loser is a standby, not a terminated/ignored child.
      assert Process.alive?(a)
      assert Process.alive?(b)
    end

    test "TC-38.3.1: FAILOVER — killing the leader promotes a surviving standby that resumes draining" do
      # The behavior AC-38.3.1 actually requires: 'If the singleton's node dies,
      # another node takes over (failover).' Kill the leader (:temporary child ⇒ NOT
      # restarted, so this cleanly simulates the OWNER NODE dying, not a same-node
      # process crash). :global frees the name; the standby's cross-node monitor fires
      # {:DOWN, ...}; it re-registers, becomes the new leader, and can still enqueue.
      tenant = fixture(:tenant)
      key = :"sth_failover_#{System.unique_integer([:positive])}"

      {a, b} = start_two_singletons(key)
      _ = :sys.get_state(a)
      _ = :sys.get_state(b)

      leader = :global.whereis_name(key)
      standby = if leader == a, do: b, else: a
      assert :sys.get_state(standby).role == :standby

      # Kill the leader and wait for its death to be observed.
      ref = Process.monitor(leader)
      Process.exit(leader, :kill)
      assert_receive {:DOWN, ^ref, :process, ^leader, _reason}, 2_000

      # The standby takes over the cluster-global leadership name (real failover).
      assert eventually(fn -> :global.whereis_name(key) == standby end)
      assert :sys.get_state(standby).role == :leader

      # And the new leader still drains: the enqueue path works after takeover.
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, _job} = SthEnqueuer.enqueue_sth_job(%{tenant_id: tenant.id})
      end)

      assert [%{args: %{"tenant_id" => enqueued_tid}}] = all_enqueued(worker: ComputeSthWorker)
      assert enqueued_tid == tenant.id
    end

    test "a conflict notice delivered while the table still names the loser: it stands down, then monitors the survivor" do
      # The order global.erl uses: the resolver sends {:global_name_conflict, key} DURING the
      # name exchange, and the name table is updated afterwards. So the notice arrives while
      # :global.whereis_name/1 still answers the loser.
      key = :"sth_conflict_#{System.unique_integer([:positive])}"
      topic = Loopctl.AuditChain.PubSub.firehose_topic()
      loser = start_singleton(key, :sth_conflict_loser)

      assert :sys.get_state(loser).role == :leader
      assert loser in subscribers(topic)

      send(loser, {:global_name_conflict, key})
      state = :sys.get_state(loser)

      assert :global.whereis_name(key) == loser
      assert state.role == :standby
      assert state.leader_ref == nil
      refute loser in subscribers(topic)

      # A retry while the table still names the loser changes nothing.
      Process.sleep(SthEnqueuer.leadership_retry_ms() * 3)
      assert :sys.get_state(loser).role == :standby
      refute loser in subscribers(topic)

      # Then the table is updated to the survivor, as the name server's cast would.
      survivor = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(survivor, :kill) end)
      :yes = :global.re_register_name(key, survivor)

      assert eventually(fn -> monitors?(loser, survivor) end)
      assert :sys.get_state(loser).role == :standby
      refute loser in subscribers(topic)

      # And it still fails over: the survivor dies, the ex-leader takes the name back.
      Process.exit(survivor, :kill)
      assert eventually(fn -> :global.whereis_name(key) == loser end)
      assert eventually(fn -> :sys.get_state(loser).role == :leader end)
      assert loser in subscribers(topic)
    end

    test "a conflict notice whose exchange never completes: the loser leads again once the wait is spent" do
      # The connection dropped before the name table was updated, so the name is still the
      # loser's everywhere it can be seen. Nobody else drains; it must resume.
      key = :"sth_conflict_stale_#{System.unique_integer([:positive])}"
      topic = Loopctl.AuditChain.PubSub.firehose_topic()
      loser = start_singleton(key, :sth_conflict_stale)
      assert :sys.get_state(loser).role == :leader

      send(loser, {:global_name_conflict, key})
      assert :sys.get_state(loser).role == :standby

      assert eventually(fn -> :sys.get_state(loser).role == :leader end, 200, 25)
      assert :global.whereis_name(key) == loser
      assert loser in subscribers(topic)
    end

    test "a loser that resumed after the wait stands down when the table later names the peer" do
      # A slow exchange: the notice arrives, the wait runs out with the table still naming
      # the loser, it leads again — and only then the table is updated.
      key = :"sth_conflict_late_#{System.unique_integer([:positive])}"
      topic = Loopctl.AuditChain.PubSub.firehose_topic()
      loser = start_singleton(key, :sth_conflict_late)
      assert :sys.get_state(loser).role == :leader

      send(loser, {:global_name_conflict, key})
      assert eventually(fn -> :sys.get_state(loser).role == :leader end, 200, 25)
      assert loser in subscribers(topic)

      survivor = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(survivor, :kill) end)
      :yes = :global.re_register_name(key, survivor)

      assert eventually(fn -> :sys.get_state(loser).role == :standby end, 200, 25)
      refute loser in subscribers(topic)
      assert monitors?(loser, survivor)
    end

    test "a leader whose name vanished from the table registers again" do
      key = :"sth_vanished_#{System.unique_integer([:positive])}"
      leader = start_singleton(key, :sth_vanished)
      assert :sys.get_state(leader).role == :leader

      :global.unregister_name(key)

      assert eventually(fn -> :global.whereis_name(key) == leader end, 200, 25)
      assert :sys.get_state(leader).role == :leader
    end

    test "repeated conflict notices keep one retry timer and, once the holder is known, one monitor" do
      key = :"sth_conflict_flap_#{System.unique_integer([:positive])}"
      loser = start_singleton(key, :sth_conflict_flap)
      assert :sys.get_state(loser).role == :leader

      send(loser, {:global_name_conflict, key})
      {_ref, first_timer} = :sys.get_state(loser).retry_timer

      for _ <- 1..5, do: send(loser, {:global_name_conflict, key})
      {_ref, last_timer} = :sys.get_state(loser).retry_timer

      # Every superseded timer was cancelled: only the newest is pending.
      assert Process.read_timer(first_timer) == false
      refute first_timer == last_timer

      survivor = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(survivor, :kill) end)
      :yes = :global.re_register_name(key, survivor)

      assert eventually(fn -> monitors?(loser, survivor) end)
      # Let any stray retry chain run out before counting.
      Process.sleep(SthEnqueuer.leadership_retry_ms() * 5)
      {:monitors, monitors} = Process.info(loser, :monitors)
      assert Enum.count(monitors, &(&1 == {:process, survivor})) == 1
    end

    test "retry messages from superseded timers do not shorten a conflict loser's wait" do
      key = :"sth_conflict_stale_msgs_#{System.unique_integer([:positive])}"
      loser = start_singleton(key, :sth_conflict_stale_msgs)
      assert :sys.get_state(loser).role == :leader

      send(loser, {:global_name_conflict, key})
      # Timers an earlier notice would have set, already fired into the mailbox.
      for _ <- 1..40, do: send(loser, {:retry_leadership, make_ref()})

      state = :sys.get_state(loser)
      assert state.role == :standby
      assert state.conflict_retries == 0
    end

    test "a standby whose holder lost the name while staying alive moves its one monitor to the new holder" do
      key = :"sth_holder_moved_#{System.unique_integer([:positive])}"
      first = spawn(fn -> Process.sleep(:infinity) end)
      second = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        Process.exit(first, :kill)
        Process.exit(second, :kill)
      end)

      :yes = :global.register_name(key, first)
      standby = start_singleton(key, :sth_holder_moved)
      assert :sys.get_state(standby).role == :standby
      assert monitors?(standby, first)

      :yes = :global.re_register_name(key, second)

      assert eventually(fn -> monitors?(standby, second) end, 200, 25)
      refute monitors?(standby, first)
      assert :sys.get_state(standby).leader_pid == second

      # And the new holder's death is what it now fails over on.
      Process.exit(second, :kill)
      assert eventually(fn -> :global.whereis_name(key) == standby end, 200, 25)
    end

    @tag timeout: 60_000
    test "two nodes that each boot as leader and then connect end with exactly one leader" do
      # Two real BEAM nodes (:peer), each running a subscribed singleton under the same key,
      # registered while unconnected, then connected — the boot and netsplit-heal case, with
      # :global's own resolver and table update in their real order.
      key = :"sth_peer_#{System.unique_integer([:positive])}"
      topic = Loopctl.AuditChain.PubSub.firehose_topic()

      [{a, a_pid}, {b, b_pid}] =
        for name <- [:sth_peer_a, :sth_peer_b] do
          peer = start_peer(name)
          {peer, start_peer_singleton(peer, key)}
        end

      assert peer_role(a, a_pid) == :leader
      assert peer_role(b, b_pid) == :leader

      assert :peer.call(a, Node, :connect, [:peer.call(b, Kernel, :node, [])])

      assert eventually(
               fn ->
                 roles = Enum.sort([peer_role(a, a_pid), peer_role(b, b_pid)])
                 holder = :peer.call(a, :global, :whereis_name, [key])

                 roles == [:leader, :standby] and
                   holder == :peer.call(b, :global, :whereis_name, [key])
               end,
               200,
               25
             )

      holder = :peer.call(a, :global, :whereis_name, [key])
      assert holder in [a_pid, b_pid]
      {standby_peer, standby_pid} = if holder == a_pid, do: {b, b_pid}, else: {a, a_pid}

      # Both processes are alive (no resolver would have killed one), the holder alone
      # drains, and the standby monitors it.
      assert :peer.call(a, Process, :alive?, [a_pid])
      assert :peer.call(b, Process, :alive?, [b_pid])
      assert eventually(fn -> peer_subscribers(standby_peer, topic) == [] end, 200, 25)

      assert eventually(
               fn -> {:process, holder} in peer_monitors(standby_peer, standby_pid) end,
               200,
               25
             )
    end

    test "TC-38.3.1: the app-boot instance holds the cluster-global {:global, SthEnqueuer} leadership" do
      # The app-boot instance started with default opts (:singleton mode keyed on
      # __MODULE__), so it registered under {:global, SthEnqueuer} and is the live
      # cluster singleton — exactly one active drainer across the (single-node) cluster.
      leader = :global.whereis_name(SthEnqueuer)
      assert is_pid(leader)
      assert Process.alive?(leader)
    end
  end

  # Start two :singleton-mode instances contending on one isolated leadership_key.
  # :temporary so a killed leader is NOT restarted (clean node-death simulation);
  # subscribe: false so neither touches the sandbox from its own process.
  defp start_two_singletons(key) do
    a =
      start_supervised!(
        Supervisor.child_spec({SthEnqueuer, [leadership_key: key, subscribe: false]},
          id: :sth_singleton_a,
          restart: :temporary
        )
      )

    b =
      start_supervised!(
        Supervisor.child_spec({SthEnqueuer, [leadership_key: key, subscribe: false]},
          id: :sth_singleton_b,
          restart: :temporary
        )
      )

    {a, b}
  end

  # Poll a predicate until true or a bounded deadline — assert outcome CLASS, not
  # exact timing (the async-suite flake lesson): failover is asynchronous (:global
  # de-register + monitor :DOWN + re-register), so we wait for the end state.
  defp start_singleton(key, id) do
    start_supervised!(
      Supervisor.child_spec({SthEnqueuer, [leadership_key: key, subscribe: true]},
        id: id,
        restart: :temporary
      )
    )
  end

  defp monitors?(pid, target) do
    {:monitors, monitors} = Process.info(pid, :monitors)
    {:process, target} in monitors
  end

  # A distributed peer node carrying this build's code, controlled over stdio (this test
  # node itself is not distributed). Long names on 127.0.0.1 need no DNS.
  defp start_peer(name) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    unique = :"#{name}_#{System.unique_integer([:positive])}"

    {:ok, peer, _node} =
      :peer.start_link(%{
        name: unique,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: paths
      })

    # Linked to the test process, so it usually stops with it before on_exit runs.
    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    for app <- [:elixir, :logger, :phoenix_pubsub] do
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [app])
    end

    # Under kernel_sup: a process linked to the short-lived :peer.call caller would die with it.
    {:ok, _} =
      :peer.call(peer, :supervisor, :start_child, [
        :kernel_sup,
        Phoenix.PubSub.child_spec(name: Loopctl.PubSub)
      ])

    peer
  end

  defp start_peer_singleton(peer, key) do
    spec =
      Supervisor.child_spec({SthEnqueuer, [leadership_key: key, subscribe: true]}, id: :sth_peer)

    {:ok, pid} = :peer.call(peer, :supervisor, :start_child, [:kernel_sup, spec])
    pid
  end

  defp peer_role(peer, pid), do: :peer.call(peer, :sys, :get_state, [pid]).role

  defp peer_subscribers(peer, topic) do
    for {pid, _} <- :peer.call(peer, Registry, :lookup, [Loopctl.PubSub, topic]), do: pid
  end

  defp peer_monitors(peer, pid) do
    {:monitors, monitors} = :peer.call(peer, Process, :info, [pid, :monitors])
    monitors
  end

  defp subscribers(topic) do
    for {pid, _value} <- Registry.lookup(Loopctl.PubSub, topic), do: pid
  end

  defp eventually(fun, attempts \\ 100, sleep_ms \\ 20)
  defp eventually(_fun, 0, _sleep_ms), do: false

  defp eventually(fun, attempts, sleep_ms) do
    if fun.() do
      true
    else
      Process.sleep(sleep_ms)
      eventually(fun, attempts - 1, sleep_ms)
    end
  end
end
