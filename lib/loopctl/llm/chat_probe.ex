defmodule Loopctl.Llm.ChatProbe do
  @moduledoc """
  Config-time probe + credential rule for the pluggable chat endpoint (US-41.3,
  AC-41.3.3). Mirrors US-41.2's embedding-endpoint rules verbatim.

  ## What it does, in order

  1. **Credential rule.** Changing the chat ENDPOINT while a key is STORED requires
     either a matching `chat_api_key` in the SAME PATCH, or an explicit
     `acknowledge_key_transmission: true` stating that the ALREADY-STORED key will
     be transmitted to the new host. Without one of those the write is REFUSED —
     the probe never ships an existing credential to a new host silently. A tenant
     with NO stored key may configure a KEYLESS endpoint (Ollama / llama.cpp /
     LM Studio / vLLM commonly serve `/chat/completions` with no auth at all); the
     probe then sends no authorization header rather than a fabricated placeholder.
  2. **Egress policy.** The probe consults `Loopctl.Egress.Policy` (via the single
     `Loopctl.Provider` chokepoint), NOT a private URL policy of its own. That is
     why this story depends on US-41.4 and lands after it: a second, divergent URL
     policy is an AC-41.4.9 review failure.
  3. **Trivial completion.** One 1-token completion PER DISTINCT RESOLVED MODEL is
     issued BEFORE anything is persisted, so a tenant cannot save a configuration
     that provably does not work and then discover it when a harvest silently stops
     producing articles. The models probed are exactly the ones
     `Loopctl.Llm.model_for/2` will hand to real extraction / classification /
     merge calls — probing some other model id (a hardcoded default, say) would
     validate a configuration that is not the one that runs.

  ## What counts as a change worth probing

  The chat-SURFACE configuration, not just the URL string: provider, base_url, a
  rotated `chat_api_key`, and any of the three per-operation models. A key rotation
  against the same host that skipped the probe would be discovered only when the
  next ingestion 401s — the exact failure class this probe exists to prevent — and
  an unprobed model change reintroduces the model-divergence hole above. A PATCH
  touching NONE of them probes nothing (AC-41.3.7).

  ## Failure shapes

  Each failure is distinguished and carries a `remediation` in the
  `Loopctl.Llm.Remediation` ACTION-REQUIRED shape:

    * `:endpoint_unreachable` — transport error / timeout.
    * `:auth_rejected` — 401/403: the key is wrong FOR THIS host.
    * `:not_openai_compatible` — 200 without a chat-completions envelope, or a
      non-2xx that is neither of the above.
    * `:egress_blocked` / `:pin_stale` / `:egress_unavailable` — the egress guard
      refused (including the SSRF denylist, since `chat_base_url` is tenant-
      writable); NO request was made and no data left the boundary.
    * `:acknowledgement_required` — the credential rule above.
    * `:model_required` — `openai_compatible` was selected with no model the
      endpoint could serve.
    * `:invalid_base_url` — the url is not a BARE absolute http(s) API base (see
      `Loopctl.Llm.ChatBaseUrl`, the single shape validator shared with the
      changeset: no query string, fragment or embedded credentials).
    * `:plaintext_endpoint` — plaintext `http` to a host the ONE egress policy does
      NOT classify `:network_local`. On this path the request carries the
      `chat_api_key` and the tenant's full document text, so cleartext is allowed
      only for a genuinely LAN/loopback endpoint.

  The URL is ECHOED in every message (it is the tenant's own declared host and
  naming it is the whole point); the KEY never is. The probe is bounded by a short
  receive timeout and rate-limited per tenant through the SAME
  `Loopctl.Provider.Admission` bucket the real calls use.
  """

  require Logger

  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Llm
  alias Loopctl.Llm.ChatBaseUrl
  alias Loopctl.Llm.OpenAiChat
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Llm.Remediation
  alias Loopctl.Llm.TenantLlmSettings
  alias Loopctl.Provider
  alias Loopctl.Provider.Admission

  # A probe must never hold a request slot for long — it runs inline in a PATCH.
  @probe_receive_timeout 8_000
  @probe_max_tokens 1

  # The chat operations whose resolved model must be verified before the write.
  @chat_operations [:extraction, :classification, :merge]

  # The fields of the PENDING row this preflight reconstructs from the PATCH. They
  # are exactly the inputs to `Loopctl.Llm.model_for/2` plus the endpoint itself.
  @pending_fields [
    :chat_provider,
    :chat_base_url,
    :extraction_model,
    :classification_model,
    :merge_model
  ]

  @typedoc "Why a chat-endpoint write was refused. A bounded, agent-readable set."
  @type refusal ::
          :invalid_base_url
          | :plaintext_endpoint
          | :model_required
          | :acknowledgement_required
          | :endpoint_unreachable
          | :auth_rejected
          | :not_openai_compatible
          | :rate_limited_local
          | :egress_blocked
          | :pin_stale
          | :egress_unavailable

  @typedoc "The refusal detail rendered as a 422 body."
  @type details :: %{code: String.t(), message: String.t(), remediation: map()}

  @doc """
  Validates + probes a pending chat-endpoint change, BEFORE anything is persisted.

  `attrs` is the normalized (string- or atom-keyed) PATCH body. Returns `:ok` when
  the write may proceed — including the very common case where the PATCH does not
  touch the chat endpoint at all, in which case NOTHING is probed and behaviour is
  byte-identical to before this story (AC-41.3.7).
  """
  @spec preflight(Ecto.UUID.t(), map()) :: :ok | {:error, refusal(), details()}
  def preflight(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    # UNCACHED read: this is a WRITE path, and BOTH decisions below are security
    # controls. `Llm.get_settings/1` is a node-local ETS read-through — on a
    # multi-node deploy that dropped a peer's invalidation broadcast, a stale
    # `chat_base_url` makes `host_change?/2` false and SKIPS the AC-41.3.3
    # acknowledgement rule (the stored key is then probed against what is in fact a
    # different host), and a stale `chat_api_key` probes the wrong credential.
    # `Llm.upsert_settings/2` already reads uncached on this same path for the
    # weaker reason that a stale struct must not seed the changeset.
    existing = Llm.load_settings(tenant_id)
    pending = pending_settings(existing, attrs)

    cond do
      # Nothing on the chat surface changed — nothing to probe.
      not chat_surface_change?(existing, pending, attrs) -> :ok
      # The tenant switched BACK to (or stayed on) Anthropic: the hardcoded
      # endpoint needs no probe and carries no tenant-supplied host.
      pending.chat_provider != "openai_compatible" -> :ok
      true -> probe_change(tenant_id, existing, pending, attrs)
    end
  end

  defp probe_change(tenant_id, existing, pending, attrs) do
    # Shape-validate the tenant-supplied URL BEFORE anything else. The changeset
    # validates it too, but the changeset runs AFTER this preflight — probing a
    # malformed url would hand garbage to the HTTP client (and produce a confusing
    # transport error instead of a legible validation message).
    with :ok <- validate_base_url(pending.chat_base_url),
         :ok <- validate_transport(tenant_id, pending.chat_base_url),
         {:ok, models} <- resolve_probe_models(pending),
         {:ok, key} <- resolve_probe_key(existing, attrs, host_change?(existing, pending)) do
      probe_models(tenant_id, pending.chat_base_url, key, models)
    end
  end

  # Probe EVERY distinct model a real call can resolve to, short-circuiting on the
  # first failure. Usually one request (all three operations share the tenant's
  # declared model); at most three.
  defp probe_models(tenant_id, base_url, key, models) do
    Enum.reduce_while(models, :ok, fn model, _acc ->
      case probe(tenant_id, base_url, key, model) do
        :ok -> {:cont, :ok}
        {:error, _tag, _details} = refusal -> {:halt, refusal}
      end
    end)
  end

  # The models the REAL calls will use, resolved through the single
  # `Loopctl.Llm.model_for/2` point against the PENDING (not yet persisted) row.
  defp resolve_probe_models(pending) do
    models =
      @chat_operations
      |> Enum.map(&Llm.model_for(pending, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case models do
      [] -> model_required()
      models -> {:ok, models}
    end
  end

  defp model_required do
    {:error, :model_required,
     detail(
       "chat_model_required",
       "Configuring an OpenAI-compatible chat endpoint requires a model this endpoint " <>
         "serves (extraction_model). The server default is an Anthropic model id, which " <>
         "an OpenAI-compatible endpoint cannot serve — so there is no safe fallback and " <>
         "the configuration was NOT saved.",
       ["extraction_model"]
     )}
  end

  # Shape, through the SINGLE `Loopctl.Llm.ChatBaseUrl` validator the changeset also
  # uses (no second copy of the URL rules).
  defp validate_base_url(url) do
    case ChatBaseUrl.normalize(url) do
      {:ok, _normalized} -> :ok
      {:error, reason} -> invalid_base_url(reason)
    end
  end

  defp invalid_base_url(reason) do
    {:error, :invalid_base_url,
     detail(
       "chat_base_url_invalid",
       "chat_base_url #{ChatBaseUrl.message(reason)}.",
       ["chat_base_url"]
     )}
  end

  # PLAINTEXT http is accepted ONLY for a host the ONE egress policy classifies
  # `:network_local` — i.e. a LAN/loopback box the OPERATOR deployment allowlist
  # carved out. That is the legitimate case (Ollama / llama.cpp / LM Studio / vLLM
  # on the deployment's own network) and it is the ONLY one: on this path
  # `Loopctl.Llm.OpenAiChat.do_post/8` sends `authorization: Bearer <key>` together
  # with the tenant's FULL document text, so `http://llm.example.com/v1` would ship
  # the credential AND the private corpus in cleartext across the internet — inside
  # the feature whose stated purpose is that the text never leaves the tenant's
  # chosen boundary.
  #
  # The locality decision is DELEGATED to `Loopctl.Egress.Policy` rather than
  # re-derived here; a second, divergent URL policy is an AC-41.4.9 review failure.
  # Fail-closed: an unclassifiable host does NOT get plaintext.
  defp validate_transport(tenant_id, url) do
    if ChatBaseUrl.plaintext?(url) do
      host = URI.parse(url).host

      case Policy.classify(EgressScope.new(tenant_id), host, :inference) do
        {:ok, %{verdict: :network_local}} ->
          :ok

        # A DENYLISTED host is refused a few lines later by the egress guard, with
        # the SSRF-specific message and remediation. Pre-empting that with the
        # weaker plaintext message would only make an SSRF attempt harder to read;
        # nothing gets through either way.
        {:ok, %{verdict: :denylisted}} ->
          :ok

        _other ->
          plaintext_refused(host)
      end
    else
      :ok
    end
  end

  defp plaintext_refused(host) do
    {:error, :plaintext_endpoint,
     detail(
       "chat_endpoint_plaintext_refused",
       "chat_base_url uses plaintext http and #{inspect(host)} is not classified as " <>
         "network-local, so the request would carry the chat_api_key AND the full " <>
         "document text in cleartext. Use https, or have the OPERATOR allowlist the " <>
         "host if it really is on the deployment's own network. The configuration was " <>
         "NOT saved.",
       ["chat_base_url"]
     )}
  end

  @doc """
  Issues ONE trivial completion against `base_url` with `api_key` + `model`.

  `api_key` may be `nil` for a keyless endpoint — no authorization header is sent.
  Public so the endpoint can be re-verified independently of a write.
  """
  @spec probe(Ecto.UUID.t(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, refusal(), details()}
  def probe(tenant_id, base_url, api_key, model)
      when is_binary(tenant_id) and is_binary(base_url) and is_binary(model) and
             (is_binary(api_key) or is_nil(api_key)) do
    url = OpenAiChat.completions_url(base_url)

    # Rate-limit the probe through the SAME node-local bucket the real calls use,
    # so a PATCH loop cannot be turned into an outbound request amplifier.
    case Admission.admit(tenant_id, :openai_compatible) do
      {:error, :rate_limited_local} ->
        {:error, :rate_limited_local,
         detail(
           "chat_endpoint_probe_rate_limited",
           "Too many endpoint probes for this tenant right now. Retry shortly; the " <>
             "configuration was NOT saved."
         )}

      :ok ->
        url
        |> issue_probe(tenant_id, api_key, model)
        |> classify(url)
    end
  end

  defp issue_probe(url, tenant_id, api_key, model) do
    opts = [
      json: %{
        model: model,
        max_tokens: @probe_max_tokens,
        messages: [%{role: "user", content: "ping"}]
      },
      headers: auth_headers(api_key),
      retry: false,
      receive_timeout: @probe_receive_timeout
    ]

    opts =
      case Application.get_env(:loopctl, :openai_chat_req_plug) do
        nil -> opts
        plug -> Keyword.put(opts, :plug, plug)
      end

    # THE single egress chokepoint — which is also the single egress POLICY module
    # (AC-41.4.9). The probe deliberately has no URL policy of its own.
    # `tenant_supplied_url: true` opts this call into the SSRF denylist on the
    # default (non-`local_only`) path: `chat_base_url` is tenant-writable, and the
    # probe's DISTINGUISHABLE outcomes (unreachable / auth-rejected /
    # not-OpenAI-compatible / saved) would otherwise be an internal host+port
    # scanning oracle for any role-`:user` key.
    Provider.post(url, opts, %{
      scope: EgressScope.new(tenant_id),
      purpose: :inference,
      tenant_supplied_url: true
    })
  end

  # A keyless endpoint sends NO authorization header (see the credential rule).
  defp auth_headers(api_key) when is_binary(api_key) and api_key != "",
    do: [{"authorization", "Bearer " <> api_key}]

  defp auth_headers(_keyless), do: []

  defp classify({:ok, %{status: 200, body: %{"choices" => _}}}, _url), do: :ok

  defp classify({:ok, %{status: 200, body: _body}}, url) do
    {:error, :not_openai_compatible,
     detail(
       "chat_endpoint_not_openai_compatible",
       "#{url} answered 200 but the body was not an OpenAI chat-completions " <>
         "response (no `choices`). Point chat_base_url at an OpenAI-compatible " <>
         "server's API base (the probe appends /chat/completions)."
     )}
  end

  defp classify({:ok, %{status: status}}, url) when status in [401, 403] do
    {:error, :auth_rejected,
     detail(
       "chat_endpoint_auth_rejected",
       "#{url} rejected the supplied credential (HTTP #{status}). Send a " <>
         "chat_api_key that is valid FOR THIS host. The configuration was NOT saved."
     )}
  end

  defp classify({:ok, %{status: status}}, url) do
    {:error, :not_openai_compatible,
     detail(
       "chat_endpoint_probe_failed",
       "#{url} answered HTTP #{status} to a trivial completion. The configuration " <>
         "was NOT saved."
     )}
  end

  defp classify({:error, {tag, _details}}, url)
       when tag in [:egress_blocked, :pin_stale, :egress_unavailable] do
    {:error, tag,
     %{
       code: to_string(tag),
       message:
         "The egress guard refused the probe to #{url}; NO request was made and no " <>
           "data left the boundary.",
       remediation: Remediation.for_fallback_reason(to_string(tag)) || %{}
     }}
  end

  defp classify({:error, reason}, url) do
    Logger.warning(
      "Loopctl.Llm.ChatProbe: probe transport failure " <>
        "(#{ProviderError.log_tag({:request_failed, reason})})"
    )

    {:error, :endpoint_unreachable,
     detail(
       "chat_endpoint_unreachable",
       "#{url} could not be reached (transport error or timeout). Check the host is " <>
         "running and reachable from loopctl. The configuration was NOT saved."
     )}
  end

  # --- credential rule (AC-41.3.3, verbatim from US-41.2 AC-41.2.3) ---

  defp resolve_probe_key(existing, attrs, host_change?) do
    supplied = present(fetch(attrs, :chat_api_key))
    acknowledged? = truthy?(fetch(attrs, :acknowledge_key_transmission))
    stored = present(existing && existing.chat_api_key)

    case decide_probe_key(supplied, acknowledged?, stored, host_change?) do
      {:ok, key} -> {:ok, key}
      {:refused, {tag, details}} -> {:error, tag, details}
    end
  end

  # The credential rule, one clause per case:
  #   a key in THIS request always wins; otherwise a stored key may be reused
  #   freely against the SAME host (the tenant already consented to that
  #   transmission) but demands an explicit acknowledgement to reach a NEW one;
  #   otherwise the endpoint is probed KEYLESS.
  defp decide_probe_key(supplied, _acknowledged?, _stored, _host_change?)
       when is_binary(supplied),
       do: {:ok, supplied}

  defp decide_probe_key(nil, _acknowledged?, stored, false) when is_binary(stored),
    do: {:ok, stored}

  defp decide_probe_key(nil, true, stored, true) when is_binary(stored), do: {:ok, stored}

  defp decide_probe_key(nil, _acknowledged?, stored, true) when is_binary(stored),
    do: {:refused, key_refusal(stored)}

  # No key supplied and none stored: a KEYLESS endpoint. Local OpenAI-compatible
  # servers (Ollama, llama.cpp, LM Studio, vLLM) commonly serve /chat/completions
  # with no auth, and forcing a placeholder would only mean shipping a meaningless
  # Bearer token to the tenant's host forever. The endpoint itself is the arbiter:
  # if it DOES want auth, the probe surfaces `chat_endpoint_auth_rejected` and
  # nothing is saved.
  defp decide_probe_key(nil, _acknowledged?, nil, _host_change?), do: {:ok, nil}

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_value), do: nil

  defp key_refusal(stored_key) when is_binary(stored_key) do
    {:acknowledgement_required,
     detail(
       "chat_key_acknowledgement_required",
       "Changing the chat endpoint requires a matching chat_api_key in the SAME " <>
         "request, or an explicit acknowledge_key_transmission: true stating that " <>
         "the ALREADY-STORED key will be transmitted to the new host. The probe " <>
         "never ships an existing credential to a new host silently.",
       ["chat_api_key"]
     )}
  end

  # --- pending-state helpers ---

  # The row the PATCH would produce, as a `TenantLlmSettings` STRUCT — so model
  # resolution runs through the same `Loopctl.Llm.model_for/2` the real calls use
  # instead of a second, divergent copy of the fallback rules.
  defp pending_settings(existing, attrs) do
    base = existing || %TenantLlmSettings{}

    Enum.reduce(@pending_fields, base, fn field, acc ->
      case fetch(attrs, field) do
        nil -> acc
        value -> Map.put(acc, field, pending_value(field, value))
      end
    end)
    |> then(fn pending -> %{pending | chat_provider: pending.chat_provider || "anthropic"} end)
  end

  # The RAW PATCH value for `chat_base_url` is normalized with the SAME rules the
  # changeset applies on write (trim + strip the trailing `/`) BEFORE any comparison
  # against the stored row. Without this, re-sending the identical endpoint with a
  # trailing slash — exactly what an agent replaying `set_llm_config` does — read as
  # a HOST CHANGE and a no-op PATCH was refused 422
  # `chat_key_acknowledgement_required` unless the caller re-sent the key.
  defp pending_value(:chat_base_url, value), do: ChatBaseUrl.normalize_for_compare(value)
  defp pending_value(_field, value), do: value

  # A chat-surface change is ANY of: provider, base_url, a rotated key, or one of
  # the three per-operation models. Comparing only (provider, base_url) let a key
  # rotation and every model change be persisted UNVERIFIED.
  defp chat_surface_change?(existing, pending, attrs) do
    current = existing || %TenantLlmSettings{}

    provider_changed? = (current.chat_provider || "anthropic") != pending.chat_provider
    key_rotated? = present(fetch(attrs, :chat_api_key)) != nil

    fields_changed? =
      Enum.any?(@pending_fields -- [:chat_provider], fn field ->
        Map.get(pending, field) != Map.get(current, field)
      end)

    provider_changed? or key_rotated? or fields_changed?
  end

  # The narrower question the CREDENTIAL rule asks: is the stored key about to be
  # transmitted to a host it has never been sent to? Only a provider/base_url move
  # is a new host — a model change or a same-host re-probe is not, and demanding an
  # acknowledgement for those would make every model tweak a two-step ceremony for
  # no privacy gain.
  defp host_change?(existing, pending) do
    current = existing || %TenantLlmSettings{}

    (current.chat_provider || "anthropic") != pending.chat_provider or
      current.chat_base_url != pending.chat_base_url
  end

  defp detail(code, message, missing \\ []) do
    %{
      code: code,
      message: message,
      remediation: Remediation.for_credential(:chat, missing)
    }
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_other), do: false

  @doc false
  @spec chat_providers() :: [String.t()]
  def chat_providers, do: TenantLlmSettings.chat_providers()
end
