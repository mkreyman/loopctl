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

  # Cap friendly_name to prevent unbounded string allocation and echo DoS.
  # Matches the RootAuthenticator `validate_length(:friendly_name, max: 120)`
  # schema bound, so a valid name is never truncated. A real name is 10-50 bytes.
  @max_friendly_name_bytes 120

  # Cap attestation error reason before logging to prevent large-payload logging DoS.
  # A real error reason is well under this limit.
  @max_error_reason_bytes 500

  # Cap tenant metadata fields (name/slug/email) before they are echoed back or
  # persisted. Schema maxes are name 120 / slug 64; 512 is a safe upper bound.
  @max_tenant_field_bytes 512

  # SHARED per-connection budget that EVERY abusable handler (crypto, logging or
  # echoing attacker input) draws from, so no single handler is an unrated
  # amplifier. Generous vs a legit ceremony (~5 enrollments + a few retries +
  # submit). The tighter per-purpose caps (WebAuthn verify, signup submit) apply
  # on top for defense in depth.
  @max_actions_per_window 60

  # O(1) hard reject for the ONE unrated handler (validate, fires per keystroke).
  # A field larger than this is dropped as a no-op BEFORE any processing/echo, so
  # a flood of large validate frames can't pin the scheduler even if the
  # transport fragmented-message cap were ever misconfigured. Matches the frame
  # cap; legit form input is far smaller.
  @max_validate_field_bytes 64_000

  @doc """
  Builds the LiveView session for the `:public_signup` live_session (wired via
  the router's `session: {__MODULE__, :signup_session, []}` MFA).

  Runs in the HTTP pipeline (where `conn.remote_ip` is already resolved by the
  `LoopctlWeb.Plugs.ClientIp` plug and the request headers are present) and
  stashes the resolved client IP into the SIGNED session. The client cannot
  forge a signed session, so this is the trustworthy channel for the rate-limit
  key; it is read back identically on BOTH the disconnected and connected mount.

  Uses the shared `Loopctl.RemoteIp` resolver (single source of truth with the
  endpoint plug): resolves the forwarding headers first (preferring the
  unspoofable `fly-client-ip`), then falls back to the plug-resolved
  `conn.remote_ip`.
  """
  def signup_session(conn) do
    %{"client_ip" => Loopctl.RemoteIp.string_from(conn.req_headers) || peer_identity(conn)}
  end

  # The raw peer is a valid per-visitor identity ONLY when it is NOT one of our
  # configured proxies. A proxy peer (e.g. Fly's 6PN, when no forwarded header
  # resolved) would collapse every visitor onto one bucket, so we return nil and
  # let signup_rate_key/2 fall back to the per-connection bucket.
  defp peer_identity(conn) do
    if Loopctl.RemoteIp.proxy?(conn.remote_ip) do
      nil
    else
      Loopctl.RemoteIp.to_string_ip(conn.remote_ip)
    end
  end

  @impl true
  def mount(_params, session, socket) do
    # NB: we do NOT rate-limit page views here. Merely loading /signup must
    # never consume the bucket — the limit lives on the abusable `signup`
    # submission and the WebAuthn verification. The signed session carries the
    # HTTP-pipeline-resolved client IP (see signup_session/1); we only stash the
    # derived bucket key. Available on both the disconnected and connected mount.
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
     |> assign(:rate_key, signup_rate_key(session, socket))
     |> assign(:error, nil)}
  end

  # Per-IP bucket keyed on the signed-session client IP. If the session carries
  # no resolvable IP (should not happen behind Fly, but for safety / local /
  # direct connections) fall back to a PER-CONNECTION key — never a shared
  # bucket, which would re-create the platform-wide DoS.
  defp signup_rate_key(session, socket) do
    case session do
      %{"client_ip" => ip} when is_binary(ip) and ip != "" -> "signup:ip:#{ip}"
      _ -> "signup:session:#{socket.id}"
    end
  end

  # Shared per-connection action budget. Every abusable handler draws from this
  # single bucket so the TOTAL rate of expensive/logging/echoing events is
  # bounded (no single handler is an unrated amplifier).
  defp ensure_action_budget(socket) do
    bucket = "signup:actions:#{socket.assigns.rate_key}"

    case Loopctl.RateLimiter.impl().check_rate(bucket, @rate_window_ms, @max_actions_per_window) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, "Too many attempts. Please slow down and try again later."}
    end
  end

  # O(1) reject: is any validate field larger than the hard cap? `byte_size/1` is
  # O(1) on a binary, so this bounds validate's work regardless of input size.
  defp oversized_validate?(all, params) do
    field_oversized?(Map.get(all, "friendly_name")) or
      Enum.any?(["name", "slug", "email"], fn key ->
        field_oversized?(Map.get(params, key))
      end)
  end

  defp field_oversized?(value) when is_binary(value),
    do: byte_size(value) > @max_validate_field_bytes

  defp field_oversized?(_value), do: false

  # Size cap on a client-supplied string, applied uniformly before processing,
  # echoing, or logging. Non-binary values are treated as within-bounds (they
  # are normalized/dropped elsewhere).
  defp within_size?(value, max) when is_binary(value), do: byte_size(value) <= max
  defp within_size?(_value, _max), do: true

  defp ensure_tenant_field_sizes(params) do
    within? =
      ["name", "slug", "email"]
      |> Enum.all?(fn key -> within_size?(Map.get(params, key), @max_tenant_field_bytes) end)

    if within?, do: :ok, else: {:error, "Tenant details are too long"}
  end

  # Truncate every binary tenant field so an oversized value is never echoed
  # back into the re-rendered form.
  defp cap_tenant_params(params) when is_map(params) do
    Enum.reduce(["name", "slug", "email"], params, fn key, acc ->
      case Map.get(acc, key) do
        value when is_binary(value) ->
          Map.put(acc, key, truncate_to(value, @max_tenant_field_bytes))

        _ ->
          acc
      end
    end)
  end

  defp extract_friendly(params, socket) do
    params
    |> Map.get("friendly_name", socket.assigns.friendly_name_draft)
    |> cap_string()
    |> String.trim()
  end

  defp do_request_attestation(params, socket) do
    # extract_friendly/2 is binary-safe (cap_string returns "" for a non-binary
    # crafted friendly_name) and byte-capped, so a huge value can never be
    # processed/echoed and `to_string` can never crash.
    friendly_name = extract_friendly(params, socket)

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
  def handle_event("validate", %{"tenant" => params} = all, socket) when is_map(params) do
    # Form-change handler: not rate-limited (it fires per keystroke). Two bounds
    # keep it safe: (1) an O(1) byte-size reject drops any oversized field as a
    # no-op BEFORE processing; (2) every remaining field is byte-capped so a huge
    # value can never be echoed into the re-rendered form. `is_map(params)` guards
    # a crafted non-map "tenant"; anything else falls to the module catch-all.
    if oversized_validate?(all, params) do
      {:noreply, socket}
    else
      friendly = cap_string(Map.get(all, "friendly_name", socket.assigns.friendly_name_draft))
      params = cap_tenant_params(params)

      {:noreply,
       socket
       |> assign(:form, to_form(params, as: :tenant, errors: form_errors(params)))
       |> assign(:friendly_name_draft, friendly)
       |> clear_error()}
    end
  end

  @impl true
  def handle_event("request_attestation", %{} = params, socket) do
    # Draw the shared action budget FIRST — before extracting/truncating the
    # friendly_name — so a throttled call never pays the (bounded) parsing cost.
    case ensure_action_budget(socket) do
      {:error, _message} ->
        {:noreply,
         assign(
           socket,
           :error,
           "Too many authenticator enrollment requests. Please try again later."
         )}

      :ok ->
        do_request_attestation(params, socket)
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
    with :ok <- ensure_action_budget(socket),
         :ok <- ensure_enrollment_capacity(socket),
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
  def handle_event("attestation_error", %{"reason" => reason}, socket) do
    # A "reason" key is present (the browser hook reported a failure), so surface
    # a message. Draw the shared action budget so a burst of these can't flood
    # the logs / CPU, and NEVER inspect/log more than a capped slice of the
    # attacker-controlled reason. A non-binary reason (crafted frame) falls
    # through to the safe generic message rather than crashing.
    case ensure_action_budget(socket) do
      {:error, message} ->
        {:noreply, assign(socket, :error, message)}

      :ok ->
        {:noreply, assign(socket, :error, attestation_error_message(reason))}
    end
  end

  # Malformed attestation_error (missing/non-binary "reason") from a public
  # client is ignored rather than allowed to crash the LiveView process.
  def handle_event("attestation_error", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("remove_authenticator", %{"index" => index}, socket)
      when is_binary(index) and byte_size(index) <= 3 do
    # `byte_size(index) <= 3` (O(1)) is a hard pre-parse guard: a legit index is
    # 0..(max_authenticators-1), a single digit. Without it, Integer.parse ->
    # :erlang.binary_to_integer raises SystemLimitError on a ~2M-digit string
    # (crashing the process, uncaught by with/else) and burns O(n) CPU on a
    # ~1M-digit one. Then parse + bounds-check; any miss is a no-op.
    with {parsed, ""} <- Integer.parse(index),
         true <- parsed >= 0 and parsed < length(socket.assigns.authenticators) do
      new_auths = List.delete_at(socket.assigns.authenticators, parsed)
      {:noreply, assign(socket, :authenticators, new_auths)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Oversized index (> 3 bytes), non-binary index, missing "index", or a non-map
  # payload is a no-op — a non-map would otherwise crash `Map.get/3` before the
  # with/else could run, and an oversized index would crash Integer.parse.
  def handle_event("remove_authenticator", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("signup", %{"tenant" => params}, socket) when is_map(params) do
    # `is_map(params)` guards a crafted non-map "tenant"; anything else falls to
    # the module catch-all (no-op).
    case socket.assigns.authenticators do
      [] ->
        {:noreply,
         assign(socket, :error, "Enroll at least one authenticator before completing signup")}

      auths ->
        with :ok <- ensure_action_budget(socket),
             :ok <- ensure_tenant_field_sizes(params),
             {:allow, _count} <-
               Loopctl.RateLimiter.impl().check_rate(
                 socket.assigns.rate_key,
                 @rate_window_ms,
                 @max_signups_per_ip
               ) do
          complete_signup(params, auths, socket)
        else
          {:deny, _limit} ->
            {:noreply,
             assign(socket, :error, "Too many signup attempts. Please try again later.")}

          {:error, message} ->
            {:noreply, assign(socket, :error, message)}
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

    case Loopctl.RateLimiter.impl().check_rate(
           bucket,
           @rate_window_ms,
           @max_webauthn_verifications
         ) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, "Too many verification attempts. Please try again later."}
    end
  end

  defp attestation_error_message("webauthn_unsupported"),
    do: "This browser does not support WebAuthn — try Safari, Chrome, or Firefox"

  defp attestation_error_message("no_credential"),
    do: "The browser returned no credential — please try again"

  defp attestation_error_message(reason) do
    Logger.warning("WebAuthn ceremony failed with client reason: #{inspect(safe_reason(reason))}")
    "Authenticator ceremony failed. Please retry."
  end

  # Only ever expose a short, capped slice of the attacker-controlled reason to
  # the logs; anything non-binary or oversized is logged as a fixed placeholder.
  defp safe_reason(reason) when is_binary(reason),
    do: truncate_to(reason, @max_error_reason_bytes)

  defp safe_reason(_reason), do: "<non-binary or oversized payload>"

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

  defp maybe_blank_error(errors, field, value) when is_binary(value) do
    if String.trim(value) == "" do
      [{field, {"can't be blank", []}} | errors]
    else
      errors
    end
  end

  defp maybe_blank_error(errors, field, nil), do: [{field, {"can't be blank", []}} | errors]

  # A non-binary present value (crafted frame) is treated as present, never
  # trimmed — trimming a non-binary would crash the process.
  defp maybe_blank_error(errors, _field, _value), do: errors

  defp clear_error(socket), do: assign(socket, :error, nil)

  # Size-cap a friendly-name string for echo. Non-binary input becomes "".
  defp cap_string(value) when is_binary(value), do: truncate_to(value, @max_friendly_name_bytes)
  defp cap_string(_value), do: ""

  # BYTE-based truncation, O(max_bytes) — never grapheme-based (String.slice/
  # String.length/String.split_at walk the WHOLE input, and Unicode combining
  # marks ("Zalgo") collapse to one grapheme so a multi-MB string escapes a
  # grapheme cap entirely and burns O(input) CPU). We take the first `max_bytes`
  # bytes and snap back to the nearest valid UTF-8 boundary (≤ 3 bytes).
  # Callers always pass a binary (guarded by cap_string/1, safe_reason/1,
  # cap_tenant_params/1, or an explicit to_string/1).
  defp truncate_to(string, max_bytes) when is_binary(string) and byte_size(string) <= max_bytes,
    do: string

  defp truncate_to(string, max_bytes) when is_binary(string) do
    string |> :binary.part(0, max_bytes) |> snap_utf8()
  end

  # Drop up to 3 trailing bytes so the result is valid UTF-8 (a code point is
  # at most 4 bytes, so cutting mid-sequence leaves ≤ 3 dangling bytes).
  defp snap_utf8(bin) do
    Enum.find_value(0..3, "", fn n ->
      candidate = :binary.part(bin, 0, byte_size(bin) - n)
      if String.valid?(candidate), do: candidate
    end)
  end

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
