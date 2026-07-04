defmodule Loopctl.WebAuthn.EnrollmentTest do
  @moduledoc """
  US-26.7.2 (AC-26.7.2.1) — the persisted, single-use, TTL-bound WebAuthn
  REGISTRATION-challenge store backing the opt-in trust-tier upgrade
  ceremony. Verifies the atomic single-use `update_all` consume pattern has
  no TOCTOU (replay/double-spend/wrong-tenant/expired all fail closed) and
  that issuance carries NO existing-authenticator precondition (unlike
  `Reauth.issue_challenge/2`), since that's exactly what makes a tenant's
  FIRST enrollment possible.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.WebAuthn.Enrollment
  alias Loopctl.WebAuthn.EnrollmentChallenge

  setup :verify_on_exit!

  describe "issue/1" do
    test "persists a single-use registration challenge with no existing-authenticator precondition" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})

      # Zero authenticators — Reauth.issue_challenge/2 would refuse this
      # tenant with {:error, :no_authenticators}. issue/1 must not.
      assert {:ok, issued} = Enrollment.issue(tenant.id)
      assert is_binary(issued.challenge_id)
      assert issued.challenge_bytes != ""
      assert DateTime.compare(issued.expires_at, DateTime.utc_now()) == :gt

      stored = AdminRepo.get!(EnrollmentChallenge, issued.challenge_id)
      assert stored.tenant_id == tenant.id
      assert stored.purpose == "enroll_authenticator"
      assert is_nil(stored.used_at)
    end
  end

  describe "consume/2" do
    test "consumes a fresh challenge exactly once" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {:ok, issued} = Enrollment.issue(tenant.id)

      assert {:ok, _challenge} = Enrollment.consume(tenant.id, issued.challenge_id)

      stored = AdminRepo.get!(EnrollmentChallenge, issued.challenge_id)
      refute is_nil(stored.used_at)
    end

    test "replay of an already-consumed challenge is rejected" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {:ok, issued} = Enrollment.issue(tenant.id)

      assert {:ok, _challenge} = Enrollment.consume(tenant.id, issued.challenge_id)
      assert {:error, :challenge_not_found} = Enrollment.consume(tenant.id, issued.challenge_id)
    end

    test "an expired challenge is rejected" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {:ok, issued} = Enrollment.issue(tenant.id)

      AdminRepo.get!(EnrollmentChallenge, issued.challenge_id)
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> AdminRepo.update!()

      assert {:error, :challenge_not_found} = Enrollment.consume(tenant.id, issued.challenge_id)
    end

    test "a challenge cannot be consumed by a different tenant" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      other_tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {:ok, issued} = Enrollment.issue(tenant.id)

      assert {:error, :challenge_not_found} =
               Enrollment.consume(other_tenant.id, issued.challenge_id)
    end

    test "an unknown challenge id is rejected" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      assert {:error, :challenge_not_found} = Enrollment.consume(tenant.id, Ecto.UUID.generate())
    end

    test "a non-UUID challenge id is rejected without raising" do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      assert {:error, :invalid_challenge_id} = Enrollment.consume(tenant.id, "not-a-uuid")
      assert {:error, :invalid_challenge_id} = Enrollment.consume(tenant.id, nil)
    end
  end
end
