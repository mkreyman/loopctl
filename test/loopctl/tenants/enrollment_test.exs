defmodule Loopctl.Tenants.EnrollmentTest do
  @moduledoc """
  US-26.7.2 — the DB-only `Ecto.Multi` for enrollment (AC-26.7.2.3) and
  revocation (AC-26.7.2.4): guarded tier flip, per-tenant authenticator cap,
  race-safe last-authenticator revoke guard, and exactly-one audit entry per
  outcome.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.Audit
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Enrollment
  alias Loopctl.Tenants.RootAuthenticators

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

  describe "enroll/2 — first enrollment" do
    test "inserts the authenticator and flips agent_rooted -> human_anchored (no assertion)" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})

      # First enrollment: locked tier is agent_rooted, so no add_authenticator
      # assertion is required -> assertion_verified? = false is legitimate.
      assert {:ok, %{tenant: updated, authenticator: auth, upgraded: true}} =
               Enrollment.enroll(tenant.id, attestation_attrs(), false)

      assert updated.trust_tier == :human_anchored
      assert auth.tenant_id == tenant.id

      {:ok, entries} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_trust_upgraded")

      assert entries.total == 1
      [entry] = entries.data
      assert entry.old_state["trust_tier"] == "agent_rooted"
      assert entry.new_state["trust_tier"] == "human_anchored"

      assert entry.new_state["authenticator_fingerprint"] ==
               Tenants.fingerprint(auth.credential_id)
    end

    test "a human_anchored tenant enroll WITHOUT a verified assertion is rejected at the enroll/3 layer" do
      # The backup-enrollment invariant now lives UNDER THE LOCK, not only in
      # the controller: even calling enroll/3 directly, a human_anchored tenant
      # with assertion_verified? = false must be rejected :reauth_required and
      # insert NO authenticator.
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})

      assert {:error, :reauth_required} =
               Enrollment.enroll(tenant.id, attestation_attrs(), false)

      assert RootAuthenticators.count_by_tenant(tenant.id) == 0

      {:ok, enrolled} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "authenticator_enrolled")

      assert enrolled.total == 0
    end

    test "a human_anchored tenant enroll WITH a verified assertion enrolls a backup, no re-flip" do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})

      assert {:ok, %{tenant: updated, upgraded: false}} =
               Enrollment.enroll(tenant.id, attestation_attrs(), true)

      assert updated.trust_tier == :human_anchored

      {:ok, upgraded} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_trust_upgraded")

      assert upgraded.total == 0

      {:ok, enrolled} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "authenticator_enrolled")

      assert enrolled.total == 1
    end

    test "returns {:error, :not_found} for an unknown tenant" do
      assert {:error, :not_found} =
               Enrollment.enroll(Ecto.UUID.generate(), attestation_attrs(), false)
    end

    test "rejects re-enrolling the same credential_id for the same tenant" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      credential_id = :crypto.strong_rand_bytes(32)

      # First enroll flips agent_rooted -> human_anchored (no assertion needed).
      assert {:ok, _} =
               Enrollment.enroll(
                 tenant.id,
                 attestation_attrs(%{credential_id: credential_id}),
                 false
               )

      # Re-enroll the SAME credential on the now-human_anchored tenant, with a
      # verified assertion (assertion_verified? = true) so the request passes
      # the backup gate and reaches the unique-constraint violation.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Enrollment.enroll(
                 tenant.id,
                 attestation_attrs(%{credential_id: credential_id}),
                 true
               )

      assert %{credential_id: [_ | _]} = errors_on(changeset)
    end

    test "enforces the per-tenant authenticator cap" do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})

      for _ <- 1..Enrollment.max_authenticators() do
        fixture(:root_authenticator, tenant_id: tenant.id)
      end

      # assertion_verified? = true so we pass the backup gate and hit the cap.
      assert {:error, :too_many_authenticators} =
               Enrollment.enroll(tenant.id, attestation_attrs(), true)
    end
  end

  describe "revoke/2" do
    test "deletes a non-last authenticator and logs authenticator_revoked" do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      auth_a = fixture(:root_authenticator, tenant_id: tenant.id)
      auth_b = fixture(:root_authenticator, tenant_id: tenant.id)

      assert {:ok, deleted} = Enrollment.revoke(tenant.id, auth_b.id)
      assert deleted.id == auth_b.id

      assert {:ok, remaining} =
               RootAuthenticators.get_by_credential_id(tenant.id, auth_a.credential_id)

      assert remaining.id == auth_a.id

      assert {:error, :not_found} =
               RootAuthenticators.get_by_credential_id(tenant.id, auth_b.credential_id)

      {:ok, entries} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "authenticator_revoked")

      assert entries.total == 1
    end

    test "refuses to revoke the LAST authenticator on a human_anchored tenant" do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      auth = fixture(:root_authenticator, tenant_id: tenant.id)

      assert {:error, :last_authenticator} = Enrollment.revoke(tenant.id, auth.id)
      assert {:ok, _} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
    end

    test "returns {:error, :not_found} for an unknown authenticator id" do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      fixture(:root_authenticator, tenant_id: tenant.id)

      assert {:error, :not_found} = Enrollment.revoke(tenant.id, Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} for a cross-tenant authenticator id" do
      tenant_a = fixture(:tenant, %{trust_tier: :human_anchored})
      tenant_b = fixture(:tenant, %{trust_tier: :human_anchored})
      auth_b = fixture(:root_authenticator, tenant_id: tenant_b.id)
      fixture(:root_authenticator, tenant_id: tenant_a.id)

      assert {:error, :not_found} = Enrollment.revoke(tenant_a.id, auth_b.id)
      assert {:ok, _} = RootAuthenticators.get_by_credential_id(tenant_b.id, auth_b.credential_id)
    end
  end
end
