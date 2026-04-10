defmodule Loopctl.Knowledge.EmbeddingClient do
  @moduledoc """
  Default embedding client that calls the OpenAI-compatible embeddings API via Req.

  ## Configuration

  Set the following in your runtime config:

      config :loopctl, :embedding_provider, %{
        base_url: "https://api.openai.com/v1",
        api_key: "sk-...",
        model: "text-embedding-3-small"
      }

  All keys are optional and fall back to sensible defaults.
  """

  @behaviour Loopctl.Knowledge.EmbeddingBehaviour

  @impl true
  def generate_embedding(text) do
    config = Application.get_env(:loopctl, :embedding_provider, %{})
    base_url = config[:base_url] || "https://api.openai.com/v1"
    api_key = config[:api_key] || ""
    model = config[:model] || "text-embedding-3-small"

    case Req.post("#{base_url}/embeddings",
           json: %{input: text, model: model},
           headers: [{"authorization", "Bearer #{api_key}"}],
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
