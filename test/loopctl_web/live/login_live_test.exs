defmodule LoopctlWeb.LoginLiveTest do
  @moduledoc """
  US-45.7 (TC-45.7.1): browser login — the LiveView half that runs the ceremony and the POST
  that binds the session. Everything it touches is on `AdminRepo`, so it runs async.
  """

  use LoopctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Loopctl.AdminRepo
  alias Loopctl.WebAuthn.BrowserLogin
  alias Loopctl.WebAuthn.BrowserSession
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

  defp session_row(conn) do
    %{"session_id" => id} = get_session(conn, BrowserAuth.session_key())
    AdminRepo.get(BrowserSession, id)
  end

  describe "the ceremony (TC-45.7.1)" do
    test "a WebAuthn assertion binds the session to the tenant's human principal", ctx do
      conn = init_test_session(ctx.conn, %{"planted" => "before login"})
      {:ok, view, _html} = live(conn, ~p"/login")

      view |> element("#login-begin") |> render_click()
      assert_push_event(view, "webauthn:login", %{challenge: challenge, allowed_credentials: []})
      assert is_binary(challenge)

      render_hook(view, "assertion_captured", captured(ctx.authenticator))
      refute render(view) =~ ctx.tenant.id
      conn = follow_trigger_action(form(view, "#login-assertion-form"), conn)

      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, BrowserAuth.session_key())["tenant_id"] == ctx.tenant.id

      assert %BrowserSession{revoked_at: nil, authenticator_id: auth_id} = session_row(conn)
      assert auth_id == ctx.authenticator.id
      # The session was renewed: nothing planted before the login survives it.
      assert get_session(conn, "planted") == nil
      assert is_binary(get_session(conn, :live_socket_id))
    end

    test "the challenge the form posts is the server's, not the client's", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      view |> element("#login-begin") |> render_click()

      # A client naming its own challenge changes nothing the form posts.
      render_hook(
        view,
        "assertion_captured",
        Map.put(captured(ctx.authenticator), "challenge_id", Ecto.UUID.generate())
      )

      conn = follow_trigger_action(form(view, "#login-assertion-form"), ctx.conn)
      assert get_session(conn, BrowserAuth.session_key())["tenant_id"] == ctx.tenant.id
    end

    test "there is nothing to type: no slug field, and the page names no tenant", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/login")

      refute has_element?(view, "input[name*='slug']")
      assert has_element?(view, "#login-requirement", "discoverable credential")

      view |> element("#login-begin") |> render_click()
      assert_push_event(view, "webauthn:login", %{allowed_credentials: []})
      refute render(view) =~ ctx.tenant.id
    end

    test "an unknown credential is refused like any failed assertion", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      view |> element("#login-begin") |> render_click()

      stranger = %{ctx.authenticator | credential_id: :crypto.strong_rand_bytes(16)}
      render_hook(view, "assertion_captured", captured(stranger))
      conn = follow_trigger_action(form(view, "#login-assertion-form"), ctx.conn)

      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, BrowserAuth.session_key()) == nil
    end

    test "an assertion before any challenge, or an oversized one, arms nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      render_hook(view, "assertion_captured", captured(ctx.authenticator))
      refute has_element?(view, "#login-assertion-form[phx-trigger-action]")

      view |> element("#login-begin") |> render_click()

      render_hook(
        view,
        "assertion_captured",
        Map.put(captured(ctx.authenticator), "signature", String.duplicate("a", 9_000))
      )

      refute has_element?(view, "#login-assertion-form[phx-trigger-action]")
      assert has_element?(view, "#login-status", "cannot read")
    end

    test "the per-client challenge budget is fail-closed, keyed on the client", ctx do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "browser_login:challenge:127.0.0.1", _, _ -> {:deny, 30}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      {:ok, view, _html} = live(ctx.conn, ~p"/login")
      view |> element("#login-begin") |> render_click()

      assert has_element?(view, "#login-status", "Too many")
      refute_push_event(view, "webauthn:login", _)
    end
  end

  describe "POST /login" do
    test "a replayed assertion is refused and binds nothing", ctx do
      {:ok, issued} = BrowserLogin.begin()
      login = Map.put(captured(ctx.authenticator), "challenge_id", issued.challenge_id)

      first = post(ctx.conn, ~p"/login", %{"login" => login})
      assert get_session(first, BrowserAuth.session_key())

      replay = post(build_conn(), ~p"/login", %{"login" => login})
      assert redirected_to(replay) == ~p"/login"
      assert get_session(replay, BrowserAuth.session_key()) == nil
    end

    test "the per-client verify budget is checked before any verification", ctx do
      stub(Loopctl.MockRateLimiter, :check_rate, fn
        "browser_login:verify:127.0.0.1", _, _ -> {:deny, 30}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      expect(Loopctl.MockWebAuthn, :verify_authentication, 0, fn _, _, _ -> {:ok, %{}} end)
      {:ok, issued} = BrowserLogin.begin()

      conn =
        post(ctx.conn, ~p"/login", %{
          "login" => Map.put(captured(ctx.authenticator), "challenge_id", issued.challenge_id)
        })

      assert get_session(conn, BrowserAuth.session_key()) == nil
    end

    test "is CSRF-protected: a POST with no token is refused by the pipeline", ctx do
      {:ok, issued} = BrowserLogin.begin()

      conn =
        Plug.Test.conn(:post, "/login", %{
          "login" => Map.put(captured(ctx.authenticator), "challenge_id", issued.challenge_id)
        })

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        LoopctlWeb.Endpoint.call(conn, [])
      end
    end
  end

  describe "DELETE /logout" do
    test "revokes the session on the server and drops the cookie", ctx do
      {:ok, issued} = BrowserLogin.begin()

      logged_in =
        post(ctx.conn, ~p"/login", %{
          "login" => Map.put(captured(ctx.authenticator), "challenge_id", issued.challenge_id)
        })

      row = session_row(logged_in)
      conn = logged_in |> recycle() |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert conn.private[:plug_session_info] == :drop
      assert %BrowserSession{revoked_at: %DateTime{}} = AdminRepo.get(BrowserSession, row.id)
    end
  end
end
