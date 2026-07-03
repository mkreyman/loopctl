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

  @default_base_url "https://api.openai.com/v1"

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

  defp post(tenant_id, api_key, model, text) do
    base_url = provider_config()[:base_url] || @default_base_url

    opts =
      [
        json: %{input: text, model: model},
        # NOTE: never log `opts` / `api_key` — the key is a tenant secret.
        headers: [{"authorization", "Bearer #{api_key}"}],
        retry: :transient,
        max_retries: 2,
        receive_timeout: 30_000
      ]
      |> maybe_put_plug()

    case Req.post("#{base_url}/embeddings", opts) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]} = resp}} ->
        record_usage_safe(tenant_id, model, resp["usage"])
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Loopctl.Knowledge.EmbeddingClient: API error (status=#{status})")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.warning(
          "Loopctl.Knowledge.EmbeddingClient: request failed (error=#{inspect(reason)})"
        )

        {:error, reason}
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
