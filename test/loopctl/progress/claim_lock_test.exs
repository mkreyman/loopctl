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
  end
end
