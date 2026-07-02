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
  alias Loopctl.WebAuthn.Wax, as: WaxAdapter

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

  # Builds a REAL FIDO2 assertion: syntactically valid authenticator_data +
  # client_data_json bound to `challenge_bytes`, signed over
  # `authData <> SHA256(clientDataJSON)` with the ES256 private key — exactly what
  # Wax.authenticate/6 verifies. rp_id/origin match config/test.exs (localhost).
  defp signed_assertion(challenge_id, credential_id, priv, challenge_bytes, sign_count) do
    rp_id = "localhost"
    origin = "http://localhost:4002"

    # rp_id_hash(32) <> flags(UP|UV = 0x05) <> sign_count(4, big-endian). No
    # attested credential data on an assertion, so the AT flag stays 0.
    auth_data =
      :crypto.hash(:sha256, rp_id) <> <<0x05>> <> <<sign_count::unsigned-big-integer-size(32)>>

    client_data_json =
      Jason.encode!(%{
        "type" => "webauthn.get",
        "challenge" => Base.url_encode64(challenge_bytes, padding: false),
        "origin" => origin
      })

    message = auth_data <> :crypto.hash(:sha256, client_data_json)
    signature = :crypto.sign(:ecdsa, :sha256, message, [priv, :secp256r1])

    %{
      "challenge_id" => challenge_id,
      "credential_id" => Base.url_encode64(credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(auth_data, padding: false),
      "signature" => Base.url_encode64(signature, padding: false),
      "client_data_json" => Base.url_encode64(client_data_json, padding: false)
    }
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

  describe "verify_and_consume/3 — real Wax adapter (end-to-end crypto)" do
    # Delegate the mock to the REAL Loopctl.WebAuthn.Wax adapter for this block so
    # the full FIDO2 verification runs against genuine ES256 crypto — WITHOUT
    # Application.put_env. This is the class of bug a mock-only suite cannot catch
    # (crypto-01 CRITICAL): with the pre-fix code (raw COSE key embedded in the
    # challenge's allow_credentials) every one of these {:ok, _} assertions FAILS.
    setup do
      stub(Loopctl.MockWebAuthn, :new_authentication_challenge, fn opts ->
        WaxAdapter.new_authentication_challenge(opts)
      end)

      stub(Loopctl.MockWebAuthn, :verify_authentication, fn payload, challenge, opts ->
        WaxAdapter.verify_authentication(payload, challenge, opts)
      end)

      # Synthetic P-256 / ES256 keypair enrolled exactly as production stores it.
      {pub_point, priv} = :crypto.generate_key(:ecdh, :secp256r1)
      <<4, x::binary-size(32), y::binary-size(32)>> = pub_point
      cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}

      tenant = fixture(:tenant)
      credential_id = :crypto.strong_rand_bytes(16)

      fixture(:root_authenticator,
        tenant_id: tenant.id,
        credential_id: credential_id,
        public_key: :erlang.term_to_binary(cose_key),
        sign_count: 0
      )

      %{tenant: tenant, credential_id: credential_id, priv: priv}
    end

    test "accepts a genuine ES256 signature and persists the counter", ctx do
      {:ok, issued} = Reauth.issue_challenge(ctx.tenant.id, @purpose)
      challenge_bytes = Base.url_decode64!(issued.challenge, padding: false)

      params =
        signed_assertion(issued.challenge_id, ctx.credential_id, ctx.priv, challenge_bytes, 1)

      assert {:ok, result} = Reauth.verify_and_consume(ctx.tenant.id, @purpose, params)
      assert result.sign_count == 1

      {:ok, reloaded} = RootAuthenticators.get_by_credential_id(ctx.tenant.id, ctx.credential_id)
      assert reloaded.sign_count == 1
    end

    test "rejects a signature from the wrong key (tampered), key not rotated", ctx do
      {:ok, issued} = Reauth.issue_challenge(ctx.tenant.id, @purpose)
      challenge_bytes = Base.url_decode64!(issued.challenge, padding: false)

      # A well-formed DER signature from a DIFFERENT key — fails verification cleanly.
      {_wrong_pub, wrong_priv} = :crypto.generate_key(:ecdh, :secp256r1)

      params =
        signed_assertion(issued.challenge_id, ctx.credential_id, wrong_priv, challenge_bytes, 1)

      assert {:error, _} = Reauth.verify_and_consume(ctx.tenant.id, @purpose, params)

      {:ok, reloaded} = RootAuthenticators.get_by_credential_id(ctx.tenant.id, ctx.credential_id)
      assert reloaded.sign_count == 0
    end

    test "rejects a valid signature bound to the WRONG challenge", ctx do
      {:ok, issued} = Reauth.issue_challenge(ctx.tenant.id, @purpose)

      # Sign over random challenge bytes that don't match the stored challenge.
      wrong_bytes = :crypto.strong_rand_bytes(32)

      params =
        signed_assertion(issued.challenge_id, ctx.credential_id, ctx.priv, wrong_bytes, 1)

      assert {:error, _} = Reauth.verify_and_consume(ctx.tenant.id, @purpose, params)
    end
  end

  describe "atomic sign-counter enforcement" do
    test "a replayed counter is rejected while a strictly-increasing one persists" do
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 0)

      stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 5}}
      end)

      {:ok, i1} = Reauth.issue_challenge(tenant.id, @purpose)

      assert {:ok, _} =
               Reauth.verify_and_consume(
                 tenant.id,
                 @purpose,
                 assertion_params(i1.challenge_id, auth.credential_id)
               )

      {:ok, r1} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
      assert r1.sign_count == 5

      # Second assertion carrying the SAME counter (replay/clone) — the atomic
      # conditional UPDATE matches 0 rows (5 < 5 is false) and rejects.
      {:ok, i2} = Reauth.issue_challenge(tenant.id, @purpose)

      assert {:error, :counter_regression} =
               Reauth.verify_and_consume(
                 tenant.id,
                 @purpose,
                 assertion_params(i2.challenge_id, auth.credential_id)
               )

      # A strictly-greater counter is accepted and persisted.
      stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 6}}
      end)

      {:ok, i3} = Reauth.issue_challenge(tenant.id, @purpose)

      assert {:ok, _} =
               Reauth.verify_and_consume(
                 tenant.id,
                 @purpose,
                 assertion_params(i3.challenge_id, auth.credential_id)
               )

      {:ok, r3} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
      assert r3.sign_count == 6
    end

    test "an asserted counter of 0 against a NONZERO stored counter is rejected (FIDO2 clone signal)" do
      # The exact §7.2 clone signal: an authenticator that previously reported a
      # counter of 10 now reports 0. This must be refused and the stored counter
      # must NOT be clobbered to 0. Guards the `new_count == 0` branch: collapsing
      # it (e.g. to `sign_count == ^id` with no counter predicate) would silently
      # readmit the clone while the rest of the suite stayed green.
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 10)

      stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 0}}
      end)

      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      assert {:error, :counter_regression} =
               Reauth.verify_and_consume(
                 tenant.id,
                 @purpose,
                 assertion_params(issued.challenge_id, auth.credential_id)
               )

      # Counter unchanged — NOT clobbered to 0.
      {:ok, reloaded} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
      assert reloaded.sign_count == 10
    end

    test "a 0/0 counter (authenticator without a counter) is accepted per spec" do
      # Symmetric guard for the other collapse direction: folding the 0-branch into
      # a bare `sign_count < new_count` would reject legitimate no-counter (0/0)
      # authenticators. Stored 0 + asserted 0 must succeed.
      tenant = fixture(:tenant)
      auth = fixture(:root_authenticator, tenant_id: tenant.id, sign_count: 0)

      stub(Loopctl.MockWebAuthn, :verify_authentication, fn _p, _c, _o ->
        {:ok, %{sign_count: 0}}
      end)

      {:ok, issued} = Reauth.issue_challenge(tenant.id, @purpose)

      assert {:ok, %{sign_count: 0}} =
               Reauth.verify_and_consume(
                 tenant.id,
                 @purpose,
                 assertion_params(issued.challenge_id, auth.credential_id)
               )

      {:ok, reloaded} = RootAuthenticators.get_by_credential_id(tenant.id, auth.credential_id)
      assert reloaded.sign_count == 0
      assert reloaded.last_used_at != nil
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
