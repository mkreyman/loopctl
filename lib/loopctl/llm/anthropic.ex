defmodule Loopctl.Llm.Anthropic do
  @moduledoc """
  Shared Anthropic Messages API call for tenant-scoped LLM operations
  (Epic 28 residual, #179).

  Centralizes the mandatory-BYO + usage-tracking flow for the four LLM call
  sites (content extraction / classification / merge / review extraction):

    1. `Loopctl.Llm.resolve(tenant_id, operation)` — get the tenant's key + the
       per-operation model, or `{:error, :no_api_key}` (no global fallback).
    2. POST the Messages request with THAT key (`x-api-key`) + THAT model.
    3. On a 200, capture the response `usage` (`input_tokens`/`output_tokens`) and
       `Loopctl.Llm.record_usage/2` — BEST-EFFORT (a usage-recording failure never
       fails an already-billed Anthropic call; see `record_usage_safe/5`).
    4. Return the assistant text for the caller to parse.

  ## Timeout budget (review #5)

  Callers pass `receive_timeout` / `max_retries` in `req_opts` so the client's
  worst-case wall-clock stays strictly BELOW the caller's outer budget (the Oban
  job/`Task.async_stream` timeout). This prevents the outer supervisor from
  killing an in-flight request mid-way (which the client can neither observe nor
  retry). The defaults here are conservative; every real caller overrides them.

  The API key is NEVER logged. HTTP is injectable for tests via the
  `:anthropic_req_plug` config (a `Req.Test` plug), so the whole flow — including
  usage recording — is exercised without real API calls.
  """

  require Logger

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Provider
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter

  @base_url "https://api.anthropic.com/v1"
  @anthropic_version "2023-06-01"

  # Conservative defaults; callers override with budgets that fit their outer
  # timeout (review #5). retry :transient + max_retries drives Req's retry.
  @default_receive_timeout 25_000
  @default_max_retries 0

  @doc """
  The Anthropic API BASE URL this client actually posts to.

  The SINGLE source of truth for the chat endpoint: `Loopctl.Egress` (posture +
  the `local_only` enable pre-flight) reads it from HERE rather than re-deriving
  it from a config key nothing else consults, so the endpoint that gets vetted is
  always the endpoint the guard sees. A second, divergent URL resolution is an
  AC-41.4.9 review failure.
  """
  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @type usage_meta :: %{
          optional(:source_type) => String.t() | nil,
          optional(:article_id) => Ecto.UUID.t() | nil
        }

  @doc """
  Resolve the tenant key+model for `operation`, then POST via `call/7`.

  Returns:
    * `{:ok, text}` on a 200 (usage recorded best-effort)
    * `{:error, :no_api_key}` when the tenant has no key (mandatory BYO)
    * `{:error, :rate_limited_local}` when the local admission bucket is empty
    * `{:error, {:api_error, status, :provider_error}}` on a non-200 (sanitized)
    * `{:error, {:api_error, status, :provider_error, retry_after}}` on a throttle
      response (429/503) carrying a parsed provider Retry-After (US-37.3)
    * `{:error, {:request_failed, reason}}` on a transport error

  All returned error terms are sanitized via `Loopctl.Llm.ProviderError` and never
  carry a raw provider body — the error union below is `ProviderError.t()`.

  ## Egress scope (US-41.4, AC-41.4.2)

  The first argument is the `Loopctl.Egress.Scope` the chat call is made on behalf
  of; a bare `tenant_id` is accepted as shorthand for the tenant-wide scope. Key +
  endpoint resolution stays TENANT-scoped — the project half narrows only the
  `local_only` marking, which is applied at the egress chokepoint.
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
          | {:error, :rate_limited_local}
          | {:error, ProviderError.t()}
  def message(scope_or_tenant_id, operation, body_fun, usage_meta \\ %{}, req_opts \\ [])
      when is_function(body_fun, 1) do
    scope = EgressScope.coerce(scope_or_tenant_id)

    case Llm.resolve(scope.tenant_id, operation) do
      {:error, :no_api_key} ->
        {:error, :no_api_key}

      {:ok, %{api_key: api_key, model: model}} ->
        call(scope, operation, api_key, model, body_fun, usage_meta, req_opts)
    end
  end

  @doc """
  Like `message/5` but with EXPLICIT pre-resolved `api_key` + `model` — skips the
  per-call `Loopctl.Llm.resolve/2` DB read. Used to resolve ONCE per batch and
  thread the resolved credentials through many calls (review #19). The caller is
  responsible for having resolved the tenant's credentials.

  Returns the same shapes as `message/5` (minus `{:error, :no_api_key}`, which is
  resolved by the caller). On a throttle response (429/503) the error is the
  sanitized 4-tuple `{:error, {:api_error, status, :provider_error, retry_after}}`
  carrying a parsed provider Retry-After (US-37.3). The error union is
  `ProviderError.t()` — every returned error term is sanitized and body-free.
  """
  @spec call(
          EgressScope.t() | Ecto.UUID.t(),
          Llm.operation(),
          String.t(),
          String.t(),
          (String.t() -> map()),
          usage_meta(),
          keyword()
        ) ::
          {:ok, String.t()}
          | {:error, :rate_limited_local}
          | {:error, ProviderError.t()}
  def call(
        scope_or_tenant_id,
        operation,
        api_key,
        model,
        body_fun,
        usage_meta \\ %{},
        req_opts \\ []
      )
      when is_binary(api_key) and is_binary(model) and is_function(body_fun, 1) do
    body = model |> body_fun.() |> Map.put(:model, model)

    post(
      EgressScope.coerce(scope_or_tenant_id),
      operation,
      model,
      body,
      usage_meta,
      api_key,
      req_opts
    )
  end

  defp post(
         %EgressScope{tenant_id: tenant_id} = scope,
         operation,
         model,
         body,
         usage_meta,
         api_key,
         req_opts
       ) do
    # US-37.1: per-(tenant, provider) token-bucket admission gate. On an empty
    # node-local bucket, short-circuit with `{:error, :rate_limited_local}` BEFORE
    # building/sending the request — and crucially BEFORE the `record_provider_error/1`
    # branches below, so a local rate-limit never inflates the
    # `[:loopctl, :llm, :provider_error]` storm signal (parallel to the breaker
    # exemption in AC-37.1.3).
    with :ok <- Admission.admit(tenant_id, :anthropic) do
      do_post(scope, operation, model, body, usage_meta, api_key, req_opts)
    end
  end

  defp do_post(
         %EgressScope{tenant_id: tenant_id} = scope,
         operation,
         model,
         body,
         usage_meta,
         api_key,
         req_opts
       ) do
    opts =
      [
        json: body,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", @anthropic_version}
        ],
        retry: :transient,
        max_retries: @default_max_retries,
        receive_timeout: @default_receive_timeout
      ]
      |> Keyword.merge(req_opts)
      |> maybe_put_plug()

    # NOTE: never log `opts` / `api_key` — the key is a tenant secret.
    # US-41.4 (AC-41.4.4): routed through the SINGLE egress chokepoint, which
    # refuses `local_only` scopes on a non-local endpoint BEFORE the request is
    # built. Admission (fail-OPEN) stays its own `with` clause above so the two
    # failure modes never share a code path.
    case Provider.post("#{base_url()}/messages", opts, %{scope: scope, purpose: :inference}) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]} = resp}} ->
        record_usage_safe(tenant_id, operation, model, resp["usage"], usage_meta)
        {:ok, text}

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("Loopctl.Llm.Anthropic: 200 with unexpected shape (op=#{operation})")
        # A 200 with the wrong shape can STILL be a misconfigured/compromised
        # endpoint echoing a masked key fragment in an error-shaped body (review
        # CRIT #1). Sanitize it exactly like a non-200 — never return the raw body.
        reason = {:api_error, 200, body}
        # Review fix (LOW): deliberately do NOT `record_provider_error/1` here. A 200
        # is, semantically, a provider SUCCESS — `permanent_provider_error?/1` has no
        # 4xx/5xx clause for it, so it would fall through and window into
        # `provider_error_rate` (AC-34.3.3's genuine-OUTAGE storm signal) as
        # `:transient`. A legitimate-but-unexpected response shape (a non-text first
        # content block, or empty content on a refusal/max_tokens stop) is not a
        # 429/5xx/transport incident, so counting it would over-count the storm
        # signal on a real provider-SUCCESS path. The `Logger.warning` above plus the
        # sanitized `{:error, _}` return (still routed through the same
        # possible-compromised-endpoint handling as review CRIT #1) already keep this
        # anomaly observable/actionable without polluting the outage counter.
        {:error, ProviderError.sanitize(reason)}

      {:ok, %{status: status, body: body} = resp} ->
        Logger.warning("Loopctl.Llm.Anthropic: API error (op=#{operation}, status=#{status})")
        # SANITIZE the provider error body (review #11): it can echo a masked key
        # fragment, and callers surface it as an Oban `{:error, reason}` persisted
        # into oban_jobs.errors. Drop the body; keep only the status.
        #
        # US-37.3: on a throttle response (429/503) parse the provider Retry-After and
        # thread it (clamped, value-free) into the sanitized error so a snooze-capable
        # worker (ContentIngestionWorker) yields loss-free for ~that interval instead
        # of the blind `attempt^4` backoff. The breaker itself stays embedding-only
        # (it lives in `Knowledge` and only guards `generate_embedding/3`); the
        # Anthropic path has never had a breaker and this story does not add one —
        # `record_provider_error/1` still feeds the fleet-wide provider-error storm
        # signal, and honoring Retry-After on the worker snooze is the win here.
        # `record_provider_error/1` classifies on the RAW 3-tuple reason (429 →
        # transient), unchanged; only the RETURNED term widens to the 4-tuple.
        reason = {:api_error, status, body}
        record_provider_error(reason)
        {:error, ProviderError.sanitize(reason, RetryAfter.from_response(status, resp))}

      # US-41.4: a fail-CLOSED egress refusal (and the DISTINCT `:pin_stale`) is a
      # local CONFIGURATION decision, not a provider failure. Return the bare atom
      # WITHOUT `record_provider_error/1` — counting it would inflate the fleet-wide
      # `[:loopctl, :llm, :provider_error]` storm signal for what is, by design, a
      # permanent local refusal (the same reasoning that exempts
      # `:rate_limited_local`). No data was sent.
      {:error, {egress, _details} = refusal}
      when egress in [:egress_blocked, :pin_stale, :egress_unavailable] ->
        {:error, refusal}

      {:error, reason} ->
        # Never inspect the raw transport reason (review MED #4) — log a value-free
        # tag, mirroring EmbeddingClient.post.
        Logger.warning(
          "Loopctl.Llm.Anthropic: request failed (op=#{operation}, " <>
            "#{ProviderError.log_tag({:request_failed, reason})})"
        )

        record_provider_error({:request_failed, reason})
        {:error, {:request_failed, reason}}
    end
  end

  # Review fix (MEDIUM, AC-34.3.3): this is the ONE choke point for EVERY Anthropic
  # call site (content extraction/classification/merge/memory-promotion all funnel
  # through `message/5` -> `call/7` -> `post/7`), so wiring the genuine-provider-error
  # signal HERE — rather than duplicating it across each of the 4+ call sites —
  # guarantees a real 429/5xx/transport storm on the primary Anthropic surface (the
  # incident class US-34.3's story background names) is never invisible to
  # `[:loopctl, :llm, :provider_error]`. Classifies on the RAW (pre-sanitize) reason,
  # mirroring `ArticleEmbeddingWorker`/`MemoryEmbeddingWorker`'s own
  # `record_provider_error/1` helper — `Llm.record_provider_error/2` itself only
  # windows bounded `provider`/`class` metadata, never the reason term.
  defp record_provider_error(reason) do
    class = if Llm.permanent_provider_error?(reason), do: :permanent, else: :transient
    Llm.record_provider_error("anthropic", class)
  end

  # BEST-EFFORT usage recording (review #3). The Anthropic call has already
  # SUCCEEDED (and been billed to the tenant) by the time we get here, so a DB
  # blip / FK race while inserting the usage row must NEVER raise — that would
  # crash the job, trigger an Oban retry, and RE-BILL the tenant. Mirror
  # `ContentIngestionWorker.enqueue_embeddings/2`: log-and-continue, always :ok.
  defp record_usage_safe(tenant_id, operation, model, usage, meta) do
    record_usage(tenant_id, operation, model, usage, meta)
  rescue
    e ->
      Logger.error(
        "Loopctl.Llm.Anthropic: usage recording raised (op=#{operation}); " <>
          "the Anthropic call already succeeded, continuing: #{Exception.message(e)}"
      )

      :ok
  end

  # Record token usage from the Anthropic `usage` object. A missing/malformed usage
  # block, or an `{:error, changeset}` from the insert (e.g. a mapped FK violation),
  # is logged and skipped — never crashes a successful extraction.
  defp record_usage(tenant_id, operation, model, %{} = usage, meta) do
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)

    case Llm.record_usage(tenant_id, %{
           operation: operation,
           model: model,
           input_tokens: normalize_token(input),
           output_tokens: normalize_token(output),
           source_type: Map.get(meta, :source_type),
           article_id: Map.get(meta, :article_id)
         }) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Loopctl.Llm.Anthropic: usage record rejected (op=#{operation}): " <>
            "#{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  defp record_usage(_tenant_id, operation, _model, _usage, _meta) do
    Logger.warning("Loopctl.Llm.Anthropic: response had no usage block (op=#{operation})")
    :ok
  end

  defp normalize_token(n) when is_integer(n) and n >= 0, do: n
  defp normalize_token(_), do: 0

  defp maybe_put_plug(opts) do
    case Application.get_env(:loopctl, :anthropic_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end
end
