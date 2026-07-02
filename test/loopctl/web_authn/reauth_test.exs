defmodule Loopctl.WebAuthn.ReauthTest do
  @moduledoc """
  crypto-01 (GHSA-c3cw-5f7p-g76r) — challenge-bound WebAuthn reauth.

  Verifies the two-step ceremony: a challenge is issued + stored, and an
  assertion is only accepted against that STORED, unexpired, single-use
  challenge for an enrolled, in-tenant credential — with sign-counter
  regression rejected. The WebAuthn adapter is stubbed via `MockWebAuthn`
  (config/test.exs), never `Application.put_env`.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures
  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.WebAuthn.Reauth
  alias Loopctl.WebAuthn.ReauthChallenge

  setup :verify_on_exit!

  @purpose "rotate_audit_key"

  defp assertion_params(challenge_id, credential_id, overrides \\ %{}) do
    Map.merge(
      %{
        "challenge_id" => challenge_id,
        "credential_id" => Base.url_encode64(credential_id, padding: false),
        "authenticator_data" => Base.url_encode64(:crypto.strong_rand_bytes(37), padding: false),
        "signature" => Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
        "client_data_json" => Base.url_encode64(~s({"type":"webauthn.get"}), padding: false)
      },
      overrides
    )
  end

  describe "issue_challenge/2" do
    test "stores a single-use challenge bound to the tenant and returns credential ids" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id)

      assert {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)
      assert is_binary(issued.challenge_id)
      assert issued.challenge != ""

      assert Base.url_encode64(auth.credential_id, padding: false) in issued.allowed_credentials

      assert DateTime.compare(issued.expires_at, DateTime.utc_now()) == :gt
    end

    test "refuses when the tenant has no enrolled authenticator" do
      tenant = fixture(:tenant)
      assert {:error, :no_authenticators} = Reauth.issue_challenge(tenant.id, @purpose)
    end
  end

  describe "verify_and_consume/3 — happy path" do
    test "verifies against the stored challenge and persists the new counter" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 0)

      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      expect(Loopctl.MockWebAuthn, :verify_authentication, fn payload, _challenge, opts ->
        # The enrolled credential + its stored COSE key must be threaded in
        # (never an empty allow list — that was the placeholder bug).
        assert [{cred_id, pub}] = Keyword.fetch!(opts, :allow_credentials)
        assert cred_id == auth.credential_id
        assert pub == auth.public_key
        assert payload.credential_id == auth.credential_id
        {:ok, %{sign_count: 7}}
      end)

      params = assertion_params(issued.challenge_id, auth.credential_id)

      assert {:ok, result} = Reauth.verify_and_consume(tenant.id, @purpose, params)
      assert result.sign_count == 7
      assert is_binary(result.signature)

      {:ok, reloaded} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
      assert reloaded.sign_count == 7
      assert reloaded.last_used_at != nil
    end

    test "a challenge is single-use — replay is rejected" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 0)
      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 3}}
      end)

      params = assertion_params(issued.challenge_id, auth.credential_id)

      assert {:ok, _} = Reauth.verify_and_consume(tenant.id, @purpose, params)
      # Same challenge again → consumed, refused.
      assert {:error, :challenge_not_found} =
               Reauth.verify_and_consume(tenant.id, @purpose, params)
    end
  end

  describe "verify_and_consume/3 — rejections" do
    test "rejects when no challenge was ever issued" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id)

      params = assertion_params(Ecto.UUID.generate(), auth.credential_id)

      assert {:error, :challenge_not_found} =
               Reauth.verify_and_consume(tenant.id, @purpose, params)
    end

    test "rejects an expired challenge" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      # Backdate the stored challenge past its TTL.
      import Ecto.Query

      from(c in ReauthChallenge, where: c.id == ^issued.challenge_id)
      |> AdminRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      params = assertion_params(issued.challenge_id, auth.credential_id)

      assert {:error, :challenge_not_found} =
               Reauth.verify_and_consume(tenant.id, @purpose, params)
    end

    test "fails closed on a corrupt stored challenge (never a nil challenge to the adapter)" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id)

      # Insert a challenge whose blob is NOT valid term_to_binary output.
      {:ok, stored} =
        %ReauthChallenge{tenant_id: tenant.id}
        |> ReauthChallenge.create_changeset(%{
          purpose: @purpose,
          challenge: <<0, 1, 2, 3>>,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })
        |> AdminRepo.insert()

      params = assertion_params(stored.id, auth.credential_id)

      assert {:error, :challenge_corrupt} =
               Reauth.verify_and_consume(tenant.id, @purpose, params)
    end

    test "rejects an unknown / unenrolled credential id" do
      tenant = fixture(:tenant)
      _auth = fixture(:root_authenticator, tenant_id: tenant.id)
      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      params = assertion_params(issued.challenge_id, :crypto.strong_rand_bytes(16))

      assert {:error, :not_found} = Reauth.verify_and_consume(tenant.id, @purpose, params)
    end

    test "rejects sign-counter regression and does NOT bump the stored counter" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 10)
      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      expect(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 3}}
      end)

      params = assertion_params(issued.challenge_id, auth.credential_id)

      assert {:error, :counter_regression} =
               Reauth.verify_and_consume(tenant.id, @purpose, params)

      {:ok, reloaded} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
      assert reloaded.sign_count == 10
    end

    test "rejects an invalid signature and does NOT bump the stored counter" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 4)
      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      expect(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:error, :invalid_assertion}
      end)

      params = assertion_params(issued.challenge_id, auth.credential_id)

      assert {:error, :invalid_assertion} =
               Reauth.verify_and_consume(tenant.id, @purpose, params)

      {:ok, reloaded} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
      assert reloaded.sign_count == 4
    end
  end

  describe "tenant isolation" do
    test "tenant B cannot consume tenant A's challenge, even with a valid-looking assertion" do
      tenant_a = fixture(:tenant, %{slug: "reauth-a"})
      tenant_b = fixture(:tenant, %{slug: "reauth-b"})

      auth_a = fixture(:root_authenticator, tenant_id: tenant_a.id)
      # tenant B has its own authenticator, unrelated to A's challenge.
      _auth_b = fixture(:root_authenticator, tenant_id: tenant_b.id)

      {:ok, issued} = Reauth.issue_challenge(tenant_a.id, @purpose)

      # Tenant B replays A's challenge_id → the consume query is scoped by
      # tenant_id, so it finds nothing.
      params = assertion_params(issued.challenge_id, auth_a.credential_id)

      assert {:error, :challenge_not_found} =
               Reauth.verify_and_consume(tenant_b.id, @purpose, params)
    end

    test "issue_challenge only offers the calling tenant's credentials" do
      tenant_a = fixture(:tenant, %{slug: "reauth-c"})
      tenant_b = fixture(:tenant, %{slug: "reauth-d"})

      auth_a = fixture(:root_authenticator, tenant_id: tenant_a.id)
      auth_b = fixture(:root_authenticator, tenant_id: tenant_b.id)

      {:ok, issued} = Reauth.issue_challenge(tenant_a.id, @purpose)

      assert Base.url_encode64(auth_a.credential_id, padding: false) in issued.allowed_credentials

      refute Base.url_encode64(auth_b.credential_id, padding: false) in issued.allowed_credentials
    end
  end
end
