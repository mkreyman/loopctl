defmodule LoopctlWeb.BrowserSessionController do
  @moduledoc """
  The two HTTP halves of the thread page's login (US-45.7, AC-45.7.1). A LiveView cannot write
  the session cookie, so `LoopctlWeb.LoginLive` runs the ceremony in the browser and submits the
  assertion here as an ordinary form POST, through the `:browser` pipeline's CSRF protection.

  - `create/2` verifies the assertion (`Loopctl.WebAuthn.BrowserLogin.complete/2`, which is
    `Loopctl.WebAuthn.Reauth`'s ceremony) and binds the session. Throttled per client IP,
    fail-closed, before any verification work.
  - `delete/2` ends the session.
  """

  use LoopctlWeb, :controller

  alias Loopctl.WebAuthn.BrowserLogin
  alias LoopctlWeb.BrowserAuth

  # Per client IP, on top of `BrowserLogin`'s per-tenant budget: assertion verification is
  # CPU-bound, and the ceremony endpoints elsewhere carry the same fail-closed shape.
  @window_ms 15 * 60_000
  @max_per_window 30

  @assertion_fields ~w(challenge_id credential_id authenticator_data signature client_data_json)

  @doc "POST /login"
  def create(conn, %{"login" => %{"tenant_id" => tenant_id} = login}) when is_binary(tenant_id) do
    with :ok <- throttle(conn),
         {:ok, principal} <-
           BrowserLogin.complete(tenant_id, Map.take(login, @assertion_fields)) do
      BrowserAuth.log_in(conn, principal)
    else
      {:error, :rate_limited} -> refused(conn, "Too many sign-in attempts. Try again later.")
      {:error, _reason} -> refused(conn, "That sign-in did not verify. Try again.")
    end
  end

  def create(conn, _params), do: refused(conn, "That sign-in did not verify. Try again.")

  @doc "DELETE /logout"
  def delete(conn, _params), do: BrowserAuth.log_out(conn)

  defp throttle(conn) do
    ip = Loopctl.RemoteIp.to_string_ip(conn.remote_ip)

    if Loopctl.RateLimiter.gate_ok?("browser_login:verify:ip:#{ip}", @window_ms, @max_per_window),
      do: :ok,
      else: {:error, :rate_limited}
  end

  defp refused(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end
end
