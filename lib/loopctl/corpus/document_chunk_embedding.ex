defmodule Loopctl.Corpus.DocumentChunkEmbedding do
  @moduledoc """
  US-43.1 — a DIMENSION-TAGGED vector for a `Loopctl.Corpus.DocumentChunk`.

  Mirrors `Loopctl.Knowledge.ArticleEmbedding` in shape and constraint set on
  purpose: an UNCONSTRAINED `vector` column paired with an explicit `dim`
  discriminator, a `vector_dims(embedding) = dim` CHECK the database enforces even
  against a write that bypasses this changeset, and the column names `tenant_id`,
  `dim`, `embedding` and `live_denorm` — which are what let the
  schema-parameterized query builder
  `Loopctl.Knowledge.VectorSearch.index_safe_dimension_knn_base/6` be reused
  unchanged by US-43.2's search.

  ## `live_denorm` is load-bearing AND deliberately inert

  It carries NO trigger here and is never written false: a document chunk has no
  supersession state, so the PL/pgSQL trigger pair `article_embeddings` needs has
  nothing to mirror. The COLUMN is still required —
  `Loopctl.Repo.HnswIndex.create_dimension_index_sql/2` emits
  `WHERE dim = N AND live_denorm`, and the query builder adds the matching
  predicate — so removing it as dead code would fork both the shared index SQL and
  the shared query builder.

  ## `expected_dimension` comes from the CORPUS ROW

  It is passed IN, like `ArticleEmbedding`'s, so this validator stays PURE. Unlike
  `ArticleEmbedding`'s, its source is the corpus's own pinned `dim` — never a
  per-tenant resolver, which would return the tenant's ARTICLE dimension for a
  document corpus and, on the write-resolving variant, pin the tenant's article
  corpus to the local document model as a side effect.
  """

  use Loopctl.Schema

  import Ecto.Changeset

  alias Loopctl.Corpus.DocumentChunk
  alias Loopctl.Embeddings.Dimensions

  @type t :: %__MODULE__{}

  schema "document_chunk_embeddings" do
    tenant_field()

    field :dim, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :live_denorm, :boolean, default: true
    field :embedding_content_hash, :string

    belongs_to :document_chunk, DocumentChunk

    timestamps()
  end

  @doc """
  Changeset for a chunk embedding row.

  `tenant_id` is NEVER cast — the caller sets it on the struct. `dim` is FORCED to
  `expected_dimension` (the corpus's pinned dimension) so a caller cannot store a
  vector under a dimension tag its corpus does not use.
  """
  @spec changeset(t(), map(), pos_integer()) :: Ecto.Changeset.t()
  def changeset(row, attrs, expected_dimension) when is_integer(expected_dimension) do
    row
    |> cast(attrs, [:document_chunk_id, :embedding, :embedding_content_hash])
    |> put_change(:dim, expected_dimension)
    |> validate_required([:document_chunk_id, :dim, :embedding])
    |> Dimensions.validate_vector_length(:embedding, expected_dimension)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:document_chunk_id)
    |> unique_constraint([:tenant_id, :document_chunk_id, :dim],
      name: :document_chunk_embeddings_tenant_chunk_dim_index
    )
    |> check_constraint(:embedding,
      name: :document_chunk_embeddings_dim_matches_vector,
      message: "vector length must equal dim"
    )
  end
end
