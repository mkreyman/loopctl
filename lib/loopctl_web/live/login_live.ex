defmodule LoopctlWeb.LoginLive do
  @moduledoc """
  US-45.7 (AC-45.7.1) — browser login with the WebAuthn credential enrolled at tenant signup.

  The ceremony, in four hops:

  1. The human names the tenant (its slug) and submits `begin`. The LiveView, after a per-IP
     budget, asks `Loopctl.WebAuthn.BrowserLogin.begin/1` for a stored, single-use challenge
     bound to the tenant's enrolled authenticators, and pushes it to the `WebAuthnLogin` hook.
  2. The hook runs `navigator.credentials.get()` and pushes the assertion back.
  3. The LiveView bounds the assertion's fields and fills a plain form whose `tenant_id` and
     `challenge_id` come from ITS OWN assigns, never from the client, then triggers the form
     (`phx-trigger-action`).
  4. The form POSTs to `LoopctlWeb.BrowserSessionController`, through the `:browser` pipeline's
     CSRF check, which verifies and consumes the challenge and binds the session. A LiveView
     cannot write the session cookie, which is why the last hop is a POST.

  Nothing here decides whether the login succeeds: the POST does, on a challenge the client
  can present exactly once.
  """

  use LoopctlWeb, :live_view

  alias Loopctl.WebAuthn.BrowserLogin
  alias LoopctlWeb.BrowserAuth

  @rate_window_ms 15 * 60_000
  @max_per_window 30

  # A real FIDO2 assertion field is well under this (`Loopctl.WebAuthn.Reauth` enforces the
  # same bound again, before any decode).
  @max_field_bytes 8 * 1024
  @assertion_fields ~w(credential_id authenticator_data signature client_data_json)

  @impl true
  def mount(_params, session, socket) do
    signed_in =
      case BrowserLogin.validate(session[BrowserAuth.session_key()]) do
        {:ok, principal} -> principal
        {:error, _reason} -> nil
      end

    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:signed_in, signed_in)
     |> assign(:rate_key, rate_key(session, socket))
     |> assign(:form, to_form(%{"slug" => ""}, as: :login))
     |> assign(:pending, nil)
     |> assign(:assertion, %{})
     |> assign(:trigger_submit, false)
     |> assign(:status, nil)}
  end

  # The HTTP-resolved client IP when the session carries one; otherwise a per-connection key,
  # so a missing IP never collapses every visitor onto one bucket.
  defp rate_key(%{"client_ip" => ip}, _socket) when is_binary(ip), do: "ip:" <> ip
  defp rate_key(_session, socket), do: "conn:" <> socket.id

  @impl true
  def handle_event("begin", %{"login" => %{"slug" => slug}}, socket) when is_binary(slug) do
    with :ok <- budget(socket),
         {:ok, issued} <- BrowserLogin.begin(slug) do
      {:noreply,
       socket
       |> assign(:pending, %{tenant_id: issued.tenant_id, challenge_id: issued.challenge_id})
       |> assign(:status, {:info, "Touch your authenticator to sign in."})
       |> push_event("webauthn:login", %{
         challenge: issued.challenge,
         allowed_credentials: issued.allowed_credentials,
         rp_id: issued.rp_id
       })}
    else
      {:error, :rate_limited} ->
        {:noreply, assign(socket, :status, {:error, "Too many sign-in attempts. Try later."})}

      {:error, :unavailable} ->
        {:noreply,
         assign(
           socket,
           :status,
           {:error, "No tenant with that slug can sign in with an authenticator."}
         )}
    end
  end

  def handle_event("assertion_captured", params, %{assigns: %{pending: %{} = pending}} = socket) do
    case assertion(params) do
      {:ok, fields} ->
        {:noreply,
         socket
         |> assign(
           :assertion,
           Map.merge(fields, %{
             "tenant_id" => pending.tenant_id,
             "challenge_id" => pending.challenge_id
           })
         )
         |> assign(:pending, nil)
         |> assign(:trigger_submit, true)
         |> assign(:status, {:info, "Verifying…"})}

      :error ->
        {:noreply, fail(socket, "The authenticator returned an assertion loopctl cannot read.")}
    end
  end

  def handle_event("login_error", %{"reason" => reason}, socket) when is_binary(reason) do
    {:noreply, fail(socket, error_text(reason))}
  end

  # Terminal no-op: `/login` is public, so a crafted or out-of-order frame must not raise and
  # kill the channel (the shape `SignupLive` and `EnrollLive` keep).
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp budget(socket) do
    if Loopctl.RateLimiter.gate_ok?(
         "browser_login:challenge:" <> socket.assigns.rate_key,
         @rate_window_ms,
         @max_per_window
       ),
       do: :ok,
       else: {:error, :rate_limited}
  end

  defp assertion(params) do
    fields = Map.take(params, @assertion_fields)

    if map_size(fields) == length(@assertion_fields) and
         Enum.all?(fields, fn {_k, v} -> is_binary(v) and byte_size(v) <= @max_field_bytes end),
       do: {:ok, fields},
       else: :error
  end

  defp fail(socket, message) do
    socket |> assign(:pending, nil) |> assign(:status, {:error, message})
  end

  defp error_text("NotAllowedError"), do: "The sign-in was cancelled or timed out."
  defp error_text("webauthn_unsupported"), do: "This browser does not support WebAuthn."
  defp error_text(_reason), do: "The authenticator could not sign in."

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-md px-6 py-16" id="login-page">
      <header class="mb-8 flex items-center gap-3">
        <.icon name="hero-key" class="h-8 w-8 text-accent-500" />
        <div>
          <h1 class="font-display text-xl font-semibold text-slate-100">Sign in to loopctl</h1>
          <p class="mt-1 text-sm text-slate-400">
            With the authenticator you enrolled when the tenant was created.
          </p>
        </div>
      </header>

      <div
        :if={@signed_in}
        id="login-signed-in"
        class="space-y-4 rounded-md border border-slate-800 bg-slate-900/60 p-5"
      >
        <p class="text-sm text-slate-300">
          Signed in to tenant <span class="font-mono text-slate-100">{@signed_in.tenant_id}</span>. Open a thread from
          the link on its GitHub issue.
        </p>
        <.link
          href={~p"/logout"}
          method="delete"
          id="logout-link"
          class="inline-block font-mono text-xs uppercase tracking-wide text-accent-400 hover:text-accent-300"
        >
          Sign out
        </.link>
      </div>

      <div :if={!@signed_in} id="login-app" phx-hook="WebAuthnLogin" class="space-y-6">
        <.form
          for={@form}
          id="login-form"
          phx-submit="begin"
          class="space-y-4 rounded-md border border-slate-800 bg-slate-900/60 p-5"
        >
          <.input
            field={@form[:slug]}
            label="Tenant slug"
            placeholder="acme"
            autocomplete="username"
            required
          />
          <button
            type="submit"
            id="login-begin"
            class="w-full rounded-md bg-accent-700 px-4 py-2 text-sm font-medium text-slate-50 transition-colors hover:bg-accent-600"
          >
            Sign in with authenticator
          </button>
        </.form>

        <p
          :if={@status}
          id="login-status"
          class={[
            "font-mono text-sm",
            elem(@status, 0) == :error && "text-rose-400",
            elem(@status, 0) == :info && "text-slate-300"
          ]}
        >
          {elem(@status, 1)}
        </p>

        <.form
          for={to_form(@assertion, as: :login)}
          id="login-assertion-form"
          action={~p"/login"}
          method="post"
          phx-trigger-action={@trigger_submit}
          class="hidden"
        >
          <input
            :for={
              name <-
                ~w(tenant_id challenge_id credential_id authenticator_data signature client_data_json)
            }
            type="hidden"
            name={"login[#{name}]"}
            value={Map.get(@assertion, name)}
          />
        </.form>
      </div>
    </section>
    """
  end
end
