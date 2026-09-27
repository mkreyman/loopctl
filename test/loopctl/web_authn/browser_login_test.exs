defmodule Loopctl.WebAuthn.BrowserLoginTest do
  @moduledoc """
  US-45.7 (AC-45.7.1): browser login on `Loopctl.WebAuthn.Reauth`'s ceremony, and what ends a
  session. The WebAuthn adapter is `Loopctl.MockWebAuthn` (config/test.exs).
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.WebAuthn.BrowserLogin
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

  defp session(tenant, authenticator, at \\ System.system_time(:second)) do
    BrowserLogin.to_session(%{
      tenant_id: tenant.id,
      authenticator_id: authenticator.id,
      authenticated_at: at
    })
  end

  describe "begin/1" do
    test "issues a stored browser_login challenge for the tenant's enrolled credentials", ctx do
      assert {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)
      assert issued.tenant_id == ctx.tenant.id

      assert issued.allowed_credentials == [
               Base.url_encode64(ctx.authenticator.credential_id, padding: false)
             ]

      assert %ReauthChallenge{purpose: "browser_login"} =
               AdminRepo.get(ReauthChallenge, issued.challenge_id)
    end

    test "one answer for an unknown slug, a tenant with no authenticator, and one not active" do
      bare = fixture(:tenant)
      suspended = fixture(:tenant, %{status: :suspended})
      fixture(:root_authenticator, tenant_id: suspended.id)

      assert {:error, :unavailable} = BrowserLogin.begin("no-such-tenant")
      assert {:error, :unavailable} = BrowserLogin.begin(bare.slug)
      assert {:error, :unavailable} = BrowserLogin.begin(suspended.slug)
      assert {:error, :unavailable} = BrowserLogin.begin(nil)
    end

    test "the tenant's budget is fail-closed", ctx do
      stub(Loopctl.MockRateLimiter, :check_rate, fn "browser_login:challenge:tenant:" <> _,
                                                    _,
                                                    _ ->
        {:deny, 60}
      end)

      assert {:error, :rate_limited} = BrowserLogin.begin(ctx.tenant.slug)
    end
  end

  describe "complete/2" do
    test "a verified assertion binds the tenant and the asserting authenticator", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      assert {:ok, principal} =
               BrowserLogin.complete(
                 ctx.tenant.id,
                 assertion(issued.challenge_id, ctx.authenticator)
               )

      assert principal.tenant_id == ctx.tenant.id
      assert principal.authenticator_id == ctx.authenticator.id
      assert_in_delta principal.authenticated_at, System.system_time(:second), 5
    end

    test "the tenant's verify budget is fail-closed and checked before verification", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "browser_login:verify:tenant:" <> _, _, _ -> {:deny, 60}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      expect(Loopctl.MockWebAuthn, :verify_authentication, 0, fn _, _, _ -> {:ok, %{}} end)

      assert {:error, :rate_limited} =
               BrowserLogin.complete(
                 ctx.tenant.id,
                 assertion(issued.challenge_id, ctx.authenticator)
               )
    end

    test "a challenge is good once: the replay is refused", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)
      params = assertion(issued.challenge_id, ctx.authenticator)

      assert {:ok, _} = BrowserLogin.complete(ctx.tenant.id, params)
      assert {:error, :challenge_not_found} = BrowserLogin.complete(ctx.tenant.id, params)
    end

    test "an assertion the adapter rejects binds nothing", ctx do
      expect(Loopctl.MockWebAuthn, :verify_authentication, fn _, _, _ ->
        {:error, :invalid_signature}
      end)

      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      assert {:error, :invalid_signature} =
               BrowserLogin.complete(
                 ctx.tenant.id,
                 assertion(issued.challenge_id, ctx.authenticator)
               )
    end

    test "tenant isolation: one tenant's challenge cannot sign in to another", ctx do
      other = fixture(:tenant)
      other_auth = fixture(:root_authenticator, tenant_id: other.id)
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(other.id, assertion(issued.challenge_id, other_auth))

      assert {:error, :invalid_login} = BrowserLogin.complete("not-a-uuid", %{})
    end

    test "an expired challenge is refused", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      AdminRepo.update_all(
        Ecto.Query.from(c in ReauthChallenge, where: c.id == ^issued.challenge_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert {:error, :challenge_not_found} =
               BrowserLogin.complete(
                 ctx.tenant.id,
                 assertion(issued.challenge_id, ctx.authenticator)
               )
    end
  end

  describe "validate/2" do
    test "a live session validates", ctx do
      assert {:ok, %{tenant_id: tid}} =
               BrowserLogin.validate(session(ctx.tenant, ctx.authenticator))

      assert tid == ctx.tenant.id
    end

    test "the lifetime is absolute", ctx do
      at = System.system_time(:second) - BrowserLogin.lifetime_seconds() - 1

      assert {:error, :expired} =
               BrowserLogin.validate(session(ctx.tenant, ctx.authenticator, at))

      future = System.system_time(:second) + 3_600

      assert {:error, :expired} =
               BrowserLogin.validate(session(ctx.tenant, ctx.authenticator, future))
    end

    test "revoking the authenticator ends the session", ctx do
      {:ok, _} = RootAuthenticators.delete(ctx.tenant.id, ctx.authenticator.id)

      assert {:error, :authenticator_revoked} =
               BrowserLogin.validate(session(ctx.tenant, ctx.authenticator))
    end

    test "a tenant no longer active ends the session", ctx do
      ctx.tenant |> Ecto.Changeset.change(status: :suspended) |> AdminRepo.update!()

      assert {:error, :tenant_inactive} =
               BrowserLogin.validate(session(ctx.tenant, ctx.authenticator))
    end

    test "tenant isolation: an authenticator of another tenant does not validate", ctx do
      other = fixture(:tenant)

      assert {:error, :authenticator_revoked} =
               BrowserLogin.validate(session(other, ctx.authenticator))
    end

    test "anything else is no session" do
      assert {:error, :no_session} = BrowserLogin.validate(nil)
      assert {:error, :no_session} = BrowserLogin.validate(%{"tenant_id" => "x"})

      assert {:error, :no_session} =
               BrowserLogin.validate(%{
                 "tenant_id" => "nope",
                 "authenticator_id" => "nope",
                 "authenticated_at" => System.system_time(:second)
               })
    end
  end

  describe "RootAuthenticators.enrolled?/2" do
    test "is scoped to the tenant", ctx do
      other = fixture(:tenant)
      assert RootAuthenticators.enrolled?(ctx.tenant.id, ctx.authenticator.id)
      refute RootAuthenticators.enrolled?(other.id, ctx.authenticator.id)
    end
  end
end
