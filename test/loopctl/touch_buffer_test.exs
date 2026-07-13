defmodule Loopctl.TouchBufferTest do
  use Loopctl.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.Agents
  alias Loopctl.Auth
  alias Loopctl.TouchBuffer

  # Each test drives its OWN isolated buffer instance (unique ETS table + name)
  # so the shared app-tree singleton is never touched and the flush — which DOES
  # hit the DB — is invoked directly from the test process (which owns the
  # sandbox connection). The interval is set high so only explicit flushes fire.
  setup do
    i = System.unique_integer([:positive])
    table = :"touch_buffer_test_#{i}"
    name = :"touch_buffer_test_srv_#{i}"

    server =
      start_supervised!(
        Supervisor.child_spec(
          {TouchBuffer, [name: name, table: table, flush_interval_ms: :timer.hours(1)]},
          id: name
        )
      )

    %{table: table, server: server, name: name}
  end

  describe "record — request path (no DB write)" do
    # TC-33.4.1
    test "records the touch into the buffer with no synchronous DB write", %{table: table} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      initial = agent.last_seen_at
      now = DateTime.utc_now()

      assert :ok = TouchBuffer.record(table, {:agent, agent.id}, now)

      # The buffer holds the pending timestamp in memory...
      assert {:ok, %DateTime{} = pending} = TouchBuffer.peek(table, {:agent, agent.id})
      assert DateTime.compare(pending, now) == :eq

      # ...and the DB row is UNCHANGED until a flush.
      {:ok, reloaded} = Agents.get_agent(tenant.id, agent.id)
      assert DateTime.compare(reloaded.last_seen_at, initial) == :eq
    end
  end

  describe "flush — batched, monotonic" do
    # TC-33.4.2
    test "flush advances to the newest buffered value and never regresses", %{table: table} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      t1 = DateTime.utc_now()
      t2 = DateTime.add(t1, 5, :second)

      # Several buffered records for the same agent + key; the latest wins.
      assert :ok = TouchBuffer.record(table, {:agent, agent.id}, t1)
      assert :ok = TouchBuffer.record(table, {:agent, agent.id}, t2)
      assert :ok = TouchBuffer.record(table, {:api_key, key.id}, t1)
      assert :ok = TouchBuffer.record(table, {:api_key, key.id}, t2)

      assert :ok = TouchBuffer.flush(table)

      {:ok, a} = Agents.get_agent(tenant.id, agent.id)
      assert DateTime.compare(a.last_seen_at, t2) == :eq

      {:ok, k} = Auth.get_api_key(tenant.id, key.id)
      assert DateTime.compare(k.last_used_at, t2) == :eq

      # The buffer was drained (nothing pending after flush).
      assert TouchBuffer.peek(table, {:agent, agent.id}) == :miss

      # Monotonic (GREATEST): buffering an OLDER ts after the newer flush must NOT
      # regress the persisted value.
      t0 = DateTime.add(t1, -100, :second)
      assert :ok = TouchBuffer.record(table, {:agent, agent.id}, t0)
      assert :ok = TouchBuffer.flush(table)

      {:ok, a2} = Agents.get_agent(tenant.id, agent.id)
      assert DateTime.compare(a2.last_seen_at, t2) == :eq
    end

    # TC-33.4.3
    test "flush updates many buffered agents, each to its own newest ts", %{table: table} do
      tenant = fixture(:tenant)

      pairs =
        for i <- 1..3 do
          agent =
            fixture(:agent, %{
              tenant_id: tenant.id,
              name: "a#{i}-#{System.unique_integer([:positive])}"
            })

          ts = DateTime.add(DateTime.utc_now(), i, :second)
          assert :ok = TouchBuffer.record(table, {:agent, agent.id}, ts)
          {agent, ts}
        end

      # One flush persists all three (a single batched UPDATE over the agents
      # table — O(scopes), not O(ids)).
      assert :ok = TouchBuffer.flush(table)

      for {agent, ts} <- pairs do
        {:ok, reloaded} = Agents.get_agent(tenant.id, agent.id)
        assert DateTime.compare(reloaded.last_seen_at, ts) == :eq
      end
    end

    # TC-33.4.4 — tenant isolation
    test "flush is tenant-safe: each tenant's own row is updated, no cross-tenant write",
         %{table: table} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      agent_a = fixture(:agent, %{tenant_id: tenant_a.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      ts = DateTime.utc_now()
      assert :ok = TouchBuffer.record(table, {:agent, agent_a.id}, ts)
      assert :ok = TouchBuffer.record(table, {:agent, agent_b.id}, ts)

      assert :ok = TouchBuffer.flush(table)

      # Each tenant's own agent row was advanced.
      {:ok, ra} = Agents.get_agent(tenant_a.id, agent_a.id)
      {:ok, rb} = Agents.get_agent(tenant_b.id, agent_b.id)
      assert DateTime.compare(ra.last_seen_at, ts) == :eq
      assert DateTime.compare(rb.last_seen_at, ts) == :eq

      # And no cross-tenant write occurred: tenant A's id is not tenant B's agent
      # (globally-unique id ⇒ WHERE id = ... is self-scoping).
      assert {:error, :not_found} = Agents.get_agent(tenant_b.id, agent_a.id)
      assert {:error, :not_found} = Agents.get_agent(tenant_a.id, agent_b.id)
    end

    test "flush over an empty buffer is a no-op", %{table: table} do
      assert :ok = TouchBuffer.flush(table)
    end

    # Guards the batched flush against Postgres' 65,535 bound-param cap. At
    # epic_33 scale a single flush interval can accumulate tens of thousands of
    # active ids; each entry emits 2 bound params, so an UNCHUNKED UPDATE over
    # ~40k entries (~80k params) is rejected by AdminRepo.query!. Because
    # drain/1 has already :ets.take'd the window and do_flush swallows the
    # raise, an over-limit statement would SILENTLY lose the whole window —
    # including the real agent's touch. Chunking keeps every statement bounded,
    # so the real row still advances.
    test "flush handles a batch far larger than the bind-param cap without losing touches",
         %{table: table} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      ts = DateTime.add(DateTime.utc_now(), 30, :second)

      # One real agent whose row MUST actually advance...
      assert :ok = TouchBuffer.record(table, {:agent, agent.id}, ts)

      # ...buried among 40_000 buffered ids (80_000 bound params) — well past
      # the 65_535 cap, so a single unbounded UPDATE would raise. Non-existent
      # UUIDs match no row (harmless); they only inflate the param count.
      for _ <- 1..40_000 do
        :ok = TouchBuffer.record(table, {:agent, Ecto.UUID.generate()}, ts)
      end

      assert :ok = TouchBuffer.flush(table)

      {:ok, reloaded} = Agents.get_agent(tenant.id, agent.id)
      assert DateTime.compare(reloaded.last_seen_at, ts) == :eq
    end

    # Cross-target isolation: drain/1 :ets.take's BOTH targets up front, so a
    # raise while flushing the FIRST target (agents, ordered before api_keys in
    # @targets) must NOT swallow the second target's already-drained window. A
    # malformed agent id forces build_values -> Ecto.UUID.dump! to raise for the
    # agents UPDATE; the api_key row must still advance. Without per-target
    # isolation a deterministic agents failure would starve last_used_at every
    # interval.
    test "one target's flush failure does not swallow the sibling target's window",
         %{table: table} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})
      ts = DateTime.add(DateTime.utc_now(), 30, :second)

      # A valid api_key touch (the sibling that MUST still flush)...
      assert :ok = TouchBuffer.record(table, {:api_key, key.id}, ts)

      # ...and a MALFORMED agent entry inserted directly into ETS (bypassing
      # record/3's is_binary UUID guard) so the agents UPDATE raises in
      # build_values. The agents target fails; the api_keys target must survive.
      :ets.insert(table, {{:agent, "not-a-valid-uuid"}, ts})

      assert :ok = TouchBuffer.flush(table)

      # Sibling target advanced despite the agents-target raise.
      {:ok, k} = Auth.get_api_key(tenant.id, key.id)
      assert DateTime.compare(k.last_used_at, ts) == :eq
    end
  end

  describe "graceful shutdown" do
    test "flushes buffered touches on terminate/2" do
      i = System.unique_integer([:positive])
      table = :"touch_buffer_shutdown_#{i}"
      name = :"touch_buffer_shutdown_srv_#{i}"

      server =
        start_supervised!(
          Supervisor.child_spec(
            {TouchBuffer, [name: name, table: table, flush_interval_ms: :timer.hours(1)]},
            id: name
          )
        )

      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      initial = agent.last_seen_at
      ts = DateTime.add(DateTime.utc_now(), 10, :second)

      assert :ok = TouchBuffer.record(table, {:agent, agent.id}, ts)

      # Let the GenServer use this test's sandbox connection so its terminate/2
      # flush can write during the (in-process) shutdown.
      Sandbox.allow(Loopctl.AdminRepo, self(), server)

      # Graceful shutdown → trap_exit → terminate/2 → final flush.
      assert :ok = stop_supervised!(name)

      {:ok, reloaded} = Agents.get_agent(tenant.id, agent.id)
      assert DateTime.compare(reloaded.last_seen_at, ts) == :eq
      refute DateTime.compare(reloaded.last_seen_at, initial) == :eq
    end
  end
end
