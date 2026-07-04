defmodule Loopctl.Tenants.EnrollmentLockTest do
  @moduledoc """
  US-26.7.2 (AC-26.7.2.8e/g, TC-26.7.2.5/.7) — deterministic proof that
  `Loopctl.Tenants.Enrollment`'s `SELECT ... FOR UPDATE` tenant-row lock
  genuinely serializes concurrent enrollment/revocation across SEPARATE DB
  sessions.

  A two-`Task.async` race under `Ecto.Adapters.SQL.Sandbox`'s default shared
  mode cannot distinguish "lock present" from "lock absent" — the sandbox
  multiplexes every allowed process onto ONE checked-out connection, which
  already serializes access regardless of any application-level lock (the
  same reasoning `token_usage/correction_lock_test.exs` documents for the
  advisory-lock case). So this uses two genuinely independent
  `sandbox: false` sessions, `async: false`, and cleans up its own real
  (committed) rows via `on_exit` — deleting the tenant cascades (ON DELETE
  CASCADE) to its authenticators and audit entries.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Enrollment
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.Tenants.Tenant

  setup do
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)
    :ok
  end

  defp real_tenant(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(%{
      name: "Lock Test Tenant #{System.unique_integer([:positive])}",
      slug: "lock-test-#{System.unique_integer([:positive])}",
      email: "lock-test-#{System.unique_integer([:positive])}@example.com"
    })
    |> AdminRepo.insert!()
    |> Ecto.Changeset.change(Map.take(attrs, [:trust_tier]))
    |> AdminRepo.update!()
  end

  defp attestation_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: :erlang.term_to_binary(%{1 => 2, 3 => -7}),
        attestation_format: "none",
        sign_count: 0,
        friendly_name: "Authenticator"
      },
      overrides
    )
  end

  defp cleanup(tenant) do
    on_exit(fn ->
      :ok = Sandbox.checkout(AdminRepo, sandbox: false)
      AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)
  end

  test "the tenant-row FOR UPDATE lock blocks a second real session while held" do
    tenant = real_tenant(%{trust_tier: :agent_rooted})
    cleanup(tenant)

    parent = self()

    holder =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)

        AdminRepo.transaction(fn ->
          from(t in Tenant, where: t.id == ^tenant.id, lock: "FOR UPDATE") |> AdminRepo.one()
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 2_000

    # A different real session attempting the SAME row lock must NOT
    # complete instantly — it blocks until the holder's transaction ends.
    waiter =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        start = System.monotonic_time(:millisecond)

        AdminRepo.transaction(fn ->
          from(t in Tenant, where: t.id == ^tenant.id, lock: "FOR UPDATE") |> AdminRepo.one()
        end)

        System.monotonic_time(:millisecond) - start
      end)

    Process.sleep(200)
    send(holder.pid, :release)
    Task.await(holder, 2_000)

    elapsed_ms = Task.await(waiter, 2_000)
    assert elapsed_ms >= 150
  end

  test "concurrent double-FIRST-enroll: exactly one succeeds, the loser is rejected :reauth_required" do
    # SECURITY (review #1): both callers are FIRST enrollments (no
    # add_authenticator assertion, assertion_verified? = false). They both read
    # agent_rooted pre-lock. The one that wins the tenant-row lock flips to
    # human_anchored + enrolls; the loser re-locks, sees human_anchored + no
    # verified assertion, and is REJECTED :reauth_required. This models the
    # attacker (stolen role:user key + own hardware) racing a legitimate first
    # enroll: the attacker's device must NOT be grafted on.
    tenant = real_tenant(%{trust_tier: :agent_rooted})
    cleanup(tenant)

    task_a =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        Enrollment.enroll(tenant.id, attestation_attrs(), false)
      end)

    task_b =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        Enrollment.enroll(tenant.id, attestation_attrs(), false)
      end)

    results = [Task.await(task_a, 5_000), Task.await(task_b, 5_000)]

    successes = Enum.count(results, &match?({:ok, %{authenticator: %RootAuthenticator{}}}, &1))
    rejected = Enum.count(results, &match?({:error, :reauth_required}, &1))

    # Exactly one enrollment wins; the loser is turned away (must retry WITH an
    # existing-authenticator assertion). NOT both-succeed.
    assert successes == 1
    assert rejected == 1

    {:ok, final_tenant} = Tenants.get_tenant(tenant.id)
    assert final_tenant.trust_tier == :human_anchored

    # Exactly ONE authenticator was grafted on, and exactly ONE upgrade logged.
    assert RootAuthenticators.count_by_tenant(tenant.id) == 1

    {:ok, upgraded} =
      Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_trust_upgraded")

    assert upgraded.total == 1

    {:ok, enrolled} =
      Audit.list_entries(tenant.id, entity_type: "tenant", action: "authenticator_enrolled")

    assert enrolled.total == 0
  end

  test "concurrent revokes on a 2-authenticator tenant do not both succeed" do
    tenant = real_tenant(%{trust_tier: :human_anchored})
    cleanup(tenant)

    # Backup enrollment requires a verified assertion (assertion_verified? = true).
    {:ok, %{authenticator: auth_a}} = Enrollment.enroll(tenant.id, attestation_attrs(), true)
    {:ok, %{authenticator: auth_b}} = Enrollment.enroll(tenant.id, attestation_attrs(), true)

    task_a =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        Enrollment.revoke(tenant.id, auth_a.id)
      end)

    task_b =
      Task.async(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)
        Enrollment.revoke(tenant.id, auth_b.id)
      end)

    results = [Task.await(task_a, 5_000), Task.await(task_b, 5_000)]

    successes = Enum.count(results, &match?({:ok, _}, &1))
    blocked = Enum.count(results, &match?({:error, :last_authenticator}, &1))

    # The lock guarantees the SECOND revoke to acquire it re-counts under the
    # first's already-committed delete — so it can never also succeed once
    # only one authenticator remains. Exactly one succeeds, one is refused.
    assert successes == 1
    assert blocked == 1
  end
end
