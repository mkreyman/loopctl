defmodule Loopctl.Llm.ChatProbe do
  @moduledoc """
  Config-time probe + credential rule for the pluggable chat endpoint (US-41.3,
  AC-41.3.3). Mirrors US-41.2's embedding-endpoint rules verbatim.

  ## What it does, in order

  1. **Credential rule.** Changing the chat ENDPOINT requires either a matching
     `chat_api_key` in the SAME PATCH, or an explicit
     `acknowledge_key_transmission: true` stating that the ALREADY-STORED key will
     be transmitted to the new host. Without one of those the write is REFUSED —
     the probe never ships an existing credential to a new host silently.
  2. **Egress policy.** The probe consults `Loopctl.Egress.Policy` (via the single
     `Loopctl.Provider` chokepoint), NOT a private URL policy of its own. That is
     why this story depends on US-41.4 and lands after it: a second, divergent URL
     policy is an AC-41.4.9 review failure.
  3. **Trivial completion.** One 1-token completion is issued BEFORE anything is
     persisted, so a tenant cannot save a configuration that provably does not
     work and then discover it when a harvest silently stops producing articles.

  ## Failure shapes

  Each failure is distinguished and carries a `remediation` in the
  `Loopctl.Llm.Remediation` ACTION-REQUIRED shape:

    * `:endpoint_unreachable` — transport error / timeout.
    * `:auth_rejected` — 401/403: the key is wrong FOR THIS host.
    * `:not_openai_compatible` — 200 without a chat-completions envelope, or a
      non-2xx that is neither of the above.
    * `:egress_blocked` / `:pin_stale` / `:egress_unavailable` — the egress guard
      refused; NO request was made and no data left the boundary.
    * `:key_required` / `:acknowledgement_required` — the credential rule above.

  The URL is ECHOED in every message (it is the tenant's own declared host and
  naming it is the whole point); the KEY never is. The probe is bounded by a short
  receive timeout and rate-limited per tenant through the SAME
  `Loopctl.Provider.Admission` bucket the real calls use.
  """

  require Logger

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Llm
  alias Loopctl.Llm.OpenAiChat
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Llm.Remediation
  alias Loopctl.Llm.TenantLlmSettings
  alias Loopctl.Provider
  alias Loopctl.Provider.Admission

  # A probe must never hold a request slot for long — it runs inline in a PATCH.
  @probe_receive_timeout 8_000
  @probe_max_tokens 1

  @typedoc "Why a chat-endpoint write was refused. A bounded, agent-readable set."
  @type refusal ::
          :invalid_base_url
          | :key_required
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
    existing = Llm.get_settings(tenant_id)
    pending = pending_endpoint(existing, attrs)

    cond do
      # Not an endpoint change at all — nothing to probe.
      not endpoint_change?(existing, pending) -> :ok
      # The tenant switched BACK to (or stayed on) Anthropic: the hardcoded
      # endpoint needs no probe and carries no tenant-supplied host.
      pending.provider != "openai_compatible" -> :ok
      true -> probe_change(tenant_id, existing, pending, attrs)
    end
  end

  defp probe_change(tenant_id, existing, pending, attrs) do
    # Shape-validate the tenant-supplied URL BEFORE anything else. The changeset
    # validates it too, but the changeset runs AFTER this preflight — probing a
    # malformed url would hand garbage to the HTTP client (and produce a confusing
    # transport error instead of a legible validation message).
    with :ok <- validate_base_url(pending.base_url),
         {:ok, key} <- resolve_probe_key(existing, pending, attrs) do
      probe(tenant_id, pending.base_url, key, pending.model)
    end
  end

  defp validate_base_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      invalid_base_url()
    end
  end

  defp validate_base_url(_url), do: invalid_base_url()

  defp invalid_base_url do
    {:error, :invalid_base_url,
     detail(
       "chat_base_url_invalid",
       "chat_base_url must be an absolute http(s) URL naming the API base of an " <>
         "OpenAI-compatible server (the client appends /chat/completions).",
       ["chat_base_url"]
     )}
  end

  @doc """
  Issues ONE trivial completion against `base_url` with `api_key` + `model`.

  Public so the endpoint can be re-verified independently of a write.
  """
  @spec probe(Ecto.UUID.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, refusal(), details()}
  def probe(tenant_id, base_url, api_key, model)
      when is_binary(tenant_id) and is_binary(base_url) and is_binary(api_key) and
             is_binary(model) do
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
      headers: [{"authorization", "Bearer " <> api_key}],
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
    Provider.post(url, opts, %{
      scope: EgressScope.new(tenant_id),
      purpose: :inference
    })
  end

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

  defp resolve_probe_key(existing, _pending, attrs) do
    supplied = present(fetch(attrs, :chat_api_key))
    acknowledged? = truthy?(fetch(attrs, :acknowledge_key_transmission))
    stored = present(existing && existing.chat_api_key)

    case decide_probe_key(supplied, acknowledged?, stored) do
      {:ok, key} -> {:ok, key}
      {:refused, {tag, details}} -> {:error, tag, details}
    end
  end

  # The credential rule as a three-way decision, one clause per case:
  #   a key in THIS request always wins; otherwise reuse of the stored key demands
  #   an explicit acknowledgement; otherwise refuse.
  defp decide_probe_key(supplied, _acknowledged?, _stored) when is_binary(supplied),
    do: {:ok, supplied}

  defp decide_probe_key(nil, true, stored) when is_binary(stored), do: {:ok, stored}
  defp decide_probe_key(nil, _acknowledged?, stored), do: {:refused, key_refusal(stored)}

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

  defp key_refusal(_no_stored_key) do
    {:key_required,
     detail(
       "chat_key_required",
       "Configuring an OpenAI-compatible chat endpoint requires a chat_api_key in " <>
         "the same request (there is no stored key for this tenant to reuse).",
       ["chat_api_key"]
     )}
  end

  # --- pending-state helpers ---

  defp pending_endpoint(existing, attrs) do
    %{
      provider:
        fetch(attrs, :chat_provider) || (existing && existing.chat_provider) || "anthropic",
      base_url: fetch(attrs, :chat_base_url) || (existing && existing.chat_base_url),
      model:
        fetch(attrs, :extraction_model) || (existing && existing.extraction_model) ||
          probe_model()
    }
  end

  defp endpoint_change?(existing, pending) do
    current_provider = (existing && existing.chat_provider) || "anthropic"
    current_url = existing && existing.chat_base_url

    pending.provider != current_provider or pending.base_url != current_url
  end

  # The model the probe exercises when the tenant left extraction_model nil. The
  # server default is an Anthropic model id, which a local server would reject, so
  # a tenant configuring a local endpoint is expected to set a model too — this
  # fallback keeps the probe well-formed rather than crashing on nil.
  defp probe_model, do: "gpt-4o-mini"

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
