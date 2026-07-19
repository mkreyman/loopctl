defmodule Loopctl.CoordinationClaimRaceTest do
  @moduledoc """
  US-40.B1 / TC-40.B1.2 — deterministic proof that INSERT-to-claim is exactly-once
  under genuine concurrency.

  A two-`Task.async` race under `Ecto.Adapters.SQL.Sandbox`'s shared mode cannot
  prove this: the sandbox multiplexes every allowed process onto ONE connection, so
  the inserts serialize on the connection regardless of the unique index. So — like
  `progress/claim_lock_test.exs` — this uses genuinely independent `sandbox: false`
  sessions, `async: false`, and cleans up its own committed rows via `on_exit`
  (deleting the tenant cascades to its project/agent/claim rows).

  N agents race to claim the SAME `(tenant, project, ref)`. Postgres serializes the
  concurrent inserts on `channel_claims_ref_uidx`: exactly one commits
  (`{:ok, claim}`), the rest raise a unique violation the changeset maps to
  `{:error, :already_claimed}`. Exactly one row lands.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Tenants.Tenant

  setup do
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)
    :ok
  end

  defp scenario(n) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agents = for _ <- 1..n, do: fixture(:agent, %{tenant_id: tenant.id}).id

    on_exit(fn ->
      :ok = Sandbox.checkout(AdminRepo, sandbox: false)
      AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    %{tenant: tenant, project: project, agents: agents}
  end

  test "N agents racing the same ref: exactly one {:ok}, the rest already_claimed, exactly one row" do
    n = 8
    %{tenant: tenant, project: project, agents: agents} = scenario(n)

    audit = [actor_type: "api_key", actor_id: Ecto.UUID.generate(), actor_label: "agent:racer"]

    tasks =
      for agent_id <- agents do
        Task.async(fn ->
          :ok = Sandbox.checkout(AdminRepo, sandbox: false)
          # role: :user bypasses the membership gate so the race isolates the
          # unique-constraint serialization, not the D3 gate.
          Coordination.claim(tenant.id, agent_id, project.id, "handoff:repo#812",
            role: :user,
            audit: audit
          )
        end)
      end

    results = Task.await_many(tasks, 10_000)

    winners = Enum.filter(results, &match?({:ok, %ChannelClaim{}}, &1))
    losers = Enum.filter(results, &match?({:error, :already_claimed}, &1))

    assert length(winners) == 1
    assert length(losers) == n - 1

    # Exactly one row persisted for the ref.
    assert AdminRepo.aggregate(
             from(c in ChannelClaim,
               where: c.tenant_id == ^tenant.id and c.ref == "handoff:repo#812"
             ),
             :count
           ) == 1

    [{:ok, won}] = winners
    assert won.claimant_agent_id in agents
  end
end
