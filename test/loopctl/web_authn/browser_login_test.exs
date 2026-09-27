defmodule Loopctl.WebAuthn.BrowserLoginTest do
  @moduledoc """
  US-45.7 (AC-45.7.1): browser login on `Loopctl.WebAuthn.Reauth`'s ceremony, the one answer
  it gives every slug, and what ends a session. The WebAuthn adapter is `Loopctl.MockWebAuthn`
  (config/test.exs).

  The ceremony runs on `AdminRepo`, so its tests use `AdminRepo` fixtures; a session is
  validated under the tenant's RLS on `Loopctl.Repo`, so `validate/2`'s tests use `Repo` ones.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WebAuthn.BrowserLogin
  alias Loopctl.WebAuthn.BrowserSession
  alias Loopctl.WebAuthn.LoginChallenge
  alias Loopctl.WebAuthn.Reauth
  alias Loopctl.WebAuthn.Wax, as: WaxAdapter

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    authenticator = fixture(:root_authenticator, tenant_id: tenant.id)
    %{tenant: tenant, authenticator: authenticator}
  end

  defp assertion(challenge_id, authenticator) do
    %{
      "challenge_id" => challenge_id,
      "credential_id" => Base.url_encode64(authenticator.credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(:crypto.strong_rand_bytes(37), padding: false),
      "signature" => Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
      "client_data_json" => Base.url_encode64(~s({"type":"webauthn.get"}), padding: false)
    }
  end

  # A tenant, authenticator and session on the RLS repo, where `validate/2` reads.
  defp repo_session(attrs \\ %{}) do
    tenant = fixture(:stage_tenant, %{})
    auth = fixture(:root_authenticator, tenant_id: tenant.id, repo: Repo)

    session =
      fixture(
        :browser_session,
        Map.merge(%{tenant_id: tenant.id, authenticator_id: auth.id, repo: Repo}, attrs)
      )

    %{
      tenant: tenant,
      auth: auth,
      session: session,
      cookie: %{"tenant_id" => tenant.id, "session_id" => session.id}
    }
  end

  describe "begin/0" do
    test "issues a stored, tenantless, usernameless challenge that requires user verification" do
      expect(Loopctl.MockWebAuthn, :new_authentication_challenge, fn opts ->
        assert opts[:user_verification] == "required"
        %{bytes: <<1::256>>, rp_id: "localhost"}
      end)

      assert {:ok, issued} = BrowserLogin.begin()
      assert issued.allowed_credentials == []
      assert %{challenge_id: _, challenge: _, rp_id: _, expires_at: _} = issued

      assert %LoginChallenge{used_at: nil} =
               AdminRepo.get(LoginChallenge, issued.challenge_id)
    end

    test "it takes no input, so every visitor gets the same shape" do
      {:ok, one} = BrowserLogin.begin()
      {:ok, two} = BrowserLogin.begin()

      assert Map.keys(one) == Map.keys(two)
      assert byte_size(one.challenge) == byte_size(two.challenge)
      refute one.challenge_id == two.challenge_id
    end

    test "there is no per-tenant budget a stranger could spend" do
      expect(Loopctl.MockRateLimiter, :check_rate, 0, fn _, _, _ -> {:deny, 1} end)
      assert {:ok, _} = BrowserLogin.begin()
    end
  end

  describe "complete/1" do
    test "the asserting credential names the tenant: tenant A's credential opens A's session",
         ctx do
      other = fixture(:tenant)
      fixture(:root_authenticator, tenant_id: other.id)
      {:ok, issued} = BrowserLogin.begin()

      assert {:ok, principal} =
               BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))

      assert principal.tenant_id == ctx.tenant.id
      assert principal.authenticator_id == ctx.authenticator.id

      assert %BrowserSession{revoked_at: nil, expires_at: expires, tenant_id: tid} =
               AdminRepo.get(BrowserSession, principal.session_id)

      assert tid == ctx.tenant.id

      assert_in_delta DateTime.diff(expires, DateTime.utc_now()),
                      BrowserLogin.lifetime_seconds(),
                      5
    end

    test "an assertion spends the challenge it names and no other", ctx do
      {:ok, first} = BrowserLogin.begin()
      {:ok, second} = BrowserLogin.begin()

      # Each login advances the authenticator's counter, as a real one does.
      expect(Loopctl.MockWebAuthn, :verify_authentication, fn _, _, _ ->
        {:ok, %{sign_count: 1}}
      end)

      expect(Loopctl.MockWebAuthn, :verify_authentication, fn _, _, _ ->
        {:ok, %{sign_count: 2}}
      end)

      assert {:ok, _} = BrowserLogin.complete(assertion(second.challenge_id, ctx.authenticator))
      assert {:ok, _} = BrowserLogin.complete(assertion(first.challenge_id, ctx.authenticator))
    end

    test "a challenge is good once: the replay is refused", ctx do
      {:ok, issued} = BrowserLogin.begin()
      params = assertion(issued.challenge_id, ctx.authenticator)

      assert {:ok, _} = BrowserLogin.complete(params)
      assert {:error, :challenge_not_found} = BrowserLogin.complete(params)
    end

    test "an unknown credential fails as a bad assertion does, and spends the challenge", ctx do
      {:ok, issued} = BrowserLogin.begin()
      stranger = %{ctx.authenticator | credential_id: :crypto.strong_rand_bytes(16)}
      params = assertion(issued.challenge_id, stranger)

      assert {:error, :invalid_assertion} = BrowserLogin.complete(params)

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))
    end

    test "a reauth challenge, or an expired login challenge, cannot sign in", ctx do
      {:ok, reauth} = Reauth.issue_challenge(ctx.tenant.id, "browser_login")

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(assertion(reauth.challenge_id, ctx.authenticator))

      {:ok, issued} = BrowserLogin.begin()

      AdminRepo.update_all(
        from(c in LoginChallenge, where: c.id == ^issued.challenge_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))

      assert {:error, :invalid_assertion} = BrowserLogin.complete(:not_a_map)
    end

    test "an inactive tenant's credential opens nothing", ctx do
      ctx.tenant |> Ecto.Changeset.change(status: :suspended) |> AdminRepo.update!()
      {:ok, issued} = BrowserLogin.begin()

      assert {:error, :tenant_inactive} =
               BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))
    end

    test "an authenticator revoked before the session is written is a clean refusal", ctx do
      AdminRepo.delete!(ctx.authenticator)

      assert {:error, :authenticator_revoked} =
               BrowserLogin.open_session(ctx.tenant.id, ctx.authenticator.id)
    end

    test "a credential id is globally unique: another tenant cannot enroll it", ctx do
      other = fixture(:tenant)

      assert {:error, %Ecto.Changeset{errors: [credential_id: _]}} =
               %RootAuthenticator{tenant_id: other.id}
               |> RootAuthenticator.create_changeset(%{
                 credential_id: ctx.authenticator.credential_id,
                 public_key: :erlang.term_to_binary(%{1 => 2}),
                 attestation_format: "none",
                 friendly_name: "copy"
               })
               |> AdminRepo.insert()
    end
  end

  describe "complete/1 against the real WebAuthn verifier" do
    setup do
      stub(Loopctl.MockWebAuthn, :new_authentication_challenge, fn opts ->
        WaxAdapter.new_authentication_challenge(opts)
      end)

      stub(Loopctl.MockWebAuthn, :verify_authentication, fn payload, challenge, opts ->
        WaxAdapter.verify_authentication(payload, challenge, opts)
      end)

      {pub_point, priv} = :crypto.generate_key(:ecdh, :secp256r1)
      <<4, x::binary-size(32), y::binary-size(32)>> = pub_point
      tenant = fixture(:tenant)
      credential_id = :crypto.strong_rand_bytes(16)

      fixture(:root_authenticator,
        tenant_id: tenant.id,
        credential_id: credential_id,
        public_key: :erlang.term_to_binary(%{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y})
      )

      %{wax_tenant: tenant, credential_id: credential_id, priv: priv}
    end

    defp signed(challenge_id, credential_id, priv, challenge_b64, flags) do
      auth_data = :crypto.hash(:sha256, "localhost") <> <<flags>> <> <<1::unsigned-32>>

      client_data_json =
        Jason.encode!(%{
          "type" => "webauthn.get",
          "challenge" => challenge_b64,
          "origin" => "http://localhost:4002"
        })

      signature =
        :crypto.sign(
          :ecdsa,
          :sha256,
          auth_data <> :crypto.hash(:sha256, client_data_json),
          [priv, :secp256r1]
        )

      %{
        "challenge_id" => challenge_id,
        "credential_id" => Base.url_encode64(credential_id, padding: false),
        "authenticator_data" => Base.url_encode64(auth_data, padding: false),
        "signature" => Base.url_encode64(signature, padding: false),
        "client_data_json" => Base.url_encode64(client_data_json, padding: false)
      }
    end

    test "a verified, user-verified assertion signs in", ctx do
      {:ok, issued} = BrowserLogin.begin()
      params = signed(issued.challenge_id, ctx.credential_id, ctx.priv, issued.challenge, 0x05)

      assert {:ok, %{tenant_id: tid}} = BrowserLogin.complete(params)
      assert tid == ctx.wax_tenant.id
    end

    test "an assertion WITHOUT user verification is refused", ctx do
      {:ok, issued} = BrowserLogin.begin()
      params = signed(issued.challenge_id, ctx.credential_id, ctx.priv, issued.challenge, 0x01)

      assert {:error, :invalid_assertion} = BrowserLogin.complete(params)
    end

    test "a bad signature and an unknown credential get the same answer", ctx do
      {:ok, bad} = BrowserLogin.begin()
      {other_pub, other_priv} = :crypto.generate_key(:ecdh, :secp256r1)
      _ = other_pub
      params = signed(bad.challenge_id, ctx.credential_id, other_priv, bad.challenge, 0x05)
      assert {:error, bad_answer} = BrowserLogin.complete(params)

      {:ok, unknown} = BrowserLogin.begin()

      params =
        signed(
          unknown.challenge_id,
          :crypto.strong_rand_bytes(16),
          ctx.priv,
          unknown.challenge,
          0x05
        )

      assert {:error, ^bad_answer} = BrowserLogin.complete(params)
    end
  end

  describe "validate/2, under the tenant's RLS" do
    test "a live session validates" do
      %{cookie: cookie, tenant: tenant, session: session} = repo_session()
      assert {:ok, %{tenant_id: tid, session_id: sid}} = BrowserLogin.validate(cookie)
      assert tid == tenant.id and sid == session.id
    end

    test "the lifetime is absolute" do
      %{cookie: cookie} = repo_session(%{expires_at: DateTime.add(DateTime.utc_now(), -1)})
      assert {:error, :no_session} = BrowserLogin.validate(cookie)
    end

    test "logout revokes on the server: every copy of the cookie stops working" do
      %{cookie: cookie, session: session} = repo_session()
      copy = Map.new(cookie)

      {:ok, _} =
        Repo.with_tenant(cookie["tenant_id"], fn ->
          from(s in BrowserSession, where: s.id == ^session.id)
          |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])
        end)

      assert {:error, :no_session} = BrowserLogin.validate(copy)
    end

    test "revoke/1 writes the revocation for its own tenant's row only", ctx do
      {:ok, issued} = BrowserLogin.begin()
      {:ok, principal} = BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))
      other = fixture(:tenant)

      :ok = BrowserLogin.revoke(%{"tenant_id" => other.id, "session_id" => principal.session_id})
      assert %{revoked_at: nil} = AdminRepo.get(BrowserSession, principal.session_id)

      :ok = BrowserLogin.revoke(BrowserLogin.to_session(principal))
      assert %{revoked_at: %DateTime{}} = AdminRepo.get(BrowserSession, principal.session_id)
    end

    test "revoking the authenticator ends the session" do
      %{cookie: cookie, auth: auth} = repo_session()

      {:ok, _} =
        Repo.with_tenant(cookie["tenant_id"], fn ->
          Repo.delete_all(from a in RootAuthenticator, where: a.id == ^auth.id)
        end)

      assert {:error, :no_session} = BrowserLogin.validate(cookie)
    end

    test "a tenant no longer active ends the session" do
      %{cookie: cookie, tenant: tenant} = repo_session()

      Repo.update_all(from(t in Tenant, where: t.id == ^tenant.id), set: [status: :suspended])

      assert {:error, :no_session} = BrowserLogin.validate(cookie)
    end

    test "tenant isolation: a session presented under another tenant does not validate" do
      %{cookie: cookie} = repo_session()
      %{tenant: other} = repo_session()

      assert {:error, :no_session} =
               BrowserLogin.validate(%{cookie | "tenant_id" => other.id})
    end

    test "anything else is no session" do
      assert {:error, :no_session} = BrowserLogin.validate(nil)
      assert {:error, :no_session} = BrowserLogin.validate(%{"tenant_id" => "x"})

      assert {:error, :no_session} =
               BrowserLogin.validate(%{"tenant_id" => "nope", "session_id" => "nope"})
    end
  end
end
