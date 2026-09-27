defmodule LoopctlWeb.BrowserAuth do
  @moduledoc """
  The browser session for the thread page (US-45.7, AC-45.7.1). The mechanism is
  `Loopctl.WebAuthn.BrowserLogin`; this module binds it to Phoenix.

  ## Two layers, because a LiveView has two ways in

  `LoopctlWeb.Plugs.RequireBrowserSession` guards the HTTP request that renders a page, and
  `on_mount/4` guards the LiveView mount — including a live navigation over an already-open
  socket, which never passes through the router's plugs. Each asks
  `BrowserLogin.validate/2` itself; neither trusts that the other ran.

  ## Login and logout

  `log_in/2` renews the session and rotates the CSRF token before it writes the principal, so a
  session id or token planted before the login is worthless after it (fixation). It also gives
  the session a `live_socket_id`, so `log_out/1` can disconnect every LiveView the session has
  open rather than leaving them running on a cookie that no longer exists.
  """

  use LoopctlWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Loopctl.WebAuthn.BrowserLogin

  @session_key "browser_principal"
  @return_to_key "browser_return_to"

  @doc "The session key the principal is stored under."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  The extra session `LoopctlWeb.LoginLive` mounts with: its per-client rate-limit key,
  `Loopctl.RemoteIp.bucket_key/1` of the address the HTTP pipeline resolved — the same key
  `LoopctlWeb.BrowserSessionController` throttles on, so one client has one budget.
  """
  @spec login_session(Plug.Conn.t()) :: map()
  def login_session(conn), do: %{"login_rate_key" => client_key(conn)}

  @doc "The per-client rate-limit key for `conn` (`Loopctl.RemoteIp.bucket_key/1`)."
  @spec client_key(Plug.Conn.t()) :: String.t()
  def client_key(conn), do: Loopctl.RemoteIp.bucket_key(conn.remote_ip)

  @doc false
  def on_mount(:require_browser_session, _params, session, socket) do
    case BrowserLogin.validate(session[@session_key]) do
      {:ok, principal} ->
        {:cont, Phoenix.Component.assign(socket, :browser_principal, principal)}

      {:error, _reason} ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Sign in with your authenticator to continue.")
         |> Phoenix.LiveView.redirect(to: ~p"/login")}
    end
  end

  @doc """
  Remembers where an unauthenticated GET was going, so the login lands there. Only a thread
  page path is remembered: a `return_to` is replayed as a redirect, and anything wider is an
  open redirect.
  """
  @spec remember_return_to(Plug.Conn.t()) :: Plug.Conn.t()
  def remember_return_to(%Plug.Conn{method: "GET", request_path: "/threads/" <> _} = conn),
    do: put_session(conn, @return_to_key, conn.request_path)

  def remember_return_to(conn), do: conn

  @doc "Binds the session to `principal` and redirects to where the login was going."
  @spec log_in(Plug.Conn.t(), BrowserLogin.principal()) :: Plug.Conn.t()
  def log_in(conn, principal) do
    return_to = get_session(conn, @return_to_key)

    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@session_key, BrowserLogin.to_session(principal))
    |> put_session(:live_socket_id, "browser_sessions:" <> random_id())
    |> redirect(to: safe_return_to(return_to))
  end

  @doc """
  Ends the session ON THE SERVER (`BrowserLogin.revoke/1`), so a copy of the cookie stops
  working too, drops the cookie, and disconnects every LiveView the session has open.
  """
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    BrowserLogin.revoke(get_session(conn, @session_key))

    if live_socket_id = get_session(conn, :live_socket_id) do
      LoopctlWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  defp safe_return_to("/threads/" <> _ = path), do: path
  defp safe_return_to(_other), do: ~p"/login"

  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
