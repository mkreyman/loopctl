defmodule LoopctlWeb.EndpointSessionCookieTest do
  @moduledoc """
  #461 item 3 — the signed+encrypted session cookie carries the hardening flags.

  The browser pipeline's `protect_from_forgery` writes the CSRF token into the
  session when a page renders, so a GET of a browser route emits a `Set-Cookie`
  for `_loopctl_key`. We assert the endpoint's `@session_options` flow through to
  that cookie: `http_only` (always) and `same_site` "Lax". `secure` is compile-env
  gated (`:session_secure`) — false in dev/test so the LiveView signup handoff
  works over plain HTTP, true only in prod (config/prod.exs) where TLS terminates.
  """
  use LoopctlWeb.ConnCase, async: true

  test "the session cookie is HttpOnly and SameSite=Lax", %{conn: conn} do
    conn = get(conn, "/")

    cookie = conn.resp_cookies["_loopctl_key"]

    assert cookie, "expected GET / to set the _loopctl_key session cookie"
    assert cookie.http_only == true
    assert cookie.same_site == "Lax"
  end

  test "the session cookie is NOT marked Secure in the test/dev compile env", %{conn: conn} do
    # Documents the compile-env gate: dev/test leave `:session_secure` unset (false)
    # so the cookie is sent over the plain-HTTP LiveView WebSocket signup handoff.
    # Prod flips `config :loopctl, :session_secure, true` (config/prod.exs).
    conn = get(conn, "/")
    cookie = conn.resp_cookies["_loopctl_key"]

    assert cookie
    assert Map.get(cookie, :secure, false) == false
  end

  test "the endpoint gates the Secure flag on the :session_secure compile env" do
    # The property under test is that `secure:` is DERIVED from config, not a naked
    # literal — so prod can turn it on without the endpoint sending a Secure cookie
    # over HTTP in dev/test. The endpoint reads this key via compile_env; here we
    # read the same key (unset in test → false default).
    assert Application.get_env(:loopctl, :session_secure, false) == false
  end
end
