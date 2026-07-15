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
  Batch variant: embeds a LIST of texts in ONE provider round-trip (US-37.4).

  OpenAI-compatible `/embeddings` accepts `input` as an array and returns a `data`
  array whose entries each carry an `index` field. Implementations MUST map every
  returned vector back to its input BY that `index` (never by array position), and
  return the vectors in the SAME order as the input `texts` — so the caller can zip
  `Enum.zip(texts, vectors)` safely.

  Used ONLY on the truly-bulk background ingest path (one admission token + one
  concurrency slot per batch). The interactive single-query path stays on
  `generate_embedding/2` (latency-sensitive, one text per call).

  A partial provider response (fewer/mismatched indices than inputs) MUST fail the
  whole batch (`{:error, _}`) rather than silently returning a short/misaligned
  list — the caller retries/fails the batch as a unit (no half-written vectors).

  An empty input list returns `{:ok, []}` WITHOUT a provider call (no token spent).
  """
  @callback generate_embeddings(tenant_id :: Ecto.UUID.t(), texts :: [String.t()]) ::
              {:ok, [[float()]]} | {:error, :no_api_key} | {:error, term()}
end
