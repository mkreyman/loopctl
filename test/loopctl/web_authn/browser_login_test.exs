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
  alias Loopctl.WebAuthn.Reauth
  alias Loopctl.WebAuthn.ReauthChallenge

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

  describe "begin/1" do
    test "issues a stored browser_login challenge for the tenant's enrolled credentials", ctx do
      assert {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      assert issued.allowed_credentials == [
               Base.url_encode64(ctx.authenticator.credential_id, padding: false)
             ]

      assert %ReauthChallenge{purpose: "browser_login", tenant_id: tid} =
               AdminRepo.get(ReauthChallenge, issued.challenge_id)

      assert tid == ctx.tenant.id
      refute Map.has_key?(issued, :tenant_id)
    end

    test "every slug gets the same answer: the same keys and shapes, no tenant id", ctx do
      bare = fixture(:tenant)
      suspended = fixture(:tenant, %{status: :suspended})
      fixture(:root_authenticator, tenant_id: suspended.id)

      {:ok, real} = BrowserLogin.begin(ctx.tenant.slug)

      for slug <- ["no-such-tenant", bare.slug, suspended.slug, nil] do
        assert {:ok, decoy} = BrowserLogin.begin(slug)
        assert Map.keys(decoy) |> Enum.sort() == Map.keys(real) |> Enum.sort()
        assert {:ok, _} = Ecto.UUID.cast(decoy.challenge_id)
        assert byte_size(decoy.challenge) == byte_size(real.challenge)
        assert [credential] = decoy.allowed_credentials
        assert {:ok, _} = Base.url_decode64(credential, padding: false)
        assert decoy.rp_id == real.rp_id
        assert %DateTime{} = decoy.expires_at
        # A decoy is never stored, so its id can only fail verification.
        assert AdminRepo.get(ReauthChallenge, decoy.challenge_id) == nil
      end
    end

    test "a decoy's credential is stable for its slug and differs between slugs" do
      {:ok, one} = BrowserLogin.begin("ghost-a")
      {:ok, again} = BrowserLogin.begin("ghost-a")
      {:ok, other} = BrowserLogin.begin("ghost-b")

      assert one.allowed_credentials == again.allowed_credentials
      refute one.allowed_credentials == other.allowed_credentials
      refute one.challenge_id == again.challenge_id
    end

    test "there is no per-tenant budget a stranger could spend", ctx do
      expect(Loopctl.MockRateLimiter, :check_rate, 0, fn _, _, _ -> {:deny, 1} end)
      assert {:ok, _} = BrowserLogin.begin(ctx.tenant.slug)
    end
  end

  describe "complete/1" do
    test "a verified assertion opens a session on the tenant the stored challenge names", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      assert {:ok, principal} =
               BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))

      assert principal.tenant_id == ctx.tenant.id
      assert principal.authenticator_id == ctx.authenticator.id

      assert %BrowserSession{revoked_at: nil, expires_at: expires} =
               AdminRepo.get(BrowserSession, principal.session_id)

      assert_in_delta DateTime.diff(expires, DateTime.utc_now()),
                      BrowserLogin.lifetime_seconds(),
                      5
    end

    test "a challenge is good once: the replay is refused", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)
      params = assertion(issued.challenge_id, ctx.authenticator)

      assert {:ok, _} = BrowserLogin.complete(params)
      assert {:error, :challenge_not_found} = BrowserLogin.complete(params)
    end

    test "a decoy challenge fails exactly as a replayed one does", ctx do
      {:ok, decoy} = BrowserLogin.begin("nobody-here")

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(assertion(decoy.challenge_id, ctx.authenticator))

      assert {:error, :challenge_not_found} = BrowserLogin.complete(%{})
    end

    test "a challenge issued for another ceremony cannot sign in", ctx do
      {:ok, other} = Reauth.issue_challenge(ctx.tenant.id, "rotate_audit_key")

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(assertion(other.challenge_id, ctx.authenticator))
    end

    test "an assertion the adapter rejects opens nothing", ctx do
      expect(Loopctl.MockWebAuthn, :verify_authentication, fn _, _, _ ->
        {:error, :invalid_signature}
      end)

      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      assert {:error, :invalid_signature} =
               BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))

      assert AdminRepo.aggregate(BrowserSession, :count) == 0
    end

    test "tenant isolation: another tenant's credential cannot answer this tenant's challenge",
         ctx do
      other = fixture(:tenant)
      other_auth = fixture(:root_authenticator, tenant_id: other.id)
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      assert {:error, :not_found} =
               BrowserLogin.complete(assertion(issued.challenge_id, other_auth))
    end

    test "an expired challenge is refused", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      AdminRepo.update_all(
        from(c in ReauthChallenge, where: c.id == ^issued.challenge_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(assertion(issued.challenge_id, ctx.authenticator))
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
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)
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
