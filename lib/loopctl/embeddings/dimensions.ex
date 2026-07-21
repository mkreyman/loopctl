defmodule Loopctl.Embeddings.Dimensions do
  @moduledoc """
  US-41.1 AC-41.1.4 / AC-41.1.11 — the STATIC model-to-dimension table and the
  PURE vector-length validator.

  ## Why static, and why v1

  A tenant's embedding dimension is a property of the model it embeds with. This
  table is the v1 derivation: given `tenant_llm_settings.embedding_model`, what
  vector length will that model return? It is deliberately a compile-time constant
  map — no network call, no Repo read — so it can be consulted from a changeset,
  a migration and the discovery document alike.

  US-41.2 adds a config-time PROBE that calls the tenant's real endpoint and
  RECONCILES with (and overrides) this table when the endpoint reports a different
  dimension; the probed value is then persisted on
  `tenants.tenant_embedding_dimension`, which always wins over this table. This
  table is the fallback for a tenant that has named a model but never been probed.

  A model that is not in this table yields `nil` — the caller then falls back to
  the deployment default `:embedding_dimensions` (1536), preserving the existing
  config semantics exactly.

  ## The validator is PURE (AC-41.1.11)

  `validate_vector_length/3` takes the expected dimension as an ARGUMENT. The
  pre-41.1 validators read `Application.get_env(:loopctl, :embedding_dimensions)`
  inside the changeset; a per-tenant dimension read that way would need a Repo
  lookup per changeset, turning the ~100-article batch embedding path (US-37.4)
  into an N+1. The dimension is instead resolved ONCE per operation/batch by
  `Loopctl.Embeddings.active_dimension/1` and threaded in.
  """

  import Ecto.Changeset

  # Model id (lowercased, provider prefix and `:tag` suffix stripped) => native
  # output dimension. Sources: OpenAI embeddings docs, Nomic model card, BAAI BGE
  # model cards, mixedbread mxbai-embed-large, Snowflake arctic-embed.
  @model_dimensions %{
    # OpenAI
    "text-embedding-3-small" => 1536,
    # NOTE: 3072 is above pgvector's 2000-dimension hnsw ceiling, so it is NOT in
    # `:supported_embedding_dimensions`. Mapped here anyway so the US-41.2 probe can
    # reject it with the real number instead of an unhelpful "unknown model".
    "text-embedding-3-large" => 3072,
    "text-embedding-ada-002" => 1536,
    # Nomic (Ollama-hosted local default)
    "nomic-embed-text" => 768,
    "nomic-embed-text-v1" => 768,
    "nomic-embed-text-v1.5" => 768,
    # BAAI BGE
    "bge-m3" => 1024,
    "bge-large-en" => 1024,
    "bge-large-en-v1.5" => 1024,
    "bge-base-en" => 768,
    "bge-base-en-v1.5" => 768,
    # mixedbread / Snowflake
    "mxbai-embed-large" => 1024,
    "snowflake-arctic-embed" => 1024,
    "snowflake-arctic-embed-l" => 1024
  }

  @doc "The full static model-to-dimension table."
  @spec model_dimensions() :: %{String.t() => pos_integer()}
  def model_dimensions, do: @model_dimensions

  @doc """
  The native dimension for `model`, or `nil` when the model is unknown.

  Normalizes the common id shapes an operator actually types: a provider prefix
  (`"ollama/nomic-embed-text"`), an Ollama tag (`"nomic-embed-text:latest"`), a
  HuggingFace org prefix (`"BAAI/bge-m3"`) and casing.
  """
  @spec for_model(String.t() | nil) :: pos_integer() | nil
  def for_model(nil), do: nil

  def for_model(model) when is_binary(model) do
    Map.get(@model_dimensions, normalize_model(model))
  end

  defp normalize_model(model) do
    model
    |> String.trim()
    |> String.downcase()
    |> String.split("/")
    |> List.last()
    |> String.split(":")
    |> List.first()
  end

  @doc """
  Validates that `field`'s vector has exactly `expected` components.

  PURE: `expected` is an argument, never a config or Repo read. The error names
  BOTH values (AC-41.1.4 / TC-41.1.4) — `expected` and `actual` — so an agent
  reading the 422 body can tell what its endpoint returned versus what the tenant
  is recorded at, and nothing is truncated or silently stored.

  Accepts either a `%Pgvector{}` (a value loaded from the DB) or a plain list (a
  freshly-computed embedding); a `nil` change is a no-op.
  """
  @spec validate_vector_length(Ecto.Changeset.t(), atom(), pos_integer()) :: Ecto.Changeset.t()
  def validate_vector_length(changeset, field, expected) when is_integer(expected) do
    case vector_length(get_change(changeset, field)) do
      nil ->
        changeset

      ^expected ->
        changeset

      actual ->
        add_error(
          changeset,
          field,
          "dimension mismatch: expected %{expected}, got %{actual}",
          expected: expected,
          actual: actual
        )
    end
  end

  @doc """
  The component count of an embedding value (`%Pgvector{}` or list), or `nil` when
  the value is absent / not a vector.
  """
  @spec vector_length(term()) :: non_neg_integer() | nil
  def vector_length(nil), do: nil
  def vector_length(%Pgvector{} = vector), do: length(Pgvector.to_list(vector))
  def vector_length(value) when is_list(value), do: length(value)
  def vector_length(_), do: nil
end
