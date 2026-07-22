defmodule Loopctl.Memory.MemoryEmbedding do
  @moduledoc """
  US-41.1 — a DIMENSION-TAGGED agent-memory embedding row.

  The memory-side twin of `Loopctl.Knowledge.ArticleEmbedding`. See that module
  for the side-table rationale.

  ## `subject_id` is DENORMALIZED here on purpose

  `Loopctl.HeavyRead.guard_memory!/3` requires an OUTERMOST
  `x.subject_id == ^subject_id` equality on the query's primary output binding,
  and the index-safe ANN inner must NOT join `memories` (a join inside the
  index-ordered top-k is the #172 planner incident). Carrying `subject_id` on the
  embedding row is what lets the recall query satisfy the guard without a join
  (AC-41.1.6).

  ## `live_denorm`

  Mirrors `memories.superseded_by IS NULL` — the exact predicate US-28.2's partial
  HNSW index carries (migration `20260709000300`). Synced by the
  `memory_embeddings_live_denorm_trg` / `memories_live_denorm_propagate_trg`
  PL/pgSQL trigger pair; application writes are a convenience only.
  """

  use Loopctl.Schema

  import Ecto.Changeset

  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Memory.Memory

  @type t :: %__MODULE__{}

  schema "memory_embeddings" do
    tenant_field()

    field :subject_id, :string
    field :dim, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :live_denorm, :boolean, default: true
    field :embedding_content_hash, :string

    belongs_to :memory, Memory

    timestamps()
  end

  @doc """
  Changeset for a memory embedding row.

  `tenant_id` is never cast (set programmatically). `expected_dimension` is passed
  IN by the caller — resolved once per operation/batch — so the validator stays
  pure (AC-41.1.11).
  """
  @spec changeset(t(), map(), pos_integer()) :: Ecto.Changeset.t()
  def changeset(embedding_row, attrs, expected_dimension) when is_integer(expected_dimension) do
    embedding_row
    |> cast(attrs, [:memory_id, :subject_id, :dim, :embedding, :embedding_content_hash])
    |> put_change(:dim, expected_dimension)
    |> validate_required([:memory_id, :subject_id, :dim, :embedding])
    |> Dimensions.validate_vector_length(:embedding, expected_dimension)
    |> foreign_key_constraint(:memory_id)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :memory_id, :dim],
      name: :memory_embeddings_tenant_memory_dim_index
    )
    |> check_constraint(:embedding,
      name: :memory_embeddings_dim_matches_vector,
      message: "vector length must equal dim"
    )
  end

  @doc "The live-row predicate for a memory: `superseded_by IS NULL`."
  @spec live?(Memory.t() | nil) :: boolean()
  def live?(%Memory{superseded_by: nil}), do: true
  def live?(%Memory{}), do: false
  def live?(nil), do: false
end
