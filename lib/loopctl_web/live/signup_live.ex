defmodule LoopctlWeb.SignupLive do
  @moduledoc """
  US-26.0.1 — tenant signup LiveView with WebAuthn enrollment.

  Implements the ceremony described in `docs/chain-of-custody-v2.md`
  section 9:

  1. Operator fills out tenant metadata (name, slug, contact email).
  2. Server issues a WebAuthn registration challenge and pushes it to
     the browser via `phx-hook="WebAuthn"`.
  3. The hook calls `navigator.credentials.create()` and posts the
     raw attestation back as a `push_event`.
  4. Server verifies the attestation via `Loopctl.WebAuthn` and
     appends it to the in-memory list of enrolled authenticators.
  5. Operator repeats step 2-4 up to 5 times, then submits.
  6. Server calls `Loopctl.Tenants.signup/1` and redirects the
     operator to `/tenants/:id/onboarding`.

  The WebAuthn adapter is resolved via config-based DI (see
  `config/config.exs` and `config/test.exs`). Tests stub the
  `Loopctl.MockWebAuthn` behaviour so no real FIDO2 hardware is
  required.
  """

  use LoopctlWeb, :live_view

  require Logger

  alias Loopctl.Tenants
  alias Loopctl.WebAuthn

  @learn_more_url "https://loopctl.com/wiki/tenant-signup"

  @max_signups_per_ip 5
  @rate_window_ms 60_000 * 60

  @impl true
  def mount(_params, _session, socket) do
    ip = peer_ip(socket)

    case rate_limiter().check_rate("signup:#{ip}", @rate_window_ms, @max_signups_per_ip) do
      {:deny, _limit} ->
        {:ok,
         socket
         |> put_flash(:error, "Too many signup attempts. Please try again later.")
         |> push_navigate(to: ~p"/")}

      {:allow, _count} ->
        challenge = new_challenge()

        {:ok,
         socket
         |> assign(:page_title, "Sign up a new tenant")
         |> assign(:form, to_form(%{"name" => "", "slug" => "", "email" => ""}, as: :tenant))
         |> assign(:authenticators, [])
         |> assign(:max_authenticators, Tenants.max_authenticators_per_signup())
         |> assign(:challenge, challenge)
         |> assign(:challenge_payload, encode_challenge(challenge))
         |> assign(:learn_more_url, @learn_more_url)
         |> assign(:friendly_name_draft, "")
         |> assign(:error, nil)}
    end
  end

  defp peer_ip(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: addr} -> addr |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  defp rate_limiter do
    Application.get_env(:loopctl, :rate_limiter, Loopctl.RateLimiter.Hammer)
  end

  @impl true
  def handle_event("validate", %{"tenant" => params} = all, socket) do
    friendly = Map.get(all, "friendly_name", socket.assigns.friendly_name_draft)

    {:noreply,
     socket
     |> assign(:form, to_form(params, as: :tenant, errors: form_errors(params)))
     |> assign(:friendly_name_draft, friendly)
     |> clear_error()}
  end

  @impl true
  def handle_event("request_attestation", params, socket) do
    friendly_name =
      params
      |> case do
        nil -> %{}
        map when is_map(map) -> map
      end
      |> Map.get("friendly_name", socket.assigns.friendly_name_draft || "")
      |> to_string()
      |> String.trim()

    cond do
      length(socket.assigns.authenticators) >= socket.assigns.max_authenticators ->
        {:noreply, assign(socket, :error, "Maximum authenticators enrolled")}

      friendly_name == "" ->
        {:noreply, assign(socket, :error, "Please name this authenticator before enrolling")}

      true ->
        challenge = new_challenge()

        {:noreply,
         socket
         |> assign(:challenge, challenge)
         |> assign(:challenge_payload, encode_challenge(challenge))
         |> assign(:pending_friendly_name, friendly_name)
         |> clear_error()
         |> push_event("webauthn:challenge", %{
           challenge: encode_challenge(challenge),
           friendly_name: friendly_name,
           rp_id: Keyword.get(WebAuthn.rp_opts(), :rp_id, "loopctl.com")
         })}
    end
  end

  @impl true
  def handle_event("attestation_captured", params, socket) do
    attestation_object_b64 = Map.get(params, "attestation_object", "")
    client_data_b64 = Map.get(params, "client_data_json", "")
    credential_id_b64 = Map.get(params, "credential_id", "")

    with {:ok, attestation_object} <- decode_b64url(attestation_object_b64),
         {:ok, client_data_json} <- decode_b64url(client_data_b64),
         {:ok, credential_id} <- decode_b64url(credential_id_b64),
         {:ok, result} <-
           WebAuthn.verify_registration(
             %{
               attestation_object: attestation_object,
               client_data_json: client_data_json,
               credential_id: credential_id
             },
             socket.assigns.challenge,
             WebAuthn.rp_opts()
           ) do
      authenticators =
        socket.assigns.authenticators ++
          [
            %{
              attestation_result: result,
              friendly_name: Map.get(socket.assigns, :pending_friendly_name, "Authenticator")
            }
          ]

      {:noreply,
       socket
       |> assign(:authenticators, authenticators)
       |> assign(:pending_friendly_name, nil)
       |> clear_error()}
    else
      {:error, reason} ->
        Logger.info("WebAuthn attestation rejected: #{inspect(reason)}")

        {:noreply,
         assign(
           socket,
           :error,
           "Invalid attestation — please try again with a different authenticator"
         )}
    end
  end

  @impl true
  def handle_event("attestation_error", %{"reason" => reason}, socket) do
    message =
      case reason do
        "webauthn_unsupported" ->
          "This browser does not support WebAuthn — try Safari, Chrome, or Firefox"

        "no_credential" ->
          "The browser returned no credential — please try again"

        _ ->
          Logger.warning("WebAuthn ceremony failed with client reason: #{inspect(reason)}")
          "Authenticator ceremony failed. Please retry."
      end

    {:noreply, assign(socket, :error, message)}
  end

  @impl true
  def handle_event("remove_authenticator", %{"index" => index}, socket) do
    index = String.to_integer(index)

    new_auths = List.delete_at(socket.assigns.authenticators, index)
    {:noreply, assign(socket, :authenticators, new_auths)}
  end

  @impl true
  def handle_event("signup", %{"tenant" => params}, socket) do
    case socket.assigns.authenticators do
      [] ->
        {:noreply,
         assign(socket, :error, "Enroll at least one authenticator before completing signup")}

      auths ->
        attrs = Map.put(params, "authenticators", auths)

        case Tenants.signup(attrs) do
          {:ok, %{tenant: tenant}} ->
            token = Phoenix.Token.sign(LoopctlWeb.Endpoint, "onboarding", tenant.id)

            {:noreply,
             socket
             |> put_flash(:info, "Tenant signup complete — welcome to loopctl")
             |> push_navigate(to: ~p"/tenants/#{tenant.id}/onboarding?token=#{token}")}

          {:error, :slug_taken} ->
            {:noreply,
             assign(
               socket,
               :form,
               to_form(params, as: :tenant, errors: [slug: {"slug_taken", []}])
             )
             |> assign(:error, "That slug is already in use")}

          {:error, :email_taken} ->
            {:noreply,
             assign(
               socket,
               :form,
               to_form(params, as: :tenant, errors: [email: {"email_taken", []}])
             )
             |> assign(:error, "That email is already associated with a tenant")}

          {:error, :no_authenticators} ->
            {:noreply, assign(socket, :error, "Enroll at least one authenticator")}

          {:error, :too_many_authenticators} ->
            {:noreply,
             assign(
               socket,
               :error,
               "At most #{socket.assigns.max_authenticators} authenticators can be enrolled"
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:form, to_form(changeset, as: :tenant))
             |> assign(:error, "Please correct the highlighted fields")}
        end
    end
  end

  defp new_challenge do
    opts = WebAuthn.rp_opts()
    WebAuthn.new_registration_challenge(opts)
  end

  # Wax challenges hold binary bytes; we forward them as a base64url
  # string to the browser so the JS hook can feed them straight into
  # `navigator.credentials.create()`.
  defp encode_challenge(%{bytes: bytes}) when is_binary(bytes) do
    Base.url_encode64(bytes, padding: false)
  end

  defp encode_challenge(other) when is_binary(other), do: Base.url_encode64(other, padding: false)
  defp encode_challenge(_), do: ""

  defp decode_b64url(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        case Base.decode64(value, padding: false) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :invalid_base64}
        end
    end
  end

  defp decode_b64url(_), do: {:error, :invalid_payload}

  defp form_errors(params) do
    []
    |> maybe_blank_error(:name, params["name"])
    |> maybe_blank_error(:slug, params["slug"])
    |> maybe_blank_error(:email, params["email"])
  end

  defp maybe_blank_error(errors, field, value) do
    if String.trim(value || "") == "" do
      [{field, {"can't be blank", []}} | errors]
    else
      errors
    end
  end

  defp clear_error(socket), do: assign(socket, :error, nil)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-2xl px-6 py-16" id="signup-page">
      <header class="mb-10 flex items-center gap-4">
        <.icon name="hero-shield-check" class="h-10 w-10 text-accent-500" />
        <div>
          <h1 class="font-display text-2xl font-semibold text-slate-100">
            Create a new loopctl tenant
          </h1>
          <p class="mt-1 text-sm text-slate-400">
            Anchor this tenant with a hardware authenticator. Every destructive operation on this
            tenant for the rest of its lifetime will require a fresh touch from a device you enroll
            here.
          </p>
        </div>
      </header>

      <.form
        for={@form}
        id="signup-form"
        phx-change="validate"
        phx-submit="signup"
        class="space-y-8"
      >
        <div class="space-y-6 rounded-md border border-slate-800 bg-slate-900/60 p-6">
          <h2 class="font-display text-sm uppercase tracking-wide text-slate-400">
            Tenant metadata
          </h2>

          <.input
            field={@form[:name]}
            type="text"
            label="Display name"
            placeholder="Acme Robotics"
            required
            id="tenant-name-input"
          />

          <.input
            field={@form[:slug]}
            type="text"
            label="Slug"
            placeholder="acme-robotics"
            required
            id="tenant-slug-input"
          />

          <.input
            field={@form[:email]}
            type="email"
            label="Contact email"
            placeholder="admin@acme.example"
            required
            id="tenant-email-input"
          />
        </div>

        <div class="space-y-4 rounded-md border border-slate-800 bg-slate-900/60 p-6">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="font-display text-sm uppercase tracking-wide text-slate-400">
                Root authenticators
              </h2>
              <p class="mt-1 text-xs text-slate-500">
                Enroll at least one FIDO2 authenticator ({length(@authenticators)} of {@max_authenticators} used).
                YubiKeys, Touch ID, Windows Hello, and other platform keys all work.
              </p>
            </div>
            <.icon name="hero-key" class="h-10 w-10 text-accent-400" />
          </div>

          <ul id="enrolled-authenticators" class="space-y-2">
            <li
              :for={{auth, index} <- Enum.with_index(@authenticators)}
              id={"authenticator-#{index}"}
              class="flex items-center justify-between rounded-md border border-accent-500/40 bg-slate-950 px-4 py-3 text-sm"
            >
              <div class="flex items-center gap-3">
                <.icon name="hero-check-circle" class="h-5 w-5 text-accent-400" />
                <span class="font-mono text-xs uppercase tracking-wide text-slate-300">
                  {auth.friendly_name}
                </span>
                <span class="font-mono text-[10px] text-slate-600">
                  {auth.attestation_result.attestation_format}
                </span>
              </div>
              <button
                type="button"
                phx-click="remove_authenticator"
                phx-value-index={index}
                class="rounded-md px-2 py-1 text-xs text-slate-500 hover:text-rose-300"
              >
                <.icon name="hero-x-mark" class="h-4 w-4" />
              </button>
            </li>
          </ul>

          <div
            id="webauthn-hook"
            phx-hook="WebAuthn"
            phx-update="ignore"
            data-challenge={@challenge_payload}
            data-rp-id={Keyword.get(WebAuthn.rp_opts(), :rp_id, "loopctl.com")}
            data-rp-name="loopctl"
          >
          </div>

          <div class="flex flex-col gap-3 sm:flex-row" id="enrollment-controls">
            <input
              id="authenticator-friendly-name"
              type="text"
              name="friendly_name"
              form="signup-form"
              value={@friendly_name_draft}
              placeholder="Primary YubiKey"
              class="block flex-1 rounded-md border border-slate-800 bg-slate-900 px-3 py-2 font-mono text-sm text-slate-100 placeholder:text-slate-600 focus:border-accent-500 focus:outline-none focus:ring-1 focus:ring-accent-500"
            />
            <button
              id="enroll-authenticator-btn"
              type="button"
              phx-click="request_attestation"
              disabled={length(@authenticators) >= @max_authenticators}
              class="inline-flex items-center justify-center gap-2 rounded-md border border-accent-500 bg-accent-600/20 px-4 py-2 font-mono text-xs uppercase tracking-wide text-accent-100 hover:bg-accent-600/40 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <.icon name="hero-key" class="h-4 w-4" /> Enroll authenticator
            </button>
          </div>
        </div>

        <div
          :if={@error}
          id="signup-error"
          role="alert"
          class="rounded-md border border-rose-500/40 bg-rose-950/30 px-4 py-3 text-sm text-rose-200"
        >
          {@error}
        </div>

        <div class="flex items-center justify-between gap-4">
          <a
            href={@learn_more_url}
            class="font-mono text-xs uppercase tracking-wide text-slate-500 hover:text-accent-400"
            id="signup-learn-more"
          >
            learn more about the ceremony →
          </a>
          <button
            id="signup-submit-btn"
            type="submit"
            class="inline-flex items-center justify-center gap-2 rounded-md border border-accent-500 bg-accent-600 px-6 py-2 font-mono text-sm uppercase tracking-wide text-slate-50 hover:bg-accent-500 disabled:cursor-not-allowed disabled:opacity-50"
            disabled={@authenticators == []}
          >
            Complete signup
          </button>
        </div>
      </.form>
    </section>
    """
  end
end
