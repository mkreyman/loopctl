defmodule Loopctl.Knowledge.EmbeddingBehaviour do
  @moduledoc """
  Behaviour for embedding generation clients.

  Implementations convert text into vector embeddings for semantic search.
  The default implementation (`Loopctl.Knowledge.EmbeddingClient`) resolves the
  TENANT's OWN OpenAI embedding key + model (mandatory BYO — no operator-funded
  fallback) and calls the OpenAI-compatible embeddings API via Req, recording an
  `:embedding` usage event on success.

  ## Config-based DI

  Consumers resolve the implementation via `Application.compile_env/3`:

      @embedding_client Application.compile_env(
        :loopctl,
        :embedding_client,
        Loopctl.Knowledge.EmbeddingClient
      )

  In `config/test.exs`, the mock is configured:

      config :loopctl, :embedding_client, Loopctl.MockEmbeddingClient
  """

  @callback generate_embedding(tenant_id :: Ecto.UUID.t(), text :: String.t()) ::
              {:ok, [float()]} | {:error, :no_api_key} | {:error, term()}
end
