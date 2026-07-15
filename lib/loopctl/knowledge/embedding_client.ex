defmodule Loopctl.Knowledge.EmbeddingClient do
  @moduledoc """
  Default embedding client that calls the OpenAI-compatible embeddings API via Req,
  using the TENANT's OWN embedding key (mandatory BYO — #294 extended to embeddings).

  ## Mandatory BYO

  `generate_embedding/2` resolves the tenant's embedding key + model via
  `Loopctl.Llm.resolve(tenant_id, :embedding)`. There is NO global/operator key
  fallback: a tenant with no configured embedding key gets `{:error, :no_api_key}`
  and NO provider call is made (so a low-privilege agent key can never run up the
  operator's OpenAI bill). On a successful 200 an `:embedding` usage event is
  recorded (best-effort — a usage-recording blip never fails an already-billed
  call).

  ## Configuration

  The provider endpoint (base_url) + default model come from runtime config; the
  KEY is per-tenant and NEVER read from global config:

      config :loopctl, :embedding_provider, %{
        base_url: "https://api.openai.com/v1",
        model: "text-embedding-3-small"
      }

  HTTP is injectable for tests via the `:embedding_req_plug` config (a `Req.Test`
  plug), so the whole flow — including usage recording — is exercised without real
  API calls. The api_key is NEVER logged.
  """

  @behaviour Loopctl.Knowledge.EmbeddingBehaviour

  require Logger

  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter
  alias Loopctl.SystemConfig

  @default_base_url "https://api.openai.com/v1"

  # Single (interactive) path receive_timeout default — kept tight (latency-sensitive).
  @default_receive_timeout_ms 4_000

  # Batch path receive_timeout defaults (review MED #3). The batch path gets its OWN,
  # count-SCALED receive_timeout instead of reusing the single-text-tuned
  # `embedding_receive_timeout_ms` (raising that would also loosen the latency-sensitive
  # interactive path). base + per-item mirrors the worker's yield shape; the base is
  # kept strictly BELOW the worker's yield base so the HTTP call fails cleanly before
  # the worker's Task.yield shuts the task down. Live-tunable via SystemConfig.
  @default_batch_receive_base_ms 6_000
  @default_batch_receive_per_item_ms 100

  @impl true
  def generate_embedding(tenant_id, text) when is_binary(tenant_id) do
    case Llm.resolve(tenant_id, :embedding) do
      {:error, :no_api_key} ->
        # Mandatory BYO: no tenant key => no provider call, no operator spend.
        {:error, :no_api_key}

      {:ok, %{api_key: api_key, model: model}} ->
        post(tenant_id, api_key, model, text)
    end
  end

  @impl true
  def generate_embeddings(tenant_id, texts)
      when is_binary(tenant_id) and is_list(texts) do
    # An empty batch never touches the provider (no admission token spent).
    if texts == [] do
      {:ok, []}
    else
      case Llm.resolve(tenant_id, :embedding) do
        {:error, :no_api_key} ->
          # Mandatory BYO: no tenant key => no provider call, no operator spend.
          {:error, :no_api_key}

        {:ok, %{api_key: api_key, model: model}} ->
          post_batch(tenant_id, api_key, model, texts)
      end
    end
  end

  defp post(tenant_id, api_key, model, text) do
    # US-37.1: per-(tenant, provider) token-bucket admission gate. On an empty
    # node-local bucket, fast-fail WITHOUT building/sending the request so the
    # caller degrades cheaply (interactive search → keyword fallback; embedding
    # jobs → snooze/retry). This return is breaker-EXEMPT (see Knowledge's
    # `breaker_countable?/1`).
    with :ok <- Admission.admit(tenant_id, :embedding) do
      do_post(tenant_id, api_key, model, text)
    end
  end

  # US-37.4: batch variant. ONE admission token is taken for the WHOLE array
  # (AC-37.4.4) — the same single gate as the single-text path — so a ~100-text
  # batch is one bucket draw, not 100. Same breaker-exempt fast-fail on an empty
  # bucket.
  defp post_batch(tenant_id, api_key, model, texts) do
    with :ok <- Admission.admit(tenant_id, :embedding) do
      do_post_batch(tenant_id, api_key, model, texts)
    end
  end

  defp do_post(tenant_id, api_key, model, text) do
    opts = request_opts(api_key, %{input: text, model: model}, single_receive_timeout_ms())

    case Req.post(embeddings_url(), opts) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]} = resp}} ->
        record_usage_safe(tenant_id, model, resp["usage"])
        {:ok, embedding}

      other ->
        handle_error(other)
    end
  end

  # Sends `input` as an ARRAY and maps each returned `%{"index" => i, "embedding" =>
  # v}` back to input position `i` — sorting/looking up BY the response index, NEVER
  # by array position (AC-37.4.1). Returns vectors in INPUT ORDER so the caller can
  # zip them against `texts`. A short/mismatched `data` array (any input index with
  # no returned vector) fails the WHOLE batch (AC-37.4.3) — no partial/misaligned
  # result reaches the caller.
  defp do_post_batch(tenant_id, api_key, model, texts) do
    opts =
      request_opts(
        api_key,
        %{input: texts, model: model},
        batch_receive_timeout_ms(length(texts))
      )

    case Req.post(embeddings_url(), opts) do
      {:ok, %{status: 200, body: %{"data" => data} = resp}} when is_list(data) ->
        case map_vectors_by_index(data, length(texts)) do
          {:ok, vectors} ->
            record_usage_safe(tenant_id, model, resp["usage"])
            {:ok, vectors}

          :error ->
            Logger.warning(
              "Loopctl.Knowledge.EmbeddingClient: batch response index mismatch " <>
                "(#{length(data)} vectors for #{length(texts)} inputs)"
            )

            {:error, {:embedding_index_mismatch, length(texts), length(data)}}
        end

      other ->
        handle_error(other)
    end
  end

  # `receive_timeout` is caller-supplied and kept STRICTLY BELOW `Knowledge`'s
  # Task.yield budget (review #10): a single attempt, no client-side retries by
  # default. The single (interactive) path uses a tight, latency-sensitive budget;
  # the batch path a count-SCALED one (see the callers). Job-level retry is Oban's
  # responsibility for the worker, and the query path fast-fails to keyword search.
  # All knobs are DB-backed and live-tunable via Loopctl.SystemConfig; the in-code
  # defaults match the seeded rows and apply on a cache miss (safe degrade).
  defp request_opts(api_key, json_body, receive_timeout) do
    [
      json: json_body,
      # NOTE: never log `opts` / `api_key` — the key is a tenant secret.
      headers: [{"authorization", "Bearer #{api_key}"}],
      retry: :transient,
      max_retries: SystemConfig.get_int("embedding_max_retries", 0),
      receive_timeout: receive_timeout
    ]
    |> maybe_put_plug()
  end

  defp single_receive_timeout_ms do
    SystemConfig.get_int("embedding_receive_timeout_ms", @default_receive_timeout_ms)
  end

  # Batch path receive_timeout: base + per-item, scaled by the array size so a large
  # ~100-input request gets proportionally more wire time than one text — WITHOUT
  # loosening the single-path timeout. Mirrors the worker's yield shape (smaller base)
  # so it always fails before the worker's yield.
  defp batch_receive_timeout_ms(count) do
    base = SystemConfig.get_int("embedding_batch_receive_base_ms", @default_batch_receive_base_ms)

    per_item =
      SystemConfig.get_int(
        "embedding_batch_receive_per_item_ms",
        @default_batch_receive_per_item_ms
      )

    base + per_item * max(count, 1)
  end

  defp embeddings_url do
    base_url = provider_config()[:base_url] || @default_base_url
    "#{base_url}/embeddings"
  end

  # Builds the map index -> embedding from the (order-unguaranteed) `data` array,
  # then pulls one vector per input position 0..count-1. Any missing index halts
  # with `:error` (batch fails as a unit). Non-integer/malformed entries are dropped
  # from the lookup, which surfaces as a missing index below.
  defp map_vectors_by_index(data, count) do
    by_index =
      Enum.reduce(data, %{}, fn
        %{"index" => i, "embedding" => v}, acc when is_integer(i) and is_list(v) ->
          Map.put(acc, i, v)

        _, acc ->
          acc
      end)

    result =
      Enum.reduce_while(0..(count - 1)//1, [], fn i, acc ->
        case Map.fetch(by_index, i) do
          {:ok, v} -> {:cont, [v | acc]}
          :error -> {:halt, :error}
        end
      end)

    case result do
      :error -> :error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  # Shared non-200 / transport handling for BOTH the single and batch paths.
  defp handle_error({:ok, %{status: status, body: body} = resp}) do
    Logger.warning("Loopctl.Knowledge.EmbeddingClient: API error (status=#{status})")
    # US-37.3: on a throttle response (429/503) parse the provider Retry-After
    # and thread it (clamped, value-free) into the sanitized error so the
    # tenant-scoped breaker cooldown AND the Oban worker snooze honor it instead
    # of blind polynomial backoff. Absent/garbage → nil → the legacy 3-tuple.
    # SANITIZE either way: the provider error body can echo a masked key fragment
    # (review #3). Drop it — keep only status (+ Retry-After) — so it never
    # reaches the caller / an Oban `{:error, reason}` persisted into oban_jobs.errors.
    retry_after = RetryAfter.from_response(status, resp)
    {:error, ProviderError.sanitize({:api_error, status, body}, retry_after)}
  end

  defp handle_error({:error, reason}) do
    Logger.warning(
      "Loopctl.Knowledge.EmbeddingClient: request failed (#{ProviderError.log_tag({:request_failed, reason})})"
    )

    {:error, {:request_failed, reason}}
  end

  # BEST-EFFORT usage recording: the embedding call has already SUCCEEDED (and been
  # billed to the tenant) by the time we get here, so a DB blip / FK race while
  # inserting the usage row must NEVER raise — that would crash the worker, trigger
  # an Oban retry, and RE-BILL the tenant. Log-and-continue, always {:ok, embedding}.
  defp record_usage_safe(tenant_id, model, usage) do
    record_usage(tenant_id, model, usage)
  rescue
    e ->
      Logger.error(
        "Loopctl.Knowledge.EmbeddingClient: usage recording raised; the embedding call " <>
          "already succeeded, continuing: #{Exception.message(e)}"
      )

      :ok
  end

  # OpenAI embeddings report `usage.prompt_tokens` (== total_tokens for embeddings).
  # There is no completion, so output_tokens is 0.
  defp record_usage(tenant_id, model, %{} = usage) do
    input = Map.get(usage, "prompt_tokens") || Map.get(usage, "total_tokens") || 0

    case Llm.record_usage(tenant_id, %{
           operation: :embedding,
           model: model,
           input_tokens: normalize_token(input),
           output_tokens: 0
         }) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Loopctl.Knowledge.EmbeddingClient: usage record rejected: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  defp record_usage(_tenant_id, _model, _usage) do
    Logger.warning("Loopctl.Knowledge.EmbeddingClient: response had no usage block")
    :ok
  end

  defp normalize_token(n) when is_integer(n) and n >= 0, do: n
  defp normalize_token(_), do: 0

  defp provider_config, do: Application.get_env(:loopctl, :embedding_provider, %{})

  defp maybe_put_plug(opts) do
    case Application.get_env(:loopctl, :embedding_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end
end
