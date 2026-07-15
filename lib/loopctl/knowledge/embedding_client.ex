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
  alias Loopctl.SystemConfig

  @default_base_url "https://api.openai.com/v1"

  # Default batch HTTP knobs — a literal mirror of the seeded SystemConfig rows;
  # these in-code defaults apply on a cache miss (safe degrade). Kept here (not in
  # the guard) so the guard's Task.yield budget can be DERIVED from the SAME
  # numbers the request actually uses (review MED #1).
  @default_batch_receive_timeout_ms 30_000
  @default_batch_max_retries 0
  # Per-retry backoff allowance: `retry: :transient` sleeps between attempts
  # (Req's exponential backoff), so each extra retry adds a receive window PLUS a
  # backoff sleep. Budget generously for the sleep so a retrying-but-valid call
  # still returns before the guard fires.
  @batch_retry_backoff_ms 4_000
  # Fixed slack above the worst-case HTTP budget for task scheduling / DB overhead.
  @batch_yield_slack_ms 2_000

  @doc """
  The live-tunable per-request receive timeout (ms) the batch array call uses
  (`embedding_batch_receive_timeout_ms`, default #{@default_batch_receive_timeout_ms}).
  """
  @spec batch_receive_timeout_ms() :: pos_integer()
  def batch_receive_timeout_ms do
    SystemConfig.get_int("embedding_batch_receive_timeout_ms", @default_batch_receive_timeout_ms)
  end

  @doc """
  The live-tunable client-side retry count for a batch array call
  (`embedding_max_retries`, default #{@default_batch_max_retries}). Floored at 0.
  """
  @spec batch_max_retries() :: non_neg_integer()
  def batch_max_retries do
    max(SystemConfig.get_int("embedding_max_retries", @default_batch_max_retries), 0)
  end

  @doc """
  Worst-case wall-clock budget (ms) for a batch array call, DERIVED from the same
  live-tunable SystemConfig knobs `do_post_batch/4` actually reads:
  `receive_timeout * (max_retries + 1)` plus a per-retry backoff allowance and a
  fixed slack.

  The guarded batch path (`Loopctl.Knowledge.generate_embeddings/3`) uses this as
  its `Task.yield` budget, so raising `embedding_batch_receive_timeout_ms` or
  `embedding_max_retries` can NEVER make the yield fire BEFORE a valid in-flight
  response returns (review MED #1). Previously the yield was a compile-time 32s
  constant while these knobs were operator-tunable with no coupling — an operator
  raising either defeated the guard, killing valid slow responses and
  mis-counting them as breaker / provider-error failures.
  """
  @spec batch_yield_budget_ms() :: pos_integer()
  def batch_yield_budget_ms do
    retries = batch_max_retries()

    batch_receive_timeout_ms() * (retries + 1) + @batch_retry_backoff_ms * retries +
      @batch_yield_slack_ms
  end

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
  def generate_embeddings(_tenant_id, []), do: {:ok, []}

  def generate_embeddings(tenant_id, texts) when is_binary(tenant_id) and is_list(texts) do
    case Llm.resolve(tenant_id, :embedding) do
      {:error, :no_api_key} ->
        # Mandatory BYO: no tenant key => no provider call, no operator spend.
        {:error, :no_api_key}

      {:ok, %{api_key: api_key, model: model}} ->
        post_batch(tenant_id, api_key, model, texts)
    end
  end

  # US-37.4: one admission token for the WHOLE array call (AC-37.4.4) — the batch
  # is a single provider round-trip, so it takes exactly one token from the US-37.1
  # bucket, exactly like the single-text path.
  defp post_batch(tenant_id, api_key, model, texts) do
    with :ok <- Admission.admit(tenant_id, :embedding) do
      do_post_batch(tenant_id, api_key, model, texts)
    end
  end

  defp do_post_batch(tenant_id, api_key, model, texts) do
    base_url = provider_config()[:base_url] || @default_base_url

    # The array call is a single HTTP request carrying up to ~100 texts, so it
    # needs a longer receive budget than the single-text path (kept behind its own
    # live-tunable SystemConfig key; the in-code default applies on a cache miss).
    opts =
      [
        json: %{input: texts, model: model},
        headers: [{"authorization", "Bearer #{api_key}"}],
        retry: :transient,
        max_retries: batch_max_retries(),
        receive_timeout: batch_receive_timeout_ms()
      ]
      |> maybe_put_plug()

    case Req.post("#{base_url}/embeddings", opts) do
      {:ok, %{status: 200, body: %{"data" => data} = resp}} when is_list(data) ->
        record_usage_safe(tenant_id, model, resp["usage"])
        map_embeddings_by_index(data, length(texts))

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Loopctl.Knowledge.EmbeddingClient: batch API error (status=#{status})")
        {:error, ProviderError.sanitize({:api_error, status, body})}

      {:error, reason} ->
        Logger.warning(
          "Loopctl.Knowledge.EmbeddingClient: batch request failed (#{ProviderError.log_tag({:request_failed, reason})})"
        )

        {:error, {:request_failed, reason}}
    end
  end

  # AC-37.4.1: map each returned vector back to its input BY the response `index`
  # field — never by array position — since OpenAI-compatible endpoints do NOT
  # guarantee `data` is index-ordered. Reassemble in input order (0..n-1). A
  # missing index means the provider returned an incomplete batch: fail as a unit
  # so the caller never writes a partial/misaligned set of vectors.
  defp map_embeddings_by_index(data, count) do
    by_index =
      Enum.reduce(data, %{}, fn
        %{"index" => i, "embedding" => vec}, acc when is_integer(i) -> Map.put(acc, i, vec)
        _entry, acc -> acc
      end)

    vectors = Enum.map(0..(count - 1), &Map.get(by_index, &1))

    if Enum.any?(vectors, &is_nil/1) do
      {:error, {:embedding_batch_incomplete, count}}
    else
      {:ok, vectors}
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

  defp do_post(tenant_id, api_key, model, text) do
    base_url = provider_config()[:base_url] || @default_base_url

    # Kept STRICTLY BELOW `Knowledge`'s Task.yield budget (review #10): a single
    # attempt, no client-side retries by default. The embedding endpoint is fast;
    # job-level retry is Oban's responsibility for the worker, and the query path
    # fast-fails to keyword search. This guarantees a valid embed returns before
    # the guard kills it. Both knobs are DB-backed and live-tunable via
    # Loopctl.SystemConfig; the in-code defaults match the seeded rows and apply on
    # a cache miss (safe degrade) — keep any raised timeout under the yield budget.
    opts =
      [
        json: %{input: text, model: model},
        # NOTE: never log `opts` / `api_key` — the key is a tenant secret.
        headers: [{"authorization", "Bearer #{api_key}"}],
        retry: :transient,
        max_retries: SystemConfig.get_int("embedding_max_retries", 0),
        receive_timeout: SystemConfig.get_int("embedding_receive_timeout_ms", 4_000)
      ]
      |> maybe_put_plug()

    case Req.post("#{base_url}/embeddings", opts) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]} = resp}} ->
        record_usage_safe(tenant_id, model, resp["usage"])
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Loopctl.Knowledge.EmbeddingClient: API error (status=#{status})")
        # SANITIZE: the provider error body can echo a masked key fragment (review
        # #3). Drop it — keep only the status — so it never reaches the caller / an
        # Oban `{:error, reason}` persisted into oban_jobs.errors.
        {:error, ProviderError.sanitize({:api_error, status, body})}

      {:error, reason} ->
        Logger.warning(
          "Loopctl.Knowledge.EmbeddingClient: request failed (#{ProviderError.log_tag({:request_failed, reason})})"
        )

        {:error, {:request_failed, reason}}
    end
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
