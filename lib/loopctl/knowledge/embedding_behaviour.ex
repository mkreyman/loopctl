defmodule Loopctl.Knowledge.EmbeddingBehaviour do
  @moduledoc """
  Behaviour for embedding generation clients.

  Implementations convert text into vector embeddings for semantic search.
  The default implementation (`Loopctl.Knowledge.EmbeddingClient`) calls
  the OpenAI embeddings API via Req.

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

  @callback generate_embedding(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
end
