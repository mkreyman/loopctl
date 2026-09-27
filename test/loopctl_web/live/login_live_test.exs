defmodule LoopctlWeb.LoginLiveTest do
  @moduledoc """
  US-45.7 (TC-45.7.1): browser login — the LiveView half that runs the ceremony and the POST
  that binds the session. Everything it touches is on `AdminRepo`, so it runs async.
  """

  use LoopctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Loopctl.WebAuthn.BrowserLogin
  alias LoopctlWeb.BrowserAuth

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    authenticator = fixture(:root_authenticator, tenant_id: tenant.id)
    %{tenant: tenant, authenticator: authenticator}
  end

  defp captured(authenticator) do
    %{
      "credential_id" => Base.url_encode64(authenticator.credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(:crypto.strong_rand_bytes(37), padding: false),
      "signature" => Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false),
      "client_data_json" => Base.url_encode64(~s({"type":"webauthn.get"}), padding: false)
    }
  end

  describe "the ceremony (TC-45.7.1)" do
    test "a WebAuthn assertion binds the session to the tenant's human principal", ctx do
      conn = init_test_session(ctx.conn, %{"planted" => "before login"})
      {:ok, view, _html} = live(conn, ~p"/login")

      view |> form("#login-form", login: %{slug: ctx.tenant.slug}) |> render_submit()
      assert_push_event(view, "webauthn:login", %{challenge: challenge, allowed_credentials: ids})
      assert is_binary(challenge)
      assert ids == [Base.url_encode64(ctx.authenticator.credential_id, padding: false)]

      render_hook(view, "assertion_captured", captured(ctx.authenticator))
      conn = follow_trigger_action(form(view, "#login-assertion-form"), conn)

      assert redirected_to(conn) == ~p"/login"
      stored = get_session(conn, BrowserAuth.session_key())
      assert stored["tenant_id"] == ctx.tenant.id
      assert stored["authenticator_id"] == ctx.authenticator.id
      assert {:ok, _principal} = BrowserLogin.validate(stored)
      # The session was renewed: nothing planted before the login survives it.
      assert get_session(conn, "planted") == nil
      assert is_binary(get_session(conn, :live_socket_id))
    end

    test "the challenge and tenant the form posts are the server's, not the client's", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      view |> form("#login-form", login: %{slug: ctx.tenant.slug}) |> render_submit()

      # A client naming its own tenant and challenge changes nothing it posts.
      render_hook(
        view,
        "assertion_captured",
        Map.merge(captured(ctx.authenticator), %{
          "tenant_id" => Ecto.UUID.generate(),
          "challenge_id" => Ecto.UUID.generate()
        })
      )

      conn = follow_trigger_action(form(view, "#login-assertion-form"), ctx.conn)
      assert get_session(conn, BrowserAuth.session_key())["tenant_id"] == ctx.tenant.id
    end

    test "an unknown slug is one refusal, and nothing is pushed", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      view |> form("#login-form", login: %{slug: "nobody-here"}) |> render_submit()

      assert has_element?(view, "#login-status", "No tenant with that slug")
      refute_push_event(view, "webauthn:login", _)
    end

    test "an assertion before any challenge, or an oversized one, arms nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      render_hook(view, "assertion_captured", captured(ctx.authenticator))
      refute has_element?(view, "#login-assertion-form[phx-trigger-action]")

      view |> form("#login-form", login: %{slug: ctx.tenant.slug}) |> render_submit()

      render_hook(
        view,
        "assertion_captured",
        Map.put(captured(ctx.authenticator), "signature", String.duplicate("a", 9_000))
      )

      refute has_element?(view, "#login-assertion-form[phx-trigger-action]")
      assert has_element?(view, "#login-status", "cannot read")
    end

    test "the per-IP challenge budget is fail-closed", ctx do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "browser_login:challenge:ip:" <> _, _, _ -> {:deny, 30}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      view |> form("#login-form", login: %{slug: ctx.tenant.slug}) |> render_submit()

      assert has_element?(view, "#login-status", "Too many")
      refute_push_event(view, "webauthn:login", _)
    end
  end

  describe "POST /login" do
    test "a replayed assertion is refused and binds nothing", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      login =
        Map.merge(captured(ctx.authenticator), %{
          "tenant_id" => ctx.tenant.id,
          "challenge_id" => issued.challenge_id
        })

      first = post(ctx.conn, ~p"/login", %{"login" => login})
      assert get_session(first, BrowserAuth.session_key())

      replay = post(build_conn(), ~p"/login", %{"login" => login})
      assert redirected_to(replay) == ~p"/login"
      assert get_session(replay, BrowserAuth.session_key()) == nil
    end

    test "the per-IP verify budget is checked before any verification", ctx do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "browser_login:verify:ip:" <> _, _, _ -> {:deny, 30}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      expect(Loopctl.MockWebAuthn, :verify_authentication, 0, fn _, _, _ -> {:ok, %{}} end)
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      conn =
        post(ctx.conn, ~p"/login", %{
          "login" =>
            Map.merge(captured(ctx.authenticator), %{
              "tenant_id" => ctx.tenant.id,
              "challenge_id" => issued.challenge_id
            })
        })

      assert get_session(conn, BrowserAuth.session_key()) == nil
    end

    test "is CSRF-protected: a POST with no token is refused by the pipeline", ctx do
      {:ok, issued} = BrowserLogin.begin(ctx.tenant.slug)

      conn =
        Plug.Test.conn(:post, "/login", %{
          "login" =>
            Map.merge(captured(ctx.authenticator), %{
              "tenant_id" => ctx.tenant.id,
              "challenge_id" => issued.challenge_id
            })
        })

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        LoopctlWeb.Endpoint.call(conn, [])
      end
    end
  end

  describe "DELETE /logout" do
    test "drops the session", ctx do
      conn =
        ctx.conn
        |> init_test_session(%{
          BrowserAuth.session_key() =>
            BrowserLogin.to_session(%{
              tenant_id: ctx.tenant.id,
              authenticator_id: ctx.authenticator.id,
              authenticated_at: System.system_time(:second)
            })
        })
        |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert conn.private[:plug_session_info] == :drop
    end
  end
end
