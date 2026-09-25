defmodule Loopctl.Progress.ClaimLockTest do
  @moduledoc """
  Deterministic proof that `Loopctl.Progress.claim_story/3`'s
  `SELECT ... FOR UPDATE` story-row lock (see `lock_story/2`) genuinely
  serializes concurrent claims across SEPARATE DB sessions, so exactly one
  agent wins the claim and the loser is turned away with `:invalid_transition`.

  A two-`Task.async` race under `Ecto.Adapters.SQL.Sandbox`'s default shared
  mode cannot test this: the sandbox multiplexes every allowed process onto ONE
  checked-out connection, so connection-level serialization alone already makes
  the loser re-read the winner's committed row REGARDLESS of any application
  lock — the same reasoning documented in
  `token_usage/correction_lock_test.exs` and `tenants/enrollment_lock_test.exs`.
  Worse, two processes issuing a `FOR UPDATE` transaction on that single shared
  connection interleave nondeterministically (the old HTTP-layer race test in
  `story_status_controller_test.exs` was flaky for exactly this reason).

  So this uses two genuinely independent `sandbox: false` sessions,
  `async: false`, and cleans up its own real (committed) rows via `on_exit`
  (deleting the tenant cascades ON DELETE CASCADE to its project/epic/story/
  agent rows; the audit-log rows have no tenant FK and are harmless orphans).
  Without the lock, two separate sessions could both read `:contracted`, both
  write `:assigned`, and both commit — this test would then see two winners.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Capabilities.CapabilityToken
  alias Loopctl.Progress
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story

  setup do
    # This test uses ExUnit.Case (NOT DataCase), so it does not get DataCase's
    # default Mox stubs. claim_story/3 mints a best-effort capability, whose path
    # (Capabilities.mint -> TenantKeys.fetch_and_cache) calls MockSecrets.get; an
    # unstubbed mock raises. Stub it exactly as DataCase does (audit key
    # unavailable -> mint returns {:error, _} -> best-effort no-op). Global mode
    # because the two claimers run in SEPARATE Task processes that must see the
    # stub; safe here since the module is async: false.
    Mox.set_mox_global()
    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:error, :not_found} end)

    :ok = Sandbox.checkout(AdminRepo, sandbox: false)
    :ok
  end

  # Mirrors Progress.lock_story/2: the same `SELECT ... FOR UPDATE` on the story
  # row, scoped by (id, tenant_id).
  defp lock_row(tenant_id, story_id) do
    from(s in Story,
      where: s.id == ^story_id and s.tenant_id == ^tenant_id,
      lock: "FOR UPDATE"
    )
    |> AdminRepo.one()
  end

  defp contracted_story_with_two_agents do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})

    agent_a = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    agent_b = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    cleanup(tenant)

    %{tenant: tenant, story: story, agent_a: agent_a, agent_b: agent_b}
  end

  defp cleanup(tenant) do
    on_exit(fn ->
      :ok = Sandbox.checkout(AdminRepo, sandbox: false)
      # capability_tokens has ON DELETE :nothing, so clear any row a best-effort
      # start_cap mint may have created before deleting the tenant.
      AdminRepo.delete_all(from(c in CapabilityToken, where: c.tenant_id == ^tenant.id))
      AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)
  end

  test "the story-row FOR UPDATE lock blocks a second real session while held" do
    %{tenant: tenant, story: story} = contracted_story_with_two_agents()

    parent = self()

    holder =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)

        AdminRepo.transaction(fn ->
          lock_row(tenant.id, story.id)
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 2_000

    # A different real session attempting the SAME row lock must NOT complete
    # instantly — it blocks until the holder's transaction ends.
    waiter =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        start = System.monotonic_time(:millisecond)
        AdminRepo.transaction(fn -> lock_row(tenant.id, story.id) end)
        System.monotonic_time(:millisecond) - start
      end)

    Process.sleep(200)
    send(holder.pid, :release)
    Task.await(holder, 2_000)

    elapsed_ms = Task.await(waiter, 2_000)
    assert elapsed_ms >= 150
  end

  # US-44.5 review round 2, finding 5: a renewal that WAITED on the story lock must judge a
  # capped claim's cap from after the wait. Read before it, `now` was still ahead of a cap that
  # passed while the renewal queued, and the renewal answered 200 for a claim already ended.
  #
  # ORDERED BY EVENTS, NOT BY A WALL-CLOCK MARGIN (round 3, finding 10). The holder takes the
  # lock, waits until Postgres shows the renewal's backend BLOCKED on it, and only then writes
  # the cap as its own now — an instant after the renewal began and before it can take the
  # lock — and commits once the clock is past that cap. A renewal that read `now` before the
  # lock therefore sees the cap ahead; one that reads it after sees it passed. Nothing depends
  # on how long any step takes.
  test "a renewal that waited on the story lock past the cap is refused lease_cap_reached" do
    %{tenant: tenant, story: story, agent_a: agent_a} = contracted_story_with_two_agents()
    far = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {:ok, claimed} =
      Progress.claim_story(tenant.id, story.id, agent_id: agent_a.id, lease_until: far)

    parent = self()

    holder =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)

        AdminRepo.transaction(fn ->
          lock_row(tenant.id, story.id)
          send(parent, :locked)

          receive do
            {:renewer_backend, backend} -> wait_until_blocked(backend)
          end

          cap = DateTime.utc_now()

          {1, _} =
            from(s in Story, where: s.id == ^story.id)
            |> AdminRepo.update_all(set: [claimed_until: cap, claim_lease_cap: cap])

          wait_past(cap)
          cap
        end)
      end)

    assert_receive :locked, 2_000

    renewer =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        %{rows: [[backend]]} = AdminRepo.query!("SELECT pg_backend_pid()")
        send(holder.pid, {:renewer_backend, backend})

        Progress.renew_claim(tenant.id, story.id,
          agent_id: agent_a.id,
          claim_epoch: claimed.claim_epoch
        )
      end)

    assert {:ok, cap} = Task.await(holder, 10_000)
    assert {:error, :lease_cap_reached} = Task.await(renewer, 10_000)
    assert AdminRepo.get!(Story, story.id).claimed_until == cap
  end

  # Polls `pg_locks` until `backend` holds a lock it has NOT been granted — it is queued behind
  # the caller's. Bounded, so a renewal that never blocks fails the test instead of hanging it.
  defp wait_until_blocked(backend, attempts \\ 1_000) do
    %{rows: [[waiting]]} =
      AdminRepo.query!("SELECT count(*) FROM pg_locks WHERE pid = $1 AND NOT granted", [backend])

    cond do
      waiting > 0 ->
        :ok

      attempts == 0 ->
        raise "backend #{backend} never blocked on the story lock"

      true ->
        Process.sleep(5)
        wait_until_blocked(backend, attempts - 1)
    end
  end

  defp wait_past(%DateTime{} = at) do
    if DateTime.after?(DateTime.utc_now(), at) do
      :ok
    else
      Process.sleep(1)
      wait_past(at)
    end
  end

  test "concurrent claim: exactly one agent wins, the loser is rejected :invalid_transition" do
    %{tenant: tenant, story: story, agent_a: agent_a, agent_b: agent_b} =
      contracted_story_with_two_agents()

    task_a =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        Progress.claim_story(tenant.id, story.id, agent_id: agent_a.id)
      end)

    task_b =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        Progress.claim_story(tenant.id, story.id, agent_id: agent_b.id)
      end)

    results = [Task.await(task_a, 5_000), Task.await(task_b, 5_000)]

    winners = Enum.filter(results, &match?({:ok, %{agent_status: :assigned}}, &1))
    losers = Enum.filter(results, &match?({:error, {:invalid_transition, _}}, &1))

    # The FOR UPDATE lock guarantees the SECOND claim to acquire it re-reads the
    # winner's already-committed :assigned row and fails validation — so it can
    # never also win. Exactly one succeeds, one is refused. NOT both-succeed.
    assert length(winners) == 1
    assert length(losers) == 1

    # The winning agent is the one recorded on the persisted row.
    [{:ok, won}] = winners
    reloaded = AdminRepo.get!(Story, story.id)
    assert reloaded.agent_status == :assigned
    assert reloaded.assigned_agent_id == won.assigned_agent_id
    assert won.assigned_agent_id in [agent_a.id, agent_b.id]

    # #803: the epoch is incremented ONCE — by the winner, under the lock. A loser that
    # had also incremented would leave 2, and a claimant holding 1 would be fenced out of
    # its own claim.
    assert reloaded.claim_epoch == 1
    assert won.claim_epoch == 1
  end

  test "a halt committing while a reclaim runs wins: the reclaim waits on the tenant row and refuses" do
    %{tenant: tenant, story: story, agent_a: agent_a} = contracted_story_with_two_agents()
    {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent_a.id)

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(
        set: [claimed_until: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    parent = self()

    # A halt in flight: the tenant row is updated but not yet committed. Without the
    # FOR SHARE lock the reclaim reads the last COMMITTED row (not halted) and releases.
    halter =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)

        AdminRepo.transaction(fn ->
          {1, _} =
            from(t in Tenant, where: t.id == ^tenant.id)
            |> AdminRepo.update_all(set: [custody_halted_at: DateTime.utc_now()])

          send(parent, :halting)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :halting, 2_000

    reclaimer =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        # The reclaim first reads the dispatch ledger, on the RLS repo, for a budget kill it
        # must re-drive rather than re-queue (US-44.3).
        :ok = Sandbox.checkout(Loopctl.Repo, sandbox: false)
        Progress.reclaim_expired_claim(tenant.id, story.id, claimed.claim_epoch)
      end)

    Process.sleep(200)
    send(halter.pid, :commit)
    Task.await(halter, 2_000)

    assert {:error, :custody_halted} = Task.await(reclaimer, 5_000)
    assert AdminRepo.get!(Story, story.id).agent_status == :assigned
  end

  test "concurrent reclaim of one expired lease: exactly one release, one epoch bump" do
    %{tenant: tenant, story: story, agent_a: agent_a} = contracted_story_with_two_agents()
    {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent_a.id)

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(
        set: [claimed_until: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    # Both sweeps read the same candidate (same epoch) before either locks — the shape
    # two overlapping cron runs, or two nodes, produce.
    reclaim = fn ->
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        :ok = Sandbox.checkout(Loopctl.Repo, sandbox: false)
        Progress.reclaim_expired_claim(tenant.id, story.id, claimed.claim_epoch)
      end)
    end

    results = [reclaim.(), reclaim.()] |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, %Story{agent_status: :pending}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :claim_not_expired}, &1)) == 1
    assert AdminRepo.get!(Story, story.id).claim_epoch == claimed.claim_epoch + 1
  end
end
