defmodule Loopctl.Llm.OpenAiChat do
  @moduledoc """
  OpenAI-compatible `/chat/completions` client — the SIBLING of
  `Loopctl.Llm.Anthropic` (US-41.3, AC-41.3.1).

  Same return contract, same `Loopctl.Llm.ProviderError` mapping, same
  `Loopctl.Provider.Admission` gate, same `Loopctl.Provider` egress chokepoint, so
  every caller is unchanged. The ONLY differences are the wire protocol and where
  the endpoint comes from:

    * `base_url` + `api_key` + `model` are resolved PER TENANT from
      `tenant_llm_settings` (`chat_base_url` / `chat_api_key`), not from a
      hardcoded constant. A tenant that configures nothing never reaches this
      module at all (AC-41.3.7).
    * Anthropic's Messages API takes the system prompt as a TOP-LEVEL `system`
      field; OpenAI chat-completions takes it as the first `role: "system"`
      message. That difference lives HERE (`to_chat_completions/2`) rather than in
      the five behaviour impls, so the `body_fun` contract stays byte-identical
      across providers and a caller can be routed either way without knowing.

  ## Credential isolation

  `chat_api_key` is a SEPARATE encrypted column from the Anthropic `api_key`.
  `message/5` REFUSES (`{:error, :provider_mismatch}`) if the tenant did not
  actually resolve to `:openai_compatible`, so a routing bug can never ship the
  Anthropic key to a tenant-supplied host. `call/8`'s credentials are supplied by
  the caller, and its only in-repo caller resolves the provider BEFORE the
  credentials for the same reason.

  ## Admission (AC-41.3.5)

  Every call passes `Admission.admit(tenant_id, :openai_compatible)` before the
  request is built. The atom is a member of the FIXED `@providers` list and has a
  real `limit_for/1` clause — without the clause the gate would fail OPEN and this
  would be the one provider with no ceiling, right next to the egress guard.

  ## Usage (AC-41.3.6)

  A local endpoint frequently reports NO `usage` object. That is represented
  explicitly: a usage row is STILL written, with `provider: "openai_compatible"`,
  the configured model and ZERO tokens. A zero-cost provider is fine; a silently
  absent row is not.

  ## Testing

  HTTP is injectable via the `:openai_chat_req_plug` config (a `Req.Test` plug),
  mirroring `:anthropic_req_plug`. The API key is NEVER logged.
  """

  require Logger

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Llm.ShapeError
  alias Loopctl.Provider
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter

  # Conservative defaults; every real caller overrides them with a budget that
  # fits its outer Oban timeout (mirrors `Loopctl.Llm.Anthropic`).
  @default_receive_timeout 25_000
  @default_max_retries 0

  @provider_tag "openai_compatible"

  @type usage_meta :: %{
          optional(:source_type) => String.t() | nil,
          optional(:article_id) => Ecto.UUID.t() | nil
        }

  @doc """
  The chat-completions URL for a resolved `base_url`.

  The SINGLE place the path is appended. `Loopctl.Llm.chat_base_url/1` is the
  single source of the BASE; combining them here keeps the endpoint the egress
  guard vets and the endpoint this client posts to identical (AC-41.4.9).
  """
  @spec completions_url(String.t()) :: String.t()
  def completions_url(base_url) when is_binary(base_url),
    do: String.trim_trailing(base_url, "/") <> "/chat/completions"

  @doc """
  Resolve the tenant's OpenAI-compatible endpoint + key + model for `operation`,
  then POST via `call/8`.

  Returns the SAME union as `Loopctl.Llm.Anthropic.message/5`, plus:

    * `{:error, :provider_mismatch}` — the tenant is NOT configured for the
      OpenAI-compatible provider. Reaching this is a routing bug, and refusing is
      how the Anthropic credential is prevented from leaving for another host.
    * `{:error, ShapeError.t()}` — the endpoint answered 200 but not in the
      OpenAI chat-completions shape, i.e. it is not actually OpenAI-compatible
      (AC-41.3.4).
  """
  @spec message(
          EgressScope.t() | Ecto.UUID.t(),
          Llm.operation(),
          (String.t() -> map()),
          usage_meta(),
          keyword()
        ) ::
          {:ok, String.t()}
          | {:error, :no_api_key}
          | {:error, :provider_mismatch}
          | {:error, :rate_limited_local}
          | {:error, ShapeError.t()}
          | {:error, ProviderError.t()}
  def message(scope_or_tenant_id, operation, body_fun, usage_meta \\ %{}, req_opts \\ [])
      when is_function(body_fun, 1) do
    scope = EgressScope.coerce(scope_or_tenant_id)

    with {:ok, target} <- resolve_target(scope.tenant_id, operation) do
      call(
        scope,
        operation,
        target.base_url,
        target.api_key,
        target.model,
        body_fun,
        usage_meta,
        req_opts
      )
    end
  end

  @typedoc "A resolved OpenAI-compatible call target (endpoint is the FULL url)."
  @type target :: %{
          base_url: String.t(),
          api_key: String.t(),
          model: String.t(),
          endpoint: String.t()
        }

  @doc """
  Resolve the tenant's OpenAI-compatible endpoint + credential + model, or refuse.

  The sibling behaviour impls call this ONCE so they can name the `endpoint` and
  `model` in an AC-41.3.4 shape-validation error without a second resolve. The
  PROVIDER decision is made here, before any credential is read — resolving the
  credential first is the cross-provider leak vector.
  """
  @spec resolve_target(Ecto.UUID.t(), Llm.operation()) ::
          {:ok, target()} | {:error, :no_api_key} | {:error, :provider_mismatch}
  def resolve_target(tenant_id, operation) when is_binary(tenant_id) do
    case Llm.resolve(tenant_id, operation) do
      {:ok, %{provider: :openai_compatible, api_key: key, model: model, base_url: base_url}} ->
        {:ok,
         %{
           base_url: base_url,
           api_key: key,
           model: model,
           endpoint: completions_url(base_url)
         }}

      # The tenant resolved to a DIFFERENT provider. Never fall back to that
      # provider's credentials here — refuse.
      {:ok, %{}} ->
        {:error, :provider_mismatch}

      {:error, :no_api_key} ->
        {:error, :no_api_key}
    end
  end

  @doc """
  Like `message/5` but with an EXPLICIT pre-resolved `base_url` + `api_key` +
  `model` — skips the per-call `Loopctl.Llm.resolve/2` DB read for batch callers
  that resolve once.

  The caller is responsible for having resolved the tenant's OWN
  OpenAI-compatible credentials; passing an Anthropic key here would be exactly
  the cross-provider leak AC-41.3.3 forbids.
  """
  @spec call(
          EgressScope.t() | Ecto.UUID.t(),
          Llm.operation(),
          String.t(),
          String.t(),
          String.t(),
          (String.t() -> map()),
          usage_meta(),
          keyword()
        ) ::
          {:ok, String.t()}
          | {:error, :rate_limited_local}
          | {:error, ShapeError.t()}
          | {:error, ProviderError.t()}
  def call(
        scope_or_tenant_id,
        operation,
        base_url,
        api_key,
        model,
        body_fun,
        usage_meta \\ %{},
        req_opts \\ []
      )
      when is_binary(base_url) and is_binary(api_key) and is_binary(model) and
             is_function(body_fun, 1) do
    body = model |> body_fun.() |> to_chat_completions(model)

    post(
      EgressScope.coerce(scope_or_tenant_id),
      operation,
      base_url,
      model,
      body,
      usage_meta,
      api_key,
      req_opts
    )
  end

  # US-37.1 parity: the node-local admission gate short-circuits BEFORE the request
  # is built and BEFORE any `record_provider_error/1`, so a local rate-limit never
  # inflates the provider-error storm signal.
  defp post(
         %EgressScope{tenant_id: tenant_id} = scope,
         op,
         base_url,
         model,
         body,
         meta,
         key,
         opts
       ) do
    with :ok <- Admission.admit(tenant_id, :openai_compatible) do
      do_post(scope, op, base_url, model, body, meta, key, opts)
    end
  end

  defp do_post(
         %EgressScope{tenant_id: tenant_id} = scope,
         operation,
         base_url,
         model,
         body,
         usage_meta,
         api_key,
         req_opts
       ) do
    opts =
      [
        json: body,
        headers: [{"authorization", "Bearer " <> api_key}],
        retry: :transient,
        max_retries: @default_max_retries,
        receive_timeout: @default_receive_timeout
      ]
      |> Keyword.merge(req_opts)
      |> maybe_put_plug()

    url = completions_url(base_url)

    # NOTE: never log `opts` / `api_key` — the key is a tenant secret. Routed
    # through the SINGLE egress chokepoint (`Loopctl.Provider`), which refuses a
    # `local_only` scope on a non-local endpoint BEFORE the request is built.
    case Provider.post(url, opts, %{scope: scope, purpose: :inference}) do
      {:ok,
       %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]} = resp}}
      when is_binary(text) ->
        record_usage_safe(tenant_id, operation, model, resp["usage"], usage_meta)
        {:ok, text}

      {:ok, %{status: 200, body: %{"choices" => _}}} ->
        # 200, OpenAI-ish envelope, but no text content: a refusal / non-text
        # content block / empty choice list. AC-41.3.4: a legible CONFIGURATION
        # error naming the endpoint + model, never a silently-degraded empty result.
        Logger.warning(
          "Loopctl.Llm.OpenAiChat: 200 with no text content (op=#{operation}, endpoint=#{url})"
        )

        {:error,
         ShapeError.new(url, model, :non_text_content, "expected choices[0].message.content")}

      {:ok, %{status: 200, body: _body}} ->
        # 200 without a `choices` envelope at all: the endpoint is not actually
        # OpenAI-compatible. Deliberately NOT `record_provider_error/1` (a 200 is a
        # provider SUCCESS — see the same reasoning in `Loopctl.Llm.Anthropic`), and
        # deliberately NOT the raw body (which can echo a masked key fragment).
        Logger.warning(
          "Loopctl.Llm.OpenAiChat: 200 with unexpected shape (op=#{operation}, endpoint=#{url})"
        )

        {:error,
         ShapeError.new(
           url,
           model,
           :missing_choices,
           "the endpoint is not OpenAI chat-completions compatible"
         )}

      {:ok, %{status: status, body: body} = resp} ->
        Logger.warning(
          "Loopctl.Llm.OpenAiChat: API error (op=#{operation}, status=#{status}, endpoint=#{url})"
        )

        reason = {:api_error, status, body}
        record_provider_error(reason)
        {:error, ProviderError.sanitize(reason, RetryAfter.from_response(status, resp))}

      # US-41.4: a fail-CLOSED egress refusal is a local CONFIGURATION decision, not
      # a provider failure — returned bare, never counted as a provider error.
      {:error, {egress, _details} = refusal}
      when egress in [:egress_blocked, :pin_stale, :egress_unavailable] ->
        {:error, refusal}

      {:error, reason} ->
        Logger.warning(
          "Loopctl.Llm.OpenAiChat: request failed (op=#{operation}, endpoint=#{url}, " <>
            "#{ProviderError.log_tag({:request_failed, reason})})"
        )

        record_provider_error({:request_failed, reason})
        {:error, {:request_failed, reason}}
    end
  end

  # Translate the Anthropic-shaped `body_fun` result into an OpenAI
  # chat-completions request. This is the ONLY place the two protocols differ, so
  # the behaviour impls never branch on provider.
  defp to_chat_completions(body, model) when is_map(body) do
    messages =
      case Map.get(body, :system) do
        system when is_binary(system) ->
          [%{role: "system", content: system} | Map.get(body, :messages, [])]

        _ ->
          Map.get(body, :messages, [])
      end

    %{model: model, messages: messages}
    |> maybe_put(:max_tokens, Map.get(body, :max_tokens))
    |> maybe_put(:temperature, Map.get(body, :temperature))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Mirrors `Loopctl.Llm.Anthropic`'s single choke point so a real 4xx/5xx/transport
  # storm on the local-endpoint surface is visible to the same
  # `[:loopctl, :llm, :provider_error]` signal. The `provider` label is the FIXED
  # atom's string form — NEVER the tenant-supplied host, which would make the
  # telemetry dimension unbounded.
  defp record_provider_error(reason) do
    class = if Llm.permanent_provider_error?(reason), do: :permanent, else: :transient
    Llm.record_provider_error(@provider_tag, class)
  end

  # BEST-EFFORT: the call already succeeded, so a DB blip while inserting the usage
  # row must never raise and trigger an Oban retry of an already-served request.
  defp record_usage_safe(tenant_id, operation, model, usage, meta) do
    record_usage(tenant_id, operation, model, usage, meta)
  rescue
    e ->
      Logger.error(
        "Loopctl.Llm.OpenAiChat: usage recording raised (op=#{operation}); " <>
          "the call already succeeded, continuing: #{Exception.message(e)}"
      )

      :ok
  end

  defp record_usage(tenant_id, operation, model, usage, meta) do
    # AC-41.3.6: a local endpoint that reports NO usage object still gets a ROW,
    # with zero tokens. A zero-cost provider is fine; a silently missing row is not.
    {input, output} = token_counts(usage)

    case Llm.record_usage(tenant_id, %{
           operation: operation,
           model: model,
           provider: @provider_tag,
           input_tokens: input,
           output_tokens: output,
           source_type: Map.get(meta, :source_type),
           article_id: Map.get(meta, :article_id)
         }) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Loopctl.Llm.OpenAiChat: usage record rejected (op=#{operation}): " <>
            "#{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  defp token_counts(%{} = usage) do
    {normalize_token(Map.get(usage, "prompt_tokens", 0)),
     normalize_token(Map.get(usage, "completion_tokens", 0))}
  end

  defp token_counts(_no_usage_block), do: {0, 0}

  defp normalize_token(n) when is_integer(n) and n >= 0, do: n
  defp normalize_token(_), do: 0

  defp maybe_put_plug(opts) do
    case Application.get_env(:loopctl, :openai_chat_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end
end
