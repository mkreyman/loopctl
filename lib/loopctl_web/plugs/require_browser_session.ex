defmodule LoopctlWeb.Plugs.RequireBrowserSession do
  @moduledoc """
  The HTTP half of the thread page's session guard (US-45.7). Asks
  `Loopctl.WebAuthn.BrowserLogin.validate/2` on EVERY request — so an expired session, a revoked
  authenticator or a tenant no longer active is refused on the next page load — and assigns the
  principal. A refused request is sent to `/login`, remembering a thread page it was going to,
  and a session that no longer validates is dropped rather than left in the cookie. The
  LiveView half is `LoopctlWeb.BrowserAuth.on_mount/4`.
  """

  @behaviour Plug

  use LoopctlWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Loopctl.WebAuthn.BrowserLogin
  alias LoopctlWeb.BrowserAuth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case BrowserLogin.validate(get_session(conn, BrowserAuth.session_key())) do
      {:ok, principal} ->
        assign(conn, :browser_principal, principal)

      {:error, _reason} ->
        conn
        |> delete_session(BrowserAuth.session_key())
        |> BrowserAuth.remember_return_to()
        |> put_flash(:error, "Sign in with your authenticator to continue.")
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end
end
