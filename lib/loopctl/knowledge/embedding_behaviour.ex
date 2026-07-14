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

  @doc """
  Batch variant (US-37.4): embeds a LIST of texts in ONE provider round-trip,
  returning a list of vectors in the SAME order as the input `texts` (mapped back
  from the provider's per-entry `index`, never by array position). Used by the
  background batch embedding worker to cut N provider calls down to
  `ceil(N / batch_max)`. The interactive single-text path stays
  `generate_embedding/2` (latency-sensitive).

  An empty `texts` list returns `{:ok, []}` WITHOUT any provider call. A single
  provider error fails the whole batch as a unit (`{:error, reason}`) so no
  partial set of vectors is written.
  """
  @callback generate_embeddings(tenant_id :: Ecto.UUID.t(), texts :: [String.t()]) ::
              {:ok, [[float()]]} | {:error, :no_api_key} | {:error, term()}
end
