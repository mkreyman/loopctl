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

  # WebAuthn attestation verification is CPU-bound (CBOR decode + COSE parse +
  # signature verify). Cap the number of verify attempts per client per window
  # so a single pre-auth websocket cannot pin the scheduler, independently of
  # the final signup-submission limit. Comfortably above a legit ceremony
  # (up to 5 authenticators + a few retries).
  @max_webauthn_verifications 20

  # Reject attestation fields larger than this BEFORE base64-decoding them, to
  # bound the per-call CBOR-decode cost. A real FIDO2 attestation object is well
  # under 8 KB.
  @max_attestation_field_bytes 8 * 1024

  @impl true
  def mount(_params, _session, socket) do
    # NB: we do NOT rate-limit page views here. Merely loading /signup must
    # never consume the bucket — the limit lives on the abusable `signup`
    # submission (tenant creation). We only resolve + stash the per-IP rate
    # key at mount, when the connect_info (peer + forwarded headers) is
    # available on the connected socket.
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
     |> assign(:rate_key, signup_rate_key(socket))
     |> assign(:error, nil)}
  end

  # Builds the rate-limit bucket key for the abusable signup actions. Keyed on
  # the true client IP so one abuser can only exhaust their own bucket. When the
  # client cannot be trusted (behind a proxy but no genuine trusted-proxy hop,
  # RFC 7239 `Forwarded` not captured by `:x_headers`, or an empty chain), we
  # fall back to a PER-CONNECTION key — never the shared proxy peer, which would
  # collapse every visitor into one bucket and re-create the platform-wide DoS.
  defp signup_rate_key(socket) do
    case client_ip(socket) do
      {:ok, ip} -> "signup:ip:#{ip}"
      :unknown -> "signup:session:#{socket.id}"
    end
  end

  # Resolves the real client IP with an explicit trust boundary:
  #
  #   1. If the forwarded chain demonstrably traversed a trusted proxy (a hop
  #      RemoteIp peels off the right using the shared `:remote_ip_opts`
  #      allow-list), trust the originating client it returns.
  #   2. Otherwise, if the raw peer is a genuine PUBLIC address (a direct,
  #      non-proxied connection — local dev / tests), the unforgeable TCP peer
  #      IS the client; any client-supplied forwarding header is ignored.
  #   3. Otherwise (behind a proxy with no trustworthy forwarded client, or no
  #      peer at all) → `:unknown`, so the caller uses a per-connection bucket.
  defp client_ip(socket) do
    case forwarded_client(forwarded_headers(socket)) do
      {:ok, ip} ->
        {:ok, ip}

      :untrusted ->
        peer = peer_address(socket)

        if is_tuple(peer) and not proxy_peer?(peer) do
          {:ok, ntoa(peer)}
        else
          :unknown
        end
    end
  end

  # Trust a forwarded client ONLY when the chain contains a recognizable
  # trusted-proxy/reserved hop that RemoteIp peels off the right. If the whole
  # chain is a single client-controlled value with no proxy hop behind it
  # (`client == rightmost`), or nothing usable is present, it is UNTRUSTED — an
  # attacker cannot mint fresh per-IP buckets by forging `x-forwarded-for`.
  defp forwarded_client([]), do: :untrusted

  defp forwarded_client(headers) do
    opts = remote_ip_opts()
    client = RemoteIp.from(headers, opts)
    # With every IP forced to :client, RemoteIp returns the raw rightmost hop.
    rightmost = RemoteIp.from(headers, Keyword.merge(opts, clients: ["0.0.0.0/0", "::/0"]))

    cond do
      is_nil(client) -> :untrusted
      client == rightmost -> :untrusted
      true -> {:ok, ntoa(client)}
    end
  end

  defp forwarded_headers(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :x_headers) do
      headers when is_list(headers) -> headers
      _ -> []
    end
  end

  defp peer_address(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: addr} -> addr
      _ -> nil
    end
  end

  # True when `addr` is a reverse-proxy / reserved address (loopback, RFC1918
  # private, or `fc00::/7` unique-local — which covers Fly's `fdaa::/16` 6PN).
  # Such a peer means the request arrived via a proxy, so the peer is NOT the
  # client and must never be used as a bucket key.
  defp proxy_peer?({127, _, _, _}), do: true
  defp proxy_peer?({10, _, _, _}), do: true
  defp proxy_peer?({172, b, _, _}) when b in 16..31, do: true
  defp proxy_peer?({192, 168, _, _}), do: true
  defp proxy_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp proxy_peer?({g, _, _, _, _, _, _, _}) when g >= 0xFC00 and g <= 0xFDFF, do: true
  defp proxy_peer?(_), do: false

  defp ntoa(addr), do: addr |> :inet.ntoa() |> to_string()

  defp remote_ip_opts, do: Application.get_env(:loopctl, :remote_ip_opts, [])

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
  def handle_event("request_attestation", %{} = params, socket) do
    friendly_name =
      params
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

  # Malformed request_attestation (non-map payload) is ignored, not crashed.
  def handle_event("request_attestation", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("attestation_captured", %{} = params, socket) do
    # SERVER-SIDE enforcement, in this handler, before any crypto runs — the
    # client-side max/name gate in request_attestation can be skipped by sending
    # attestation_captured straight over the websocket. Order matters: capacity
    # and size checks reject WITHOUT consuming the verification budget; only a
    # genuine attempt draws down the per-window rate limit.
    with :ok <- ensure_enrollment_capacity(socket),
         :ok <- ensure_attestation_size(params),
         :ok <- ensure_verification_budget(socket) do
      verify_attestation(params, socket)
    else
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  # Malformed attestation_captured (non-map payload) is ignored, not crashed.
  def handle_event("attestation_captured", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("attestation_error", %{"reason" => reason}, socket) when is_binary(reason) do
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

  # Malformed attestation_error (missing/non-binary "reason") from a public
  # client is ignored rather than allowed to crash the LiveView process.
  def handle_event("attestation_error", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("remove_authenticator", %{"index" => index}, socket) when is_binary(index) do
    # Never trust the client-supplied index: parse it defensively and
    # bounds-check against the current list. A non-parseable or out-of-range
    # index is a no-op instead of crashing the public LiveView process.
    with {parsed, ""} <- Integer.parse(index),
         true <- parsed >= 0 and parsed < length(socket.assigns.authenticators) do
      new_auths = List.delete_at(socket.assigns.authenticators, parsed)
      {:noreply, assign(socket, :authenticators, new_auths)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Missing "index", non-binary index, or a non-map payload is a no-op — a
  # non-map would otherwise crash `Map.get/3` before the with/else could run.
  def handle_event("remove_authenticator", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("signup", %{"tenant" => params}, socket) do
    case socket.assigns.authenticators do
      [] ->
        {:noreply,
         assign(socket, :error, "Enroll at least one authenticator before completing signup")}

      auths ->
        case rate_limiter().check_rate(
               socket.assigns.rate_key,
               @rate_window_ms,
               @max_signups_per_ip
             ) do
          {:allow, _count} ->
            complete_signup(params, auths, socket)

          {:deny, _limit} ->
            {:noreply,
             assign(socket, :error, "Too many signup attempts. Please try again later.")}
        end
    end
  end

  # Catch-all for malformed / unknown client events on this public LiveView.
  # Must be the LAST handle_event clause. Ignoring them keeps an attacker from
  # crashing the process (and spamming the logs) with junk websocket frames.
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp ensure_enrollment_capacity(socket) do
    if length(socket.assigns.authenticators) >= socket.assigns.max_authenticators do
      {:error, "Maximum authenticators enrolled"}
    else
      :ok
    end
  end

  defp ensure_attestation_size(params) do
    within? =
      ["attestation_object", "client_data_json", "credential_id"]
      |> Enum.all?(fn key -> field_within_size?(Map.get(params, key, "")) end)

    if within?, do: :ok, else: {:error, "Attestation payload too large"}
  end

  defp field_within_size?(value) when is_binary(value),
    do: byte_size(value) <= @max_attestation_field_bytes

  defp field_within_size?(_), do: true

  defp ensure_verification_budget(socket) do
    bucket = "signup:webauthn:#{socket.assigns.rate_key}"

    case rate_limiter().check_rate(bucket, @rate_window_ms, @max_webauthn_verifications) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, "Too many verification attempts. Please try again later."}
    end
  end

  defp verify_attestation(params, socket) do
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

  defp complete_signup(params, auths, socket) do
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
